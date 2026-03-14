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
- Migrating TrueNAS apps (Plex, Tdarr, SABnzbd, etc.) — they stay on munchlax.
- Setting up Ceph on snorlax (no spare SSD for an OSD).

---

## Current State

### Proxmox Cluster

6 nodes: charmander, squirtle, bulbasaur, pikachu, snorlax (bare-metal TrueNAS), mew (spare, 256GB RAM).

All nodes except snorlax are in the Proxmox cluster. Snorlax runs TrueNAS bare-metal and needs to be converted.

### Mew — Swing Node

Dual E5-2667 v2 (16C/32T), 256GB RAM, 1.44TB disk. Already in the Proxmox cluster. Can run every existing LXC simultaneously with room to spare.

### Existing Workloads

**LXCs** (spread across charmander, bulbasaur, squirtle, pikachu, mew — mostly Ceph-backed):
homebridge, adguard, docker (runs Gramps + servarr stack), uptimekuma, ntfy, influxdb, beszel, outline, pocketid, lldap, postgresql, oauth2-proxy, mariadb, redis, grafana, traefik, tautulli, n8n, ollama, openwebui, overseer, wizarr, booklore, lazylibrarian, pelican-panel, pelican-wings, homey-shs

**VMs**: hass, articuno, zapdos, moltres, lugia, ho-oh (old K3s cluster — empty except Portainer agent)

**Docker containers** (in the docker LXC): Gramps (web, celery, redis), servarr (bazarr, lidarr, lidarr-kids, radarr, readarr, sonarr, sonarr-anime)

**TrueNAS apps** (on snorlax/munchlax): Plex, Tdarr, SABnzbd, Stash, LazyLibrarian, Romm

### Databases

**PostgreSQL LXC** — Active databases: grafana, k3s, n8n, pelican, pocket_id, romm, plus old dev experiments.

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
- 5-node K3s cluster (3 servers + 2 agents) on VLAN 10, managed by OpenTofu + Ansible
- Flux CD GitOps deploying all K8s workloads
- VLAN segmentation (mgmt, K8s, trusted, IoT, storage, guest)
- PostgreSQL LXC (**metagross**) on Ceph (HA)
- Proxmox Backup Server LXC (**deoxys**) on Ceph (HA)
- TrueNAS virtualized as munchlax on snorlax (Proxmox)
- Homey, Homebridge, Pelican Wings as LXCs on pikachu
- Pelican game server VM (**rayquaza**) on pikachu
- democratic-csi for K8s persistent storage via TrueNAS NFS

### Naming Decisions

This migration spec **supersedes** the redesign spec on the following naming changes:

| Component | Redesign Spec Name | Migration Spec Name (authoritative) |
|-----------|-------------------|--------------------------------------|
| K3s server 1 | regirock | **articuno** |
| K3s server 2 | regice | **zapdos** |
| K3s server 3 | registeel | **moltres** |
| K3s agent 1 | regieleki | **lugia** |
| K3s agent 2 | regidrago | **ho-oh** |
| PostgreSQL LXC | TBD | **metagross** |
| PBS LXC | TBD | **deoxys** |
| Pelican VM | TBD | **rayquaza** |

The redesign spec, Phase 1 plan, Phase 2 plan, OpenTofu configs, and Ansible inventory all need updating to use these names. This is a prerequisite step before implementation planning.

### Service Decisions

