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

## ✅ Validation

`01 - Validate Monitoring Automation` runs on free GitHub-hosted runners because
this repository is public.

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
