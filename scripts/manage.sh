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
smtp_app_password="${3:-}"
jenkins_secret_bundle="${4:-}"
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
# ALERTMANAGER SECRET RENDERING
#==============================================================================

render_alertmanager_configuration() {
  local configuration_file="$release_path/config/alertmanager/alertmanager.yml.template"

  if [[ ! "$smtp_app_password" =~ ^[A-Za-z0-9]{16}$ ]]; then
    printf 'A 16-character Gmail app password is required.\n' >&2
    exit 1
  fi

  sed --in-place "s/__SMTP_APP_PASSWORD__/$smtp_app_password/" "$configuration_file"
  if grep -Fq '__SMTP_APP_PASSWORD__' "$configuration_file"; then
    printf 'Alertmanager SMTP configuration was not rendered.\n' >&2
    exit 1
  fi
  chown 65534:65534 "$configuration_file"
  chmod 0400 "$configuration_file"
}

#==============================================================================
# JENKINS METRICS SECRET RENDERING
#==============================================================================

render_jenkins_metrics_secret() {
  local password_file="$release_path/secrets/jenkins-admin-password"

  if ! jq -e '
    type == "object" and
    (.admin_password | type == "string" and length >= 16 and (contains("\n") | not))
  ' <<< "$jenkins_secret_bundle" >/dev/null; then
    printf 'Jenkins secret bundle must contain a valid admin_password.\n' >&2
    exit 1
  fi

  jq -r '.admin_password' <<< "$jenkins_secret_bundle" > "$password_file"
  chown 65534:65534 "$password_file"
  chmod 0400 "$password_file"
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
  if [[ ! "$smtp_app_password" =~ ^[A-Za-z0-9]{16}$ ]]; then
    printf 'A 16-character Gmail app password is required.\n' >&2
    exit 1
  fi
  if ! jq -e '
    type == "object" and
    (.admin_password | type == "string" and length >= 16 and (contains("\n") | not))
  ' <<< "$jenkins_secret_bundle" >/dev/null; then
    printf 'Jenkins secret bundle must contain a valid admin_password.\n' >&2
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
  render_alertmanager_configuration
  render_jenkins_metrics_secret
  write_environment

  if [[ -L "$install_root/current" ]]; then
    ln -sfn "$(readlink -f "$install_root/current")" "$install_root/previous"
  fi

  ln -sfn "$release_path" "$install_root/current"
  install -m 0644 "$release_path/systemd/monitoring-stack.service" /etc/systemd/system/monitoring-stack.service
  install -m 0644 "$release_path/systemd/monitoring-stack-backup.service" /etc/systemd/system/monitoring-stack-backup.service
  install -m 0644 "$release_path/systemd/monitoring-stack-backup.timer" /etc/systemd/system/monitoring-stack-backup.timer
  systemctl daemon-reload
  systemctl enable monitoring-stack.service
  systemctl restart monitoring-stack.service
  systemctl enable --now monitoring-stack-backup.timer
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

verify_prometheus_query() {
  local check_name="$1"
  local expression="$2"
  local minimum_results="$3"
  local report_failure="${4:-true}"
  local response

  response=$(curl --fail --silent --show-error --get \
    --data-urlencode "query=$expression" \
    http://127.0.0.1:9090/api/v1/query)
  if ! jq -e --argjson minimum_results "$minimum_results" '
    .status == "success" and (.data.result | length) >= $minimum_results
  ' <<< "$response" >/dev/null; then
    if [[ "$report_failure" == "true" ]]; then
      printf 'Prometheus verification failed: %s.\n' "$check_name" >&2
    fi
    return 1
  fi

  printf '%s=ready\n' "$check_name"
}

wait_for_prometheus_query() {
  local check_name="$1"
  local expression="$2"
  local minimum_results="$3"
  local attempt

  for (( attempt = 1; attempt <= 30; attempt++ )); do
    if verify_prometheus_query "$check_name" "$expression" "$minimum_results" false; then
      return 0
    fi
    sleep 2
  done

  verify_prometheus_query "$check_name" "$expression" "$minimum_results"
}

#==============================================================================
# CLOUDFLARED NETWORK DIAGNOSTICS
#==============================================================================

show_cloudflared_network_status() {
  local target
  local target_host

  target=$(jq -r '.[0].targets[0] // empty' "$install_root/current/config/prometheus/targets/cloudflared.json")
  target_host=${target%:*}
  if [[ -z "$target_host" ]]; then
    printf 'cloudflared_target=missing\n' >&2
    return
  fi

  printf 'cloudflared_host_probe=%s\n' "$(curl --connect-timeout 3 --max-time 5 --silent --output /dev/null --write-out 'http_code=%{http_code},error=%{errormsg}' "http://$target/metrics" 2>/dev/null || true)" >&2
  printf 'cloudflared_host_route=%s\n' "$(ip -4 route get "$target_host" 2>&1 | head -n 1)" >&2
  printf 'monitoring_docker_subnet=%s\n' "$(docker network inspect monitoring-stack_default --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)" >&2
}

verify_prometheus_targets() {
  local report_failure="${1:-true}"
  local response

  response=$(curl --fail --silent --show-error http://127.0.0.1:9090/api/v1/targets)
  if ! jq -e '
    .status == "success" and
    (["alertmanager", "blackbox-exporter", "cadvisor", "cloudflared", "grafana", "jenkins", "node", "prometheus"] -
      ([.data.activeTargets[].labels.job] | unique) | length) == 0 and
    ([
      .data.activeTargets[] |
      select(.labels.job | test("^(prometheus|node|cadvisor|grafana|alertmanager|blackbox-exporter|cloudflared|jenkins)$")) |
      select(.health != "up")
    ] | length) == 0
  ' <<< "$response" >/dev/null; then
    if [[ "$report_failure" != "true" ]]; then
      return 1
    fi
    printf 'Prometheus target verification failed.\n' >&2
    jq -r '
      [.data.activeTargets[].labels.job] | unique | "prometheus_target_jobs=" + join(",")
    ' <<< "$response" >&2
    jq -r '
      .data.activeTargets[] |
      select(.labels.job | test("^(prometheus|node|cadvisor|grafana|alertmanager|blackbox-exporter|cloudflared|jenkins)$")) |
      select(.health != "up") |
      "prometheus_target_failure=" + .labels.job + "/" + .labels.instance + ":" + .health + ":" +
      (.lastError | gsub("[\\r\\n]"; " "))
    ' <<< "$response" >&2
    if jq -e '.data.activeTargets[] | select(.labels.job == "cloudflared" and .health != "up")' <<< "$response" >/dev/null; then
      show_cloudflared_network_status
    fi
    return 1
  fi

  printf 'prometheus_targets=ready\n'
}

wait_for_prometheus_targets() {
  local attempt

  for (( attempt = 1; attempt <= 30; attempt++ )); do
    if verify_prometheus_targets false; then
      return 0
    fi
    sleep 2
  done

  verify_prometheus_targets
}

verify_stack() {
  local running_services
  local dashboard_count
  local rules

  wait_for_endpoint prometheus http://127.0.0.1:9090/-/ready
  wait_for_endpoint alertmanager http://127.0.0.1:9093/-/ready
  wait_for_endpoint blackbox-exporter http://127.0.0.1:9115/-/healthy
  wait_for_endpoint grafana "http://${MONITORING_BIND_ADDRESS:-127.0.0.1}:3000/api/health"

  running_services=$(docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps --services --status running | wc -l | tr -d ' ')
  if (( running_services != 6 )); then
    printf 'Expected six running monitoring services, found %s.\n' "$running_services" >&2
    return 1
  fi
  printf 'monitoring_services=ready\n'

  wait_for_prometheus_targets
  wait_for_prometheus_query external_probes 'probe_success{job="blackbox"} == 1' 3
  wait_for_prometheus_query cloudflared_connections 'cloudflared_tunnel_ha_connections > 0' 1
  wait_for_prometheus_query jenkins_controller 'default_jenkins_up{job="jenkins"} == 1' 1
  wait_for_prometheus_query alertmanager_discovery 'prometheus_notifications_alertmanagers_discovered > 0' 1

  rules=$(curl --fail --silent --show-error http://127.0.0.1:9090/api/v1/rules)
  if ! jq -e '
    .status == "success" and
    ([.data.groups[].rules[]] | length) > 0 and
    ([.data.groups[].rules[] | select(.health != "ok")] | length) == 0
  ' <<< "$rules" >/dev/null; then
    printf 'One or more Prometheus rules are unhealthy.\n' >&2
    return 1
  fi
  printf 'prometheus_rules=ready\n'

  curl --fail --silent --show-error http://127.0.0.1:9093/api/v2/status >/dev/null
  printf 'alertmanager_status=ready\n'

  dashboard_count=$(find "$install_root/current/dashboards" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  if (( dashboard_count != 8 )); then
    printf 'Expected eight provisioned dashboards, found %s.\n' "$dashboard_count" >&2
    return 1
  fi
  printf 'grafana_dashboards=ready\n'

  systemctl is-enabled --quiet monitoring-stack-backup.timer
  systemctl is-active --quiet monitoring-stack-backup.timer
  printf 'monitoring_backup_timer=ready\n'
  printf 'monitoring_verify=ready\n'
}

#==============================================================================
# STACK STATUS DIAGNOSTICS
#==============================================================================

show_stack_status() {
  printf 'systemd_state=%s\n' "$(systemctl is-active monitoring-stack.service 2>/dev/null || true)"
  printf 'monitoring_status=ready\n'
  docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps --all || true
  docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    logs --tail 20 || true
  printf 'prometheus_http_code=%s\n' "$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:9090/-/ready || true)"
  printf 'alertmanager_http_code=%s\n' "$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:9093/-/ready || true)"
  printf 'blackbox_http_code=%s\n' "$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:9115/-/healthy || true)"
  printf 'grafana_http_code=%s\n' "$(curl --silent --output /dev/null --write-out '%{http_code}' "http://${MONITORING_BIND_ADDRESS:-127.0.0.1}:3000/api/health" || true)"
}

#==============================================================================
# MONITORING STATE BACKUP
#==============================================================================

backup_stack() {
  require_root
  install -d -m 0700 "$backup_directory"
  archive_path="$backup_directory/monitoring-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  staging_directory=$(mktemp -d "$backup_directory/.backup.XXXXXX")
  grafana_volume_path=$(docker volume inspect monitoring-stack_grafana-data --format '{{ .Mountpoint }}')
  prometheus_volume_path=$(docker volume inspect monitoring-stack_prometheus-data --format '{{ .Mountpoint }}')
  alertmanager_volume_path=$(docker volume inspect monitoring-stack_alertmanager-data --format '{{ .Mountpoint }}')

  backup_cleanup() {
    systemctl start monitoring-stack.service || true
    rm -rf "$staging_directory"
  }

  systemctl stop monitoring-stack.service
  trap backup_cleanup EXIT
  tar --create --gzip --file "$staging_directory/grafana.tar.gz" --directory "$grafana_volume_path" .
  tar --create --gzip --file "$staging_directory/prometheus.tar.gz" --directory "$prometheus_volume_path" .
  tar --create --gzip --file "$staging_directory/alertmanager.tar.gz" --directory "$alertmanager_volume_path" .
  printf 'release=%s\ncreated_at=%s\n' "$release_ref" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$staging_directory/manifest.txt"
  tar --create --gzip --file "$archive_path" --directory "$staging_directory" .
  chmod 0600 "$archive_path"
  systemctl start monitoring-stack.service
  rm -rf "$staging_directory"
  trap - EXIT
  find "$backup_directory" -maxdepth 1 -type f -name 'monitoring-*.tar.gz' -mtime +7 -delete
  printf 'monitoring_backup=%s\n' "$archive_path"
  printf 'monitoring_backup=ready\n'
}

#==============================================================================
# MONITORING STATE RESTORE
#==============================================================================

restore_stack() {
  require_root
  archive_path="${MONITORING_RESTORE_ARCHIVE:-}"
  if [[ ! -f "$archive_path" ]]; then
    printf 'MONITORING_RESTORE_ARCHIVE must identify an existing backup.\n' >&2
    exit 1
  fi
  staging_directory=$(mktemp -d "$backup_directory/.restore.XXXXXX")
  tar --extract --gzip --file "$archive_path" --directory "$staging_directory"
  for component in grafana prometheus alertmanager; do
    if [[ ! -f "$staging_directory/$component.tar.gz" ]]; then
      printf 'Backup archive is missing %s state.\n' "$component" >&2
      rm -rf "$staging_directory"
      exit 1
    fi
  done

  grafana_volume_path=$(docker volume inspect monitoring-stack_grafana-data --format '{{ .Mountpoint }}')
  prometheus_volume_path=$(docker volume inspect monitoring-stack_prometheus-data --format '{{ .Mountpoint }}')
  alertmanager_volume_path=$(docker volume inspect monitoring-stack_alertmanager-data --format '{{ .Mountpoint }}')

  restore_cleanup() {
    systemctl start monitoring-stack.service || true
    rm -rf "$staging_directory"
  }

  systemctl stop monitoring-stack.service
  trap restore_cleanup EXIT
  find "$grafana_volume_path" -mindepth 1 -delete
  find "$prometheus_volume_path" -mindepth 1 -delete
  find "$alertmanager_volume_path" -mindepth 1 -delete
  tar --extract --gzip --file "$staging_directory/grafana.tar.gz" --directory "$grafana_volume_path"
  tar --extract --gzip --file "$staging_directory/prometheus.tar.gz" --directory "$prometheus_volume_path"
  tar --extract --gzip --file "$staging_directory/alertmanager.tar.gz" --directory "$alertmanager_volume_path"
  systemctl start monitoring-stack.service
  rm -rf "$staging_directory"
  trap - EXIT
  verify_stack
  printf 'monitoring_restore=ready\n'
}

#==============================================================================
# ALERTMANAGER EMAIL DELIVERY TEST
#==============================================================================

email_notification_total() {
  local metric_name="$1"

  curl --fail --silent --show-error http://127.0.0.1:9093/metrics | awk -v metric_name="$metric_name" '
    $1 ~ ("^" metric_name "\\{") && $1 ~ /integration="email"/ { total += $2 }
    END { printf "%.0f", total + 0 }
  '
}

wait_for_email_notification() {
  local initial_total="$1"
  local initial_failures="$2"
  local phase="$3"
  local attempt
  local current_total
  local current_failures

  for (( attempt = 1; attempt <= 180; attempt++ )); do
    current_total=$(email_notification_total alertmanager_notifications_total)
    current_failures=$(email_notification_total alertmanager_notifications_failed_total)
    if (( current_failures > initial_failures )); then
      printf 'Alertmanager email notification failed during %s delivery.\n' "$phase" >&2
      return 1
    fi
    if (( current_total > initial_total )); then
      printf 'monitoring_test_alert_%s=ready\n' "$phase"
      return 0
    fi
    sleep 2
  done

  printf 'Alertmanager email notification timed out during %s delivery.\n' "$phase" >&2
  return 1
}

test_alert_delivery() {
  local initial_failures
  local initial_total
  local payload
  local resolved_total
  local starts_at

  wait_for_endpoint alertmanager http://127.0.0.1:9093/-/ready
  initial_total=$(email_notification_total alertmanager_notifications_total)
  initial_failures=$(email_notification_total alertmanager_notifications_failed_total)
  starts_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  payload=$(jq -cn --arg starts_at "$starts_at" --arg ends_at "$(date -u -d '+15 minutes' +%Y-%m-%dT%H:%M:%SZ)" '[{
    labels: {alertname: "MonitoringDeliveryTest", severity: "warning", instance: "monitoring-test", environment: "prd"},
    annotations: {summary: "Controlled monitoring email delivery test", description: "Generated by the managed monitoring lifecycle workflow."},
    startsAt: $starts_at,
    endsAt: $ends_at
  }]')
  curl --fail --silent --show-error \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    http://127.0.0.1:9093/api/v2/alerts >/dev/null
  wait_for_email_notification "$initial_total" "$initial_failures" firing

  resolved_total=$(email_notification_total alertmanager_notifications_total)
  payload=$(jq -cn --arg starts_at "$starts_at" --arg ends_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[{
    labels: {alertname: "MonitoringDeliveryTest", severity: "warning", instance: "monitoring-test", environment: "prd"},
    annotations: {summary: "Controlled monitoring email delivery test", description: "Generated by the managed monitoring lifecycle workflow."},
    startsAt: $starts_at,
    endsAt: $ends_at
  }]')
  curl --fail --silent --show-error \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    http://127.0.0.1:9093/api/v2/alerts >/dev/null
  wait_for_email_notification "$resolved_total" "$initial_failures" resolved
  printf 'monitoring_test_alert=ready\n'
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
  test-alert)
    test_alert_delivery
    ;;
  *)
    printf 'Usage: %s validate|dry-run|deploy|upgrade|verify|status|backup|restore|rollback|test-alert [grafana-password] [smtp-app-password]\n' "$0" >&2
    exit 2
    ;;
esac