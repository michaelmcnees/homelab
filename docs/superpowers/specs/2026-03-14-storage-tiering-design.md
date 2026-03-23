# Storage Tiering Redesign — Design Spec

## Overview

Redesign of the TrueNAS storage architecture to leverage new hardware (4x Intel Optane, spare SATA SSDs) and create a tiered storage system. Replaces the "Future Enhancement: NVMe Pool" section from the original redesign spec with a more practical approach using Optane for metadata/SLOG, NVMe for L2ARC, and a dedicated SSD pool for performance-sensitive workloads.

### Goals

- **Tiered performance**: SSD pool (`flash`) for K8s PVCs and app metadata, HDD pool (`data`) for bulk media and sequential workloads.
- **Improved HDD pool performance**: Optane metadata special vdev eliminates metadata-on-HDD bottleneck. Optane SLOG eliminates synchronous write penalty. NVMe L2ARC provides 2TB read cache for evicted ARC data.
- **Kubernetes-native storage**: Two democratic-csi StorageClasses with clear use-case boundaries.
- **Backup tier separation**: PBS dedup index on SSD for fast verify/prune/restore, chunk store on HDD for capacity.
- **Ceph expansion**: OSDs across 3 nodes (latios, latias, rayquaza) for HA VM/LXC storage.

### Non-Goals

- Replacing Ceph for VM/LXC storage (Ceph stays as-is for Proxmox workloads).
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

### SSD Pool (`flash`)

| Component | Configuration | Purpose |
|---|---|---|
| 4x ~1TB SATA SSD | RAIDZ1 (~3TB usable) | Performance-sensitive workloads |

All SATA SSDs connect via the same HBA as the HDDs (passthrough to snorlax).

### Dataset Distribution

**SSD pool (`flash`):**

| Dataset | Contents |
|---|---|
| `flash/k8s/` | All democratic-csi PVCs (default StorageClass target) |
| `flash/apps/` | TrueNAS app data — Plex metadata/DB, Tdarr cache, SABnzbd temp |
| `flash/backups/pbs/` | PBS dedup index and database |

**HDD pool (`data`):**

| Dataset | Contents |
|---|---|
| `data/media/` | All media libraries (~67 TiB) |
| `data/homes/` | User home directories |
| `data/isos/` | ISO images for Proxmox |
| `data/backups/postgresql/` | pg_dump outputs from metagross |
| `data/backups/timemachine/` | macOS Time Machine targets |
| `data/backups/pbs-store/` | PBS chunk store (sequential bulk data) |
| `data/k8s/` | `truenas-nfs-bulk` PVCs (media references, large sequential data) |
| `data/photos/` | Photo library (~800 GiB) |
| `data/documents/` | Documents (~450 GiB) |
| `data/backups/general/` | General backup data (~1.2 TiB) — renamed from `data/backup/` for consistency |

**Datasets to clean up during Stage 5:**
- `data/nextcloud` — no longer in use
- `data/recordings` — not in use (no Frigate)
- `data/docker` — replaced by K8s PVCs on `flash`
- `data/k3s` — old k3s PVCs, replaced by `flash/k8s/`
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

| StorageClass | Backend | Pool/Dataset | Access Mode | Use Case |
|---|---|---|---|---|
| `truenas-nfs` | democratic-csi → TrueNAS NFS | `flash/k8s/` | ReadWriteMany | **Default.** App configs, documents, Ollama models, most PVCs. |
| `truenas-nfs-bulk` | democratic-csi → TrueNAS NFS | `data/k8s/` | ReadWriteMany | Media references, large sequential data, anything >500GB. |
| `local-path` | Rancher local-path-provisioner | Ceph (via VM disk) | ReadWriteOnce | Redis persistence, NFS-hostile edge cases. Node-local. |

democratic-csi requires two NFS share configurations pointing at different parent datasets.

### Workload Assignment

