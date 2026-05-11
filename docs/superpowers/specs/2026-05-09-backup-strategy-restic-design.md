# Backup Strategy: restic, Tiered Native Approach — 2026-05-09

> Decision record (and blog-post seed) for how the homelab backs up data
> outside PostgreSQL. The TL;DR is: **most of the bulk data is already on
> TrueNAS NFS, so ZFS snapshots cover it for free; the actually-at-risk
> local-path data is small enough that a single restic repository with the
> existing CronJob pattern is the right tool.** This document captures the
> reasoning, the math, and the alternatives we rejected — both so future me
> remembers why, and so any of it can become a blog post later.

## Why this decision needed making

The [observability audit](observability-audit-2026-05-09.md) flagged that
PostgreSQL has solid backup coverage but everything else — Loki, Prometheus,
Grafana, lldap, paperless, pocket-id — has no snapshot-age metric, no Velero,
no alert. Fair critique. The audit suggested either Velero+restic or
file-level snapshots without picking a winner.

What the audit didn't surface, and what changed the answer, was an honest
inventory of what's actually at risk.

## The data-at-risk inventory

### Already on TrueNAS NFS (~5+ TiB, no K8s tooling needed)

These PVCs use `storageClassName: ""` and bind to NFS PVs that point at
`10.0.1.1:/mnt/data/...`. ZFS snapshots on TrueNAS cover them for free.

| Workload | Path | Size |
|---|---|---|
| paperless-ngx media / consume / export | `/mnt/data/k8s/apps/paperless/...` | 250 + 25 + 50 GiB |
| grimmory-books, grimmory-bookdrop | `/mnt/data/media/library/books`, `/mnt/data/media/bookdrop` | 2 TiB + 250 GiB |
| romm-library | `/mnt/data/media/library/games` | 2 TiB |
| Plex shared media library | (NFS) | (large) |
| postgresql-logical-backups | `/mnt/data/backups/postgresql` | 100 GiB |

### On Talos node disk via `local-path` (~250 GiB, the actual problem)

| Tier | Workload | Size | Recoverable without backup? |
|---|---|---|---|
| **Database** | grimmory MariaDB | 10 GiB | No — needs `mariadb-dump` |
| **Application config / state** | adguard config+work, *arr configs (×11), grimmory-data, paperless-data, paperless-gpt-prompts, hermes data+workspace, open-webui chats, uptime-kuma history | ~150 GiB total | Yes, but tedious to rebuild |
| **Large user-curated data** | romm-assets (box art, screenshots, manuals) | 200 GiB | No — manually curated |
| **Replaceable** | ollama-models | 50 GiB | Yes, re-download |
| **Ephemeral / derived** | Loki, Prometheus, Grafana state | ~75 GiB | Yes, fully derived from configs in Git |

The **actually irreplaceable, must-back-up** local-path data is roughly
**~360 GiB**: ~150 GiB of small config/state PVCs + ~200 GiB of romm-assets +
the MariaDB. Everything else either lives on NFS (snapshots cover it) or is
trivially recreatable.

## What we rejected, and why

### Velero + restic to TrueNAS S3

The most "industry standard" answer. We rejected it for this homelab.

- Velero earns its keep when you have multi-tenant clusters, atomic-restore
  SLAs, multi-cluster DR, or many stateful tenants per cluster. None of those
  describe a one-operator homelab.
- The CRDs + controller surface is heavier than the problem. Velero brings
  `Backup`, `Restore`, `Schedule`, `BackupStorageLocation`,
  `VolumeSnapshotLocation`, plus a controller pod, plus its own
  observability that we'd have to bridge into our existing stack.
- restic-as-Velero-engine works well, but Velero's value-add over running
  restic directly is "K8s objects + PVC data atomically." For a GitOps
  cluster where every K8s object is already in Git, the K8s-object half is
  free — `flux reconcile` rebuilds the cluster from main. We only need the
  PVC half.

### tar + gzip + retention rotation

Simplest possible: nightly tarball, keep N daily / N weekly / N monthly,
delete the rest.

We rejected it on storage math. With ~360 GiB live data and a reasonable
retention (7 daily + 4 weekly + 6 monthly = 17 backups), naïve tar would
consume:

```
360 GiB × 17 ≈ 6 TiB
```

— because tar deduplicates *nothing*. The 11 *arr config dirs with 30–50%
overlap get stored 11×. The mostly-stable MariaDB dump gets stored 17× even
though daily change is small. romm-assets, which barely changes once curated,
gets re-stored fully every night.

That's a backup strategy that ages into a problem.

### rsync + `--link-dest` (Time Machine style)

