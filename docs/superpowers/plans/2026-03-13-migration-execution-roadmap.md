# Migration Execution Roadmap

Use this to track where you are in the migration. When starting a new Claude session, say: **"I'm on step X.Y of the migration roadmap"** and Claude will know exactly where to pick up.

---

## Stage 0: Consolidate + Hardware

### 0A: Consolidate onto Mew

| Step | Type | Task | Status |
|------|------|------|--------|
| 0A.1 | 🖥️ Physical | Inventory all LXCs: note CTID, current node, storage backend (Ceph vs local) | ⬜ |
| 0A.2 | 🖥️ Physical | Live-migrate Ceph-backed LXCs to Mew (one at a time, zero downtime). **Skip:** Docker LXC (NFS dep, stays on its node) | ⬜ |
| 0A.3 | 🖥️ Physical | Backup/restore local-storage LXCs to Mew (schedule off-hours, brief downtime each) | ⬜ |
| 0A.4 | 🖥️ Physical | Shut down Booklore + LazyLibrarian LXCs (NFS dep, can't move to Mew) | ⬜ |
| 0A.5 | 🖥️ Physical | Verify critical services on Mew: AdGuard DNS, Traefik ingress, Homey/Homebridge | ⬜ |
| 0A.6 | 🖥️ Physical | Destroy old K3s VMs (articuno–ho-oh, hass) and MariaDB LXC | ⬜ |
| 0A.7 | 🖥️ Physical | Verify nodes clean. Docker LXC's node (charmander or squirtle) keeps that one LXC — all others empty | ⬜ |

### 0B: Snorlax Conversion

| Step | Type | Task | Status |
|------|------|------|--------|
| 0B.1 | 🖥️ Physical | Export TrueNAS config, document pool layout, snapshot all datasets, export pools | ⬜ |
| 0B.2 | 🖥️ Physical | Communicate Plex downtime to household | ⬜ |
| 0B.3 | 🖥️ Physical | Install Proxmox on snorlax boot SSD (DO NOT touch HBA drives) | ⬜ |
| 0B.4 | 🖥️ Physical | Join snorlax to Proxmox cluster, verify Ceph client access | ⬜ |
| 0B.5 | 🖥️ Physical | Enable IOMMU in BIOS + Proxmox, load VFIO modules, blacklist i915 | ⬜ |
| 0B.6 | 🖥️ Physical | Identify PCI addresses for HBA, iGPU, NVMe drives | ⬜ |
| 0B.7 | 🖥️ Physical | Create munchlax VM with passthrough (HBA, iGPU, NVMe), install TrueNAS | ⬜ |
| 0B.8 | 🖥️ Physical | Import ZFS pools, restore config, verify all TrueNAS apps + Plex transcoding | ⬜ |

**Gate:** All services running, all 4 build nodes clean, snorlax converted, Plex working.

---

## Stage 1: Networking

| Step | Type | Task | Status |
|------|------|------|--------|
| 1.1 | 💻 Software | Write OpenTofu Unifi module (`terraform/unifi/`) — VLANs, firewall rules, port profiles | ⬜ |
| 1.2 | 💻 Software | `tofu apply` — create VLANs in Unifi | ⬜ |
| 1.3 | 🖥️ Physical | Configure trunk ports on switches for Proxmox hosts (VLANs 1, 10, 40) | ⬜ |
| 1.4 | 🖥️ Physical | Configure VLAN-aware bridges on each Proxmox node | ⬜ |
| 1.5 | 🔀 Both | Verify: spin up test VM on VLAN 10, confirm IP assignment + inter-VLAN routing | ⬜ |
| 1.6 | 🔀 Both | Verify AdGuard (on Mew, flat network) reachable from all VLANs | ⬜ |

**Gate:** All VLANs active, VLAN 10 test VM passes connectivity tests.

---

## Stage 2: K3s Infrastructure

| Step | Type | Task | Status |
|------|------|------|--------|
| 2.0 | 💻 Software | Update all specs/plans/configs: regi→bird names, VLAN 10 IPs, add kube-vip | ⬜ |
| 2.1 | 💻 Software | Update OpenTofu VM definitions (bird names, VLAN 10 interfaces) | ⬜ |
| 2.2 | 💻 Software | Update Ansible inventory + group_vars (bird names, VLAN 10 IPs) | ⬜ |
| 2.3 | 🔀 Both | Run cloud-init template playbook on each Proxmox node | ⬜ |
| 2.4 | 🔀 Both | `tofu apply` — create 4 K3s VMs (skip the node hosting Docker LXC) | ⬜ |
| 2.5 | 🔀 Both | `task ansible:k3s-prepare` — OS prep + prereqs | ⬜ |
| 2.6 | 🔀 Both | `task ansible:k3s-install` — bootstrap HA cluster | ⬜ |
| 2.7 | 🔀 Both | Deploy kube-vip for API VIP at 10.0.10.10 | ⬜ |
| 2.8 | 🔀 Both | Set up SOPS + age (generate key, update .sops.yaml, create K8s secret) | ⬜ |
| 2.9 | 🔀 Both | Bootstrap Flux CD, configure SOPS decryption | ⬜ |
| 2.10 | 🔀 Both | Verify: 5 nodes Ready, Flux syncing, SOPS works, defaults disabled | ⬜ |

**Gate:** `kubectl get nodes` = 5 Ready, `flux get kustomizations` = all synced.

---

## Stage 3: Core Platform

| Step | Type | Task | Status |
|------|------|------|--------|
| 3.1 | 💻 Software | Add Helm repository manifests (MetalLB, Traefik, cert-manager, etc.) | ⬜ |
| 3.2 | 💻 Software | Deploy democratic-csi + local-path-provisioner (storage classes) | ⬜ |
| 3.3 | 💻 Software | Deploy MetalLB + Traefik v3 (ingress) | ⬜ |
| 3.4 | 💻 Software | Deploy cert-manager + ExternalDNS (TLS + public DNS) | ⬜ |
| 3.5 | 🔀 Both | Create metagross LXC (OpenTofu), install PostgreSQL (Ansible) | ⬜ |
| 3.6 | 🔀 Both | Migrate databases to metagross: pocket_id, pelican, n8n, romm (pg_dump/restore) | ⬜ |
| 3.7 | 💻 Software | Deploy Redis in K8s | ⬜ |
| 3.8 | 💻 Software | Deploy auth chain: LLDAP → Pocket ID → OAuth2-Proxy | ⬜ |
| 3.9 | 🔀 Both | Verify: all HelmReleases Ready, test Ingress gets TLS cert, auth SSO works | ⬜ |

**Gate:** Full platform running, test Ingress with TLS works, PostgreSQL reachable from K8s.

---

## Stage 4: Service Migration

Each wave follows: export data → deploy to K3s → import data → verify → update DNS → monitor → destroy LXC.

| Step | Type | Task | Status |
|------|------|------|--------|
| 4.1 | 🔀 Both | **Wave 1:** AdGuard Home → K3s. Cut over DHCP DNS to MetalLB VIP. | ⬜ |
| 4.2 | 🔀 Both | **Wave 2:** Traefik cutover — update DNS records to K3s Traefik. | ⬜ |
| 4.3 | 🔀 Both | **Wave 3:** Auth chain verification — test SSO end-to-end. | ⬜ |
| 4.4 | 🔀 Both | **Wave 4:** Servarr stack (sonarr×2, radarr, lidarr×2, bazarr, prowlarr, recyclarr). Migrate Docker volumes. | ⬜ |
| 4.4b | 🔀 Both | Destroy Docker LXC, deploy 5th K3s VM on freed node, join to cluster | ⬜ |
| 4.5 | 🔀 Both | **Wave 5:** Seer, Wizarr, Tautulli. Mostly config migration. | ⬜ |
| 4.6 | 🔀 Both | **Wave 6:** Outline, Booklore, Paperless-ngx+ai, Gramps. Migrate DBs + file data. | ⬜ |
| 4.7 | 🔀 Both | **Wave 7:** Ollama + OpenWebUI, n8n. | ⬜ |
| 4.8 | 🔀 Both | **Wave 8:** Monitoring (kube-prometheus-stack, Beszel, Uptime Kuma). Retire InfluxDB. | ⬜ |
| 4.9 | 🔀 Both | **Wave 9:** Pelican Panel → K3s (points at Wings LXC on pikachu). | ⬜ |
| 4.10 | 💻 Software | **Wave 10:** Scrypted (new deploy, replaces Homebridge cameras). | ⬜ |
| 4.11 | 🔀 Both | **Wave 11:** Tailscale subnet router, DbGate, Netboot.xyz LXC. | ⬜ |
| 4.12 | 🖥️ Physical | Destroy retired LXCs: InfluxDB, Overseerr, ntfy, LazyLibrarian, old Traefik, old PostgreSQL, Docker | ⬜ |

**Gate:** All services in K3s verified, old LXCs destroyed, Mew nearly empty.

---

## Stage 5: Cleanup & Finalization

| Step | Type | Task | Status |
|------|------|------|--------|
| 5.1 | 🔀 Both | Move WiFi clients to VLAN 20 (trusted) — update McNet SSID VLAN | ⬜ |
| 5.2 | 🔀 Both | Move IoT devices to VLAN 30 — update McNet_IoT SSID VLAN | ⬜ |
| 5.3 | 🔀 Both | Create guest WiFi on VLAN 50 (McNet Guest, internet-only) | ⬜ |
| 5.4 | 💻 Software | Import DHCP reservations into OpenTofu (`terraform/unifi/`) | ⬜ |
| 5.5 | 🔀 Both | Decommission flat /22 — verify everything works on VLANs first | ⬜ |
| 5.6 | 🖥️ Physical | Clean up Mew — destroy remaining LXCs, repurpose or decommission | ⬜ |
| 5.7 | 🔀 Both | Create deoxys (PBS LXC), configure backup jobs | ⬜ |
| 5.8 | 🔀 Both | Create rayquaza (Pelican VM) on pikachu | ⬜ |
| 5.9 | 💻 Software | Write documentation: break-glass guide, in-case-of-death plan, runbooks | ⬜ |

**Gate:** All VLANs active, flat /22 gone, PBS running, docs complete. **Migration done.**

---

## Legend

- 🖥️ Physical = Hands-on Proxmox/hardware/BIOS work (Michael does these)
- 💻 Software = Code/config that Claude can write (OpenTofu, Ansible, K8s manifests, Flux)
- 🔀 Both = Claude writes the code/config, Michael runs it against real infra

## Implementation Plans

| Stage | Plan Document | Status |
|-------|--------------|--------|
| Stage 0 | `docs/superpowers/plans/2026-03-13-stage0-consolidate-hardware.md` | Written |
| Stage 1 | Needs writing | ⬜ |
| Stage 2 | `docs/superpowers/plans/2026-03-11-phase1-foundation.md` (needs bird name + VLAN update) | Needs update |
| Stage 3 | `docs/superpowers/plans/2026-03-11-phase2-core-platform.md` (needs bird name update) | Needs update |
| Stage 4 | Needs writing (per-wave plans) | ⬜ |
| Stage 5 | Needs writing | ⬜ |

## Key Reference Documents

- Migration spec: `docs/superpowers/specs/2026-03-13-migration-plan-design.md`
- Redesign spec: `docs/superpowers/specs/2026-03-11-homelab-redesign-design.md`
- Stage 0 plan: `docs/superpowers/plans/2026-03-13-stage0-consolidate-hardware.md`
