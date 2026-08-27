#!/usr/bin/env bash

#==============================================================================
# VERSIONED MONITORING BOOTSTRAP
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# BOOTSTRAP INPUTS
#==============================================================================

action="${1:-validate}"
automation_repository="${2:-}"
automation_ref="${3:-}"
grafana_domain="${4:-localhost}"
grafana_root_url="${5:-http://localhost:3000}"
bind_address="${6:-127.0.0.1}"
restore_archive="${7:-}"
grafana_admin_password="${8:-}"
smtp_app_password="${9:-}"

#==============================================================================
# ACTION VALIDATION
#==============================================================================

case "$action" in
  validate|dry-run|deploy|verify|status|backup|restore|rollback|test-alert) ;;
  *) printf 'Invalid action.\n' >&2; exit 2 ;;
esac

#==============================================================================
# REPOSITORY VALIDATION
#==============================================================================

if [[ ! "$automation_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'Invalid repository.\n' >&2
  exit 1
fi

#==============================================================================
# RELEASE VALIDATION
#==============================================================================

if [[ ! "$automation_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Invalid release.\n' >&2
  exit 1
fi

#==============================================================================
# DEPLOYMENT PRIVILEGES
#==============================================================================

if [[ "$action" =~ ^(deploy|verify|status|backup|restore|rollback|test-alert)$ ]] && { ! command -v sudo >/dev/null 2>&1 || ! sudo -n true; }; then
  printf 'Non-interactive sudo is required.\n' >&2
  exit 1
fi

#==============================================================================
# VERSIONED SOURCE DOWNLOAD
#==============================================================================

temporary_root=$(mktemp -d)
trap 'rm -rf "$temporary_root"' EXIT
curl --fail --location --silent --show-error \
  "https://github.com/$automation_repository/archive/refs/tags/$automation_ref.tar.gz" \
  --output "$temporary_root/source.tar.gz"
mkdir "$temporary_root/source"
tar --extract --gzip --file "$temporary_root/source.tar.gz" --directory "$temporary_root/source" --strip-components=1

#==============================================================================
# VERSIONED AUTOMATION EXECUTION
#==============================================================================

run_env=(
  "AUTOMATION_REF=$automation_ref"
  "GRAFANA_DOMAIN=$grafana_domain"
  "GRAFANA_ROOT_URL=$grafana_root_url"
  "MONITORING_BIND_ADDRESS=$bind_address"
  "MONITORING_RESTORE_ARCHIVE=$restore_archive"
)
source_root="$temporary_root/source"
manage_script="$source_root/scripts/manage.sh"

if [[ "$action" == "deploy" ]]; then
  sudo -n bash "$source_root/scripts/install-docker.sh" "$action"
  sudo -n env "${run_env[@]}" bash "$manage_script" "$action" "$grafana_admin_password" "$smtp_app_password"
elif [[ "$action" =~ ^(verify|status|backup|restore|rollback|test-alert)$ ]]; then
  sudo -n env "${run_env[@]}" bash "$manage_script" "$action"
else
  bash "$source_root/scripts/install-docker.sh" "$action"
  env "${run_env[@]}" bash "$manage_script" "$action" "$grafana_admin_password" "$smtp_app_password"
fi