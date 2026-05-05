# Storage Tiering Redesign — Design Spec

## Overview

Redesign of the TrueNAS storage architecture to leverage new hardware while keeping Kubernetes app PVCs on `local-path` volumes backed by the Proxmox `ceph-nvme` VM disks. This supersedes the earlier `flash/k8s` plan: spare SATA SSDs are better reserved for future bulk capacity or Ceph expansion than for a separate TrueNAS default PVC pool.

### Goals

- **Ceph-backed app PVCs**: `local-path` is the default Kubernetes StorageClass. Talos VM disks sit on Proxmox `ceph-nvme`, so single-pod app PVCs get fast replicated storage without a TrueNAS dependency.
- **Improved HDD pool performance**: Optane metadata special vdev eliminates metadata-on-HDD bottleneck. Optane SLOG eliminates synchronous write penalty. NVMe L2ARC provides 2TB read cache for evicted ARC data.
- **TrueNAS for bulk/shared data**: NFS is reserved for media, downloads, ROMs, documents, archives, backups, and workloads that truly need ReadWriteMany semantics.
- **Backup tier separation**: PBS dedup index on SSD for fast verify/prune/restore, chunk store on HDD for capacity.
- **Ceph expansion**: OSDs across 3 nodes (latios, latias, rayquaza) for HA VM/LXC storage.

### Non-Goals

- Deploying Kubernetes Ceph CSI in this phase. Kubernetes consumes Ceph indirectly through Talos VM disks and `local-path`.
- Off-box backup for media (160TB+ is snapshot-only).
- Changing the HDD vdev layout (existing 2x RAIDZ1 4-wide preserved).

---

## Section 1: Hardware Layout

### Custom Compute Nodes (latios, latias)

| Component | Spec |
|---|---|
| CPU | AMD Ryzen 7 8700G |
| Motherboard | MSI Pro B650M-P |
| RAM | 64 GB DDR5-5600 |
| Boot Drive | Samsung 970 EVO 500GB NVMe (Proxmox OS) |
| Ceph OSD | 1-2x 1TB SATA SSD per node |
| NIC | 2.5GbE (onboard) |
| PSU | EVGA 450BT |
| Case | Rosewill RSV-Z2700U 2U |
| Cooler | Dynatron AM5 |
| SATA ports | 4x available |
| Drive bays | 4x 3.5/2.5 available |

### Rayquaza (Storage Node)

| Component | Allocation |
|---|---|
| RAM — snorlax (TrueNAS VM) | 48 GB |
| RAM — moltres (K3s server VM) | 10 GB |
| RAM — metagross LXC | 2 GB |
| RAM — Proxmox host | 4 GB |
| HBA | Passthrough to snorlax (all SATA drives) |
| iGPU (i3-13100) | Passthrough to snorlax (Plex transcoding) |
| NVMe slots (x2) | Passthrough to snorlax (L2ARC) |
| Ceph OSD | 1-2x 1TB SATA SSD |
| Boot SSD | Proxmox OS (separate from HBA) |

### Snorlax Boot Disk

Ceph-backed (RBD) — lives on remote OSDs across latios/latias/rayquaza. This is a network dependency, but acceptable: snorlax is pinned to rayquaza by PCI passthrough anyway, and Ceph provides redundancy if an OSD node goes down. The boot disk is small (~32 GB); all bulk data lives on the HBA-attached drives.

### K3s Datastore

Embedded etcd across 3 server nodes (articuno, zapdos, moltres). Included here to confirm: no PostgreSQL dependency on the storage tier for K3s itself.

### RAM Allocation Notes

ho-oh is a K3s agent VM on latias with 20 GB RAM. Moltres is a K3s server VM on rayquaza with 10 GB RAM. Ollama (4-6 GB) scheduling preference should go to lugia (40 GB K3s agent on latios) as the preferred node for large model workloads.

---

## Section 2: TrueNAS Pool Topology (snorlax)

### HDD Pool (`data`)

| Component | Configuration | Purpose |
|---|---|---|
| 8x 20TB Exos | 2x RAIDZ1 (4-wide) — existing layout preserved | Bulk data storage (~105 TiB usable) |
| 2x 16GB Intel Optane | Mirrored metadata special vdev | Replaces 1TB NVMes for metadata duty |
| 2x 16GB Intel Optane | Mirrored SLOG | New — previously all ZIL writes hit HDDs (1.5 TiB observed) |
| 2x 1TB NVMe | Striped L2ARC | 2TB read cache for ARC evictions (34.7 TiB eligible observed) |