| `truenas-nfs` (flash) | `truenas-nfs-bulk` (data) | `local-path` |
|---|---|---|
| Paperless-ngx documents + OCR | Servarr media libraries | Redis |
| Ollama models | Bulk downloads (SABnzbd complete) | NFS-hostile edge cases |
| App configs (all apps) | Anything >500GB | |
| Outline attachments | | |
| Booklore/Gramps data | | |

**SABnzbd dual-mount:** Temp/incomplete downloads on `flash` (random I/O during extraction), completed downloads on `data` (sequential bulk). Configured at the app level with two mount paths, not at the StorageClass level.

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
| K3s PVCs (`flash/k8s/`) | App data, configs, documents | Daily | ZFS snapshots for point-in-time recovery + `proxmox-backup-client` file-level backup to PBS |
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
| **0B+** (Post-conversion, new sub-stage) | **Not in the migration spec — inserted between Stage 0 and Stage 1.** Add 4x Optane: 2x mirrored metadata special vdev, 2x mirrored SLOG. Remove NVMes from metadata duty. Add 2x NVMe as striped L2ARC. Create `flash` SSD pool. Create datasets: `flash/k8s/`, `flash/apps/`, `flash/backups/pbs/`. Move Plex metadata → `flash/apps/plex/`. |
| **1** (Networking) | No storage work. |
| **2** (K3s Infrastructure) | Add Ceph OSDs across latios, latias, rayquaza (1-2 SATA SSDs per node). |
| **3** (Core Platform) | Configure democratic-csi with two NFS provisioners (`truenas-nfs` → `flash/k8s/`, `truenas-nfs-bulk` → `data/k8s/`). Set up PBS datastore on deoxys with split paths. |
| **4** (Service Migration) | PVCs land on `flash` by default. Servarr wave: media mounts use `truenas-nfs-bulk`. SABnzbd gets dual mounts. |
| **5** (Cleanup) | Remove stale datasets: `data/nextcloud`, `data/recordings`, `data/docker`, `data/k3s` (old), `data/vms`. |

### Risk Notes

- **Stage 0B is two-phase:** First prove the snorlax VM works with the existing pool on rayquaza. Then restructure. If Optane/L2ARC/SSD changes go wrong, you still have a working TrueNAS.
- **SATA SSDs on HBA:** The flash pool SSDs share the same HBA as the HDDs. If HBA passthrough works for HDDs (required), SSDs will work too. Verify all drives visible in snorlax (TrueNAS) before creating the pool.
- **Optane metadata vdev:** Once added, the metadata special vdev cannot be removed without destroying and recreating the pool. The Optane drives are mirrored, so single-drive failure is survivable.
- **Optane sourcing:** Intel Optane M.2 16GB drives are discontinued. Buy spares now (they're cheap on the secondary market). If both drives in a mirror fail and no replacement is available, recovery requires: export pool data, destroy pool, recreate without special vdev, reimport. This is disruptive but not data-losing if backups are current.

---

## Relationship to Other Specs

This spec **supersedes** the following sections of the [redesign spec](2026-03-11-homelab-redesign-design.md):
- "Future Enhancement: NVMe Pool + Optane Metadata" — NVMe pool concept replaced by `flash` SSD pool; NVMe drives become L2ARC instead.
- Storage class tables in Section 2 — `truenas-nfs-bulk` added, `truenas-nfs` retargeted to `flash`.
- RAM allocation for rayquaza VMs in Section 1 — updated to 48/10/2/4 GB split (snorlax/moltres/metagross/Proxmox).
- NVMe passthrough description in Section 1 — NVMes no longer serve as metadata vdev; Optane replaces them.
- Ceph OSD topology — OSDs distributed across latios, latias, rayquaza (1-2x 1TB SATA SSD per node).

Implementation ordering integrates with the [migration spec](2026-03-13-migration-plan-design.md) stage structure. Stage 0B+ is a new sub-stage not present in the migration spec, inserted between Stage 0 (Track B) and Stage 1.
