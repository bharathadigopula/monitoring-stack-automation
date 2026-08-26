#!/usr/bin/env bash

#==============================================================================
# MONITORING STACK LIFECYCLE
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# LIFECYCLE INPUTS
#==============================================================================

action="${1:-validate}"
grafana_admin_password="${2:-}"
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
install_root="${MONITORING_INSTALL_ROOT:-/opt/monitoring-stack}"
release_ref="${AUTOMATION_REF:-local}"
release_key=${release_ref//[^a-zA-Z0-9._-]/-}
release_path="$install_root/releases/$release_key"
backup_directory="${MONITORING_BACKUP_DIRECTORY:-/var/backups/monitoring-stack}"

#==============================================================================
# STACK VALIDATION
#==============================================================================

validate_stack() {
  bash "$source_root/scripts/validate.sh"
}

#==============================================================================
# ROOT PRIVILEGE VALIDATION
#==============================================================================

require_root() {
  if (( EUID != 0 )); then
    printf '%s must run as root.\n' "$action" >&2
    exit 1
  fi
}

#==============================================================================
# RELEASE ENVIRONMENT
#==============================================================================

write_environment() {
  cat > "$release_path/.env" <<EOF
GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER:-admin}
GRAFANA_ADMIN_PASSWORD_FILE=./secrets/grafana-admin-password
GRAFANA_DOMAIN=${GRAFANA_DOMAIN:-localhost}
GRAFANA_ROOT_URL=${GRAFANA_ROOT_URL:-http://localhost:3000}
MONITORING_BIND_ADDRESS=${MONITORING_BIND_ADDRESS:-127.0.0.1}
PROMETHEUS_RETENTION_SIZE=${PROMETHEUS_RETENTION_SIZE:-8GB}
PROMETHEUS_RETENTION_TIME=${PROMETHEUS_RETENTION_TIME:-7d}
EOF
  chmod 0600 "$release_path/.env"
}

#==============================================================================
# STACK DEPLOYMENT
#==============================================================================

deploy_stack() {
  require_root
  if [[ -z "$grafana_admin_password" || "$grafana_admin_password" == *$'\n'* ]]; then
    printf 'A single-line Grafana administrator password is required.\n' >&2
    exit 1
  fi

  validate_stack
  docker compose version >/dev/null
  install -d -m 0755 "$install_root/releases"
  rm -rf "$release_path"
  install -d -m 0755 "$release_path"
  cp -a "$source_root/." "$release_path/"
  install -d -m 0700 "$release_path/secrets"
  printf '%s\n' "$grafana_admin_password" > "$release_path/secrets/grafana-admin-password"
  chown 472:472 "$release_path/secrets/grafana-admin-password"
  chmod 0400 "$release_path/secrets/grafana-admin-password"
  write_environment

  if [[ -L "$install_root/current" ]]; then
    ln -sfn "$(readlink -f "$install_root/current")" "$install_root/previous"
  fi

  ln -sfn "$release_path" "$install_root/current"
  install -m 0644 "$release_path/systemd/monitoring-stack.service" /etc/systemd/system/monitoring-stack.service
  systemctl daemon-reload
  systemctl enable --now monitoring-stack.service
  verify_stack
  printf 'monitoring_deploy=ready\n'
}

#==============================================================================
# STACK HEALTH VERIFICATION
#==============================================================================

wait_for_endpoint() {
  local service_name="$1"
  local endpoint="$2"
  local attempt

  for (( attempt = 1; attempt <= 60; attempt++ )); do
    if curl --fail --silent --show-error "$endpoint" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  printf '%s did not become ready at %s.\n' "$service_name" "$endpoint" >&2
  docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps >&2 || true
  return 1
}

verify_stack() {
  wait_for_endpoint prometheus http://127.0.0.1:9090/-/ready
  wait_for_endpoint grafana http://127.0.0.1:3000/api/health
  printf 'monitoring_verify=ready\n'
}

#==============================================================================
# STACK STATUS DIAGNOSTICS
#==============================================================================

show_stack_status() {
  printf 'systemd_state=%s\n' "$(systemctl is-active monitoring-stack.service 2>/dev/null || true)"
  docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps --all || true
  docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    logs --tail 20 || true
  printf 'prometheus_http_code=%s\n' "$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:9090/-/ready || true)"
  printf 'grafana_http_code=%s\n' "$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:3000/api/health || true)"
  printf 'monitoring_status=ready\n'
}

#==============================================================================
# GRAFANA BACKUP
#==============================================================================

backup_stack() {
  require_root
  install -d -m 0700 "$backup_directory"
  archive_path="$backup_directory/grafana-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  volume_path=$(docker volume inspect monitoring-stack_grafana-data --format '{{ .Mountpoint }}')
  systemctl stop monitoring-stack.service
  trap 'systemctl start monitoring-stack.service' EXIT
  tar --create --gzip --file "$archive_path" --directory "$volume_path" .
  chmod 0600 "$archive_path"
  systemctl start monitoring-stack.service
  trap - EXIT
  printf 'monitoring_backup=%s\n' "$archive_path"
}

#==============================================================================
# GRAFANA RESTORE
#==============================================================================

restore_stack() {
  require_root
  archive_path="${MONITORING_RESTORE_ARCHIVE:-}"
  if [[ ! -f "$archive_path" ]]; then
    printf 'MONITORING_RESTORE_ARCHIVE must identify an existing backup.\n' >&2
    exit 1
  fi
  volume_path=$(docker volume inspect monitoring-stack_grafana-data --format '{{ .Mountpoint }}')
  systemctl stop monitoring-stack.service
  trap 'systemctl start monitoring-stack.service' EXIT
  find "$volume_path" -mindepth 1 -delete
  tar --extract --gzip --file "$archive_path" --directory "$volume_path"
  systemctl start monitoring-stack.service
  trap - EXIT
  verify_stack
  printf 'monitoring_restore=ready\n'
}

#==============================================================================
# RELEASE ROLLBACK
#==============================================================================

rollback_stack() {
  require_root
  if [[ ! -L "$install_root/previous" ]]; then
    printf 'No previous monitoring release is available.\n' >&2
    exit 1
  fi
  previous_release=$(readlink -f "$install_root/previous")
  current_release=$(readlink -f "$install_root/current")
  ln -sfn "$previous_release" "$install_root/current"
  ln -sfn "$current_release" "$install_root/previous"
  systemctl restart monitoring-stack.service
  verify_stack
  printf 'monitoring_rollback=ready\n'
}

#==============================================================================
# ACTION ROUTING
#==============================================================================

case "$action" in
  validate)
    validate_stack
    ;;
  dry-run)
    validate_stack
    printf 'Would deploy release %s to %s.\n' "$release_ref" "$release_path"
    printf 'monitoring_dry_run=ready\n'
    ;;
  deploy|upgrade)
    deploy_stack
    ;;
  verify)
    verify_stack
    ;;
  status)
    show_stack_status
    ;;
  backup)
    backup_stack
    ;;
  restore)
    restore_stack
    ;;
  rollback)
    rollback_stack
    ;;
  *)
    printf 'Usage: %s validate|dry-run|deploy|upgrade|verify|status|backup|restore|rollback [grafana-password]\n' "$0" >&2
    exit 2
    ;;
esac