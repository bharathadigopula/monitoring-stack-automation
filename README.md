<!--
==============================================================================
MONITORING STACK AUTOMATION
==============================================================================
-->

# Monitoring Stack Automation

Production monitoring for OCI hosts and platform services using Prometheus,
Alertmanager, Grafana, Node Exporter, cAdvisor, and Blackbox Exporter.

## 📊 Coverage

- OCI host CPU, memory, filesystem, and container capacity
- GitHub Actions runner availability, activity, queue depth, and failures
- Backstage readiness, PostgreSQL, and backup freshness
- Cloudflare Tunnel health, external probes, and certificate expiry
- Prometheus, Alertmanager, and Grafana health

Jenkins targets, credentials, alerts, probes, and dashboards are not part of the
stack.

| Component | Version | CPU limit | Memory limit | Purpose |
| --- | --- | ---: | ---: | --- |
| Prometheus | `v3.15.0` | `0.40` | `1536M` | Metrics storage, recording rules, and alert evaluation |
| Alertmanager | `v0.34.1` | `0.05` | `64M` | Gmail SMTP notification routing and inhibition |
| Grafana | `13.2.2` | `0.20` | `512M` | Dashboards and native authentication |
| Node Exporter | `v1.12.1` | `0.05` | `64M` | Local K3s host and textfile metrics inside the Compose network |
| cAdvisor | `v0.60.6` | `0.10` | `192M` | Docker container metrics |
| Blackbox Exporter | `v0.28.0` | `0.05` | `64M` | External HTTPS availability and TLS certificate probes |

Release `v1.2.14` uses a five-second refresh interval for file-discovered targets so strict post-deployment verification sees every production job within its bounded readiness window. Prometheus uses a 60-second scrape interval, seven-day retention, and an 8 GB storage ceiling. Prometheus, Alertmanager, and Blackbox Exporter bind to loopback. Grafana binds to `MONITORING_BIND_ADDRESS`, which should be a private address when an outbound tunnel provides ingress. Native Node Exporter `v1.12.1` agents are deployed separately by `shared-host-automation` on all three hosts; the local Compose exporter lets Prometheus read `k3s` and textfile metrics without opening Docker bridge access through the host firewall.

<!--
==============================================================================
DEPLOYMENT REQUIREMENTS
==============================================================================
-->

## Requirements

- Ubuntu 24.04 on AMD64 or ARM64
- Root execution for deployment and lifecycle mutations
- `curl`, `jq`, `tar`, and systemd
- Outbound HTTPS access to GitHub, Docker Hub, Google Container Registry, and Docker's Ubuntu repository
- A single-line Grafana administrator password supplied by a secret manager
- A 16-character Gmail app password supplied separately by a secret manager
- Private Node Exporter endpoints on TCP `9100` for `k3s`, `platform`, and `web-01`
- Readable K3s kubeconfig at `/etc/rancher/k3s/k3s.yaml`

<!--
==============================================================================
VALIDATION AND DRY RUN
==============================================================================
-->

## Validate And Dry Run

Validation and dry-run operations do not mutate the host:

```bash
shellcheck scripts/*.sh
bash scripts/validate.sh
```

## 🚀 Operations

`06 - Configure production monitoring` in `bharath-oci-host-config` runs through
OCI self-hosted runners and OCI Run Command. Use actions in this order:

1. `validate` or `dry-run`
2. `deploy`
3. `verify`
4. `status`, `backup`, `restore`, `rollback`, or `test-alert` when needed

Only `deploy` retrieves the Grafana administrator and Alertmanager SMTP secrets
from OCI Vault. Production mutations require the protected `production`
environment.

## 🔒 Recovery

Daily backups are stored root-only under `/var/backups/monitoring-stack` with
seven-day retention. Use `restore` with a managed archive path, then run `verify`.

<!--
==============================================================================
LIFECYCLE OPERATIONS
==============================================================================
-->

## Operations

`scripts/manage.sh` supports these actions:

| Action | Mutation | Result |
| --- | --- | --- |
| `validate` | No | Checks repository configuration |
| `dry-run` | No | Validates and reports the release path |
| `deploy` | Yes | Installs a release and starts systemd service |
| `upgrade` | Yes | Deploys a new release while retaining the previous symlink |
| `verify` | No | Checks endpoints, six services, all three hosts, K3s and WordPress state, probes, GitHub runners, Cloudflare, rules, thirteen dashboards, and both timers |
| `status` | No | Reports systemd, Compose, logs, and control-plane endpoint codes |
| `backup` | Yes | Creates a root-only archive of Grafana, Prometheus, and Alertmanager state |
| `restore` | Yes | Restores `MONITORING_RESTORE_ARCHIVE` |
| `rollback` | Yes | Exchanges current and previous release symlinks |
| `test-alert` | No | Sends controlled firing and resolved emails through an accelerated test-only route and verifies Alertmanager notification counters |

`monitoring-stack-backup.timer` runs daily at 02:30 with a random delay of up to 15 minutes. Backups are written under `/var/backups/monitoring-stack`, retain three Docker volumes, and delete archives older than seven days. Restore accepts only an existing managed archive and verifies all four control-plane endpoints after startup.

