# Homelab Migration — Design Spec

## Overview

Migration plan for moving the McNees homelab from its current state (mix of Proxmox LXCs, Docker containers, bare-metal TrueNAS, and an unused K3s cluster on a flat /22 network) to the target architecture defined in `docs/superpowers/specs/2026-03-11-homelab-redesign-design.md` (K3s GitOps platform with VLAN segmentation).

### Goals

- **Zero downtime for critical services**: AdGuard, Traefik, Homey/Homebridge, and Plex remain running at every point during the migration.
- **Preserve data and configuration**: Databases, app configs, and integration work migrate to the new platform — not rebuilt from scratch.
- **Hardware-first**: Convert snorlax to Proxmox and consolidate existing workloads before building new infrastructure.
- **Network-before-compute**: Implement VLAN segmentation before deploying K3s so nodes are born on the correct network.
- **IaC from the start**: New VLANs and firewall rules managed by OpenTofu from day one. Existing DHCP reservations imported later.

### Non-Goals

- Migrating the 57 existing DHCP reservations into OpenTofu during the initial migration (cleanup task in Stage 5).
- Migrating TrueNAS apps that stay (Plex, Tdarr, SABnzbd) — they remain on snorlax (TrueNAS VM on rayquaza). Stash and Romm move to K8s.

---

## Current State

### Proxmox Cluster (Current)

6 nodes: charmander, squirtle, bulbasaur, pikachu, snorlax (bare-metal TrueNAS), mew (spare, 256GB RAM).

All nodes except snorlax are in the Proxmox cluster. Snorlax runs TrueNAS bare-metal and will be converted to rayquaza (Proxmox) with snorlax as a TrueNAS VM.

### Target Proxmox Cluster

3 nodes: latios (custom AMD 8700G, 64GB), latias (custom AMD 8700G, 64GB), rayquaza (formerly snorlax, i3-13100, 64GB). No QDevice needed — 3 nodes provides native quorum with single-node failure tolerance.

One Dell 3050 Micro kept powered off as a cold DR spare. Mew decommissioned and sold after migration.

### Mew — Swing Node (Temporary)

Dual E5-2667 v2 (16C/32T), 256GB RAM, 1.44TB disk. Already in the Proxmox cluster. Can run every existing LXC simultaneously with room to spare. Used during migration only — decommissioned and sold at the end.

### Existing Workloads

**LXCs** (spread across charmander, bulbasaur, squirtle, pikachu, mew — mostly Ceph-backed):
homebridge, adguard, docker (runs Gramps + servarr stack), uptimekuma, ntfy, influxdb, beszel, pocketid, lldap, postgresql, oauth2-proxy, mariadb, redis, grafana, traefik, tautulli, ollama, openwebui, overseer, wizarr, lazylibrarian, pelican-panel, pelican-wings, homey-shs

**VMs**: hass, articuno, zapdos, moltres, lugia, ho-oh (old K3s cluster — empty except Portainer agent)

**Docker containers** (in the docker LXC): Gramps (web, celery, redis), servarr (bazarr, lidarr, lidarr-kids, radarr, readarr, sonarr, sonarr-anime)

**TrueNAS apps** (on snorlax VM / rayquaza host): Plex, Tdarr, SABnzbd (permanent residents); Stash, Romm (migrating to K8s); LazyLibrarian (retiring, fresh K8s deploy)

### Databases

**PostgreSQL LXC** — Active databases: grafana, k3s, pelican, pocket_id, romm, plus old dev experiments.

**MariaDB LXC** — Unused, never configured post-installation. Can be destroyed.

### Networking

Flat `10.0.0.0/22` subnet with 57 devices holding reserved IPs in Unifi. No VLAN segmentation.

### Critical Services

Services where downtime is immediately noticed by the household:
- **AdGuard Home** — DNS resolution for all devices
- **Traefik** — Ingress/reverse proxy for all services
- **Homey / Homebridge** — Smart home automation
- **Plex** — Media streaming (on TrueNAS)

