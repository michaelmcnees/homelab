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
- `homelab-pod-logs`: namespace-filtered Loki log volume and log search.
- `homelab-proxmox`: Proxmox host and VM metrics from prometheus-pve-exporter.

## Proxmox Metrics

The `proxmox-exporter` component runs `prompve/prometheus-pve-exporter` in the `observability` namespace. Prometheus scrapes `/metrics` for exporter health and `/pve` for each Proxmox node:

- `latios`: `10.0.3.196`
- `latias`: `10.0.3.40`
- `rayquaza`: `10.0.1.100`

The exporter credentials live in the SOPS-encrypted `proxmox-exporter-config` Secret. Prefer a Proxmox API token with `PVEAuditor` permissions at `/`; the first bootstrap currently reuses the local Terraform API token so we can replace it with a read-only monitoring token later.

## Alerts

kube-prometheus-stack already provides the baseline Kubernetes alert pack, including target down, pod crashlooping, pod not ready, persistent volume filling, node filesystem pressure, and Prometheus/operator health.

Homelab-specific alerts live in the `homelab-alerts` PrometheusRule:

- cert-manager certificate expiration at 21 days and 7 days.
- frequent pod restarts outside `kube-system`.
- Proxmox exporter scrape failures.
- Proxmox node down for `latios`, `latias`, and `rayquaza`.
- Proxmox on-boot VM/LXC guests down.
- Proxmox storage over 85% full.

cert-manager metrics are scraped through the `cert-manager` ServiceMonitor in the `infrastructure` namespace.

## Alert Delivery

Alertmanager uses the SOPS-encrypted `alertmanager-homelab-config` Secret as its `configSecret`.

Routing is intentionally simple:

- `Watchdog` and `info` alerts are dropped.
- `warning` alerts go to email.
- `critical` alerts go to both Pushover and email.

The local source values live outside Git in `.secrets/alertmanager.yml`. Regenerate `kubernetes/infrastructure/observability/kube-prometheus-stack/alertmanager-config.sops.yaml` after changing Pushover or SMTP credentials.

## Current Tradeoffs

Node-exporter is enabled through `kube-prometheus-stack`. The `observability` namespace is explicitly labeled with `pod-security.kubernetes.io/enforce=privileged` because node-exporter needs host-level access for node metrics. Keep privileged workloads in this namespace limited to observability components.

Prometheus uses a `50Gi` `local-path` PVC for TSDB data with 30 days of retention. The chart/operator-managed Prometheus pod security context runs as UID/GID `1000:2000` with `fsGroup=2000`. Because the operator mounts the data volume through a subPath, an init container chowns `/prometheus` before startup so Prometheus can create `queries.active` and TSDB files.
