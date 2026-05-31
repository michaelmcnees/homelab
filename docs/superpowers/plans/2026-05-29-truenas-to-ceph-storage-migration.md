# TrueNAS To Ceph Storage Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce TrueNAS pressure by moving app-private Kubernetes storage to Ceph-backed storage, while keeping TrueNAS as the selective backup target for important data.

**Architecture:** Treat TrueNAS NFS as canonical bulk media and backup storage, not the default place for app data. Use Ceph-backed Kubernetes storage for app-private durable data: native Ceph RBD/CephFS when available, with the current `local-path` provisioner on Ceph-backed Talos VM disks as the interim path. Back up high-value Ceph-resident data back to TrueNAS with explicit jobs and monitoring.

**Tech Stack:** Kubernetes, Flux, Kustomize, SOPS, Rancher local-path-provisioner, TrueNAS NFS, Proxmox/Ceph, RustFS S3, restic.

---

## Current Inventory

### TrueNAS NFS Persistent Volumes

These are the repo-declared static NFS PVs using `10.0.1.1:/mnt/data/...`.

| PV | Claim | Size | Path | Initial Decision |
| --- | --- | ---: | --- | --- |
| `media-library` | `media/media-library` | 120Ti | `/mnt/data/media` | Keep on TrueNAS. This is canonical bulk media. |
| `romm-library` | `media/romm-library` | 2Ti | `/mnt/data/media/library/games` | Keep for now; revisit after app-private moves. |
| `grimmory-books` | `apps/grimmory-books` | 2Ti | `/mnt/data/media/library/books` | Keep for now; likely canonical library data. |
| `grimmory-bookdrop` | `apps/grimmory-bookdrop` | 250Gi | `/mnt/data/media/bookdrop` | Revisit after Paperless and backup rehearsals. |
| `immich-library` | `apps/immich-library` | 1Ti | `/mnt/data/k8s/apps/immich/library` | Safe sandbox while Immich is not in use yet. Use for early backup/restore rehearsal before production migrations. |
| `paperless-media` | `apps/paperless-media` | 250Gi | `/mnt/data/k8s/apps/paperless/media` | Best first migration candidate. |
| `paperless-consume` | `apps/paperless-consume` | 25Gi | `/mnt/data/k8s/apps/paperless/consume` | Migrate with Paperless workflow. |
| `paperless-export` | `apps/paperless-export` | 50Gi | `/mnt/data/k8s/apps/paperless/export` | Keep as backup/export target or migrate after export flow is clear. |
| `obsidian-vault` | `apps/obsidian-vault` | 100Gi | `/mnt/data/reference/obsidian` | Keep unless Syncthing becomes the canonical external access path. |
| `postgresql-logical-backups` | `internal/postgresql-logical-backups` | 100Gi | `/mnt/data/backups/postgresql` | Keep on TrueNAS. This is already backup data. |

### Ceph-Backed Or Ceph-Adjacent PVCs

The repo has no native Ceph CSI storage classes today. Existing `local-path` PVCs land on Talos node disks at `/var/local-path-provisioner` via `kubernetes/infrastructure/controllers/local-path-provisioner/helmrelease.yaml`; those node disks are documented as Proxmox Ceph-backed VM disks. That makes this storage effectively Ceph-backed, but node-bound and not equivalent to proper Ceph RBD/CephFS.

Important `local-path` allocations:

| PVC | Size | Note |
| --- | ---: | --- |
| `object-storage/rustfs-data` | 50Gi | RustFS is not using NFS. It is on `local-path`. |
| `media/romm-assets` | 200Gi | Already off TrueNAS NFS. |
| `media/romm-resources` | 200Gi | Already off TrueNAS NFS. |
| `apps/ollama-models` | 50Gi | Already off TrueNAS NFS. |
| `apps/immich-postgres-data` | 50Gi | Already off TrueNAS NFS. |
| `apps/immich-ml-cache` | 20Gi | Already off TrueNAS NFS. |
| many app config PVCs | 1-20Gi each | Small, but should eventually move to native Ceph RBD for rescheduling safety. |

