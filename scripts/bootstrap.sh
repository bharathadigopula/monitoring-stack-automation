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
grafana_admin_password="${7:-}"

#==============================================================================
# REPOSITORY VALIDATION
#==============================================================================

if [[ ! "$automation_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'A GitHub owner/repository value is required.\n' >&2
  exit 1
fi

#==============================================================================
# RELEASE VALIDATION
#==============================================================================

if [[ ! "$automation_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'An immutable semantic version tag is required.\n' >&2
  exit 1
fi

#==============================================================================
# DEPLOYMENT PRIVILEGES
#==============================================================================

if [[ "$action" == "deploy" ]]; then
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true; then
    printf 'Deployment requires non-interactive sudo access.\n' >&2
    exit 1
  fi
fi

#==============================================================================
# VERSIONED SOURCE DOWNLOAD
#==============================================================================

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
archive_url="https://github.com/$automation_repository/archive/refs/tags/$automation_ref.tar.gz"
curl --fail --location --silent --show-error "$archive_url" --output "$temporary_directory/automation.tar.gz"
mkdir "$temporary_directory/source"
tar --extract --gzip --file "$temporary_directory/automation.tar.gz" \
  --directory "$temporary_directory/source" --strip-components=1

#==============================================================================
# VERSIONED AUTOMATION EXECUTION
#==============================================================================

if [[ "$action" == "deploy" ]]; then
  sudo -n bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  sudo -n env \
    AUTOMATION_REF="$automation_ref" \
    GRAFANA_DOMAIN="$grafana_domain" \
    GRAFANA_ROOT_URL="$grafana_root_url" \
    MONITORING_BIND_ADDRESS="$bind_address" \
    bash "$temporary_directory/source/scripts/manage.sh" "$action" "$grafana_admin_password"
else
  bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  AUTOMATION_REF="$automation_ref" \
  GRAFANA_DOMAIN="$grafana_domain" \
  GRAFANA_ROOT_URL="$grafana_root_url" \
  MONITORING_BIND_ADDRESS="$bind_address" \
    bash "$temporary_directory/source/scripts/manage.sh" "$action" "$grafana_admin_password"
fi