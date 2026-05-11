# Observability Improvements Roadmap — 2026-05-09

Companion execution plan to [`observability-audit-2026-05-09.md`](../specs/observability-audit-2026-05-09.md).

The audit produced 12 prioritized items plus 5 larger initiatives. Quick wins
already landed in this branch. This document sequences the rest by dependency,
not just by priority, so each phase can be merged independently without
breaking the next one.

## Status legend

- ☐ pending
- ▣ in progress
- ✓ landed
- ⏸ deferred — blocked on a decision

## Phase A — Independent dashboard work

Pure Grafana JSON. No HelmRelease changes, no new exporters. All metrics are
already scraped. Each item is one ConfigMap edit.

- ✓ A0. Quick wins from audit (Ready Nodes thresholds, drop Future Databases
  row, generic PVC alert, runbook_url annotations, top log producers panel,
  cross-dashboard links).
- ✓ A1. **Storage / PVC dashboard** (`homelab-storage-dashboard.yaml`). PVC fill
  table, per-node filesystem fill, PVC → pod → node mapping table.
- ✓ A2. **Cert-manager dashboard** (`homelab-certmanager-dashboard.yaml`).
  Per-certificate days-to-expiry table, ACME request rate / latency, controller
  sync rate.
- ✓ A3. **Capacity / headroom dashboard** (`homelab-capacity-dashboard.yaml`).
  Cluster-wide and per-node CPU/memory/pod-density headroom, root filesystem
  fill, 7-day `predict_linear` projection table.
- ✓ A4. **K8s overview enhancements.** CPU formula → idle-based percentunit,
  memory formula → utilisation percentunit, `$node`/`$namespace` variables,
  pending-pods/CrashLoopBackOff/node-pressure panels, PVC % full table.
- ✓ A5. **Proxmox dashboard enhancements.** Edit `homelab-proxmox-dashboard.yaml`.
  Added `$proxmox_node` variable based on real PVE node names, storage usage /
  inventory panels, VM/LXC CPU and memory panels, and replaced "Down Scrape
  Targets" with a table that names each target. Verified live
  `prometheus-pve-exporter` metrics; direct swap and ZFS pool health metrics are
  not exposed by this exporter, so those panels are intentionally deferred until
  we add a host-level exporter or custom collector.
- ✓ A6. **AI dashboard enhancements.** Edit `homelab-ai-dashboard.yaml`. Added
  `$ai_workload` / `$ollama_model` filters, converted Ollama model RAM and
  context stats to multi-model tables, replaced hardcoded ready count with a
  `replicas_available / replicas_desired` readiness ratio, and added workload
  log links into the Pod Logs dashboard. Also added a `$pod` filter to
  `homelab-pod-logs-dashboard.yaml` so linked workload logs are pre-filtered.
- ✓ A7. **Network dashboard enhancements.** Edit `homelab-network-dashboard.yaml`.
  Added `$network_path`, `$probe`, `$ap_name`, and `$essid` variables and wired
  existing blackbox / UniFi panels through them.
- ✓ A8. **App-versions dashboard enhancement.** Edit `homelab-app-versions-dashboard.yaml`.
  Added `$exported_namespace` filter and a "latest image lookup age" stat
  (`time() - max(version_checker_last_checked)`).
- ✓ A9. **Databases dashboard enhancements.** Edit `homelab-databases-dashboard.yaml`.
  Added `$datname`, wired Postgres size / connection / transaction / cache
  panels through it, cleaned threshold details out of stat titles, and rebuilt
  Database Inventory as a joined table with size, connections, deadlocks, and
  cache-hit columns.

## Phase B — Enable scraping of unscraped components

HelmRelease / ServiceMonitor changes only. No dashboards yet. Each item lands
independently. Verify scrape target is `up` before moving the matching Phase C
dashboard work.

- ✓ B1. **Traefik metrics + ServiceMonitor.** Enabled
  `metrics.prometheus.serviceMonitor` in
  [`controllers/traefik/helmrelease.yaml`](../../kubernetes/infrastructure/controllers/traefik/helmrelease.yaml)
  with `release: kube-prometheus-stack` selector label.
