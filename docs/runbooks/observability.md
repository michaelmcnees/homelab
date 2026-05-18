# Observability

## Grafana Auth

Grafana is exposed at `https://grafana.home.mcnees.me` through Traefik and the shared `oauth2-proxy` middleware.

The auth flow is:

1. Browser requests `grafana.home.mcnees.me`.
2. Traefik asks OAuth2-Proxy to authorize the request.
3. OAuth2-Proxy validates the Pocket ID session.
4. OAuth2-Proxy returns identity headers to Traefik, including `X-Auth-Request-Email`.
5. Traefik forwards those headers to Grafana.
6. Grafana auth-proxy mode uses `X-Auth-Request-Email` as the user identity and auto-creates the user.

Auto-created Grafana users default to the Viewer org role. Promote admin users explicitly in Grafana after their first login, or add group-to-role mapping later if Pocket ID group claims become authoritative enough for Grafana role assignment.

## Logs

Loki is deployed in single-binary mode for cluster logs. Grafana gets Loki as a datasource from the `grafana-loki-datasource` ConfigMap.

Alloy ships pod logs to Loki with `loki.source.kubernetes`, which tails container logs through the Kubernetes API. This avoids hostPath mounts, privileged containers, root filesystem access, and DaemonSet requirements while the cluster is still running baseline Pod Security. Alloy relabels Kubernetes discovery metadata into `namespace`, `pod`, `container`, and `job` labels for Grafana queries.

Loki's local ingestion rate is raised above the chart default to absorb the startup burst when Alloy opens log streams for all existing pods.

## Dashboards

Grafana dashboards are provisioned from ConfigMaps labeled `grafana_dashboard: "1"` in `kubernetes/infrastructure/observability/kube-prometheus-stack`.

The homelab-specific dashboards are:

- `homelab-k8s-overview`: cluster and node vitals backed by Prometheus.
- `homelab-databases`: PostgreSQL, Redis, metagross LXC, and database backup health.
- `homelab-ai`: Ollama, Open WebUI, Hermes, and Paperless-GPT workload health, resource usage, AI logs, and loaded Ollama model metadata.
- `homelab-network`: blackbox network probes and UniFi metric ingestion status.
- `homelab-pod-logs`: namespace-filtered Loki log volume and log search.
- `homelab-proxmox`: Proxmox host and VM metrics from prometheus-pve-exporter.

## AI Metrics

AI service health is split between standard Kubernetes metrics, Loki logs, and a small custom `ollama-exporter` in the `observability` namespace.

`ollama-exporter` polls `http://ollama.apps.svc.cluster.local:11434/api/ps` and `/api/tags`, then exposes:

- whether Ollama is reachable.
- the loaded model name, family, parameters, and quantization.
- loaded model memory footprint.
- loaded model context length.
- model expiry timestamp.
- available local models.

The `homelab-ai` dashboard combines those exporter metrics with pod CPU, pod memory, restarts, and log warnings/errors for `ollama`, `open-webui`, `hermes`, and `paperless-gpt`.

## Network Metrics

Network trend monitoring has two layers:

- `blackbox-exporter` probes known LAN and WAN targets every 30 seconds.
- `unpoller` collects UniFi controller, gateway, switch, AP, and client metrics once UniFi credentials are configured.

Blackbox probes currently cover:

- Traefik internal HTTPS at `10.0.10.200:443`.
- UniFi console HTTPS at `10.0.0.17:443`.
- Cloudflare HTTPS at `1.1.1.1:443`.
- Google DNS TCP at `8.8.8.8:53`.
- Cloudflare HTTP at `https://cloudflare.com`.
- GitHub HTTP at `https://github.com`.
- AdGuard DNS at `10.0.10.201:53`.
- Cloudflare DNS at `1.1.1.1:53`.
- TrueNAS NFS at `10.0.1.1:2049`.
- Proxmox HTTPS on `latios`, `latias`, and `rayquaza`.

Use these probes to distinguish local Traefik/LAN failures from WAN or upstream DNS instability. They are intentionally simple availability and latency checks; they do not replace full throughput tests.

The `homelab-network` Grafana dashboard combines these probes with UniFi metrics:

- Internet speed and quality: UniFi gateway speedtest, WAN throughput, WAN probe success, HTTP latency, DNS latency, and UniFi site/uplink latency.
- Wi-Fi quality: average client satisfaction, AP/radio channel utilization, AP/SSID client counts, RSSI, link rates, retry/drop rates, and lowest-satisfaction clients.
- LAN/storage quality: Traefik, UniFi console, Proxmox UI, and TrueNAS NFS probes.

Use the dashboard from top to bottom when isolating performance issues. If WAN probes and gateway speedtest dip together, suspect ISP/upstream. If WAN is clean but Wi-Fi satisfaction, RSSI, retries, or AP channel utilization degrade, suspect RF/client/AP placement. If only LAN/storage probes fail, suspect internal routing, VLAN, switch, or service health.

UniFi metrics require a local UniFi account that can read network data. Edit the SOPS secret after creating that account:

```sh
SOPS_AGE_KEY_FILE=homelab.age.key sops kubernetes/infrastructure/observability/unpoller/secret.sops.yaml
```