### Spare SATA SSDs

The four spare SATA SSDs are no longer allocated to a TrueNAS `flash/k8s` pool. Keep them available for future bulk-capacity strategy, Ceph OSD expansion, or a deliberately scoped TrueNAS SSD pool if a concrete workload appears.

### Dataset Distribution

**HDD pool (`data`):**

| Dataset | Contents |
|---|---|
| `data/media/` | All media libraries (~67 TiB) |
| `data/homes/` | User home directories |
| `data/isos/` | ISO images for Proxmox |
| `data/backups/postgresql/` | pg_dump outputs from metagross |
| `data/backups/timemachine/` | macOS Time Machine targets |
| `data/backups/pbs-store/` | PBS datastore / chunk store (sequential bulk data) |
| `data/k8s-bulk/` | Optional NFS-backed bulk/shared Kubernetes datasets |
| `data/photos/` | Photo library (~800 GiB) |
| `data/documents/` | Documents (~450 GiB) |
| `data/backups/general/` | General backup data (~1.2 TiB) — renamed from `data/backup/` for consistency |

**Datasets to clean up during Stage 5:**
- `data/nextcloud` — no longer in use
- `data/recordings` — not in use (no Frigate)
- `data/docker` — replaced by K8s PVCs on `local-path` plus selected TrueNAS bulk mounts
- `data/k3s` — old k3s PVCs, replaced by Talos `local-path`
- `data/vms` — VMs use Ceph now

### ARC Analysis (baseline from 2026-03-14)

| Metric | Value | Implication |
|---|---|---|
| ARC hit rate | 99.2% | Excellent — current workload fits well in RAM |
| ARC size | 36 GB on 62.6 GB RAM | 48 GB snorlax RAM should yield ~36 GB ARC (same) |
| L2ARC-eligible evictions | 34.7 TiB | Strong case for L2ARC — 2 TB NVMe will absorb hot evictions |
| ZIL writes (no SLOG) | 1.5 TiB on HDDs | Optane SLOG eliminates synchronous write penalty |
| ARC composition | 91.5% data / 8.5% metadata | Metadata fits in Optane special vdev + ARC |

---

## Section 3: Kubernetes StorageClasses

### StorageClass Definitions

| StorageClass | Backend | Location | Access Mode | Use Case |
|---|---|---|---|---|
| `local-path` | Rancher local-path-provisioner | Talos VM disks on Proxmox `ceph-nvme` | ReadWriteOnce | **Default.** App configs, caches, Redis persistence, and single-pod service state. Node-bound at the Kubernetes layer. |
| TrueNAS NFS | Static or future dynamic NFS | `data/media`, `data/downloads`, `data/roms`, `data/documents`, `data/k8s-bulk` | ReadWriteMany | Bulk/shared datasets and workloads needing shared filesystem semantics. |

No `truenas-nfs` default StorageClass is required for the current implementation. Add static PVs or a future NFS provisioner only for concrete bulk/shared workloads.

### Workload Assignment

| `local-path` | TrueNAS NFS |
|---|---|
| Redis persistence | Servarr media libraries |
| App configs and caches | Bulk downloads |
| SQLite or NFS-hostile edge cases | Paperless document archive |
| Small single-pod service data | Ollama models, ROM libraries, large assets |

**SABnzbd dual-mount:** Temp/incomplete downloads can use `local-path` if node-bound operation is acceptable; completed downloads live on TrueNAS bulk storage.

**LLDAP:** Uses PostgreSQL on metagross — no SQLite fallback, no `local-path` needed.

---

## Section 4: Ceph Expansion

| | Configuration |
|---|---|
| OSD nodes | 3 (latios, latias, rayquaza) |
| Drives per node | 1-2x 1TB SATA SSD |
| Raw capacity | 3-6 TB (depending on drive count) |
| Replication | 3-way |
| Usable capacity | ~1-2 TB |
| Min replicas (`min_size`) | 2 |
| Failure tolerance | 1 node |

Ceph OSDs are distributed across all 3 Proxmox nodes. Each node contributes 1-2x 1TB SATA SSDs. Used for VM/LXC HA storage: metagross PostgreSQL LXC, K3s VM boot disks, snorlax TrueNAS boot disk, etc. CRUSH distributes 3 replicas across 3 hosts automatically.

---

## Section 5: Backup Strategy

### PBS Datastore (deoxys)

PBS supports split-path datastores. The dedup index (heavily random-read) goes on SSD for fast verify/prune/restore. The chunk store (sequential bulk) goes on HDD for capacity.