- ✓ B2. **Flux PodMonitor.** Added
  [`flux-podmonitor.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/flux-podmonitor.yaml)
  selecting on `app.kubernetes.io/part-of: flux` in flux-system, scraping
  `http-prom` port. Flux ships annotation-based scrape config but no
  ServiceMonitor; this PodMonitor closes the gap.
- ✓ B3. **Auth tier ServiceMonitors.**
  - ✓ oauth2-proxy: `--metrics-address=0.0.0.0:44180` added,
    [`servicemonitor.yaml`](../../kubernetes/auth/oauth2-proxy/servicemonitor.yaml)
    in place.
  - ⏸ pocket-id v2.5: no native Prometheus endpoint. Current coverage is
    kube-state-metrics + Loki + blackbox; sidecar/exporter work is deferred
    until we see a concrete gap.
  - ⏸ lldap: no native Prometheus endpoint. Current coverage is
    kube-state-metrics + Loki + blackbox; sidecar/exporter work is deferred
    until we see a concrete gap.
  - ⏸ kenway-arr oauth2-proxies: scope deferred (Tailscale-only ingress;
    not on the home network critical path).
- ✓ B4. **Loki ServiceMonitor.** Added an explicit `ServiceMonitor` for the
  Loki `http-metrics` service port with the `release: kube-prometheus-stack`
  selector label. Prereq for C4.
- ✓ B5. **Controller plane ServiceMonitors.** Audited `external-dns`, `metallb`,
  `tailscale-operator`, and `local-path-provisioner` for `/metrics` endpoints.
  Added an `external-dns` `ServiceMonitor` plus MetalLB controller/speaker
  `PodMonitor`s for `monitoring` and `frrmetrics`. Skipped Tailscale operator
  and local-path-provisioner because their deployed pods expose no metrics port.

## Phase C — New dashboards/alerts that depend on Phase B

Each item is one new ConfigMap dashboard plus PrometheusRule additions.

- ✓ C1. **Traefik RED dashboard + ingress alerts.**
  [`homelab-traefik-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-traefik-dashboard.yaml)
  + alerts in
  [`homelab-platform-alerts.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-platform-alerts.yaml)
  (`TraefikServiceErrorRateHigh`, `TraefikServiceLatencyHigh`, `TraefikDown`).
- ✓ C2. **Flux GitOps dashboard + alerts.**
  [`homelab-flux-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-flux-dashboard.yaml)
  + alerts (`FluxKustomizationFailing`, `FluxHelmReleaseFailing`,
  `FluxResourceSuspended`, `FluxControllerDown`).