---

## Target State

As defined in the redesign spec (with naming and service updates from this migration spec — this document is authoritative where it differs):
- 3-node Proxmox cluster: latios, latias, rayquaza (no QDevice needed)
- 5-node K3s cluster (3 servers + 2 agents) on VLAN 10, managed by OpenTofu + Ansible
- Flux CD GitOps deploying all K8s workloads
- VLAN segmentation (mgmt, K8s, trusted, IoT, storage, guest)
- PostgreSQL LXC (**metagross**) on rayquaza, Ceph (HA)
- Proxmox Backup Server (**deoxys**) as TrueNAS app on snorlax (avoids NFS round trip for backup data)
- TrueNAS virtualized as **snorlax** on rayquaza (Proxmox)
- Homey LXC on latios, Homebridge LXC on latias, Home Assistant VM on latios
- Pelican game server VM (**pelipper**) on latias
- local-path for default K8s persistent storage on Ceph-backed Talos VM disks; TrueNAS NFS only for bulk/shared datasets
- Cold spare Dell 3050 powered off for DR

### Naming Decisions

This migration spec **supersedes** the redesign spec on the following naming changes:

| Component | Name | Host |
|-----------|------|------|
| K3s server 1 | **articuno** | latios |
| K3s server 2 | **zapdos** | latias |
| K3s server 3 | **moltres** | rayquaza |
| K3s agent 1 | **lugia** | latios |
| K3s agent 2 | **ho-oh** | latias |
| TrueNAS VM | **snorlax** | rayquaza |
| Pelican VM | **pelipper** | latias |
| PostgreSQL LXC | **metagross** | rayquaza |
| PBS (TrueNAS app) | **deoxys** | rayquaza (snorlax VM) |

The redesign spec, Phase 1 plan, Phase 2 plan, OpenTofu configs, and Ansible inventory all need updating to use these names. This is a prerequisite step before implementation planning.

### Service Decisions

This migration spec also supersedes the redesign spec on:
- **n8n**: Removed (replaced by Mantle). Database no longer needs migration. Mantle is promoted into the near-term Kubernetes plan so it can be dogfooded before the migration is complete.
- **Scrypted**: Removed.
- **Outline, Linkwarden, Actual Budget, Booklore, Glances, InfluxDB, Portainer**: Removed.
- **Paperless-ngx + Paperless-GPT**: Added to Phase 3 service deployments.
- **Pelican Panel and Wings**: Panel must be migrated and publicly reachable before Wings is finalized. Panel uses `games.mcnees.me`; Wings API/control uses `wings.games.mcnees.me`; game allocations may use `games.mcnees.me:<port>` direct TCP/UDP exposure. Wings is the daemon that runs game instances and remains outside K3s on the game-hosting backend. Pelipper VM (on latias) hosts additional game server capacity.
- **Home Assistant**: Removed from the lab; clear legacy DNS and route references.

### K3s Node Mapping

| Node | Role | Proxmox Host | RAM | IP (VLAN 10) |
|------|------|-------------|-----|--------------|
| (VIP) | K3s API | — | — | `10.0.10.10` |
| articuno | K3s server | latios | 10GB | `10.0.10.11` |
| zapdos | K3s server | latias | 10GB | `10.0.10.12` |
| moltres | K3s server | rayquaza | 10GB | `10.0.10.13` |
| lugia | K3s agent | latios | 40GB | `10.0.10.14` |
| ho-oh | K3s agent | latias | 20GB | `10.0.10.15` |

---

## Migration Stages

### Stage 0: Build New Hardware + Consolidate (parallel tracks)

Two independent tracks that can run in parallel or in either order.

#### Track A: Consolidate onto Mew

**Goal:** Move all LXCs/VMs off charmander, squirtle, bulbasaur, and pikachu so those Dell nodes can be decommissioned.

