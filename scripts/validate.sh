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
  config/alertmanager/alertmanager.yml.template
  config/blackbox/blackbox.yml
  config/prometheus/prometheus.yml
  config/prometheus/rules/monitoring.rules.yml
  config/prometheus/targets/blackbox.json
  config/prometheus/targets/cloudflared.json
  config/prometheus/targets/jenkins.json
  config/grafana/provisioning/datasources/datasource.yml
  config/grafana/provisioning/dashboards/default.yml
  dashboards/monitoring-health.json
  scripts/check-latest-versions.sh
  systemd/monitoring-stack-backup.service
  systemd/monitoring-stack-backup.timer
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

if ! jq -e '
  length == 1 and
  .[0].targets == ["10.10.10.68:8080"] and
  .[0].labels.service == "jenkins"
' "$repository_root/config/prometheus/targets/jenkins.json" >/dev/null; then
  printf 'Production Jenkins metrics target must be configured.\n' >&2
  exit 1
fi

if ! jq -e '
  ([.[].labels.service] | sort) == ["Cloudflare Access", "Grafana", "Jenkins origin"]
' "$repository_root/config/prometheus/targets/blackbox.json" >/dev/null; then
  printf 'Blackbox targets must use the expected service labels.\n' >&2
  exit 1
fi

if ! grep -Fq 'password_file: /run/secrets/jenkins-admin-password' \
  "$repository_root/config/prometheus/prometheus.yml" || \
  ! grep -Fq './secrets/jenkins-admin-password:/run/secrets/jenkins-admin-password:ro' \
    "$repository_root/compose.yaml"; then
  printf 'Jenkins metrics must use the mounted password file.\n' >&2
  exit 1
fi

#==============================================================================
# GRAFANA DASHBOARD VALIDATION
#==============================================================================

dashboard_count=0
while IFS= read -r dashboard_file; do
  jq -e '
    type == "object" and
    (.uid | type == "string" and length > 0) and
    (.title | type == "string" and length > 0) and
    (.panels | type == "array" and length > 0) and
    (all(.panels[];
      (.id | type == "number") and
      (.title | type == "string" and length > 0) and
      (.targets | type == "array" and length > 0) and
      all(.targets[]; .expr | type == "string" and length > 0)
    )) and
    (([.panels[].id] | unique | length) == (.panels | length))
  ' "$dashboard_file" >/dev/null
  dashboard_count=$((dashboard_count + 1))
done < <(find "$repository_root/dashboards" -type f -name '*.json' -print)

if (( dashboard_count == 0 )); then
  printf 'At least one Grafana dashboard is required.\n' >&2
  exit 1
fi

