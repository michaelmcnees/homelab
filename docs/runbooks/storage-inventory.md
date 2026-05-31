# Storage Inventory

Last checked: 2026-05-30.

## Storage Classes

| StorageClass | Provisioner | Reclaim | Binding | Expansion | Notes |
| --- | --- | --- | --- | --- | --- |
| `local-path` | `cluster.local/local-path-provisioner` | `Retain` | `WaitForFirstConsumer` | yes | Default class. Uses hostPath storage under `/var/local-path-provisioner`. |
| `ceph-rbd` | `rbd.csi.ceph.com` | `Delete` | `Immediate` | yes | Native Ceph CSI RBD class for RWO app state. Uses the `kubernetes-rbd` pool. |
| `ceph-cephfs` | `cephfs.csi.ceph.com` | `Delete` | `Immediate` | yes | Native Ceph CSI CephFS class for file-oriented/RWX app data. Uses filesystem `k8s-cephfs`. |

`local-path` remains the default class. The Ceph classes are opt-in until app migrations are tested one workload at a time.

## Nodes

| Node | Role | Status | CPU | Memory | Ephemeral Storage |
| --- | --- | --- | ---: | ---: | ---: |
| `articuno` | control-plane | Ready, no DiskPressure | 4 cores | ~10Gi | ~48Gi |
| `moltres` | control-plane | Ready, no DiskPressure | 4 cores | ~10Gi | ~48Gi |
| `zapdos` | control-plane | Ready, no DiskPressure | 4 cores | ~10Gi | ~48Gi |
| `ho-oh` | worker | Ready, no DiskPressure | 6 cores | ~20Gi | ~100Gi |
| `lugia` | worker | NotReady on 2026-05-30 | 8 cores | ~40Gi | ~100Gi |

`kubectl top nodes` showed low CPU pressure and moderate memory pressure during the original inventory. Local-path capacity should still be treated carefully because it is node-bound and depends on where pods schedule.

## TrueNAS NFS Volumes

These are static PV/PVC pairs pointing at `10.0.1.1:/mnt/data/...`.

| PV | PVC | Size | Path | Decision |
| --- | --- | ---: | --- | --- |
| `media-library` | `media/media-library` | 120Ti | `/mnt/data/media` | Keep on TrueNAS. This is canonical bulk media. |
| `romm-library` | `media/romm-library` | 2Ti | `/mnt/data/media/library/games` | Keep for now; revisit after app-private moves. |
| `grimmory-books` | `apps/grimmory-books` | 2Ti | `/mnt/data/media/library/books` | Keep for now; likely canonical library data. |
| `grimmory-bookdrop` | `apps/grimmory-bookdrop` | 250Gi | `/mnt/data/media/bookdrop` | Re-evaluate after Paperless and Immich. |
| `immich-library` | `apps/immich-library` | 1Ti | `/mnt/data/k8s/apps/immich/library` | Good backup/restore rehearsal target because Immich is not in use yet. |
| `paperless-media` | `apps/paperless-media` | 250Gi | `/mnt/data/k8s/apps/paperless/media` | First real TrueNAS reclaim target. |
| `paperless-consume` | `apps/paperless-consume` | 25Gi | `/mnt/data/k8s/apps/paperless/consume` | Migrate with Paperless workflow. |
| `paperless-export` | `apps/paperless-export` | 50Gi | `/mnt/data/k8s/apps/paperless/export` | Use as export/backup target or migrate after validation. |
| `obsidian-vault` | `apps/obsidian-vault` | 100Gi | `/mnt/data/reference/obsidian` | Keep unless Syncthing becomes the canonical external access path. |
| `postgresql-logical-backups` | `internal/postgresql-logical-backups` | 100Gi | `/mnt/data/backups/postgresql` | Keep on TrueNAS. This is already backup data. |

## Local-Path Volumes

The live cluster uses `local-path` for application config/state, observability state, Redis persistence, RustFS, and several media app support volumes. This is effectively Ceph-adjacent in this lab because Talos VM disks live on Proxmox/Ceph, but Kubernetes sees these as node-local hostPath volumes.