Each backup is a directory; unchanged *files* are hardlinks to the previous
backup. Storage cost is roughly "live data × (1 + average daily churn × N
retained)" — much better than tar.

We seriously considered this. Pros:
- Backups are browsable directories. No special tool to read them. In an
  emergency, `cd /mnt/data/backups/2026-05-08T03:00/` and grab files.
- Dead simple operationally; no daemon, no key management.

Cons that made us pick restic instead:
- Hardlinks dedupe at *file* granularity, not *block* granularity. SQLite
  databases (every *arr config), MariaDB dumps, and similar
  large-but-mostly-stable files get fully copied every night because the file
  bytes did change, even if 99% of the contents are identical.
- No built-in encryption. Today the backup target is on the LAN; the day we
  add an off-site replica (Backblaze B2, a friend's house, etc.), we'd have
  to re-engineer.
- rsync needs application-aware staging anyway — you can't `rsync` a live
  database, you must dump first. Once you accept "dump first then back up,"
  the operational shape is the same as restic; the dedup story is the only
  differentiator.

## Why restic

Two sentences: **restic does content-defined chunking with global
deduplication and built-in retention, so the storage cost stays roughly
"live data size, total" no matter how long the retention window is.** And
the operational shape — one binary in a CronJob — fits the homelab's existing
postgres backup pattern almost identically.

### The math, with restic

restic chunks files at ~4 MiB content-defined boundaries (rolling hash —
chunks are robust to file-position shifts), compresses chunks (zstd by
default in v0.15+), deduplicates *across the entire repository* by chunk
hash. Concretely for our data:

- Initial backup of ~360 GiB live data → ~120–180 GiB on disk after
  compression and the first round of dedup. (Estimate; actual ratio depends
  on entropy of the data — *arr configs and SQLite are very compressible.)
- Daily delta: only chunks corresponding to changed bytes. For a homelab
  where the *arr DBs see modest churn and romm-assets barely change once
  curated, this is on the order of 1–5 GiB/day raw, dropping to <1 GiB after
  dedup.
- 6-month retention with `forget --keep-daily 7 --keep-weekly 4
  --keep-monthly 6`: the repository converges to roughly **1.0× live data
  size**, because old chunks that are still referenced by any retained
  snapshot are kept, and chunks no longer referenced by any retained
  snapshot are pruned.

So:

| Strategy | Worst case | Realistic steady state |
|---|---|---|
| tar | ~6 TiB | ~6 TiB |
| rsync + hardlinks | ~1.5–2.5 TiB | ~600 GiB–1 TiB |
| restic | ~500 GiB | **~150–250 GiB** |

That's a 20–40× efficiency gain on TrueNAS storage versus the simplest
approach, with no operational complexity penalty.

### The operational shape

Mirrors the existing
[`postgres backup-cronjob.yaml`](../../kubernetes/databases/postgresql/backup-cronjob.yaml)
almost line for line. The pattern per workload:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: <workload>-restic-backup
spec:
  schedule: "30 3 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: backup
              image: restic/restic:0.17.4   # pinned
              env:
                - { name: RESTIC_REPOSITORY, value: "/mnt/restic" }
                - { name: RESTIC_PASSWORD,
                    valueFrom: { secretKeyRef: { name: restic-repo, key: password } } }
              command:
                - /bin/sh
                - -ec
                - |
                  # Optional: dump-first for app-aware backups (DBs)
                  # mariadb-dump > /tmp/dump.sql

                  restic backup /data --tag <workload>
                  restic forget --tag <workload> \
                    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
                    --prune
              volumeMounts:
                - { name: data,    mountPath: /data,    readOnly: true }
                - { name: restic,  mountPath: /mnt/restic }
          volumes:
            - name: data
              persistentVolumeClaim: { claimName: <workload>-config }
            - name: restic
              persistentVolumeClaim: { claimName: restic-repo }
```

Single restic repository for the whole homelab (mounted from TrueNAS NFS at
`/mnt/data/backups/restic-homelab`). One repo, not one per workload, so
cross-workload dedup works — the 11 *arr config dirs share their common
chunks once.

### Observability

Mirrors the
[postgres backup metrics deployment](../../kubernetes/databases/postgresql/backup-metrics-deployment.yaml).
A small Deployment mounts the restic repository read-only, runs
`restic snapshots --json` and `restic stats --json` on a schedule, and emits:

| Metric | Meaning |
|---|---|
| `homelab_backup_latest_timestamp_seconds{tag, kind}` | Most recent successful snapshot per workload |
| `homelab_backup_repo_total_size_bytes` | Logical (un-deduped) size — what tar would store |
| `homelab_backup_repo_physical_size_bytes` | Actual on-disk size after dedup + compression |
| `homelab_backup_repo_snapshot_count{tag}` | Snapshots retained per tag |

The `total / physical` ratio is the dedup-effectiveness signal. If it
collapses week-over-week, something's writing high-entropy data (or the
backup is corrupted) — alert on it.

Alerts (in `homelab-platform-alerts.yaml`, group `homelab.backups`):

- `BackupStale{tag=...}` — `homelab_backup_latest_timestamp_seconds < time() - 36h`
- `BackupRepoFillingUp` — repo physical size > 80% of restic-repo PVC size
- `BackupSizeAnomalous` — ratio of `total / physical` drops > 50% week over week
- `BackupCronJobFailing` — `kube_job_failed{job_name=~"<workload>-restic-backup-.*"} > 0`

### Encryption — included for free

restic encrypts every chunk with a repo-wide passphrase (AES-256, Poly1305
authentication). The passphrase lives in a SOPS-encrypted secret in this
repo. A backup target compromise leaks ciphertext, not data. This costs
nothing today and pays off the day the backup target moves off-LAN.

### Off-site replication — one command later

`restic copy --from-repo /mnt/restic --repo s3:b2:homelab-backup` mirrors the
local repo to a second target. We don't need this yet but the doors are open.

## What restic doesn't solve

Worth being explicit about the limits:

- **Application consistency** is still on us. restic captures the on-disk
  bytes; if a database is mid-transaction, those bytes are inconsistent. For
  databases (postgres, MariaDB) we dump first, then restic the dump. SQLite
  files in *arr configs are slightly risky — but the SQLite WAL mode is
  resilient to in-flight reads, and the *arr apps tolerate restoring from a
  not-quite-consistent SQLite by replaying the WAL on next start.
- **K8s object recovery** is not what restic does. Our K8s objects live in
  Git; we recover by `flux reconcile`. If we ever needed restoring from
  cluster-snapshot for some pathological case, that's where Velero would
  earn its weight — but the homelab GitOps model makes this unnecessary.
- **Bare-metal recovery** of the TrueNAS box itself is out of scope here.
  That's a TrueNAS replication / snapshot story, not a K8s backup story.

## What we'll build (concrete, GitOps-shaped)

1. New SOPS-encrypted secret `restic-repo-credentials` in the `internal`
   namespace with the repository password.
2. Two new PV/PVC pairs: one for the restic repository
   (`/mnt/data/backups/restic-homelab` on NFS, RWX), one for staging dumps if
   needed.
3. Reusable CronJob template per local-path workload to back up. Initial
   set:
   - grimmory MariaDB (dump-first)
   - adguard config (only — `work/` is too churny and low-value)
   - All *arr configs (sonarr, sonarr-anime, radarr, prowlarr, lidarr,
     lidarr-kids, bazarr, lazylibrarian, tautulli, overseerr, wizarr)
   - paperless-data, paperless-gpt-prompts
   - open-webui-data, hermes-data, hermes-workspace
   - uptime-kuma-data
   - grimmory-data
   - romm-config, romm-assets
4. New `homelab-backups-metrics-exporter` Deployment in observability.
5. New PrometheusRule group `homelab.backups`.
6. New Grafana dashboard `homelab-backups-dashboard.yaml`: per-tag latest
   age, total + physical size over time, dedup ratio, recent failures.
7. Document TrueNAS-side ZFS snapshot tasks for the NFS-resident data in
   [`docs/runbooks/truenas.md`](../runbooks/truenas.md):
   `tank/k8s` and `tank/media` — hourly×24, daily×14, weekly×8, monthly×6.

The roadmap entry is in
[`2026-05-09-observability-improvements-roadmap.md`](../plans/2026-05-09-observability-improvements-roadmap.md)
phase D3.

## Lessons / blog-post hooks

- **Inventory before you tool.** The audit suggested Velero. The actual data
  shape — most-bulk-on-NFS-already, small-tail-on-local-path — picked a
  different answer. Counting bytes by tier first changed the recommendation.
- **Block-level dedup is the only thing that bounds backup storage growth
  over long retention.** tar grows linearly in retention × live-data;
  rsync+hardlinks grows linearly in retention × churn; restic grows
  ~constant in live-data. For the homelab horizon (years, not months), only
  the third has stable economics.
- **Match the tool's seriousness to the problem's seriousness.** Velero is
  excellent for what it does. It's the wrong serious for a homelab where
  every K8s object is already in Git. Reach for the lighter tool that fits
  the actual recovery story.
- **Pattern-match within the repo.** The postgres backup CronJob has been
  working for months. Replicating its shape for restic is faster, more
  reliable, and easier to operate than introducing a new abstraction. The
  only diff is the body of the script.