if ! jq -s -e '([.[].uid] | unique | length) == length' "$repository_root"/dashboards/*.json >/dev/null; then
  printf 'Grafana dashboard UIDs must be unique.\n' >&2
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
# COMPONENT CONFIGURATION VALIDATION
#==============================================================================

run_quietly() {
  local output_file
  output_file=$(mktemp)

  if ! "$@" > "$output_file" 2>&1; then
    cat "$output_file" >&2
    rm -f "$output_file"
    return 1
  fi

  rm -f "$output_file"
}

if docker version >/dev/null 2>&1; then
  run_quietly docker run --rm \
    --entrypoint /bin/promtool \
    --volume "$repository_root/config/prometheus:/etc/prometheus:ro" \
    prom/prometheus:v3.14.0 \
    check config /etc/prometheus/prometheus.yml

  run_quietly docker run --rm \
    --entrypoint /bin/amtool \
    --volume "$repository_root/config/alertmanager:/etc/alertmanager:ro" \
    prom/alertmanager:v0.34.0 \
    check-config /etc/alertmanager/alertmanager.yml.template

  run_quietly docker run --rm \
    --entrypoint /bin/blackbox_exporter \
    --volume "$repository_root/config/blackbox:/etc/blackbox_exporter:ro" \
    quay.io/prometheus/blackbox-exporter:v0.28.0 \
    --config.file=/etc/blackbox_exporter/blackbox.yml \
    --config.check
fi

#==============================================================================
# CONTROLLED ALERT ROUTE VALIDATION
#==============================================================================

controlled_alert_route=$'    - receiver: operations-email\n      matchers:\n        - alertname="MonitoringDeliveryTest"\n      group_wait: 5s\n      group_interval: 15s\n      repeat_interval: 4h'
if ! grep --fixed-strings --quiet "$controlled_alert_route" \
  "$repository_root/config/alertmanager/alertmanager.yml.template"; then
  printf 'Controlled alert delivery route must complete within the workflow timeout.\n' >&2
  exit 1
fi

#==============================================================================
# GRAFANA SECRET PERMISSION VALIDATION
#==============================================================================

if ! grep -Fq "chown 472:472 \"\$release_path/secrets/grafana-admin-password\"" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "chmod 0400 \"\$release_path/secrets/grafana-admin-password\"" "$repository_root/scripts/manage.sh"; then
  printf 'Grafana secret must be readable only by container UID 472.\n' >&2
  exit 1
fi

if ! grep -Fq "chown 65534:65534 \"\$password_file\"" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "chmod 0400 \"\$password_file\"" "$repository_root/scripts/manage.sh"; then
  printf 'Jenkins metrics password must be readable only by Prometheus UID 65534.\n' >&2
  exit 1
fi

#==============================================================================
# SYSTEMD RELEASE ACTIVATION VALIDATION
#==============================================================================

if ! grep -Fq 'systemctl restart monitoring-stack.service' "$repository_root/scripts/manage.sh"; then
  printf 'Deployment must restart the active service to apply the new release.\n' >&2
  exit 1
fi

#==============================================================================
# GRAFANA HEALTH ADDRESS VALIDATION
#==============================================================================

if ! grep -Fq "wait_for_endpoint grafana \"http://\${MONITORING_BIND_ADDRESS:-127.0.0.1}:3000/api/health\"" \
  "$repository_root/scripts/manage.sh"; then
  printf 'Grafana health must use the configured private bind address.\n' >&2
  exit 1
fi

#==============================================================================
# OCI OUTPUT BUDGET VALIDATION
#==============================================================================

if ! grep -Fq 'apt-get update >/dev/null' "$repository_root/scripts/install-docker.sh" || \
  ! grep -Fq 'docker version >/dev/null' "$repository_root/scripts/install-docker.sh" || \
  ! grep -Fq 'docker compose version >/dev/null' "$repository_root/scripts/install-docker.sh"; then
  printf 'Routine installer output must remain quiet so OCI retains readiness markers.\n' >&2
  exit 1
fi

#==============================================================================
# OCI BOOTSTRAP PAYLOAD VALIDATION
#==============================================================================

sample_arguments=$(jq -cn '[
  "deploy",
  "bharathadigopula/monitoring-stack-automation",
  "v1.1.0",
  "grafana.bharathcloudops.com",
  "https://grafana.bharathcloudops.com",
  "10.10.10.3",
  "",
  "AAAAAAAAAAAAAAAAAAAAAAAA",
  "abcdefghijklmnop",
  ({admin_password: ("J" * 180)} | tojson)
]')
argument_line=$(jq -r '[.[] | @sh] | "set -- " + join(" ")' <<< "$sample_arguments")
rendered_size=$(printf '%s\n%s' "$argument_line" "$(cat "$repository_root/scripts/bootstrap.sh")" | wc -c | tr -d ' ')
if (( rendered_size > 4096 )); then
  printf 'Rendered monitoring bootstrap exceeds the OCI 4096-byte inline limit.\n' >&2
  exit 1
fi

#==============================================================================
# VALIDATION RESULT
#==============================================================================

printf 'monitoring_validation=ready\n'