# Observability Audit — 2026-05-09

Read-only audit of the Flux-managed homelab observability stack at
`kubernetes/infrastructure/observability/`. The cluster runs kube-prometheus-stack
84.5.0, Loki 6.55.0 (single-binary, filesystem), Alloy 1.5.3 as the log collector,
plus standalone Beszel, Blackbox, Proxmox, Ollama, Unpoller and version-checker
deployments.

## 1. Executive summary

- **No dashboard variables anywhere except pod logs.** Six of the eight dashboards
  ship with empty `templating.list` blocks ([proxmox](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-proxmox-dashboard.yaml),
  [k8s-overview](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-k8s-overview-dashboard.yaml),
  [databases](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-databases-dashboard.yaml),
  [paperless](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-paperless-dashboard.yaml),
  [app-versions](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-app-versions-dashboard.yaml),
  [ai](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-ai-dashboard.yaml)).
  No `$namespace`, `$node`, `$pod`, `$proxmox_node` filters; everything is
  hard-coded.
- **No cross-dashboard navigation.** Every dashboard has `"links": []`. There is
  no drill-down from the k8s overview into pod logs, no link from databases into
  the postgresql runbook, no link from AI overview into paperless or pod-logs
  scoped to the same workload.
- **Traefik is a major scrape blind spot.** `traefik` is deployed as a DaemonSet
  on every node ([helmrelease.yaml](../../kubernetes/infrastructure/controllers/traefik/helmrelease.yaml))
  but Helm values do not enable the metrics endpoint, no ServiceMonitor exists,
  and there is no SLO-style request/error/latency dashboard for ingress. Every
  ingress'd workload is invisible at L7.
- **Auth tier (pocket-id, lldap, oauth2-proxy) has zero observability.** No
  ServiceMonitors, no alerts, no dashboard panels — even though they are on the
  critical path for everything behind oauth2-proxy. Auth outage is currently
  detected only via blackbox probes against downstream services.
- **Loki is used for ad-hoc log search and one paperless count panel; there are
  no Loki-based recording rules or alerts.** Alloy ([helmrelease.yaml](../../kubernetes/infrastructure/observability/alloy/helmrelease.yaml))
  ships pod logs without parsing structure. There are no LogQL alerts on
  oauth/auth failures, traefik 5xx surges, postgres errors, or Flux
  reconciliation failures.
- **Flux itself is not monitored** — no `gotk_reconcile_*` dashboard, no alerts
  on suspended Kustomizations / failed HelmReleases / image-automation backlog.
  This silently breaks the GitOps feedback loop.
- **Storage observability is shallow.** Only kubelet PVC fill is graphed (in the
  k8s-overview panel "PVC Requests" and as paperless-specific bargauges). The
  `local-path-provisioner` ([helmrelease.yaml](../../kubernetes/infrastructure/controllers/local-path-provisioner/helmrelease.yaml))
  pins data to one node, so a node failure means a per-PVC outage — but there is
  no panel showing PVC → node → workload mapping or per-node disk pressure.
- **No backup observability for non-postgres data.** PostgreSQL CronJob backups
  are well covered ([backup-alerts.yaml](../../kubernetes/databases/postgresql/backup-alerts.yaml),
  [backup-metrics-servicemonitor.yaml](../../kubernetes/databases/postgresql/backup-metrics-servicemonitor.yaml))
  but Loki, Prometheus TSDB, Grafana state, lldap SQLite, paperless data, and
  pocket-id state have no snapshot-age metric, no Velero/restic, and no alert.