This migration spec also supersedes the redesign spec on:
- **n8n**: Retained (redesign spec listed it as retired). Moves to K3s, PostgreSQL database migrated.
- **Pelican Wings**: Stays as existing LXC on pikachu (redesign spec described a Pelican game server VM but didn't mention Wings). Wings is the daemon that runs game instances; Panel is the management UI in K3s. Rayquaza VM hosts additional game server capacity alongside the Wings LXC.

### K3s Node Mapping

| Node | Role | Proxmox Host | IP (VLAN 10) |
|------|------|-------------|--------------|
| (VIP) | K3s API | — | `10.0.10.10` |
| articuno | K3s server | charmander | `10.0.10.11` |
| zapdos | K3s server | squirtle | `10.0.10.12` |
| moltres | K3s server | bulbasaur | `10.0.10.13` |
| lugia | K3s agent | pikachu | `10.0.10.14` |
| ho-oh | K3s agent | snorlax | `10.0.10.15` |

---

## Migration Stages

### Stage 0: Consolidate + Hardware (parallel tracks)

Two independent tracks that can run in parallel or in either order.

#### Track A: Consolidate onto Mew

**Goal:** Move all LXCs/VMs off charmander, squirtle, bulbasaur, and pikachu so those nodes are clean for K3s VM provisioning.

**Steps:**
1. Identify storage backend per LXC — Ceph-backed ones live-migrate (zero downtime), local-storage ones backup/restore (brief downtime).
2. Live-migrate Ceph LXCs to Mew, one at a time.
3. Backup/restore local-storage LXCs to Mew during low-usage hours.
4. Verify all services running on Mew — spot-check AdGuard (DNS), Traefik (ingress), Homey/Homebridge (smart home).
5. Destroy old K3s VMs (articuno, zapdos, moltres, lugia, ho-oh) and hass VM — nothing running on them. Note: the bird names are intentionally reused for the new K3s VMs in Stage 2.
6. Destroy MariaDB LXC — confirmed unused.
7. Verify charmander, squirtle, bulbasaur, pikachu have zero VMs/LXCs.

**Exception:** Homey and Homebridge LXCs can stay on pikachu (host networking requirement, they never move to K3s) or temporarily move to Mew if pikachu needs to be fully clean.

**Data preservation:** LXCs move intact with all data — this is a Proxmox migration, not a service migration.

#### Track B: Snorlax Conversion

**Goal:** Convert snorlax from bare-metal TrueNAS to Proxmox host with TrueNAS VM (munchlax).

**Steps:**
1. Full backup of TrueNAS config — export config file, document pool layout, snapshot all datasets.
2. Verify ZFS pools are exportable — pools are on HBA-connected drives, independent of the boot disk.
3. Install Proxmox on snorlax's boot SSD — wipe only the boot drive, NOT the HBA drives.
4. Join snorlax to Proxmox cluster.
5. Configure HBA passthrough to munchlax VM (all drives visible to TrueNAS).
6. Configure iGPU passthrough for Plex/Tdarr QuickSync transcoding.
7. Pass through NVMe metadata drives (2x 1TB) for ZFS metadata vdev.
8. Create munchlax VM — ~32GB RAM, Ceph-backed boot disk.
9. Install TrueNAS in munchlax, import ZFS pools from passed-through HBA drives.
10. Restore TrueNAS config or recreate shares/datasets.
11. Verify Plex, Tdarr, SABnzbd, and all TrueNAS apps working.

**Risk:** Plex downtime is unavoidable during snorlax conversion (likely a few hours). Schedule when nobody is streaming.

**Gate:** All TrueNAS apps functional, HBA/iGPU/NVMe passthrough confirmed, munchlax stable.

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
2. Storage — democratic-csi (TrueNAS NFS via `truenas-nfs` storage class) + local-path-provisioner (`local-path` storage class). Requires firewall rule: VLAN 10 → munchlax TrueNAS API.
3. Ingress — MetalLB (LoadBalancer IPs from VLAN 10) + Traefik v3.
4. TLS + DNS — cert-manager (Let's Encrypt, Cloudflare DNS-01) + ExternalDNS (Cloudflare).
5. PostgreSQL LXC (metagross) — OpenTofu creates LXC (Ceph-backed, Proxmox HA). Ansible installs and configures PostgreSQL.
6. Migrate databases from old PostgreSQL LXC on Mew:
   - `pocket_id` — needed for auth chain
   - `pelican` — needed for Pelican Panel
   - `n8n` — preserving workflows
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
| 4 | Servarr stack | Sonarr, Sonarr-anime, Radarr, Lidarr, Lidarr-kids, Bazarr, Prowlarr, Recyclarr. From Docker LXC. Need democratic-csi NFS to TrueNAS media datasets. Migrate Docker volume configs. |
| 5 | Media adjacent | Seer (replaces Overseerr), Wizarr, Tautulli. Low data, mostly config. |
| 6 | Productivity | Outline, Booklore, Paperless-ngx + Paperless-ai, Gramps. Outline has file attachments to move. Gramps has family tree data in Docker volume. |
| 7 | AI / Automation | Ollama + OpenWebUI (models on TrueNAS NFS, prefer scheduling on ho-oh/snorlax for memory headroom), n8n (database already migrated in Stage 3). |
| 8 | Monitoring | Grafana (fresh via kube-prometheus-stack), Beszel, Uptime Kuma. Replaces InfluxDB with Prometheus — no data migration. |
| 9 | Gaming | Pelican Panel (K3s, database already migrated). Points at existing Pelican Wings LXC on pikachu. |
| 10 | Camera | Scrypted — new deployment, replaces Homebridge camera duties. |
| 11 | Misc infra | Tailscale subnet router, DbGate, Netboot.xyz LXC. |

**Services that stay as LXCs (do NOT migrate to K3s):**
- Homey → LXC on pikachu (host networking)
- Homebridge → LXC on pikachu (host networking + USB)
- Pelican Wings → LXC on pikachu (existing, stays)
- PostgreSQL → new LXC (created in Stage 3)
- Netboot.xyz → LXC on any Proxmox host

**Services retired:**
- MariaDB LXC — unused (destroyed in Stage 0)
- InfluxDB LXC — replaced by Prometheus
- Overseerr LXC — replaced by Seer
- ntfy LXC — no longer needed
- LazyLibrarian LXC — already runs as a TrueNAS app on munchlax
- hass VM — replaced by Homey
- Traefik LXC — replaced by Traefik in K3s (Stage 3)
- Old PostgreSQL LXC — destroyed after databases migrated to metagross
- Docker LXC — destroyed after servarr + Gramps migrated

**Data preservation details:**
- **Servarr apps** — Export Docker volumes (config dirs with databases + settings). Import into K8s PVCs.
- **Gramps** — Export Docker volume (family tree data). Import into K8s PVC.
- **Outline** — Requires PostgreSQL (may have local Postgres in LXC, not in the shared PostgreSQL LXC). During Wave 6: dump database, create `outline` database on metagross, restore, update connection string. Also needs Redis (deployed in Stage 3). File attachments move to NFS PVC.
- **n8n** — PostgreSQL database migrated in Stage 3. Workflow data is in the DB.
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
6. Clean up Mew — all LXCs destroyed. Repurpose or decommission.
7. PBS setup — create Proxmox Backup Server LXC (deoxys, Ceph-backed), configure backup jobs per spec (nightly incremental, weekly verify, retention policy).
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
| Redesign spec (`docs/superpowers/specs/2026-03-11-homelab-redesign-design.md`) | Bird names for K3s nodes, metagross/deoxys/rayquaza hostnames, n8n retained (not retired), Pelican Wings stays as LXC, repo structure reflects bird names |
| Phase 1 plan (`docs/superpowers/plans/2026-03-11-phase1-foundation.md`) | Bird hostnames replacing regi names, VLAN 10 IPs, kube-vip for API VIP |
| Phase 2 plan (`docs/superpowers/plans/2026-03-11-phase2-core-platform.md`) | Bird hostnames, metagross as PostgreSQL LXC hostname |
| OpenTofu configs (`terraform/proxmox/`) | Rename .tf files and resource names from regi to bird names |
| Ansible inventory (`ansible/inventory/hosts.yml`) | Bird hostnames and VLAN 10 IPs |
