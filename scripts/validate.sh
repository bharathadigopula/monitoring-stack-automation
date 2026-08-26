#!/usr/bin/env bash

#==============================================================================
# MONITORING STACK VALIDATION
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# REPOSITORY PATHS
#==============================================================================

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

#==============================================================================
# REQUIRED FILES
#==============================================================================

required_files=(
  compose.yaml
  config/prometheus/prometheus.yml
  config/prometheus/rules/monitoring.rules.yml
  config/prometheus/targets/cloudflared.json
  config/prometheus/targets/jenkins.json
  config/grafana/provisioning/datasources/datasource.yml
  config/grafana/provisioning/dashboards/default.yml
  dashboards/monitoring-health.json
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$repository_root/$required_file" ]]; then
    printf 'Missing required file: %s\n' "$required_file" >&2
    exit 1
  fi
done

#==============================================================================
# CONTAINER IMAGE VALIDATION
#==============================================================================

if grep -R --line-number --extended-regexp 'image:[[:space:]]+[^[:space:]]+:latest([[:space:]]|$)' \
  "$repository_root/compose.yaml"; then
  printf 'Container images must use pinned version tags.\n' >&2
  exit 1
fi

#==============================================================================
# PROMETHEUS TARGET VALIDATION
#==============================================================================

for target_file in "$repository_root"/config/prometheus/targets/*.json; do
  jq -e '
    type == "array" and
    all(.[ ];
      type == "object" and
      (.targets | type == "array") and
      (.labels | type == "object")
    )
  ' "$target_file" >/dev/null
done

#==============================================================================
# GRAFANA DASHBOARD VALIDATION
#==============================================================================

dashboard_count=0
while IFS= read -r dashboard_file; do
  jq -e '
    type == "object" and
    (.uid | type == "string" and length > 0) and
    (.title | type == "string" and length > 0) and
    (.panels | type == "array")
  ' "$dashboard_file" >/dev/null
  dashboard_count=$((dashboard_count + 1))
done < <(find "$repository_root/dashboards" -type f -name '*.json' -print)

if (( dashboard_count == 0 )); then
  printf 'At least one Grafana dashboard is required.\n' >&2
  exit 1
fi

#==============================================================================
# DOCKER COMPOSE VALIDATION
#==============================================================================

if docker compose version >/dev/null 2>&1; then
  temporary_secret=$(mktemp)
  trap 'rm -f "$temporary_secret"' EXIT
  printf 'validation-only\n' > "$temporary_secret"
  GRAFANA_ADMIN_PASSWORD_FILE="$temporary_secret" docker compose \
    --file "$repository_root/compose.yaml" config --quiet
fi

  #==============================================================================
  # VALIDATION RESULT
  #==============================================================================

printf 'monitoring_validation=ready\n'