| Component | Location | Why |
|---|---|---|
| PBS dedup index + DB | `flash/backups/pbs/` (SSD) | Random-read heavy — SSD dramatically speeds verify, prune, restore |
| PBS chunk store | `data/backups/pbs-store/` (HDD) | Sequential writes, capacity matters more than speed |

### Backup Targets

| Source | What | Frequency | Destination |
|---|---|---|---|
| Talos VM disks / `local-path` PVCs | App data, configs, caches | Weekly VM backup, plus app-level exports where needed | PBS via Proxmox VM backups |
| metagross (PostgreSQL) | All databases (pg_dump) | Daily | `data/backups/postgresql/` → PBS |
| VM/LXC disks (Ceph) | Boot disks for K3s VMs, metagross, snorlax | Weekly | PBS |
| TrueNAS `data/` | Media, homes, photos | ZFS snapshots only | No off-box backup (too large) |

### What Doesn't Change

- TimeMachine backups stay on `data/backups/timemachine/`
- Ceph VM/LXC backups still go through Proxmox Backup Client → PBS (same path, faster index lookups)

---

## Section 6: Implementation Ordering

Storage changes are interleaved with migration stages. The critical principle: **get snorlax running with the existing pool layout first, then restructure.**

| Stage | Storage Work |
|---|---|
| **0B** (Rayquaza conversion) | Install Proxmox on rayquaza. Create snorlax VM with HBA + NVMe + iGPU passthrough. Install TrueNAS. Import existing `data` pool **as-is** — no topology changes. Verify Plex, all TrueNAS apps, NFS shares all working. |
| **0B+** (Post-conversion, optional) | Add Optane metadata/SLOG and NVMe L2ARC only after TrueNAS is stable. Do not create `flash/k8s`; Kubernetes PVCs use `local-path` on Ceph-backed Talos VM disks. |
| **1** (Networking) | No storage work. |
| **2** (K3s Infrastructure) | Add Ceph OSDs across latios, latias, rayquaza (1-2 SATA SSDs per node). |
| **3** (Core Platform) | Configure `local-path` as the default StorageClass. Add TrueNAS NFS only for concrete bulk/shared workloads. Set up PBS storage paths separately. |
| **4** (Service Migration) | App config/cache PVCs land on `local-path` by default. Servarr media mounts and other bulk datasets use TrueNAS NFS. |
| **5** (Cleanup) | Remove stale datasets: `data/nextcloud`, `data/recordings`, `data/docker`, `data/k3s` (old), `data/vms`. |

### Risk Notes

- **Stage 0B is two-phase:** First prove the snorlax VM works with the existing pool on rayquaza. Then restructure. If Optane/L2ARC/SSD changes go wrong, you still have a working TrueNAS.
- **Node-bound PVCs:** `local-path` does not provide Kubernetes-native cross-node volume movement. Critical databases stay on metagross; future Ceph CSI can be added if node-bound PVCs become operationally painful.
- **Optane metadata vdev:** Once added, the metadata special vdev cannot be removed without destroying and recreating the pool. The Optane drives are mirrored, so single-drive failure is survivable.
- **Optane sourcing:** Intel Optane M.2 16GB drives are discontinued. Buy spares now (they're cheap on the secondary market). If both drives in a mirror fail and no replacement is available, recovery requires: export pool data, destroy pool, recreate without special vdev, reimport. This is disruptive but not data-losing if backups are current.

---

## Relationship to Other Specs

This spec **supersedes** the following sections of the [redesign spec](2026-03-11-homelab-redesign-design.md):
- "Future Enhancement: NVMe Pool + Optane Metadata" — NVMe drives are L2ARC candidates; no `flash/k8s` default PVC pool is planned.
- Storage class tables in Section 2 — `local-path` becomes the default; TrueNAS NFS is reserved for bulk/shared workloads.
- RAM allocation for rayquaza VMs in Section 1 — updated to 48/10/2/4 GB split (snorlax/moltres/metagross/Proxmox).
- NVMe passthrough description in Section 1 — NVMes no longer serve as metadata vdev; Optane replaces them.
- Ceph OSD topology — OSDs distributed across latios, latias, rayquaza (1-2x 1TB SATA SSD per node).

Implementation ordering integrates with the [migration spec](2026-03-13-migration-plan-design.md) stage structure. Stage 0B+ is a new sub-stage not present in the migration spec, inserted between Stage 0 (Track B) and Stage 1.