### Backup State

Backups already point at TrueNAS:

- PostgreSQL logical backups use `internal/postgresql-logical-backups` at `/mnt/data/backups/postgresql`.
- Restic backup scaffolding uses `/mnt/data/backups/restic-homelab`.
- Current implemented restic jobs cover AdGuard config, Grimmory MariaDB, Immich library rehearsal data, and Paperless media/consume/export data.
- The older backup design assumed TrueNAS had space and that NFS-resident app data was covered by ZFS snapshots. That assumption is now stale.

## Quick Review

1. RustFS does not need a TrueNAS migration. It is already on `local-path`, so its bytes are on the Kubernetes node disk path, not an NFS share.
2. Immich is not in use yet, so it is the safest early backup/restore test bed. Use it to prove backup jobs, restore flow, and storage-class behavior before touching production data.
3. The first TrueNAS reclaim target should still be Paperless. It is app-private, bounded at 325Gi across media/consume/export, and is the first meaningful production migration after the Immich rehearsal.
4. Do not move `media-library` first. It is huge, likely canonical outside Kubernetes, and would turn this into a media-platform migration instead of a storage cleanup.
5. Native Ceph CSI is the right end state. `local-path` on Ceph-backed VM disks is useful, but it remains node-bound and awkward for RWX workloads.
6. TrueNAS should become the backup/export tier for Kubernetes app data, not the primary storage tier for every app-private volume.

## Implementation Tasks

### Task 1: Capture Live Cluster Storage Usage

**Files:**
- Create: `docs/runbooks/storage-inventory.md`

- [ ] **Step 1: Gather Kubernetes PV/PVC runtime state**

Run:

```bash
kubectl get pv,pvc -A -o wide
kubectl get storageclass
kubectl top nodes
```

Expected:

- PV/PVC output shows every bound claim and current storage class.
- Storage classes include `local-path`.
- If native Ceph classes already exist live but are missing from GitOps, record them as drift.

- [ ] **Step 2: Gather node disk pressure**

Run:

```bash
kubectl get nodes -o name
kubectl describe nodes | rg -n "Name:|DiskPressure|ephemeral-storage|Allocated resources"
```

Expected:

- No node reports `DiskPressure=True`.
- The runbook records any node where local-path growth would be risky.

- [ ] **Step 3: Write inventory runbook**

Create `docs/runbooks/storage-inventory.md` with:

```markdown
# Storage Inventory

## Storage Classes

- `local-path`: Rancher local-path-provisioner, default class, hostPath volumes under `/var/local-path-provisioner`.
- Static TrueNAS NFS PVs: manually declared PV/PVC pairs pointing at `10.0.1.1:/mnt/data/...`.

## TrueNAS NFS Volumes

| PV | PVC | Size | Path | Decision |
| --- | --- | ---: | --- | --- |
| `media-library` | `media/media-library` | 120Ti | `/mnt/data/media` | Keep on TrueNAS |
| `romm-library` | `media/romm-library` | 2Ti | `/mnt/data/media/library/games` | Keep for now |
| `grimmory-books` | `apps/grimmory-books` | 2Ti | `/mnt/data/media/library/books` | Keep for now |
| `grimmory-bookdrop` | `apps/grimmory-bookdrop` | 250Gi | `/mnt/data/media/bookdrop` | Re-evaluate after Paperless and backup rehearsals |
| `immich-library` | `apps/immich-library` | 1Ti | `/mnt/data/k8s/apps/immich/library` | Use for backup/restore rehearsal before production data moves |
| `paperless-media` | `apps/paperless-media` | 250Gi | `/mnt/data/k8s/apps/paperless/media` | Migrate first |
| `paperless-consume` | `apps/paperless-consume` | 25Gi | `/mnt/data/k8s/apps/paperless/consume` | Migrate with Paperless |
| `paperless-export` | `apps/paperless-export` | 50Gi | `/mnt/data/k8s/apps/paperless/export` | Use as export/backup target or migrate after validation |
| `obsidian-vault` | `apps/obsidian-vault` | 100Gi | `/mnt/data/reference/obsidian` | Keep unless external access changes |
| `postgresql-logical-backups` | `internal/postgresql-logical-backups` | 100Gi | `/mnt/data/backups/postgresql` | Keep on TrueNAS |

## Migration Order

1. Immich rehearsal only: backup, restore, and storage-class proof while the app is not in use.
2. Paperless as the first real TrueNAS reclaim target.
3. Grimmory bookdrop/books if they are app-private.
4. RomM library only if games no longer need direct TrueNAS access.
5. Never move `media-library` as part of this cleanup plan.
```

