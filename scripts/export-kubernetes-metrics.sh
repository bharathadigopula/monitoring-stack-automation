#!/usr/bin/env bash

#==============================================================================
# K3S AND WORDPRESS METRICS EXPORTER
#==============================================================================

set -euo pipefail

k3s_binary="${K3S_BINARY:-/usr/local/bin/k3s}"
kubeconfig="${K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
output_directory="${NODE_EXPORTER_TEXTFILE_DIRECTORY:-/var/lib/node-exporter/textfile}"
target_directory="${PROMETHEUS_TARGET_DIRECTORY:-/opt/monitoring-stack/current/config/prometheus/targets}"
temporary_directory=$(mktemp -d)
temporary_output=$(mktemp "$output_directory/kubernetes.prom.XXXXXX")
temporary_targets=$(mktemp "$target_directory/wordpress.json.XXXXXX")
trap 'rm -rf "$temporary_directory"; rm -f "$temporary_output" "$temporary_targets"' EXIT

kubectl_command=("$k3s_binary" kubectl --kubeconfig "$kubeconfig")

if [[ ! -x "$k3s_binary" || ! -r "$kubeconfig" ]] || \
  ! "${kubectl_command[@]}" get nodes -o json > "$temporary_directory/nodes.json" || \
  ! "${kubectl_command[@]}" get pods --all-namespaces -o json > "$temporary_directory/pods.json" || \
  ! "${kubectl_command[@]}" get deployments --all-namespaces -o json > "$temporary_directory/deployments.json" || \
  ! "${kubectl_command[@]}" get statefulsets --all-namespaces -o json > "$temporary_directory/statefulsets.json" || \
  ! "${kubectl_command[@]}" get persistentvolumeclaims --all-namespaces -o json > "$temporary_directory/pvcs.json" || \
  ! "${kubectl_command[@]}" get persistentvolumes -o json > "$temporary_directory/pvs.json" || \
  ! "${kubectl_command[@]}" get jobs --all-namespaces -o json > "$temporary_directory/jobs.json" || \
  ! "${kubectl_command[@]}" get namespaces -o json > "$temporary_directory/namespaces.json" || \
  ! "${kubectl_command[@]}" get ingresses --all-namespaces -o json > "$temporary_directory/ingresses.json"; then
  printf 'bharath_k3s_collector_success 0\n' > "$temporary_output"
  chmod 0644 "$temporary_output"
  mv "$temporary_output" "$output_directory/kubernetes.prom"
  trap - EXIT
  rm -rf "$temporary_directory"
  exit 1
fi

jq -r '
  .items[] |
  select(.metadata.labels["bharathcloudops.com/wordpress-site"] != null) |
  [.metadata.labels["bharathcloudops.com/wordpress-site"], .metadata.name] |
  @tsv
' "$temporary_directory/namespaces.json" > "$temporary_directory/wordpress-sites.tsv"

