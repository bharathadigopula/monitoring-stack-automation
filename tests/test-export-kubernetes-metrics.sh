#!/usr/bin/env bash

#==============================================================================
# K3S AND WORDPRESS METRICS EXPORTER TEST
#==============================================================================

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/targets" "$test_root/textfile" "$test_root/volume"
touch "$test_root/kubeconfig" "$test_root/volume/content.txt"

cat > "$test_root/k3s" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

arguments=" $* "
case "$arguments" in
  *" get nodes "*)
    printf '%s\n' '{"items":[{"metadata":{"name":"k3s-01"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    ;;
  *" get pods "*)
    printf '%s\n' '{"items":[{"metadata":{"namespace":"ignitox","name":"wordpress-1"},"status":{"phase":"Running","containerStatuses":[{"name":"wordpress","ready":true,"restartCount":1}]}}]}'
    ;;
  *" get deployments "*)
    printf '%s\n' '{"items":[{"metadata":{"namespace":"ignitox","name":"wordpress"},"spec":{"replicas":1},"status":{"availableReplicas":1}},{"metadata":{"namespace":"ignitox","name":"redis"},"spec":{"replicas":1},"status":{"availableReplicas":1}}]}'
    ;;
  *" get statefulsets "*)
    printf '%s\n' '{"items":[{"metadata":{"namespace":"ignitox","name":"mariadb"},"spec":{"replicas":1},"status":{"readyReplicas":1}}]}'
    ;;
  *" get persistentvolumeclaims "*)
    printf '%s\n' '{"items":[{"metadata":{"namespace":"ignitox","name":"wordpress-uploads"},"status":{"phase":"Bound"}}]}'
    ;;
  *" get persistentvolumes "*)
    jq -cn --arg volume_path "$TEST_VOLUME_PATH" '{items:[{spec:{claimRef:{namespace:"ignitox",name:"wordpress-uploads"},hostPath:{path:$volume_path}}}]}'
    ;;
  *" get jobs "*)
    printf '%s\n' '{"items":[{"metadata":{"namespace":"ignitox","ownerReferences":[{"kind":"CronJob","name":"wordpress-backup"}]},"status":{"succeeded":1,"completionTime":"2026-09-30T00:00:00Z"}}]}'
    ;;
  *" get namespaces "*)
    printf '%s\n' '{"items":[{"metadata":{"name":"ignitox","labels":{"bharathcloudops.com/wordpress-site":"ignitox"}}}]}'
    ;;
  *" get ingresses "*)
    printf '%s\n' '{"items":[{"metadata":{"namespace":"ignitox","name":"wordpress"},"spec":{"rules":[{"host":"ignitox.bharathcloudops.com"}]}}]}'
    ;;
  *" exec statefulset/mariadb "*)
    printf '%s\n' $'Threads_connected\t2' $'Max_used_connections\t4' $'Questions\t100' $'Slow_queries\t1' $'Uptime\t3600' $'max_connections\t151'
    ;;
  *" exec deployment/redis "*)
    printf '%s\n' 'redis_version:8.2.1' 'connected_clients:3' 'used_memory:4096' 'evicted_keys:0' 'keyspace_hits:90' 'keyspace_misses:10' 'uptime_in_seconds:3600'
    ;;
  *)
    printf 'Unexpected mock K3s command: %s\n' "$*" >&2
    exit 1
    ;;
esac
MOCK
chmod 0755 "$test_root/k3s"

TEST_VOLUME_PATH="$test_root/volume" \
K3S_BINARY="$test_root/k3s" \
K3S_KUBECONFIG="$test_root/kubeconfig" \
NODE_EXPORTER_TEXTFILE_DIRECTORY="$test_root/textfile" \
PROMETHEUS_TARGET_DIRECTORY="$test_root/targets" \
  bash "$repository_root/scripts/export-kubernetes-metrics.sh" >/dev/null

metrics_file="$test_root/textfile/kubernetes.prom"
for expected_metric in \
  'bharath_k3s_collector_success 1' \
  'bharath_k3s_node_ready{node="k3s-01"} 1' \
  'bharath_k3s_deployment_replicas_available{namespace="ignitox",deployment="wordpress"} 1' \
  'bharath_k3s_pvc_used_bytes{namespace="ignitox",persistentvolumeclaim="wordpress-uploads"}' \
  'bharath_wordpress_backup_last_success_timestamp_seconds{site="ignitox",namespace="ignitox"} 1790726400' \
  'bharath_wordpress_mariadb_threads_connected{site="ignitox",namespace="ignitox"} 2' \
  'bharath_wordpress_redis_used_memory_bytes{site="ignitox",namespace="ignitox"} 4096'; do
  if ! grep -Fq "$expected_metric" "$metrics_file"; then
    printf 'Expected metric was not exported: %s\n' "$expected_metric" >&2
    exit 1
  fi
done

jq -e '
  length == 1 and
  .[0].targets == ["https://ignitox.bharathcloudops.com"] and
  .[0].labels.site == "ignitox" and
  .[0].labels.namespace == "ignitox"
' "$test_root/targets/wordpress.json" >/dev/null

printf 'kubernetes_metrics_test=ready\n'