- ✓ C3. **Auth tier dashboard + alerts.**
  [`homelab-auth-dashboard.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-auth-dashboard.yaml)
  combines oauth2-proxy native metrics with kube-state-metrics for pocket-id /
  lldap and Loki error counts. Alerts: `OAuth2ProxyErrorRateHigh`,
  `AuthDeploymentUnavailable`.
- ✓ C4. **Loki health dashboard + LogQL alerts.** Added
  `homelab-loki-dashboard.yaml` covering Loki scrape status, ingestion rate,
  bytes received, request/query latency, storage failures, memberlist health,
  memory, and log-pattern panels for Postgres, oauth2-proxy, and Flux errors.
  Added Prometheus-side Loki health alerts for target down, stopped ingestion,
  high latency, storage failures, and memberlist health. True LogQL alerts are
  intentionally deferred until we choose Loki Ruler or Grafana-managed
  alerting; `PrometheusRule` cannot evaluate LogQL.

## Phase D — Decisions made (2026-05-09 grilling session)

All four items resolved through guided design discussion. Each has a concrete
implementation plan; nothing here is blocked on more deciding.

### ✓ D1. AdGuard query metrics — separate Deployment

Deploy [`ebrianne/adguard-exporter`](https://github.com/ebrianne/adguard-exporter)
as a standalone Deployment in the `observability` namespace, scraped via a
ServiceMonitor with the `release: kube-prometheus-stack` selector label.
Mirrors the existing pattern of `proxmox-exporter`, `ollama-exporter`,
`unpoller`. Decoupled lifecycle from a critical-tier pod.

### ✓ D1.5 (added during grilling). AdGuard HA — active-active, two replicas

The metrics decision triggered a redundancy decision. Final shape:

- **Two independent Deployments**: `adguard-a` (primary, IP `10.0.10.201`,
  preserves existing PVC and config) and `adguard-b` (replica, new IP
  `10.0.10.202`, fresh PVCs, syncs from `adguard-a`).
- **Two RWO `local-path` PVCs per replica** (4 total). Hot query log stays
  off NFS to avoid I/O on the wire and to keep replica failure domains
  truly independent.
- **Config sync via [bakito/adguardhome-sync](https://github.com/bakito/adguardhome-sync)**
  Deployment polling primary every 10m and pushing to replica via REST API.
  Web UI on `adguard-a` is the source of truth; web UI on `adguard-b` works
  but changes get overwritten.
- **`topologySpreadConstraints` with `whenUnsatisfiable: DoNotSchedule`** on
  `kubernetes.io/hostname` — non-negotiable for HA on a 3-node cluster.
- **`externalTrafficPolicy: Local`** on both Services (preserve client IPs
  for AdGuard's per-client filtering rules).
- **Single adguard-exporter Deployment** scraping both via env-var targets
  (`ADGUARD_HOSTNAME_0=adguard-a.apps.svc:80`, `..._1=adguard-b...`).
- **UniFi DHCP option 6** advertises both `.201` and `.202`. Clients see
  two DNS servers; failover is at the resolver layer (instant), not at the
  pod-reschedule layer.
- **Migration is additive**: rename current Deployment to `adguard-a`
  (existing PVC stays bound), add `adguard-b` from scratch, sync populates
  config on first run. No data loss.

### ✓ D2. Media stack — `onedr0p/exportarr` for Tier 1 + tautulli-exporter for Tier 2

Tiered scope:

- **Tier 1 (rich app metrics):** sonarr, sonarr-anime, radarr, prowlarr,
  lidarr, lidarr-kids, bazarr — all via [`onedr0p/exportarr`](https://github.com/onedr0p/exportarr).
  One Deployment per *arr in the `media` namespace, env-driven config, API
  keys in a single SOPS-encrypted `media-exporter-keys` Secret. One
  ServiceMonitor selecting on `app.kubernetes.io/component: exportarr` for
  all of them.
- **Tier 2 (community exporter):** tautulli via [`sebcaillot/tautulli_exporter`](https://github.com/sebcaillot/tautulli_exporter).
- **Tier 3 (pod-health-only, accepted):** overseerr, lazylibrarian, wizarr,
  romm. Use kube-state-metrics + existing blackbox HTTP probes; if we find
  we need more later, revisit.
- **One new dashboard:** `homelab-media-dashboard.yaml`. Sections per *arr:
  queue size, indexer health table, history rate, missing/wanted counts.
- **New alerts (in `homelab-platform-alerts.yaml`, group `homelab.media`):**
  `MediaIndexerDown`, `MediaQueueStalled`, `MediaArrUnhealthy`.

### ✓ D3. Backups beyond postgres — restic with single repo, tiered native approach

See full design doc:
[`2026-05-09-backup-strategy-restic-design.md`](../specs/2026-05-09-backup-strategy-restic-design.md).

- **TL;DR:** Velero is over-engineered for this risk surface. Most bulk data
  is already on TrueNAS NFS (covered by ZFS snapshots for free); the
  actually-at-risk local-path data is ~360 GiB. A single restic repository
  used inside the existing CronJob pattern (mirroring postgres) covers it.
- **Storage math drove the decision:** tar would consume ~6 TiB at 6mo
  retention; rsync+hardlinks ~600 GiB–1 TiB; restic ~150–250 GiB (constant
  in retention thanks to chunk-level dedup).
- **Skip from backups:** observability state (Loki, Prometheus, Grafana) —
  fully ephemeral, all configuration is in Git. ollama-models — re-downloadable.
- **TrueNAS-side:** ZFS Periodic Snapshot Tasks on `tank/k8s` and `tank/media`
  (hourly×24, daily×14, weekly×8, monthly×6) cover the NFS-resident data.
  Documented in [`docs/runbooks/truenas.md`](../runbooks/truenas.md).
- **Backup metrics + alerts** mirror the postgres pattern: a small
  read-only-mounted Deployment runs `restic snapshots --json` and emits
  per-tag latest-snapshot-age + repo size metrics. New alert group
  `homelab.backups` with `BackupStale`, `BackupRepoFillingUp`,
  `BackupSizeAnomalous`, `BackupCronJobFailing`.
- **New dashboard:** `homelab-backups-dashboard.yaml` — per-tag age, total
  vs physical size, dedup ratio (catches corruption signals).
- **Encryption** is included for free (restic native AES-256). Off-site
  replication is a future `restic copy` away.

### ✓ D4. Beszel — keep, repurpose for physical hosts only

User redirect: keep Beszel as a deliberately-scoped tool for non-cluster
machines. Cluster monitoring stays with kube-prometheus-stack.

- **Drop oauth2-proxy middleware** from Beszel's IngressRoute. Beszel has
  its own auth system and an admin user model; manage family-member access
  through Beszel directly.
- **Add Tailscale exposure** via the existing tailscale-operator so roaming
  hosts (laptops, traveling Mac Studio) can reach the hub off-LAN.
- **Per-host agents installed via Ansible** — new `ansible/roles/host-monitoring`
  role that installs *both* the Beszel agent and node-exporter idempotently
  per-OS (macOS via brew, Linux via systemd unit + binary). Tailscale stays
  out-of-band per-device (different lifecycle from monitoring agents). This
  satisfies user requirement: "I don't want to manage three packages per
  workstation by hand."
- **Two parallel data paths chosen deliberately:** Beszel agent → Beszel hub
  (UI + alerting). node-exporter → Prometheus (Grafana). Each tool does its
  native job; no glue exporter to maintain.
- **Phones / tablets covered via:**
  - **Tailscale API exporter** (community or rolled small) — emits
    `tailscale_device_*` metrics: last_seen, online, os, version. Pulls
    `/api/v2/tailnet/-/devices` every 60s. Read-only OAuth client.
  - **`unifi_client_*` metrics** already flowing from `unpoller` (the audit
    flagged these aren't surfaced in any dashboard yet — this is when they
    earn their keep). Per-device hostname, AP, RSSI, last DHCP renewal.
  - These two answer different questions: Tailscale = "device reachable
    anywhere"; UniFi = "device on home Wi-Fi right now."
- **New dashboard:** `homelab-household-compute-dashboard.yaml` — separate
  from the homelab capacity dashboard. Sections: workstations (from
  node-exporter, tagged `job=household_compute`), battery (laptops only),
  Beszel UI link panels, phones/tablets row (Tailscale + UniFi joined).
- **New alert group `homelab.physical-hosts`:** generic filesystem fill,
  memory pressure, host-down on the static targets — but careful about
  noise (a laptop being asleep is not an alert).

## Phase E — Larger initiatives (multi-step, design first)

Each of these wants its own design doc before implementation.

- ⏸ E1. **Alloy log parsing.** Add `loki.process` chain in
  [`alloy/helmrelease.yaml`](../../kubernetes/infrastructure/observability/alloy/helmrelease.yaml)
  with per-producer parsers (traefik, postgres, paperless, ollama, oauth2-proxy)
  to extract `level`, `status`, `latency`. Unlocks LogQL alerts and dashboard
  variables (`$severity`, `$status`).
- ⏸ E2. **Label-based "workload tier" selection.** Add label
  `homelab.mcnees.me/observability-tier=ai|auth|media|core` to deployments.
  Refactor PrometheusRules and dashboards to select by label instead of regex.
- ⏸ E3. **Traefik-driven SLO framework.** Once C1 lands, define one SLO per
  user-facing host. Generate burn-rate alerts. Replaces most `*Unavailable`
  alerts in `homelab-alerts.yaml` and `homelab-ai-network-alerts.yaml`.
- ⏸ E4. **Homelab Health meta-dashboard.** Single page combining Flux reconcile
  state, certificate days-to-expiry, PVC fill, scrape target up status,
  blackbox probe rollup. Depends on C2, C4 landing.
- ⏸ E5. **Loki retention + HA decision.** Single-binary, filesystem, 20Gi, no
  retention configured. Set explicit `retention_period`. Decide whether to
  move to S3-compatible object storage on TrueNAS.

## Execution order

1. Phase A (low-risk, in-place edits) — work through A1..A9 in batches.
2. Phase B (enable scraping) — B1..B5 in parallel where possible. Verify
   scrape targets `up` before declaring done.
3. Phase C, item by item, gated on the matching B item.
4. Pause for D1..D4 decisions.
5. Begin E series with their own design docs.

## Tracking

Each item gets checked off in this file as it lands. Items that grow into
their own design docs should add a link from the bullet to the new spec.