- [ ] **Step 4: Verify docs render cleanly**

Run:

```bash
git diff --check docs/runbooks/storage-inventory.md
```

Expected: no output.

### Task 2: Choose Native Ceph CSI Or Interim Local-Path

**Status:** Complete. Native Ceph CSI was added on 2026-05-30.

**Files:**
- Modify: `docs/runbooks/storage-inventory.md`
- Create if native Ceph CSI is chosen: `kubernetes/infrastructure/controllers/ceph-csi/`

- [x] **Step 1: Check whether native Ceph CSI is already installed**

Run:

```bash
kubectl get storageclass
kubectl get pods -A | rg -i "ceph|rook|rbd|cephfs"
rg -n "ceph|rook|rbd|cephfs" kubernetes docs ansible
```

Expected:

- If no Ceph classes or CSI pods exist, keep implementation on the interim `local-path` path for the first Paperless migration unless Ceph credentials are ready.
- If Ceph classes exist live, record the class names in `docs/runbooks/storage-inventory.md` and add missing GitOps manifests before migrating data.

- [x] **Step 2: Decide the first migration storage class**

Use this decision rule:

```text
If native Ceph RBD/CephFS exists and is GitOps-managed:
  Use CephFS for RWX Paperless media/consume/export replacement volumes.
  Use RBD for RWO app config volumes.
Else:
  Use local-path for the first Paperless proof-of-pattern only if the target app can tolerate node-bound storage.
```

- [x] **Step 3: Record the decision**

Append this section to `docs/runbooks/storage-inventory.md`:

```markdown
## Storage Class Decision

The first migration will use one of these paths:

- Native Ceph path: CephFS for RWX app-private files, RBD for RWO app state.
- Interim path: `local-path` on Ceph-backed Talos VM disks for one bounded migration, followed by native Ceph CSI work before additional high-value migrations.

Immich is the first backup/restore rehearsal target because it is not in use yet. Paperless remains the first production migration and TrueNAS reclaim target.
```

### Task 3: Use Immich As A Backup/Restore Rehearsal

**Files:**
- Modify: `docs/runbooks/immich.md`
- Create: `kubernetes/backups/immich-library-restic-cronjob.yaml`
- Modify: `kubernetes/backups/kustomization.yaml`
- Modify: `kubernetes/backups/backup-alerts.yaml`
- Optionally modify after rehearsal proof: `kubernetes/apps/immich/pvc.yaml`

- [x] **Step 1: Document Immich restore requirements**

Create or update `docs/runbooks/immich.md` with:

```markdown
# Immich

## Storage

- `immich-library`: unused photo/video library rehearsal volume.
- `immich-postgres-data`: app database PVC.
- `immich-ml-cache`: machine-learning cache.

## Rehearsal Rule

Immich is not in use yet, so it can be used as a safe backup/restore and storage migration rehearsal before production app data moves.

Before migrating production workloads:

1. Create a successful Immich library backup on TrueNAS.
2. Restore that backup into a temporary PVC.
3. If desired, move the unused `immich-library` PVC to the selected Ceph-backed class to prove the copy and rollback steps.
4. Record the observed backup, restore, and storage-class behavior for the Paperless migration.
```