- **DNS / AdGuard query metrics are unscraped.** Blackbox probes confirm AdGuard
  port 53 is reachable ([blackbox servicemonitor](../../kubernetes/infrastructure/observability/blackbox-exporter/servicemonitor.yaml#L184))
  but query rate, NXDOMAIN ratio, blocked-request percentage, upstream latency
  by upstream, etc. are not available because AdGuard's own statistics endpoint
  is not exposed to Prometheus.

## 2. Dashboard-by-dashboard review

### [`homelab-k8s-overview-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-k8s-overview-dashboard.yaml)

7 panels, default range 6h, 30s refresh, prometheus only, no variables, no
links. Panels: Ready Nodes, Running Pods, Restarts/1h, CPU Used By Node,
Memory Available By Node, Running Pods By Namespace, PVC Requests.

- The "Ready Nodes" stat thresholds (`red: null`, `green: 1`) only flag a *zero*
  reading. With three nodes, it should be `red < 3, orange = 2, green = 3` so
  that one missing node is visible without reading the number.
- "CPU Used By Node" uses `sum by (instance) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))`.
  This sums all cores per node and is hard to interpret across the new 3-node AMD
  rearchitect with different core counts. Replace with `1 - avg by (instance)
  (rate(node_cpu_seconds_total{mode="idle"}[5m]))` and unit `percentunit`.
- "Memory Available By Node" plots raw bytes. With a heterogeneous fleet, plot
  `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` instead — easier
  to compare and to threshold.
- "PVC Requests" plots *requests*, not *usage*. There is no "PVC % full" panel
  in the overview; the only one is paperless-specific. Add a `kubelet_volume_stats_used_bytes
  / kubelet_volume_stats_capacity_bytes` table sorted descending.
- Missing: pod pending count, pod CrashLoopBackOff count, node disk pressure
  / memory pressure conditions, unschedulable pods.
- Add variables: `$node` (label_values(node_uname_info, nodename)),
  `$namespace` (label_values(kube_namespace_status_phase, namespace)).
- Add links to: Proxmox dashboard (host view), Pod Logs dashboard
  (pre-filtered to `$namespace`).

### [`homelab-proxmox-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-proxmox-dashboard.yaml)

7 panel definitions. 652 lines — much of the file is duplicated panel-config
boilerplate. No variables, no links.

- Hard-codes `id=~"node/.*"` and `id=~"qemu/.*"` everywhere. Add
  `$proxmox_node` (latios|latias|rayquaza) variable so the dashboard works for
  per-node troubleshooting.
- LXC observability appears only in the *databases* dashboard (Metagross LXC
  panels), but Proxmox runs many containers. Add an "LXC overview" row with
  CPU, memory, disk per LXC.
- Missing: Proxmox **storage** panel (`pve_disk_usage_bytes / pve_disk_size_bytes`)
  even though the alert `HomelabProxmoxStorageFillingUp` exists. The alert
  fires but a viewer can't see the trend.
- Missing: ZFS pool health (`pve_storage_*` for ZFS), SMART, swap usage.
  These are exposed by the Proxmox exporter PVE module.
- Missing: power / thermal — relevant for the cost/headroom story of the
  3-node rearchitect.
- "Down Scrape Targets" stat is a `count(up == 0)` — it does not name *which*
  target is down. Replace with a table showing `up{job="proxmox-exporter"}`
  with red mappings.

### [`homelab-network-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-network-dashboard.yaml)

17 panels. The single best dashboard in the repo: real Wi-Fi satisfaction,
RSSI, retry counters, channel utilization, blackbox WAN/LAN/storage probes,
DNS lookup time. Defaults to 24h.

- Still no variables. Add `$ap_name`, `$network_path`, `$probe`.
- "DNS Lookup Time" only graphs blackbox-driven measurements; it does not show
  AdGuard's own query time histogram (because AdGuard isn't scraped).
- Add a panel that joins `unpoller_client_*` to a per-device hostname so a
  client problem can be localized; today legend keys are `ap_name / essid`,
  not the offending client.
- Add a "DNS query rate" panel powered by AdGuard once a scrape exists.
- Add link from each AP/SSID to a filtered-pod-logs dashboard scoped to
  `pod=traefik-*` (when traefik metrics land).

### [`homelab-databases-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-databases-dashboard.yaml)

33 panels organized via row titles (Overview, PostgreSQL, Redis, Metagross
LXC, Backups, Future Databases). 2,372 lines — by far the largest dashboard.

- Solid coverage of postgres, redis, backup metrics, and the Metagross LXC.
  No variables means selecting one database forces editing the panel.
- "Latest Backup Age" stat thresholds bake the warn/crit values into the panel
  title. Use Grafana threshold steps so the title stays simple ("Latest Backup
  Age") and the colour reflects state.
- Panel "Database Inventory" mixes three time-series in a table; consider a
  proper `transformations` block to merge them on `datname`.
- "Future Databases" row is an empty placeholder — drop it or fill it with a
  reminder/text panel explaining the roadmap.
- Add `$datname` variable for postgres panels (`label_values(pg_database_size_bytes, datname)`).
- Missing: replication lag (none deployed yet, but a "no replicas configured"
  text panel with a link to the runbook would help).
- Missing: postgres slow-query / `pg_stat_statements` — postgres-exporter can
  expose this; today it doesn't.

### [`homelab-pod-logs-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-pod-logs-dashboard.yaml)

The only dashboard with a variable (`$namespace` from Loki). 2 panels —
log volume by namespace and a flat log feed.

- Add `$pod` (`label_values({namespace="$namespace"}, pod)`) and `$severity`
  (regex `(?i)(error|warn|info|debug)`).
- Add a "log levels stacked" timeseries (`sum by (level) (count_over_time(...))`)
  using a label parser if Alloy is taught to extract `level`. Right now Alloy
  ships logs with no parsing — a missed opportunity.
- Add a "top log producers" table (`topk(20, sum by (pod) (rate({namespace="$namespace"}[5m])))`)
  to surface a chatty pod the moment Loki ingestion approaches the 16 MB/s
  rate or 32 MB burst configured in [`loki/helmrelease.yaml`](../../kubernetes/infrastructure/observability/loki/helmrelease.yaml).
- Panel id 1 uses `drawStyle: bars` for log volume — fine, but legend is a
  table with `lastNotNull`; switch to `total` for a quick "who logs most" read.

### [`homelab-ai-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-ai-dashboard.yaml)

9 panels including a logs panel and a Loki errors-count panel. Ollama-aware,
6h default range.

- "AI Workloads Ready" thresholds assume exactly 4 workloads. Add a $workload
  variable or rebuild as `(replicas_available / replicas_desired)`.
- The Ollama panels assume a single loaded model. With multi-model use,
  `ollama_model_size_bytes` becomes multi-valued and "Ollama Model RAM" stat
  picks an arbitrary one. Convert to a table.
- No GPU panels — the AMD rearchitect may include iGPU/dGPU; add
  `nvidia_gpu_*` or `amd_smi_*` panels behind feature detection (or a text
  panel saying "GPU acceleration not yet deployed").
- No latency/throughput panels: `ollama_request_duration_seconds` and
  `ollama_tokens_generated_total` (if exposed) would make this an actual SLO
  dashboard.
- Add link from each pod row to Pod Logs dashboard pre-filtered to that pod.

### [`homelab-paperless-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-paperless-dashboard.yaml)

8 panels. App-specific; mixes deployment health, PVC fill (bargauge!), Loki
warning/error counts, and a "document and AI activity" Loki count panel.

- The cleanest single-app dashboard pattern. Use it as the template for new
  app dashboards (see "Missing dashboards" §4).
- The Loki regex `Consuming|consumption finished|New document id|/api/chat|truncating`
  is fragile — pin it to a comment or move to a configurable derived field.
- Add a link to the [paperless runbook](../../docs/runbooks/paperless.md)
  in the dashboard's `links`.

### [`homelab-app-versions-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-app-versions-dashboard.yaml)

6 panels. Powered by version-checker. Stats for Updates Available, Tracked
Images, Lookup Failures (1h), Kubernetes Current; tables for image versions
and Kubernetes version.

- Solid for what it does. Add a `$exported_namespace` variable for filtering
  the image-versions table.
- Add a stat panel "Latest Image Lookup" using `time() - max(version_checker_*_timestamp)`
  so a stalled exporter is obvious.

## 3. Coverage gap matrix

Legend: ✓ = present, · = absent, ◐ = partial.

| Workload (path)                                    | Metrics scraped | Dashboard panel | Alert rule |
| -------------------------------------------------- | :-------------: | :-------------: | :--------: |
| kube-state-metrics / node-exporter                 |        ✓        |        ✓        |    ✓ (default rules) |
| Prometheus / Alertmanager / Grafana self           |        ✓        |        ·        |    ✓ (default rules) |
| Loki                                               |    ◐ (alloy SM only) |   ·         |     ·      |
| Alloy                                              |        ✓        |        ·        |     ·      |
| [Traefik](../../kubernetes/infrastructure/controllers/traefik/helmrelease.yaml) |        ·        |        ·        |     ·      |
| [cert-manager](../../kubernetes/infrastructure/controllers/cert-manager/servicemonitor.yaml) |        ✓        |        ·        |    ✓ (cert expiry) |
| [external-dns](../../kubernetes/infrastructure/controllers/external-dns) |        ·        |        ·        |     ·      |
| [metallb](../../kubernetes/infrastructure/controllers/metallb)             |        ·        |        ·        |     ·      |
| [tailscale-operator](../../kubernetes/infrastructure/controllers/tailscale-operator) |    ·    |        ·        |     ·      |
| [local-path-provisioner](../../kubernetes/infrastructure/controllers/local-path-provisioner) |   · |    ·     |     ·      |
| Flux controllers                                   |        ·        |        ·        |     ·      |
| [PostgreSQL (metagross)](../../kubernetes/databases/postgresql/postgres-exporter-servicemonitor.yaml) |   ✓   |   ✓   |     ✓     |
| [Redis](../../kubernetes/databases/redis/servicemonitor.yaml) |   ✓   |   ✓   |     ✓     |
| postgres logical backups                           |        ✓        |        ✓        |    ✓     |
| [pocket-id](../../kubernetes/auth/pocket-id)        |        ·        |        ·        |     ·      |
| [lldap](../../kubernetes/auth/lldap)                |        ·        |        ·        |     ·      |
| [oauth2-proxy](../../kubernetes/auth/oauth2-proxy)  |        ·        |        ·        |     ·      |
| [oauth2-proxy-kenway-arr](../../kubernetes/auth/oauth2-proxy-kenway-arr) |        ·        |        ·        |     ·      |
| [adguard](../../kubernetes/apps/adguard)            |  ◐ (blackbox only)  |   ·   |     ·      |
| [open-webui](../../kubernetes/apps/open-webui)      |    ◐ (kube-state)   |   ✓ (AI dash) |  ✓ (AI alerts) |
| [ollama](../../kubernetes/apps/ollama)              |   ✓ (ollama-exporter) | ✓     |     ✓     |
| [paperless-ngx](../../kubernetes/apps/paperless-ngx) | ◐ (kube-state)  |        ✓        |     ✓     |
| [paperless-gpt](../../kubernetes/apps/paperless-gpt) | ◐ (kube-state)  |        ✓        |     ✓     |
| [hermes](../../kubernetes/apps/hermes)              |    ◐ (kube-state)   |   ◐   |  ✓ (AI alerts) |
| [grimmory](../../kubernetes/apps/grimmory)          |    ◐ (kube-state)   |   ·   |     ·      |
| [recyclarr](../../kubernetes/apps/recyclarr)        |    ◐ (kube-state)   |   ·   |     ·      |
| [uptime-kuma](../../kubernetes/apps/uptime-kuma)    |    ◐ (kube-state)   |   ·   |     ·      |
| [homepage](../../kubernetes/apps/homepage)          |    ◐ (kube-state)   |   ·   |     ·      |
| Media stack (sonarr/radarr/lidarr/prowlarr/bazarr/overseerr/wizarr/tautulli/lazylibrarian/romm) | ◐ (kube-state) | · |     ·      |
| [Beszel](../../kubernetes/infrastructure/observability/beszel) |  · (no Prom export) |   ·   |     ·      |
| [version-checker](../../kubernetes/infrastructure/observability/version-checker) |   ✓   |   ✓   |     ·      |
| [unpoller](../../kubernetes/infrastructure/observability/unpoller/servicemonitor.yaml) |   ✓   |   ✓   |    ✓ (down) |
| [proxmox-exporter](../../kubernetes/infrastructure/observability/proxmox-exporter/servicemonitor.yaml) |  ✓   |   ✓   |    ✓     |
| [blackbox probes](../../kubernetes/infrastructure/observability/blackbox-exporter/servicemonitor.yaml) |  ✓   |   ✓   |    ✓     |
| External: [Plex](../../kubernetes/apps/external-services/plex.yaml) |  · (TLS proxy only) |   ·   |     ·      |
| External: [TrueNAS](../../kubernetes/apps/external-services/truenas.yaml) |  ◐ (NFS port probe) | ◐ |     ·      |
| External: Tdarr / SABnzbd / Homebridge / Homey / Pelican-Wings | · | · | · |
| External: Proxmox hosts (latios / latias / rayquaza) |  ✓ (PVE exporter)  |   ✓   |    ✓     |

## 4. Missing dashboards / alerts

### P0 — fix before anything else

1. **Traefik metrics + RED dashboard.** Enable `metrics.prometheus.serviceMonitor` in
   [`kubernetes/infrastructure/controllers/traefik/helmrelease.yaml`](../../kubernetes/infrastructure/controllers/traefik/helmrelease.yaml),
   and create a dashboard with rate, error %, and `histogram_quantile(0.95,
   sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket[5m])))`.
   Add alerts: `TraefikServiceErrorRateHigh` (5xx > 1% for 10m) and
   `TraefikServiceLatencyHigh` (p95 > 1s for 10m). Without this, every ingress'd
   workload is a black box.
2. **Flux GitOps dashboard + alerts.** Create a `homelab-flux-dashboard.yaml`
   reading `gotk_reconcile_condition`, `gotk_reconcile_duration_seconds`, and
   `gotk_suspend_status`. Add alerts:
   - `FluxKustomizationFailing` — `gotk_reconcile_condition{type="Ready",status="False",kind="Kustomization"} == 1` for 15m.
   - `FluxHelmReleaseFailing` — same on `kind="HelmRelease"`.
   - `FluxResourceSuspended` — `gotk_suspend_status == 1` for 24h (catches forgotten manual suspends).
3. **Auth tier observability.** pocket-id, oauth2-proxy, and lldap each expose
   `/metrics`. Add ServiceMonitors under
   [`kubernetes/auth/`](../../kubernetes/auth/) and a
   `homelab-auth-dashboard.yaml` with login attempts, 4xx/5xx ratio, LDAP bind
   time, oauth2-proxy session count. Alert on
   `rate(oauth2_proxy_requests_total{code=~"5.."}[5m]) > 0` for 5m and on
   absence of any `lldap_*` metric for 10m.

### P1 — high leverage, scoped work

4. **AdGuard query metrics scrape.** AdGuard ships a `/control/stats` HTTP API,
   not a Prometheus endpoint. Either deploy
   [`adguardhome-exporter`](https://github.com/ebrianne/adguard-exporter) as a
   sidecar in [`kubernetes/apps/adguard/`](../../kubernetes/apps/adguard) or
   write a tiny `prometheus.exporter.unix` Alloy-side exporter pulling the JSON.
   Add a panel to the network dashboard: query rate, blocked %, top clients,
   top blocked domains, upstream latency.
5. **Storage / PVC dashboard.** Single dashboard combining `kubelet_volume_stats_*`
   per PVC, `node_filesystem_avail_bytes` for `/var/local-path-provisioner`,
   and a table mapping PVC → node (since [`local-path-provisioner`](../../kubernetes/infrastructure/controllers/local-path-provisioner/helmrelease.yaml)
   pins data). Generic alert: any PVC > 85% for 30m (today only paperless PVCs
   are alerted in [`homelab-alerts.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-alerts.yaml#L57)).
6. **Loki self-observability + LogQL alerts.** Loki is single-binary on
   `local-path` with 20Gi PVC ([loki helmrelease](../../kubernetes/infrastructure/observability/loki/helmrelease.yaml#L48)).
   Add a "Loki health" dashboard (`loki_ingester_*`, `loki_distributor_*`,
   chunks ingested, ingestion errors, query latency) and these LogQL alerts:
   - traefik 5xx surge (once metrics exist, dual-purpose).
   - Postgres `FATAL`/`ERROR` rate spike.
   - Repeated oauth2-proxy failed-login.
   - Flux controller `level=error` rate.
7. **Cert-manager dashboard.** Metrics are scraped already
   ([`servicemonitor.yaml`](../../kubernetes/infrastructure/controllers/cert-manager/servicemonitor.yaml))
   but there is no panel showing time-to-expiry per certificate, ACME challenge
   failures, or HTTP-01/DNS-01 success rate. The existing
   `HomelabCertificateExpiringSoon` alert ([homelab-alerts.yaml](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-alerts.yaml#L13))
   fires a notification but you can't see *which* cert from a dashboard.
8. **Media stack dashboard.** Sonarr/Radarr/Lidarr/Prowlarr each expose a
   Prometheus exporter via the `*arr-exporter` projects. Add ServiceMonitors
   and a single dashboard with queue size, indexer health, history, episode/file
   counts, and download throughput. Pair with alerts on `*arr` deployment
   unavailability (today nothing alerts on these).
9. **Backup observability beyond postgres.** Decide on a strategy (Velero with
   restic to TrueNAS NFS is the lightest fit) and add `velero_backup_*` and
   `velero_restic_*` panels + alerts. Until that lands, document the gap with a
   text panel on the databases dashboard so the missing coverage is visible.

### P2 — nice-to-have

10. **SLO dashboard.** Define SLOs (99.9% homepage success over 30d, p95
    homepage latency < 500 ms, etc.) and use `sloth` or hand-authored
    recording rules to compute burn rates. Wire to multi-window multi-burn-rate
    alerts.
11. **Capacity / cost dashboard for the 3-node rearchitect.** CPU /
    memory / disk headroom per node, projected burn-down based on
    `predict_linear`, derived "$/month if I added one more app" from
    average-pod-utilization.
12. **Beszel coverage.** [Beszel](../../kubernetes/infrastructure/observability/beszel)
    is deployed but has no Prometheus integration and no panel referencing it.
    Either expose its metrics endpoint via its v0.18+ API and scrape it, or
    decide it's redundant with node-exporter and remove it.

## 5. Quick wins (each <1 hour)

- Add `links` array to every dashboard pointing at the others. Single edit per
  file.
- Fix "Ready Nodes" thresholds in
  [k8s-overview](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-k8s-overview-dashboard.yaml#L46-L55)
  to red < 3 / orange = 2 / green = 3.
- Add `$namespace`, `$node` variables to k8s-overview.
- Drop the "Future Databases" empty row from the databases dashboard or replace
  with a markdown text panel.
- Add `runbook_url` annotations to every rule in
  [`homelab-alerts.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-alerts.yaml)
  and [`homelab-ai-network-alerts.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-ai-network-alerts.yaml)
  — the runbooks already exist under [`docs/runbooks/`](../../docs/runbooks).
- Replace per-deployment `deployment=~"a|b|c"` regexes in alerts with a
  ConfigMap-driven label selector, so adding a new AI workload doesn't require
  editing both [`homelab-alerts.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-alerts.yaml#L41)
  *and* [`homelab-ai-network-alerts.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-ai-network-alerts.yaml#L13).
- Add `severity: page|ticket|info` labels to alerts and route via Alertmanager
  rather than hand-tuning duplicate `severity: warning` everywhere.
- Add a generic "any PVC > 85%" rule to
  [`homelab-alerts.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-alerts.yaml#L56)
  (the paperless one is already a copy-paste candidate).
- Add a `topk(5, ...)` "log producers" panel to
  [`homelab-pod-logs-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-pod-logs-dashboard.yaml).

## 6. Larger initiatives

- **Teach Alloy to parse log structure.** Today
  [`alloy/helmrelease.yaml`](../../kubernetes/infrastructure/observability/alloy/helmrelease.yaml#L65)
  ships logs raw with only `cluster=homelab` as a static label. A small
  `loki.process` chain with `stage.regex` / `stage.json` per known producer
  (traefik, postgres, paperless, ollama, oauth2-proxy) lets every dashboard
  get a `level` and a `latency` label for free, unlocks LogQL alerts, and
  makes pod-logs dashboard variables (`$severity`, `$status`) trivial.
- **Single source of truth for "what is an AI workload".** The set
  `ollama|open-webui|hermes|paperless-gpt` is hard-coded in 4 places: the
  AI dashboard, the AI alerts, the paperless alerts, and the paperless
  dashboard. Replace with a Kubernetes label
  (`homelab.mcnees.me/observability-tier=ai`) and select on the label
  everywhere. Same applies to "auth", "media", "core".
- **A traefik-driven SLO framework.** Once metrics land, define one SLO per
  user-facing host and let everything (paperless, open-webui, plex, grafana,
  pocket-id) inherit a generated burn-rate alert. This replaces most of the
  `*Unavailable` alerts in [`homelab-alerts.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-alerts.yaml)
  and [`homelab-ai-network-alerts.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-ai-network-alerts.yaml).
- **Flux as the meta-control plane.** Add a top-level "Homelab Health"
  dashboard that combines: Flux reconcile state, certificate days-to-expiry,
  PVC fill, scrape target up status, blackbox probe rollup. This is the one
  page the operator should glance at first.
- **Decision on storage tier and matching observability.** The migration plan
  ([`2026-03-14-storage-tiering-design.md`](../2026-03-14-storage-tiering-design.md))
  exists; the observability for whichever choice (longhorn / openebs-zfs /
  truenas-csi) needs to land at the same time, not after.
- **Loki HA + retention policy.** Single-binary, filesystem, 20Gi, no
  retention configured ([helmrelease](../../kubernetes/infrastructure/observability/loki/helmrelease.yaml#L29-L39)).
  Logs will silently be evicted when the PVC fills. Set explicit `retention_period`,
  add a Loki self-monitoring dashboard, and decide whether to move to
  S3-compatible object storage on TrueNAS for long-term retention.