**Steps:**
1. Identify storage backend per LXC — Ceph-backed ones live-migrate (zero downtime), local-storage ones backup/restore (brief downtime).
2. Live-migrate Ceph LXCs to Mew, one at a time.
3. Backup/restore local-storage LXCs to Mew during low-usage hours.
4. Verify all services running on Mew — spot-check AdGuard (DNS), Traefik (ingress), Homey/Homebridge (smart home).
5. Destroy old K3s VMs (articuno, zapdos, moltres, lugia, ho-oh) and hass VM — nothing running on them. Note: the bird names are intentionally reused for the new K3s VMs in Stage 2.
6. Destroy MariaDB LXC — confirmed unused.
7. Remove charmander, squirtle, bulbasaur, pikachu from Proxmox cluster. Keep one Dell 3050 as cold DR spare, decommission the rest.

**Exceptions:**
- Homey and Homebridge LXCs temporarily move to Mew during consolidation, then to latios/latias respectively in Stage 2.
- Docker LXC stays running on an existing Dell during migration — it has NFS mounts to TrueNAS for media. Dells remain powered on for legacy services until Phase 3 migrates them.
- LazyLibrarian LXC shut down during Stage 0 (being retired).

**Data preservation:** LXCs move intact with all data — this is a Proxmox migration, not a service migration.

#### Track B: Build latios + latias, Convert snorlax to rayquaza

**Goal:** Build two custom AMD 8700G nodes (latios, latias), rename snorlax to rayquaza, and convert TrueNAS to a VM (snorlax).

**Steps — New Nodes (latios, latias):**
1. Assemble hardware: Ryzen 7 8700G, MSI Pro B650M-P, 64GB DDR5-5600, Samsung 970 EVO 500GB, EVGA 450BT, Rosewill RSV-Z2700U 2U, Dynatron AM5 cooler.
2. Install Proxmox on each node's NVMe boot drive.
3. Join latios and latias to Proxmox cluster.
4. Install SATA SSDs for Ceph OSDs on each node.
5. Connect to Flex XG switch at 2.5GbE.

**Steps — Snorlax Conversion to rayquaza:**
1. Full backup of TrueNAS config — export config file, document pool layout, snapshot all datasets.
2. Verify ZFS pools are exportable — pools are on HBA-connected drives, independent of the boot disk.
3. Install Proxmox on snorlax's boot SSD — wipe only the boot drive, NOT the HBA drives. Rename host to rayquaza.
4. Join rayquaza to Proxmox cluster. Connect at 10GbE to Flex XG switch.
5. Install SATA SSD for Ceph OSD on rayquaza.
6. Configure HBA passthrough to snorlax VM (all drives visible to TrueNAS).
7. Configure iGPU passthrough for Plex/Tdarr QuickSync transcoding.
8. Pass through NVMe metadata drives (2x 1TB) for ZFS metadata vdev.
9. Create snorlax VM — ~48GB RAM, Ceph-backed boot disk.
10. Install TrueNAS in snorlax VM, import ZFS pools from passed-through HBA drives.
11. Restore TrueNAS config or recreate shares/datasets.
12. Verify Plex, Tdarr, SABnzbd, and all TrueNAS apps working.

**Risk:** Plex downtime is unavoidable during snorlax-to-rayquaza conversion (likely a few hours). Schedule when nobody is streaming.

**Gate:** All three Proxmox nodes (latios, latias, rayquaza) in cluster with Ceph OSDs. TrueNAS apps functional on snorlax VM, HBA/iGPU/NVMe passthrough confirmed.

---

### Stage 1: Networking

**Goal:** Create VLAN infrastructure via OpenTofu so K3s nodes and future services are born on the correct networks. Flat /22 stays active as fallback.

**VLAN Layout:**