<!--
==============================================================================
PROMETHEUS METRICS TARGETS
==============================================================================
-->

## Metrics Targets

Prometheus always scrapes itself, Alertmanager, Grafana, all three native Node Exporters, cAdvisor, Blackbox Exporter, and the GitHub Actions runner exporter. File-based service discovery configures service probes and private targets:

- `config/prometheus/targets/blackbox.json`
- `config/prometheus/targets/cloudflared.json`
- `config/prometheus/targets/github-runners.json`
- `config/prometheus/targets/nodes.json`

The node targets are the local `k3s` Compose exporter, `platform` (`10.10.10.68:9100`), and `web-01` (`10.10.10.125:9100`). All carry stable `host` labels. Static Blackbox targets cover Grafana and Cloudflare Access. WordPress targets are discovered from labeled K3s namespaces and their ingress hosts, then written atomically to a separate file-discovery target. The Cloudflare target scrapes `web-01:8880`. The `github-runners` job independently scrapes `platform:9101` for runner online/busy state, workflow queue depth, and recent failures. Keep Prometheus and Alertmanager private; expose Grafana only through authenticated ingress while preserving Grafana's native login.

<!--
==============================================================================
K3S AND WORDPRESS METRICS
==============================================================================
-->

## K3s Metrics

`kubernetes-metrics-exporter.timer` queries the local K3s API every minute and writes atomic Prometheus textfile metrics. K3s remains a distinct monitoring surface covering node readiness and scheduling, pods by namespace and phase, container readiness and restarts, deployment replicas, StatefulSet replicas, and PVC binding. It does not expose the Kubernetes API outside the host.

## WordPress Metrics

WordPress is a separate application surface. Its dashboard provides a project selector backed by the `bharathcloudops.com/wordpress-site` namespace label and combines WordPress and Redis deployment readiness, MariaDB StatefulSet readiness and connection pressure, Redis memory and evictions, pod phases, container restarts, PVC binding and actual local-path bytes, backup completion age, public HTTPS availability, and response latency. Every application metric carries `site` and `namespace` labels. This separation prevents host or cluster health from masking an application failure and allows each project to be inspected independently.

## Storage Coverage

Node Exporter records every mounted filesystem's capacity, free space, inode pressure, and disk throughput. The shared host storage collector records aggregate size, file count, and availability only for paths declared in the private host inventory. Detailed filenames are intentionally excluded from Prometheus; the scheduled host-monitoring pipeline stores the twenty largest files per declared path in protected seven-day run artifacts.

<!--
==============================================================================
ALERT DELIVERY
==============================================================================
-->

## Alert Delivery

Prometheus routes firing alerts to the private Alertmanager service. Alertmanager sends resolved and firing notifications from `bharathcloudops@gmail.com` to `adigopulabharath@outlook.com` through `smtp.gmail.com:587` with TLS. Critical alerts repeat hourly, warning alerts use the four-hour default, and matching warnings are inhibited while their critical alert is active.

Alert rules cover target availability, external endpoints, certificates, Cloudflare, GitHub runners and queues, host CPU/RAM/swap/disk/inodes/systemd, managed storage paths, K3s node/workload/container/PVC state, WordPress application/database/backup state, container memory, Prometheus health, and Alertmanager delivery failures.

<!--
==============================================================================
GRAFANA DASHBOARDS
==============================================================================
-->

## Dashboards

Provisioned dashboards use stable UIDs:

- `monitoring-health`
- `linux-host`
- `container-health`
- `service-health`
- `external-availability`
- `alert-operations`
- `cloudflare-tunnel`
- `github-actions-runners`
- `infrastructure-overview`
- `storage-capacity`
- `kubernetes-cluster`
- `wordpress-platform`

The dashboards keep infrastructure, storage, K3s, and WordPress projects distinct while retaining the existing monitoring, container, external availability, alert, Cloudflare, Backstage, and GitHub runner views.

<!--
==============================================================================
UPGRADE AND ROLLBACK
==============================================================================
-->

## Upgrade And Rollback

1. Validate the new immutable tag.
2. Run `dry-run` through the same remote execution path used by production.
3. Back up Grafana, Prometheus, and Alertmanager.
4. Run `upgrade` with the new tag.
5. Verify all four control-plane endpoints, scrape targets, rules, dashboards, and notification delivery.
6. Run `rollback` if verification fails.

Docker Engine `29.8.1`, containerd `2.3.6`, Buildx `0.37.1`, and Compose `5.5.1` are pinned for Ubuntu 24.04. Daily CI compares all component releases and Docker packages with official upstream metadata and verifies AMD64 and ARM64 image support.

<!--
==============================================================================
SECURITY CONTROLS
==============================================================================
-->

## Security

- No public Prometheus port is configured.
- Alertmanager and Blackbox Exporter are loopback-only.
- Grafana registration is disabled.
- The administrator password is loaded from a file with root-only permissions.
- The SMTP credential is a separate OCI Vault secret and is never committed.
- Images use explicit version tags rather than `latest`.
- Deployment requires an explicit mutating action.
- Versioned target files may contain non-secret production domains and private service addresses.
- Credentials and cloud identifiers are never stored in this repository.