- [x] **Step 2: Add Immich library backup for rehearsal**

Create `kubernetes/backups/immich-library-restic-cronjob.yaml` with schedule:

```yaml
spec:
  schedule: "15 8 * * *"
  concurrencyPolicy: Forbid
```

Use restic tag:

```text
immich-library
```

- [x] **Step 3: Verify backup and restore**

Run:

```bash
kubectl kustomize kubernetes/backups
kubectl -n apps create job --from=cronjob/immich-library-restic-backup immich-library-restic-backup-manual
kubectl -n apps wait job/immich-library-restic-backup-manual --for=condition=complete --timeout=4h
```

Expected: backup completes before any production storage migration is attempted.

Result: completed on 2026-05-30. Snapshot `1059b4d8` restored successfully into a throwaway `local-path` PVC. The scheduled job now runs at `08:15` to avoid overlapping with larger Paperless backups.

### Task 4: Build Backup Coverage Before Moving Paperless

**Files:**
- Create: `kubernetes/backups/paperless-restic-cronjob.yaml`
- Modify: `kubernetes/backups/kustomization.yaml`
- Modify: `docs/runbooks/paperless.md`

- [x] **Step 1: Add a Paperless restic backup CronJob**

Create `kubernetes/backups/paperless-restic-cronjob.yaml` following the existing restic pattern from `kubernetes/backups/adguard-config-backup-cronjob.yaml`, with:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: paperless-restic-backup
  namespace: apps
spec:
  schedule: "30 4 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
```

Mount:

- `paperless-media` read-only from namespace `apps`.
- `paperless-consume` read-only from namespace `apps`.
- `paperless-export` read-only from namespace `apps`.
- the restic repository at `/mnt/restic`.

Use one restic snapshot containing all three Paperless paths with all of these tags:

- `paperless-media`
- `paperless-consume`
- `paperless-export`
- `homelab`

Use host `paperless` and retention of 7 daily, 4 weekly, and 6 monthly snapshots.

- [x] **Step 2: Wire the CronJob into Kustomize**

Add this line to `kubernetes/backups/kustomization.yaml`:

```yaml
  - paperless-restic-cronjob.yaml