| VLAN | Subnet | Purpose |
|------|--------|---------|
| VLAN 1 (default) | `10.0.0.0/24` | Management — Proxmox hosts, Unifi gear |
| VLAN 10 | `10.0.10.0/24` | K8s — K3s node VMs, pod/service CIDRs |
| VLAN 20 | `10.0.20.0/24` | Trusted clients — desktops, laptops, phones |
| VLAN 30 | `10.0.30.0/24` | IoT — smart home devices, cameras |
| VLAN 40 | `10.0.40.0/24` | Storage — Ceph replication, NFS |
| VLAN 50 | `10.0.50.0/24` | Guest — internet-only, no LAN access |

No overlap with the existing `/22` except VLAN 1 (management), which is a subset. Proxmox hosts are already in the `10.0.0.x` range.

**Steps:**
1. Write OpenTofu Unifi module (`terraform/unifi/`) — networks, firewall rules, port profiles.
2. `tofu apply` to create VLANs.
3. Configure inter-VLAN routing on Unifi gateway.
4. Set up firewall rules per spec (IoT isolated, guest internet-only, K8s reaches storage + mgmt, trusted reaches K8s services).
5. Configure trunk ports on switches — Proxmox host ports need VLANs 1, 10, 40 at minimum.
6. Configure VLAN-aware bridges on each Proxmox node.
7. Verify — test VM on VLAN 10 gets correct IP, can reach storage and management VLANs per rules.
8. Ensure AdGuard (on Mew, flat network) is reachable from all VLANs via firewall rules.

**What stays on flat /22:** All 57 reserved devices, all LXCs on Mew, client devices, IoT. These move to proper VLANs in Stage 5.

**What goes on VLANs immediately:** K3s VMs (VLAN 10), any new infrastructure.

**Gate:** All VLANs active, test VM on VLAN 10 passes connectivity tests, AdGuard reachable from all VLANs.

---

### Stage 2: K3s Infrastructure

**Goal:** Stand up the K3s cluster on VLAN 10. This is the Phase 1 implementation plan with bird names and VLAN 10 IPs.

**Steps:**
1. Update OpenTofu VM definitions — bird hostnames, VLAN 10 network interfaces, IPs per the node mapping table above.
2. Update Ansible inventory with new hostnames and IPs.
3. Create cloud-init VM template on each Proxmox node hosting a K3s VM.
4. `tofu apply` — create the 5 K3s VMs.
5. `task ansible:k3s-prepare` — OS prep + k3s prereqs.
6. `task ansible:k3s-install` — Bootstrap 3-server HA cluster + 2 agents.
7. Deploy kube-vip for API VIP at `10.0.10.10`.
8. Set up SOPS + age — generate key, update `.sops.yaml` with real public key, create K8s secret.
9. Bootstrap Flux CD — `flux bootstrap github`, configure SOPS decryption.
10. Verify — 5 nodes Ready, Flux syncing, SOPS works, built-in Traefik/ServiceLB/local-storage disabled.

**Gate:** `kubectl get nodes` shows 5 Ready nodes, `flux get kustomizations` shows all synced, SOPS encryption round-trip passes.

---

### Stage 3: Core Platform

**Goal:** Deploy infrastructure services into K3s so the cluster is ready to receive application workloads. This is the Phase 2 implementation plan.

