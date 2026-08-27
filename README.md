<!--
==============================================================================
MONITORING STACK AUTOMATION
==============================================================================
-->

# Monitoring Stack Automation

Deploy a resource-constrained Prometheus, Alertmanager, Blackbox Exporter, and Grafana stack on AMD64 or ARM64 Ubuntu hosts with Docker Compose and systemd. Production scrape and probe targets are versioned as non-secret configuration; credentials are injected from OCI Vault during versioned OCI Run Command execution.

<!--
==============================================================================
STACK COMPONENTS
==============================================================================
-->

## Stack

| Component | Version | CPU limit | Memory limit | Purpose |
| --- | --- | ---: | ---: | --- |
| Prometheus | `v3.14.0` | `0.40` | `1536M` | Metrics storage, recording rules, and alert evaluation |
| Alertmanager | `v0.34.0` | `0.05` | `64M` | Gmail SMTP notification routing and inhibition |
| Grafana | `13.2.0` | `0.20` | `512M` | Dashboards and native authentication |
| Node Exporter | `v1.9.1` | `0.05` | `64M` | Linux host metrics |
| cAdvisor | `v0.52.1` | `0.10` | `192M` | Docker container metrics |
| Blackbox Exporter | `v0.28.0` | `0.05` | `64M` | External HTTPS availability and TLS certificate probes |

Prometheus defaults to a 60-second scrape interval, seven-day retention, and an 8 GB storage ceiling. Prometheus, Alertmanager, and Blackbox Exporter bind to loopback. Grafana binds to `MONITORING_BIND_ADDRESS`, which should be a private address when an outbound tunnel provides ingress.

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
bash scripts/manage.sh dry-run
bash scripts/install-docker.sh dry-run
```

When Docker is available, validation renders the complete Compose model and runs the pinned Prometheus, Alertmanager, and Blackbox Exporter native validators. Every dashboard is checked for valid JSON, a stable UID, a title, panels, target expressions, and unique panel identifiers. Validation also fails when the rendered bootstrap would exceed OCI Run Command's 4,096-byte inline limit.

<!--
==============================================================================
VERSIONED DEPLOYMENT
==============================================================================
-->

## Versioned Deployment

Use an immutable semantic version tag. `bootstrap.sh` is deliberately smaller than the OCI Run Command 4,096-byte payload limit and downloads the full tagged source archive before validation or deployment.

```bash
bash scripts/bootstrap.sh \
  dry-run \
  owner/monitoring-stack-automation \
  v1.1.3 \
  grafana.example.com \
  https://grafana.example.com \
  10.0.0.10
```

For deployment, append the Grafana administrator password followed by the Gmail app password and use `deploy` explicitly. The host configuration workflow retrieves both values independently from OCI Vault and preserves this order. Grafana reads its password from a root-managed file; the SMTP password is rendered into a release-local Alertmanager configuration with mode `0400`.

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
| `verify` | No | Checks endpoints, six services, scrape targets, probes, Cloudflare connections, Alertmanager discovery, rules, seven dashboards, and backup timer |
| `status` | No | Reports systemd, Compose, logs, and control-plane endpoint codes |
| `backup` | Yes | Creates a root-only archive of Grafana, Prometheus, and Alertmanager state |
| `restore` | Yes | Restores `MONITORING_RESTORE_ARCHIVE` |
| `rollback` | Yes | Exchanges current and previous release symlinks |

`monitoring-stack-backup.timer` runs daily at 02:30 with a random delay of up to 15 minutes. Backups are written under `/var/backups/monitoring-stack`, retain three Docker volumes, and delete archives older than seven days. Restore accepts only an existing managed archive and verifies all four control-plane endpoints after startup.

<!--
==============================================================================
PROMETHEUS METRICS TARGETS
==============================================================================
-->

## Metrics Targets

Prometheus always scrapes itself, Alertmanager, Grafana, Node Exporter, cAdvisor, and Blackbox Exporter. File-based service discovery configures external HTTPS probes, the Cloudflare connector, and the optional Jenkins endpoint:

- `config/prometheus/targets/blackbox.json`
- `config/prometheus/targets/cloudflared.json`
- `config/prometheus/targets/jenkins.json`

The production Blackbox target file probes Grafana and Cloudflare Access over HTTPS. The Cloudflare target scrapes the connector's private `:8880` metrics listener. Keep Prometheus and Alertmanager private; expose Grafana only through authenticated ingress while preserving Grafana's native login.

<!--
==============================================================================
ALERT DELIVERY
==============================================================================
-->

## Alert Delivery

Prometheus routes firing alerts to the private Alertmanager service. Alertmanager sends resolved and firing notifications from `bharathcloudops@gmail.com` to `adigopulabharath@outlook.com` through `smtp.gmail.com:587` with TLS. Critical alerts repeat hourly, warning alerts use the four-hour default, and matching warnings are inhibited while their critical alert is active.

Alert rules cover target availability, external endpoint failures, certificate expiry, Cloudflare connector metrics and HA connections, host CPU/memory/disk/inodes, container memory, Prometheus reload/evaluation/storage health, and Alertmanager delivery failures.

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

The dashboards cover host and container capacity, monitoring control-plane health, service targets, external probes and certificate lifetime, active alerts and notification failures, and Cloudflare Tunnel connections.

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

Docker Engine and Compose package versions are pinned for Ubuntu 24.04. Update the package versions only after validation on both supported architectures.

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