```

- [x] **Step 3: Rely on generic backup staleness alert**

Do not add a duplicate Paperless-specific alert. The existing generic `BackupStale` alert covers `paperless-media`, `paperless-consume`, and `paperless-export` after the first successful snapshot is exported by `backup-metrics-exporter`.

- [x] **Step 4: Verify render**

Run:

```bash
kubectl kustomize kubernetes/backups
```

Expected: manifests render with the new Paperless CronJob and the existing generic backup alerts.

### Task 5: Migrate Paperless Storage

**Files:**
- Modify: `kubernetes/apps/paperless-ngx/pvc.yaml`
- Modify: `docs/runbooks/paperless.md`

**Status:** Unblocked by native Ceph CSI. The Paperless backup and restore rehearsal passed on 2026-05-30 with snapshot `6cf2671e`; `ceph-cephfs` now passed a RWX smoke test and is the target storage class for Paperless media/consume/export.

Ceph inventory from 2026-05-30:

- Cluster health: `HEALTH_OK`
- FSID: `940ec7cc-501f-4b4c-b938-4b304f133c04`
- Monitors: `10.0.3.196:3300`, `10.0.1.100:3300`, `10.0.3.40:3300`
- Existing VM/LXC data pool: `ceph-nvme`, application `rbd`, size `2`, min size `2`
- Kubernetes RBD pool: `kubernetes-rbd`, application `rbd`, size `2`, min size `2`
- Kubernetes CephFS pools: `k8s-cephfs-data` and `k8s-cephfs-metadata`, size `2`, min size `2`
- CephFS filesystem: `k8s-cephfs`
- Kubernetes storage classes:
  - `ceph-rbd`
  - `ceph-cephfs`
- Approximate available capacity: 3.4 TB

Use `ceph-cephfs` for the Paperless file volumes. Keep `paperless-export` on TrueNAS only if it is intentionally an export/backup handoff rather than app-private working storage.

- [ ] **Step 1: Freeze Paperless writes**

Run:

```bash
kubectl -n apps scale deploy paperless-ngx --replicas=0
kubectl -n apps wait deploy paperless-ngx --for=jsonpath='{.status.replicas}'=0 --timeout=120s
```

Expected: Paperless deployment has zero running pods.

- [ ] **Step 2: Copy data to the new storage target**

Use a one-shot migration Job that mounts the old NFS PVC and the new Ceph-backed PVC, then runs:

```bash
rsync -aHAX --numeric-ids --info=progress2 /old/ /new/
```

Expected:

- Job exits 0.
- A second dry run shows no file changes:

```bash
rsync -aHAXn --numeric-ids --delete /old/ /new/
```

- [ ] **Step 3: Switch Paperless to the new PVCs**

Modify `kubernetes/apps/paperless-ngx/pvc.yaml` so the Paperless app-private volumes are no longer static TrueNAS NFS PVs:

- `paperless-media`
- `paperless-consume`
- `paperless-export`, unless export remains intentionally on TrueNAS

Use the storage class chosen in Task 2.

- [ ] **Step 4: Reconcile and verify Paperless**

Run:

```bash
kubectl kustomize kubernetes/apps
flux reconcile kustomization apps --with-source
kubectl -n apps rollout status deploy/paperless-ngx --timeout=5m
```

Expected:

- Render succeeds.
- Flux applies successfully.
- Paperless starts and can read existing documents.

- [ ] **Step 5: Confirm backup after migration**

Run:

```bash
kubectl -n apps create job --from=cronjob/paperless-restic-backup paperless-restic-backup-manual
kubectl -n apps wait job/paperless-restic-backup-manual --for=condition=complete --timeout=4h
```

Expected: backup job completes successfully.

### Task 6: Revisit RustFS Capacity And Backups

**Files:**
- Modify: `kubernetes/storage/rustfs/pvc.yaml`
- Create: `docs/runbooks/rustfs.md`
- Create if needed: `kubernetes/backups/rustfs-bucket-backup-cronjob.yaml`

- [ ] **Step 1: Decide whether RustFS remains the object store hub**

Current state:

```text
object-storage/rustfs-data = 50Gi local-path
```

If Penpot, Outline, Invoice Ninja, Chatwoot, and future app attachments all use RustFS, increase capacity before moving more data into buckets.

- [ ] **Step 2: Add RustFS runbook**

Create `docs/runbooks/rustfs.md` with:

```markdown
# RustFS

RustFS is the in-cluster S3-compatible object store. Its PVC is `object-storage/rustfs-data`.

## Current Backing

The PVC uses `local-path`, which writes under `/var/local-path-provisioner` on Talos nodes. In this homelab, those VM disks are backed by Proxmox/Ceph, but the Kubernetes storage class is still node-bound local-path storage.

## Backup Rule

Buckets containing irreplaceable user data must have an explicit backup job to TrueNAS. Cache-only buckets do not need backup.
```

- [ ] **Step 3: Add bucket backup jobs only for important buckets**

Back up buckets that contain user-created attachments or documents. Do not back up disposable caches.

Run after adding each backup:

```bash
kubectl kustomize kubernetes/backups
```

Expected: backup manifests render successfully.

## Completion Criteria

- Paperless no longer depends on TrueNAS NFS for app-private active storage.
- Paperless backups land on TrueNAS and have an alert for staleness.
- Immich has backup and restore proof from the unused-library rehearsal before production data moves.
- RustFS backing and backup policy are documented.
- `media-library`, PostgreSQL logical backups, and restic repository remain on TrueNAS intentionally.
- All changed Kustomize roots render successfully:

```bash
kubectl kustomize kubernetes/backups
kubectl kustomize kubernetes/apps
kubectl kustomize kubernetes/storage
kubectl kustomize kubernetes
git diff --check
```