{
  printf 'bharath_k3s_collector_success 1\n'
  jq -r '
    .items[] |
    .metadata.name as $node |
    ([.status.conditions[]? | select(.type == "Ready")][0].status == "True") as $ready |
    "bharath_k3s_node_ready{node=\"\($node)\"} \(if $ready then 1 else 0 end)",
    "bharath_k3s_node_unschedulable{node=\"\($node)\"} \(if (.spec.unschedulable // false) then 1 else 0 end)"
  ' "$temporary_directory/nodes.json"
  jq -r '
    [.items[] | {namespace: .metadata.namespace, phase: (.status.phase // "Unknown")}] |
    group_by([.namespace, .phase])[] |
    "bharath_k3s_pods{namespace=\"\(.[0].namespace)\",phase=\"\(.[0].phase)\"} \(length)"
  ' "$temporary_directory/pods.json"
  jq -r '
    .items[] as $pod |
    ($pod.status.containerStatuses // [])[] |
    "bharath_k3s_container_restarts_total{namespace=\"\($pod.metadata.namespace)\",pod=\"\($pod.metadata.name)\",container=\"\(.name)\"} \(.restartCount // 0)",
    "bharath_k3s_container_ready{namespace=\"\($pod.metadata.namespace)\",pod=\"\($pod.metadata.name)\",container=\"\(.name)\"} \(if .ready then 1 else 0 end)"
  ' "$temporary_directory/pods.json"
  jq -r '
    .items[] |
    "bharath_k3s_deployment_replicas_desired{namespace=\"\(.metadata.namespace)\",deployment=\"\(.metadata.name)\"} \(.spec.replicas // 0)",
    "bharath_k3s_deployment_replicas_available{namespace=\"\(.metadata.namespace)\",deployment=\"\(.metadata.name)\"} \(.status.availableReplicas // 0)"
  ' "$temporary_directory/deployments.json"
  jq -r '
    .items[] |
    "bharath_k3s_statefulset_replicas_desired{namespace=\"\(.metadata.namespace)\",statefulset=\"\(.metadata.name)\"} \(.spec.replicas // 0)",
    "bharath_k3s_statefulset_replicas_ready{namespace=\"\(.metadata.namespace)\",statefulset=\"\(.metadata.name)\"} \(.status.readyReplicas // 0)"
  ' "$temporary_directory/statefulsets.json"
  jq -r '
    .items[] |
    "bharath_k3s_pvc_bound{namespace=\"\(.metadata.namespace)\",persistentvolumeclaim=\"\(.metadata.name)\"} \(if .status.phase == "Bound" then 1 else 0 end)"
  ' "$temporary_directory/pvcs.json"
  jq -r '
    .items[] |
    select(.spec.claimRef.namespace != null and .spec.claimRef.name != null) |
    [.spec.claimRef.namespace, .spec.claimRef.name, (.spec.hostPath.path // .spec.local.path // "")] |
    @tsv
  ' "$temporary_directory/pvs.json" |
    while IFS=$'\t' read -r namespace persistentvolumeclaim volume_path; do
      if [[ -n "$volume_path" && -d "$volume_path" ]]; then
        volume_bytes=$(du --bytes --summarize --one-file-system -- "$volume_path" 2>/dev/null | awk '{print $1}' || printf 0)
        printf 'bharath_k3s_pvc_used_bytes{namespace="%s",persistentvolumeclaim="%s"} %s\n' \
          "$namespace" "$persistentvolumeclaim" "${volume_bytes:-0}"
      fi
    done
  while IFS=$'\t' read -r site namespace; do
    jq -r --arg site "$site" --arg namespace "$namespace" '
      [.items[] | select(.metadata.namespace == $namespace and any(.metadata.ownerReferences[]?; .kind == "CronJob" and .name == "wordpress-backup") and (.status.succeeded // 0) > 0) | .status.completionTime | fromdateiso8601] |
      max // 0 |
      "bharath_wordpress_backup_last_success_timestamp_seconds{site=\"\($site)\",namespace=\"\($namespace)\"} \(.)"
    ' "$temporary_directory/jobs.json"
  done < "$temporary_directory/wordpress-sites.tsv"
} > "$temporary_output"

#==============================================================================
# WORDPRESS DEPENDENCY METRICS
#==============================================================================

while IFS=$'\t' read -r site namespace; do
  metric_labels="site=\"$site\",namespace=\"$namespace\""
  database_status=$("${kubectl_command[@]}" --namespace "$namespace" exec statefulset/mariadb -- \
    sh -c "MYSQL_PWD=\"\$MARIADB_PASSWORD\" mariadb --user=\"\$MARIADB_USER\" --batch --skip-column-names --execute='SHOW GLOBAL STATUS WHERE Variable_name IN (\"Threads_connected\",\"Max_used_connections\",\"Questions\",\"Slow_queries\",\"Uptime\"); SHOW GLOBAL VARIABLES LIKE \"max_connections\";'" 2>/dev/null || true)
  if [[ -n "$database_status" ]]; then
    printf 'bharath_wordpress_mariadb_up{%s} 1\n' "$metric_labels" >> "$temporary_output"
    awk -v labels="$metric_labels" 'BEGIN { IGNORECASE=1 }
      $1 == "Threads_connected" { print "bharath_wordpress_mariadb_threads_connected{" labels "} " $2 }
      $1 == "Max_used_connections" { print "bharath_wordpress_mariadb_max_used_connections{" labels "} " $2 }
      $1 == "Questions" { print "bharath_wordpress_mariadb_questions_total{" labels "} " $2 }
      $1 == "Slow_queries" { print "bharath_wordpress_mariadb_slow_queries_total{" labels "} " $2 }
      $1 == "Uptime" { print "bharath_wordpress_mariadb_uptime_seconds{" labels "} " $2 }
      $1 == "max_connections" { print "bharath_wordpress_mariadb_max_connections{" labels "} " $2 }
    ' <<< "$database_status" >> "$temporary_output"
  else
    printf 'bharath_wordpress_mariadb_up{%s} 0\n' "$metric_labels" >> "$temporary_output"
  fi

  redis_status=$("${kubectl_command[@]}" --namespace "$namespace" exec deployment/redis -- \
    redis-cli --raw INFO stats memory clients 2>/dev/null || true)
  if grep -Fq 'redis_version:' <<< "$redis_status" || grep -Fq 'uptime_in_seconds:' <<< "$redis_status"; then
    printf 'bharath_wordpress_redis_up{%s} 1\n' "$metric_labels" >> "$temporary_output"
    awk -F: -v labels="$metric_labels" '
      $1 == "connected_clients" { print "bharath_wordpress_redis_connected_clients{" labels "} " $2 }
      $1 == "used_memory" { print "bharath_wordpress_redis_used_memory_bytes{" labels "} " $2 }
      $1 == "evicted_keys" { print "bharath_wordpress_redis_evicted_keys_total{" labels "} " $2 }
      $1 == "keyspace_hits" { print "bharath_wordpress_redis_keyspace_hits_total{" labels "} " $2 }
      $1 == "keyspace_misses" { print "bharath_wordpress_redis_keyspace_misses_total{" labels "} " $2 }
      $1 == "uptime_in_seconds" { print "bharath_wordpress_redis_uptime_seconds{" labels "} " $2 }
    ' <<< "$redis_status" | tr -d '\r' >> "$temporary_output"
  else
    printf 'bharath_wordpress_redis_up{%s} 0\n' "$metric_labels" >> "$temporary_output"
  fi
done < "$temporary_directory/wordpress-sites.tsv"

jq -n --slurpfile namespaces "$temporary_directory/namespaces.json" --slurpfile ingresses "$temporary_directory/ingresses.json" '
  [$namespaces[0].items[] |
    select(.metadata.labels["bharathcloudops.com/wordpress-site"] != null) |
    .metadata.name as $namespace |
    .metadata.labels["bharathcloudops.com/wordpress-site"] as $site |
    $ingresses[0].items[] |
    select(.metadata.namespace == $namespace) |
    .spec.rules[]?.host |
    select(. != null) |
    {targets: ["https://" + .], labels: {environment: "prd", probe: "https", service: "WordPress", site: $site, namespace: $namespace}}]
' > "$temporary_targets"

chmod 0644 "$temporary_output"
mv "$temporary_output" "$output_directory/kubernetes.prom"
chmod 0644 "$temporary_targets"
mv "$temporary_targets" "$target_directory/wordpress.json"
trap - EXIT
rm -rf "$temporary_directory"
printf 'kubernetes_metrics=ready\n'