Large or important allocations:

| PVC | Size | Note |
| --- | ---: | --- |
| `object-storage/rustfs-data` | 50Gi | Active RustFS data PVC; not backed by NFS. |
| `media/romm-assets` | 200Gi | Already off TrueNAS NFS. |
| `media/romm-resources` | 200Gi | Already off TrueNAS NFS. |
| `apps/ollama-models` | 50Gi | Already off TrueNAS NFS. |
| `apps/immich-postgres-data` | 50Gi | Immich app database PVC. |
| `apps/immich-ml-cache` | 20Gi | Immich ML cache. |
| `observability/prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0` | 50Gi | Prometheus data. |
| `observability/storage-loki-0` | 20Gi | Loki data. |

The live cluster also has retained released PVs for old `storage/rustfs-data`, `apps/outline-data`, and `apps/paperless-ai-next-data` claims. Clean those up only after confirming they are intentionally abandoned.

## Backup State

- PostgreSQL logical backups write to `internal/postgresql-logical-backups`, backed by `/mnt/data/backups/postgresql` on TrueNAS.
- Restic repository jobs use `/mnt/data/backups/restic-homelab` on TrueNAS.
- Current implemented restic jobs cover AdGuard config, Grimmory MariaDB, Immich library rehearsal data, and Paperless media/consume/export data.
- The older backup design assumed NFS app data could rely on TrueNAS snapshots. That assumption is stale now that TrueNAS capacity is constrained.

## Migration Order

1. Use Immich for backup/restore rehearsal because it is not in use yet.
2. Move Paperless after the backup pattern is proven; it is the first meaningful TrueNAS reclaim target.
3. Revisit Grimmory bookdrop/books only if they are app-private rather than canonical library data.
4. Revisit RomM library only if games no longer need direct TrueNAS access.
5. Keep `media-library`, PostgreSQL logical backups, and the restic repository on TrueNAS.

## Storage Class Decision

Native Ceph CSI is now installed and should be the target for app-private migrations:

- CephFS for RWX app-private file data.
- Ceph RBD for RWO app state.

Do not migrate high-value production data without explicit backup and restore proof. Immich and Paperless backup rehearsals have passed; Paperless can now move to `ceph-cephfs` after a freeze/copy/switch validation.

Smoke tests completed on 2026-05-30:

- `ceph-rbd`: a 1Gi RWO test PVC bound and a job wrote/read data successfully.
- `ceph-cephfs`: a 1Gi RWX test PVC bound after widening the CephFS CSI client caps and restarting the provisioner; one job wrote data and a second job read it back.

## Ceph Inventory

Checked from Proxmox on 2026-05-30:

- Cluster health: `HEALTH_WARN` because two OSDs reported BlueStore slow operations; placement groups remained `active+clean`.
- FSID: `940ec7cc-501f-4b4c-b938-4b304f133c04`
- Monitors:
  - `latios`: `10.0.3.196:3300`, `10.0.3.196:6789`
  - `rayquaza`: `10.0.1.100:3300`, `10.0.1.100:6789`
  - `latias`: `10.0.3.40:3300`, `10.0.3.40:6789`
- Pools:
  - `.mgr`
  - `ceph-nvme`, application `rbd`, size `2`, min size `2`
  - `kubernetes-rbd`, application `rbd`, size `2`, min size `2`
  - `k8s-cephfs-data`, application `cephfs`, size `2`, min size `2`
  - `k8s-cephfs-metadata`, application `cephfs`, size `2`, min size `2`
- CephFS filesystem: `k8s-cephfs`
  - active MDS: `rayquaza`
  - standby MDS: `latios`
  - `latias` MDS creation failed with a local `rados_conf_read_file` error and was left unchanged because active plus standby is sufficient for this migration phase.
- Approximate available capacity: 3.4 TB

Next storage step: migrate Paperless media/consume/export to `ceph-cephfs` using the freeze/copy/switch plan, then run the Paperless restic backup again.