Set:

- `UP_UNIFI_DEFAULT_USER`
- `UP_UNIFI_DEFAULT_PASS`

The controller URL is `https://10.0.0.17`, site is `default`, and TLS verification is disabled because the console uses an internal/self-signed certificate.

The UniFi API key used by OpenTofu is not used here. `unpoller` authenticates with `UP_UNIFI_DEFAULT_USER` and `UP_UNIFI_DEFAULT_PASS`, so use a dedicated local read-only monitoring account instead of the OpenTofu API token or the K3s cluster token from Ansible.

## Proxmox Metrics

The `proxmox-exporter` component runs `prompve/prometheus-pve-exporter` in the `observability` namespace. Prometheus scrapes `/metrics` for exporter health and `/pve` for each Proxmox node:

- `latios`: `10.0.3.196`
- `latias`: `10.0.3.40`
- `rayquaza`: `10.0.1.100`

The exporter credentials live in the SOPS-encrypted `proxmox-exporter-config` Secret. Prefer a Proxmox API token with `PVEAuditor` permissions at `/`; the first bootstrap currently reuses the local Terraform API token so we can replace it with a read-only monitoring token later.

## Alerts

kube-prometheus-stack already provides the baseline Kubernetes alert pack, including target down, pod crashlooping, pod not ready, persistent volume filling, node filesystem pressure, and Prometheus/operator health.

The chart's kube-proxy scrape is disabled because the Talos nodes do not expose kube-proxy metrics on the default `10249` endpoint. Leaving it enabled creates a permanently firing `TargetDown` alert for `kube-system/kube-proxy`.

Homelab-specific alerts live in the `homelab-alerts` PrometheusRule:

- cert-manager certificate expiration at 21 days and 7 days.
- frequent pod restarts outside `kube-system`.
- Proxmox exporter scrape failures.
- Proxmox node down for `latios`, `latias`, and `rayquaza`.
- Proxmox on-boot VM/LXC guests down.
- Proxmox storage over 85% full.

AI and network alerts live in `homelab-ai-network-alerts`:

- AI workloads unavailable for 10 minutes.
- Ollama exporter cannot reach Ollama.
- loaded Ollama model memory above 16 GB.
- network probe failures for 5 minutes.
- WAN probe success below 90% over 15 minutes.
- UniFi poller scrape failures.

Database-specific alerts live in the `metagross-backups` PrometheusRule:

- PostgreSQL exporter scrape failures.
- PostgreSQL exporter unable to connect to metagross.
- Redis down or missing from metrics.
- Open WebUI database missing from PostgreSQL metrics.
- PostgreSQL backup metrics scrape failures.
- PostgreSQL logical backup stale, missing, or failed.
- PostgreSQL backup PVC over 80% full.
- incomplete PostgreSQL backup temp directories present for more than 1 hour.

cert-manager metrics are scraped through the `cert-manager` ServiceMonitor in the `infrastructure` namespace.

Database metrics are split by responsibility:

- PostgreSQL server and database usage metrics come from `postgres-exporter` in the `internal` namespace.
- PostgreSQL logical backup storage and retention metrics come from `postgresql-backup-metrics`, which mounts the backup PVC read-only and exposes derived gauges.
- Redis metrics come from the Bitnami Redis chart's metrics exporter and ServiceMonitor.
- metagross LXC resource metrics come from the Proxmox exporter and are shown on the database dashboard with `pve_*` metrics for `lxc/200`.

## Alert Delivery

Alertmanager uses the SOPS-encrypted `alertmanager-homelab-config` Secret as its `configSecret`.

Routing is intentionally simple:

- `Watchdog` and `info` alerts are dropped.
- `warning` alerts go to email.
- `critical` alerts go to both Pushover and email.

Alert links use internal Traefik hostnames instead of cluster service names:

- Alertmanager: `https://alertmanager.home.mcnees.me`
- Prometheus: `https://prometheus.home.mcnees.me`
- Grafana: `https://grafana.home.mcnees.me`

Prometheus and Alertmanager are protected by the shared `oauth2-proxy` middleware, matching Grafana's internal access pattern.

The local source values live outside Git in `.secrets/alertmanager.yml`. Regenerate `kubernetes/infrastructure/observability/kube-prometheus-stack/alertmanager-config.sops.yaml` after changing Pushover or SMTP credentials.

## Current Tradeoffs

Node-exporter is enabled through `kube-prometheus-stack`. The `observability` namespace is explicitly labeled with `pod-security.kubernetes.io/enforce=privileged` because node-exporter needs host-level access for node metrics. Keep privileged workloads in this namespace limited to observability components.

Prometheus uses a `50Gi` `local-path` PVC for TSDB data with 30 days of retention. The chart/operator-managed Prometheus pod security context runs as UID/GID `1000:2000` with `fsGroup=2000`. Because the operator mounts the data volume through a subPath, an init container chowns `/prometheus` before startup so Prometheus can create `queries.active` and TSDB files.

Alertmanager uses a `1Gi` `local-path` PVC for silences and the notification log. It uses the same UID/GID pattern and a matching init container chowns `/alertmanager` before startup so Alertmanager can maintain silences and notification dedupe state.