**Steps (all GitOps via Flux):**
1. Helm repositories — add chart sources for all infrastructure components.
2. Storage — local-path-provisioner (`local-path` default StorageClass) on Ceph-backed Talos VM disks. Add TrueNAS NFS only for bulk/shared datasets.
3. Ingress — MetalLB (LoadBalancer IPs from VLAN 10) + Traefik v3.
4. TLS + DNS — cert-manager (Let's Encrypt, Cloudflare DNS-01) + ExternalDNS (Cloudflare).
5. PostgreSQL LXC (metagross) — OpenTofu creates LXC (Ceph-backed, Proxmox HA). Ansible installs and configures PostgreSQL.
6. Migrate databases from old PostgreSQL LXC on Mew:
   - `pocket_id` — needed for auth chain
   - `pelican` — needed for Pelican Panel
   - `romm` — app runs on TrueNAS but database migrates to metagross for centralized management
   - Not migrated: `grafana` (fresh deploy via kube-prometheus-stack), `k3s` (old cluster DB), dev experiments
   - Method: `pg_dump` on old LXC → `pg_restore` on metagross
7. Redis — deploy in K8s (`databases` namespace).
8. Auth chain — LLDAP → Pocket ID → OAuth2-Proxy. Pocket ID uses migrated database.
9. Verify — all infrastructure services healthy, Ingress with TLS works, SOPS secrets decrypt, PostgreSQL reachable from K8s pods, auth chain SSO functional.

**Gate:** `flux get helmreleases -A` all show Ready, test Ingress gets valid TLS cert, PostgreSQL accepts connections from K8s pods.

---

### Stage 4: Service Migration

**Goal:** Migrate services from Mew LXCs into K3s one-by-one, preserving data and configs.

**Migration pattern per service:**
1. Export data/config from the LXC (or Docker volume)
2. Deploy to K3s via Flux (HelmRelease or manifests + SOPS secrets)
3. Import data into the new deployment (K8s PVC)
4. Verify the service works
5. Update DNS/ingress to point to the K3s version
6. Monitor for a day
7. Destroy the old LXC

**Migration waves:**

| Wave | Services | Rationale |
|------|----------|-----------|
| 1 | AdGuard Home | DNS — everything depends on it. Cut over DHCP DNS settings to new MetalLB VIP. |
| 2 | Traefik cutover | Already deployed in Stage 3. Cut over ingress from old Traefik LXC — update DNS records. |
| 3 | Auth chain verification | Already deployed in Stage 3 (LLDAP, Pocket ID, OAuth2-Proxy). Verify SSO end-to-end. |
| 4 | Servarr stack | Sonarr, Sonarr-anime, Radarr, Lidarr, Lidarr-kids, Bazarr, Prowlarr, Recyclarr. From Docker LXC. Config PVCs use local-path; media libraries mount from TrueNAS bulk storage. Migrate Docker volume configs. |
| 5 | Media adjacent | Seer (replaces Overseerr), Wizarr, Tautulli. Low data, mostly config. |
| 6 | Productivity | Paperless-ngx + Paperless-GPT. |
| 7 | AI | Ollama + OpenWebUI (models on TrueNAS NFS, prefer scheduling on lugia/latios for memory headroom). |
| 8 | Automation + Gaming | Mantle (n8n replacement, dogfood early). Pelican Panel (K3s, database already migrated) before Pelican Wings public exposure. |
| 9 | Misc infra | Tailscale subnet router, DbGate, Netboot.xyz, Stash, Romm, LazyLibrarian. |

**Services that stay outside K3s:**
- Pelican Wings → outside K3s on the game-hosting backend; configure after the public Panel migration
- PostgreSQL (metagross) → LXC on rayquaza (created in Stage 3, 2GB)

**Services retired:**
- Homey LXC — migrated to K3s
- Homebridge LXC — migrated to K3s
- Home Assistant — removed from the lab
- MariaDB LXC — unused (destroyed in Stage 0)
- InfluxDB LXC — replaced by Prometheus
- Overseerr LXC — replaced by Seer
- ntfy LXC — no longer needed
- LazyLibrarian LXC — migrated to K3s
- Traefik LXC — replaced by Traefik in K3s (Stage 3)
- Old PostgreSQL LXC — destroyed after databases migrated to metagross
- Docker LXC — destroyed after servarr migration and any remaining non-migrating containers are retired
- n8n — replaced by Mantle
- Scrypted — removed
- Outline — removed
- Linkwarden — removed
- Actual Budget — removed
- Booklore — removed
- Glances — removed
- Portainer — replaced by Flux + Grafana
- Readarr — dropped in favor of LazyLibrarian/Grimmory

**Data preservation details:**
- **Servarr apps** — Export Docker volumes (config dirs with databases + settings). Import into K8s PVCs.
- **Pocket ID** — PostgreSQL database migrated in Stage 3.
- **Pelican Panel** — PostgreSQL database migrated in Stage 3.
- **Uptime Kuma** — Export monitors config, reimport.
- **Beszel** — Fresh deploy, re-add agents.
- **Grafana** — Fresh via kube-prometheus-stack. Dashboards defined as code.

**Gate:** All services running in K3s, verified functional, old LXCs destroyed, Mew has only non-migrating LXCs remaining (if any).

---

### Stage 5: Cleanup & Device Migration

**Goal:** Move remaining devices to proper VLANs, decommission the flat /22, finalize infrastructure.

**Steps:**
1. Move client devices to VLAN 20 (trusted) — update McNet WiFi SSID VLAN assignment, update wired client port profiles.
2. Move IoT devices to VLAN 30 — update McNet_IoT SSID VLAN.
3. Create guest WiFi on VLAN 50 — new McNet Guest SSID, internet-only.
4. Import 57 DHCP reservations into OpenTofu (`terraform/unifi/`) — now on their proper VLANs.
5. Decommission flat /22 — once all devices are on VLANs, remove the old network. Management /24 (VLAN 1) remains.
6. Decommission Mew — all LXCs destroyed. Remove from cluster, sell.
7. PBS setup — set up Proxmox Backup Server (deoxys) as TrueNAS app on snorlax — avoids NFS round trip for backup data. Configure backup jobs per spec (nightly incremental, weekly verify, retention policy).
8. Documentation — write break-glass guide, in-case-of-death plan, common tasks runbook.

**Gate:** All devices on correct VLANs, flat /22 decommissioned, PBS backing up all VMs/LXCs, documentation complete.

---

## Risk Summary

| Risk | Mitigation |
|------|-----------|
| Plex downtime during snorlax conversion | Schedule during off-hours, pre-communicate with household |
| AdGuard DNS cutover breaks resolution | Keep old AdGuard on Mew running until new one verified. Update DHCP DNS in one change. |
| VLAN misconfiguration isolates devices | Keep flat /22 as fallback, test each VLAN before moving devices |
| Data loss during service migration | LXCs stay on Mew until K3s version is verified and monitored for a day |
| PostgreSQL migration corrupts data | `pg_dump` with `--format=custom` for reliable restore, test restore before cutting over |
| K3s cluster issues on VLAN 10 | Verify inter-VLAN routing before deploying, management access via VLAN 1 always available |

---

## Relationship to Existing Plans

This migration spec is **authoritative** for naming, service decisions, and migration ordering. The following documents need updating before implementation planning begins:

| Document | Updates Needed |
|----------|---------------|
| Redesign spec (`docs/superpowers/specs/2026-03-11-homelab-redesign-design.md`) | Updated: 3-node cluster (latios/latias/rayquaza), bird names, snorlax/pelipper/metagross/deoxys hostnames, service removals, PriorityClasses |
| Phase 1 plan (`docs/superpowers/plans/2026-03-11-phase1-foundation.md`) | Bird hostnames replacing regi names, VLAN 10 IPs, kube-vip for API VIP, new host assignments |
| Phase 2 plan (`docs/superpowers/plans/2026-03-11-phase2-core-platform.md`) | Bird hostnames, metagross as PostgreSQL LXC hostname, snorlax as TrueNAS VM |
| OpenTofu configs (`terraform/proxmox/`) | Rename .tf files and resource names from regi to bird names, update host targets |
| Ansible inventory (`ansible/inventory/hosts.yml`) | Bird hostnames, VLAN 10 IPs, new Proxmox host names (latios/latias/rayquaza) |
