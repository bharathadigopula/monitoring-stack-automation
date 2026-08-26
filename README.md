<!--
==============================================================================
MONITORING STACK AUTOMATION
==============================================================================
-->

# Monitoring Stack Automation

Deploy a resource-constrained Prometheus and Grafana stack on AMD64 or ARM64 Ubuntu hosts with Docker Compose and systemd. The repository contains no environment-specific addresses or credentials and is designed for versioned execution through OCI Run Command or another remote command service.

<!--
==============================================================================
STACK COMPONENTS
==============================================================================
-->

## Stack

| Component | Version | CPU limit | Memory limit | Purpose |
| --- | --- | ---: | ---: | --- |
| Prometheus | `v3.5.0` | `0.40` | `1536M` | Metrics storage, rules, and alerts |
| Grafana | `12.1.1` | `0.20` | `512M` | Dashboards and native authentication |
| Node Exporter | `v1.9.1` | `0.05` | `64M` | Linux host metrics |
| cAdvisor | `v0.52.1` | `0.10` | `192M` | Docker container metrics |

Prometheus defaults to a 60-second scrape interval, seven-day retention, and an 8 GB storage ceiling. Prometheus is bound to loopback. Grafana binds to `MONITORING_BIND_ADDRESS`, which should be a private address when an outbound tunnel provides ingress.

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

When Docker Compose is installed, validation also renders the complete Compose model. Every dashboard is checked for valid JSON, a stable UID, a title, and panels.

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
  v1.0.0 \
  grafana.example.com \
  https://grafana.example.com \
  10.0.0.10
```

For deployment, pass the secret-manager value as the final argument and use `deploy` explicitly. The value is written root-only and is never stored in Compose YAML.

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
| `verify` | No | Checks Prometheus and Grafana health endpoints |
| `backup` | Yes | Creates a root-only Grafana archive |
| `restore` | Yes | Restores `MONITORING_RESTORE_ARCHIVE` |
| `rollback` | Yes | Exchanges current and previous release symlinks |

Grafana state is backed up because it contains local users and runtime state. Prometheus data is treated as disposable telemetry and is not included. Test restore operations before relying on backups.

<!--
==============================================================================
PROMETHEUS METRICS TARGETS
==============================================================================
-->

## Metrics Targets

Prometheus always scrapes itself, Grafana, Node Exporter, and cAdvisor. Optional Cloudflare connector and Jenkins endpoints use file-based service discovery:

- `config/prometheus/targets/cloudflared.json`
- `config/prometheus/targets/jenkins.json`

Private consumers should render those files in their release before deployment. Keep Prometheus private; expose Grafana only through authenticated ingress while preserving Grafana's native login.

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

The service dashboard displays Prometheus, Grafana, Cloudflare connector, and Jenkins target availability when their metrics endpoints are configured.

<!--
==============================================================================
UPGRADE AND ROLLBACK
==============================================================================
-->

## Upgrade And Rollback

1. Validate the new immutable tag.
2. Run `dry-run` through the same remote execution path used by production.
3. Back up Grafana.
4. Run `upgrade` with the new tag.
5. Verify both health endpoints and dashboards.
6. Run `rollback` if verification fails.

Docker Engine and Compose package versions are pinned for Ubuntu 24.04. Update the package versions only after validation on both supported architectures.

<!--
==============================================================================
SECURITY CONTROLS
==============================================================================
-->

## Security

- No public Prometheus port is configured.
- Grafana registration is disabled.
- The administrator password is loaded from a file with root-only permissions.
- Images use explicit version tags rather than `latest`.
- Deployment requires an explicit mutating action.
- Public automation contains no domains, private IP addresses, cloud identifiers, or credentials.