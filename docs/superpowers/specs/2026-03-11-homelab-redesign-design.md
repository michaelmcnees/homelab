# Homelab Redesign — Design Spec

## Overview

Full redesign of the McNees homelab, moving from a mix of Proxmox LXCs and TrueNAS apps to an Infrastructure-as-Code architecture with Kubernetes (K3s) as the primary workload platform, GitOps via Flux CD, and comprehensive observability.

### Goals

- **IaC everywhere**: Track all changes in git. Point to a commit when something breaks, revert to fix it.
- **GitOps-driven workloads**: Push a manifest, Flux deploys it. No manual `kubectl apply`.
- **Full observability**: Know about problems before anyone in the house complains.
- **Proper remote access**: Tailscale subnet routing for secure access from anywhere.
- **Selective public exposure**: Wizarr, Booklore, Pocket ID, and other chosen services safely exposed to the internet.
- **Unifi as Code**: Manage network infrastructure (VLANs, SSIDs, firewall rules) declaratively via OpenTofu.
- **Dev lab**: Isolated environment for career development, experimentation, and learning.
- **Thorough documentation**: Break-glass guide, in-case-of-death plan, and operational runbooks.

### Non-Goals

- Full CI/CD automation for OpenTofu/Ansible (manual with Taskfile guardrails for now).
- Multi-site or cloud hybrid deployment.
- Replacing TrueNAS for storage-heavy workloads.

---

## Section 1: Infrastructure Layer

### Proxmox Cluster — 5 Nodes

| Node | Hostname | Hardware | Role |
|------|----------|----------|------|
| pve1 | **charmander** | Dell 5050, i7-7700T, 32GB RAM, 250GB NVMe + 1TB SATA SSD | K3s server (control plane) + Ceph OSD |
| pve2 | **squirtle** | Dell 5050, i7-7700T, 32GB RAM, 250GB NVMe + 1TB SATA SSD | K3s server (control plane) + Ceph OSD |
| pve3 | **bulbasaur** | Dell 5050, i7-7700T, 32GB RAM, 250GB NVMe + 1TB SATA SSD | K3s server (control plane) + Ceph OSD |
| pve4 | **pikachu** | Dell 5050, i7-7700T, 32GB RAM, 250GB NVMe | K3s agent (worker) + LXCs + Pelican VM |
| pve5 | **snorlax** | Custom NAS, i3-13100, 64GB RAM, 200GB SSD + HBA card | TrueNAS VM (munchlax) + K3s agent (worker) |

### K3s Cluster — 5 VMs (Regi naming theme)

| K3s VM | Hostname | Runs on | Role |
|--------|----------|---------|------|
| k3s-server-1 | **regirock** | charmander | Control plane |
| k3s-server-2 | **regice** | squirtle | Control plane |
| k3s-server-3 | **registeel** | bulbasaur | Control plane |
| k3s-agent-1 | **regieleki** | pikachu | Worker |
| k3s-agent-2 | **regidrago** | snorlax | Worker |

> **Why VMs, not LXCs?** K3s nodes run as VMs intentionally. LXCs share the host kernel, so a misbehaving K8s workload (OOM, bad syscall, cgroup conflict) can take down the Proxmox host and everything else on it. K8s also pushes kernel boundaries hard — iptables, overlay filesystems, containerd, nested cgroups — which works in LXC but runs closer to the edge with each upgrade. VMs contain the blast radius: a kernel panic inside a K3s VM doesn't touch Proxmox. The RAM overhead (~2-3GB per VM for the guest kernel) is acceptable on 32GB+ nodes. LXCs are the right choice for single-purpose, trusted workloads like PostgreSQL, Homey, and Homebridge where you control exactly what runs.

### TrueNAS VM

- **Hostname**: munchlax
- **Runs on**: snorlax (pve5)
- **Passthrough**: HBA card (all 8x 20TB Exos drives) + iGPU (QuickSync for Plex/Tdarr)
- **NVMe metadata drives**: The 2x 1TB M.2 NVMe SSDs are on the motherboard (not HBA-connected). Passed to the TrueNAS VM separately (as virtual disks backed by local storage, or via PCIe/virtio passthrough) to continue serving as the mirrored metadata vdev.
- **RAM allocation**: ~32GB to munchlax, ~16GB to regidrago (K3s agent), ~16GB remaining for Proxmox overhead
- **Boot disk**: Ceph-backed (live-migratable, though passthrough pins it to snorlax in practice)

### Pelican Game Server VM

- **Hostname**: TBD (Pokémon name)
- **Runs on**: pikachu
- **Resources**: 16GB RAM minimum (more if available after LXC allocation). Dedicated VM for game server hosting.
- **Managed by**: Pelican Panel (running in K8s) connects to this node as a remote game server host.
- **Resource budget**: Pikachu has 32GB total. Proxmox host overhead ~2GB + Homey/Homebridge LXCs ~2GB + K3s agent VM (regieleki) ~8GB = ~12GB reserved, leaving ~20GB for the Pelican VM.

### Other VMs/LXCs (outside K8s)

| Workload | Type | Host | Reason |
|----------|------|------|--------|
| PostgreSQL | LXC | any (Ceph HA) | Central database for all apps. Proxmox HA restarts on any node if host fails. See "Database Architecture" below. |
| Homey (self-hosted) | LXC | pikachu | Host networking required |
| Homebridge | LXC | pikachu | Host networking + USB access (camera duties moved to Scrypted in K8s) |
| Proxmox Backup Server | LXC or VM | any (Ceph HA) | Deduplicated, incremental VM/LXC backups. Stores backup data on TrueNAS NFS share. |
| Netboot.xyz | LXC | any Proxmox host | PXE/TFTP needs management network access |
| Pelican game server | VM | pikachu | 16GB+ RAM, runs game instances managed by Pelican Panel |

### Database Architecture — PostgreSQL LXC

A single **PostgreSQL LXC** on Proxmox serves as the central database for all applications that support it. This eliminates SQLite-on-NFS issues, simplifies backups, and gives native disk performance on Ceph-backed storage.

- **Hostname**: TBD (Pokémon name)
- **Runs on**: Any Proxmox node (Ceph-backed disk = live-migratable, Proxmox HA enabled)
- **Resources**: 2-4GB RAM, 2 vCPU (lightweight — homelab query volume is low)
- **Storage**: Ceph-backed LXC disk (fast local I/O, replicated across nodes)
- **Backups**: Proxmox nightly LXC backup + PostgreSQL `pg_dump` cron for logical backups to TrueNAS
- **Managed by**: OpenTofu (LXC provisioning) + Ansible (PostgreSQL installation, configuration, database/user creation)

**Apps using PostgreSQL (configured via environment variables):**

| App | Config Method |
|-----|---------------|
| Sonarr, Sonarr-anime, Radarr, Lidarr, Lidarr-kids, Prowlarr | `*__POSTGRES__HOST`, `*__POSTGRES__PORT`, etc. env vars |
| Bazarr | PostgreSQL env vars |
| Paperless-ngx | `PAPERLESS_DBENGINE=postgresql`, `PAPERLESS_DBHOST`, etc. |
| Outline | `DATABASE_URL` connection string (requires Postgres) |
| Gramps Web | PostgreSQL connection string |
| Pocket ID | `DB_CONNECTION_STRING` env var |
| Pelican Panel | Database connection env vars |
| LLDAP | Planned — env var config exists but documentation is sparse. Falls back to SQLite on `local-path` if Postgres doesn't work. |

**Redis** runs as a K8s deployment (not in the LXC). It's a cache/session store, not a durable database — running it in-cluster next to the apps that use it (Outline, Paperless-ngx, etc.) minimizes latency. Uses `local-path` storage for optional persistence.

### IaC Tooling for Infrastructure

- **OpenTofu** (bpg/proxmox provider): Declaratively manages all VMs and LXCs — specs, disks, network interfaces, passthrough devices.
- **OpenTofu** (filipowm/unifi provider): Manages Unifi network infrastructure — VLANs, SSIDs, firewall rules, port profiles. See Section 3 for details.
- **OpenTofu** (cloudflare/cloudflare provider): Manages Cloudflare zone settings, DNS records (MX, SPF, DKIM, etc. that ExternalDNS doesn't handle), page rules, and WAF rules.
- **OpenTofu** (tailscale/tailscale provider): Manages Tailscale ACL policies, DNS settings, device authorization rules, and subnet route approvals.
- **Ansible**: Configures Proxmox hosts (Ceph, networking, repos, SSH hardening), K3s VM OS (packages, users, kernel params, K3s bootstrap), PostgreSQL LXC (installation, configuration, database/user creation), TrueNAS (datasets, shares, users, permissions via REST API), and AdGuard Home (DNS rewrites, upstream servers, filtering lists, client settings via REST API).

---

## Section 2: Storage Architecture

### Proxmox VM Storage — Ceph

3x 1TB SATA SSDs on charmander/squirtle/bulbasaur form a Ceph pool with 3-way replication (~1TB usable). Used for:

- K3s VM boot disks (HA, live-migratable)
- Munchlax boot disk
- Pelican VM boot disk
- PostgreSQL LXC disk (HA, live-migratable — critical shared database)
- Any other VM/LXC disks

### Kubernetes Persistent Volumes — democratic-csi

**democratic-csi** connects K8s to TrueNAS via its API, dynamically creating ZFS datasets per PVC.

| Storage Class | Backend | Use Case |
|---------------|---------|----------|
| `truenas-nfs` | democratic-csi -> TrueNAS NFS | Most workloads (bulk data, media references, document storage). ReadWriteMany. |
| `local-path` | Rancher local-path-provisioner | SQLite fallbacks (e.g., LLDAP), Redis persistence, anything with NFS/locking issues. Node-local Ceph-backed storage. |

Why democratic-csi over Longhorn: The Dell nodes have limited local storage (250GB NVMe minus Proxmox). Longhorn would compete for that space. democratic-csi puts all persistent data on TrueNAS's massive ZFS pool — K3s nodes stay stateless compute. Simpler, more storage, fewer moving parts.

### Storage Class Selection Guide

With databases externalized to the PostgreSQL LXC, most K8s apps no longer manage their own databases. This dramatically simplifies storage — almost everything can go on `truenas-nfs`.

| Use `local-path` | Use `truenas-nfs` |
|-------------------|-------------------|
| Redis (optional persistence) | Paperless-ngx document storage |
| LLDAP (if Postgres fallback to SQLite) | Ollama model files |
| Any app with known NFS/locking issues | Media references, bulk downloads |
| | App configs (no longer databases — just config files) |
| | Everything else by default |

**Why this is simpler now:** The *arr apps, Paperless-ngx, Gramps, Outline, Pocket ID, and Pelican Panel all use the PostgreSQL LXC for their databases. Their K8s PVCs only store config files and cache — safe on NFS.

**Escape hatch:** If NFS performance becomes an issue for a service, moving it to `local-path` is a PVC migration — not an architecture change.

### Future Enhancement: NVMe Pool + Optane Metadata

When Intel Optane drives become affordable, add a pair as a mirrored metadata special vdev on the HDD pool (replacing the current 1TB NVMe metadata vdev). Then repurpose the 2x existing 1TB NVMe drives + 2x new 1TB NVMe drives into a 4x RAIDZ1 NVMe pool (~3TB usable).

**Workloads to move to NVMe pool:**
- `data/k8s/` — All democratic-csi PVCs get NVMe speeds (Paperless OCR, Ollama model loading, app configs)
- `data/apps/` — TrueNAS app datasets (Plex metadata/database, Tdarr transcode cache, SABnzbd)
- `data/backups/pbs/` — PBS dedup index is heavily random-read; NVMe dramatically speeds up restores and verify jobs

**Stays on HDD pool:** `media/`, `homes/`, `isos/`, `backups/postgresql/`, `backups/timemachine/` — all sequential/throughput-oriented.

This is a hardware purchase + pool migration, not an architecture change — democratic-csi and TrueNAS apps just point at a different pool.

### TrueNAS Dataset Layout

```
data/
├── media/
│   ├── library/            # Trash Guides structure — movies/, tv/, music/, etc.
│   └── usenet/             # Download pipeline
├── apps/                   # TrueNAS app datasets (Plex, Tdarr, SABnzbd, etc.)
│   ├── plex/
│   ├── tdarr/
│   ├── sabnzbd/
│   ├── stash/
│   ├── lazylibrarian/
│   └── romm/
├── k8s/                    # democratic-csi managed (auto-creates child datasets)
│   ├── nfs/
│   └── snapshots/
├── backups/
│   ├── pbs/                # Proxmox Backup Server datastore (deduplicated, incremental)
│   ├── postgresql/         # pg_dump logical backups from PostgreSQL LXC
│   └── timemachine/        # macOS Time Machine targets
├── homes/
│   ├── michael/
│   └── hannah/
└── isos/                   # OS images for Proxmox
```

### Backups

#### Proxmox Backup Server (PBS)

A **PBS instance** (LXC or lightweight VM) provides deduplicated, incremental backups for all VMs and LXCs. Replaces the current vzdump-over-NFS approach.

- **Hostname**: TBD (Pokémon name)
- **Runs on**: Any Proxmox node (Ceph-backed disk = live-migratable)
- **Resources**: 2GB RAM, 2 vCPU (PBS is lightweight)
- **Backup storage**: NFS datastore pointing at TrueNAS (`data/backups/pbs/`)
- **Managed by**: OpenTofu (LXC provisioning) + Ansible (PBS installation, datastore config, backup job schedules)

**Why PBS over vzdump-to-NFS:**
- **Block-level deduplication**: K3s VMs share ~90% identical Ubuntu base — PBS stores common blocks once, not 5x. Significant space savings.
- **Incremental forever**: After the first full backup, only changed blocks transfer. Nightly backups complete in seconds instead of minutes.
- **Integrity verification**: Scheduled verify jobs catch bit-rot before you need a restore.
- **Granular file restore**: Mount a backup and pull individual files without restoring the entire VM.
- **Retention policies**: keep-last/daily/weekly/monthly/yearly with automatic pruning.

**Backup schedule:**
- **Nightly**: All VMs and LXCs (incremental — fast after first full)
- **Verification**: Weekly integrity check of all backup chunks
- **Retention**: 7 daily, 4 weekly, 3 monthly, 1 yearly

#### Other Backup Layers

- **PostgreSQL**: `pg_dump` cron inside the LXC writes logical backups to TrueNAS (`data/backups/postgresql/`). Supplements the PBS VM-level backup with application-consistent database dumps.
- **K8s persistent data**: Protected by TrueNAS ZFS snapshots (automated hourly/daily/weekly retention). democratic-csi creates per-PVC datasets, so each service's data gets independent snapshot coverage.
- **GitOps repo**: The GitHub repo IS the backup for all K8s manifests and configuration. Cluster can be rebuilt entirely from the repo.
- **TrueNAS ZFS**: Automated snapshot schedule (hourly/daily/weekly retention) via built-in snapshot tasks.

---

## Section 3: Networking & Access

### VLAN Segmentation

| VLAN | Subnet | Purpose |
|------|--------|---------|
| VLAN 1 (default) | 10.0.0.0/24 | Management — Proxmox hosts, Unifi gear |
| VLAN 10 | 10.0.10.0/24 | K8s — K3s node VMs, pod/service CIDRs |
| VLAN 20 | 10.0.20.0/24 | Trusted clients — desktops, laptops, phones |
| VLAN 30 | 10.0.30.0/24 | IoT — smart home devices, cameras |
| VLAN 40 | 10.0.40.0/24 | Storage — Ceph replication, NFS |
| VLAN 50 | 10.0.50.0/24 | Guest — internet-only, no LAN access |

Firewall rules between VLANs:
- **Trusted** (VLAN 20): Can reach K8s services, management, and storage.
- **IoT** (VLAN 30): Can reach Homey and the internet. No other LAN access.
- **Guest** (VLAN 50): Internet only. Completely isolated from all other VLANs. Rate-limited.
- **Storage** (VLAN 40): Isolated to Proxmox hosts and K3s nodes only.
- **K8s** (VLAN 10): Can reach storage VLAN and management VLAN (for Proxmox API).

VLAN segmentation is high-value but can be migrated incrementally — not a day-one blocker.

### WiFi SSIDs & VLAN Mapping

| SSID | VLAN | Purpose |
|------|------|---------|
| McNet | VLAN 20 (Trusted) | Family devices — phones, laptops, tablets |
| McNet_IoT | VLAN 30 (IoT) | Smart home devices, cameras |
| McNet Guest | VLAN 50 (Guest) | Visitors — internet only, no LAN access |

All SSIDs broadcast from U7 Pro Wall APs. VLAN tagging handled by the APs and trunk ports to switches.

### Unifi as Code — OpenTofu

The `filipowm/unifi` Terraform provider manages the entire Unifi network declaratively:

**What it manages:**
- Networks (VLANs, subnets, DHCP ranges)
- WiFi SSIDs and their VLAN assignments
- Firewall rules between VLANs
- Port profiles for switch ports
- Device settings

**What it doesn't manage (manual):**
- Physical device adoption
- Firmware updates
- AP placement and RF tuning

This lives in a separate OpenTofu module:

```
terraform/
├── proxmox/                # bpg/proxmox provider — VMs, LXCs
│   ├── main.tf
│   ├── nodes/
│   └── ...
├── unifi/                  # filipowm/unifi provider — network infra
│   ├── main.tf
│   ├── networks.tf         # VLANs, subnets
│   ├── wireless.tf         # SSIDs, VLAN mappings
│   ├── firewall.tf         # Inter-VLAN rules
│   └── port-profiles.tf    # Switch port configs
│
├── cloudflare/             # cloudflare/cloudflare provider — DNS & security
│   ├── main.tf
│   ├── zone.tf             # Zone settings, SSL mode, security level
│   ├── dns.tf              # MX, SPF, DKIM, DMARC, and other records ExternalDNS doesn't manage
│   └── rules.tf            # Page rules, WAF rules
│
└── tailscale/              # tailscale/tailscale provider — mesh networking
    ├── main.tf
    ├── acls.tf             # ACL policies, tag owners
    ├── dns.tf              # MagicDNS settings, search domains
    └── device-auth.tf      # Device authorization rules, subnet route approvals
```

### DNS

| Domain | Resolver | Purpose |
|--------|----------|---------|
| `mcnees.me` | Cloudflare (public) | Externally exposed services |
| `home.mcnees.me` | AdGuard Home (internal) | Internal services |
| `dev.home.mcnees.me` | AdGuard Home (internal) | Dev lab services (see Section 8) |

- **AdGuard Home**: Wildcard `*.home.mcnees.me` -> MetalLB VIP (Traefik). Covers both production internal and dev lab services.
- **ExternalDNS**: Runs in K8s, manages Cloudflare records for public `*.mcnees.me` services automatically when Ingress resources are created.

### Ingress & TLS

- **Traefik**: K8s ingress controller via IngressRoute CRDs.
  - External entrypoint: ports 81/444 (router forwards 80/443 -> 81/444).
  - Internal entrypoint: separate ports, isolated from external traffic.
- **cert-manager**: Let's Encrypt certificates via Cloudflare DNS-01 challenge. Valid TLS for both internal and external services.
- **MetalLB**: Assigns stable LoadBalancer IPs from the K8s VLAN for Traefik.

Future consideration: evaluate Caddy as an alternative ingress controller once the cluster is stable.

### Remote Access — Tailscale

- **Subnet router**: Runs as a K8s pod, advertises home subnets to the tailnet.
- **Use case**: Access all internal services via `home.mcnees.me` names from anywhere.
- **Tailscale SSH**: Bonus — SSH into Proxmox nodes from anywhere without port forwarding.
- Publicly exposed services (Wizarr, Booklore, Pocket ID) go through external Traefik entrypoint via Cloudflare, not Tailscale.

---

## Section 4: GitOps & IaC Toolchain

### Three-Layer Toolchain

| Layer | Tool | Manages |
|-------|------|---------|
| Infrastructure | **OpenTofu** | Proxmox VMs/LXCs, Unifi networking, Cloudflare DNS/security, Tailscale ACLs/routing |
| Configuration | **Ansible** | OS-level setup on Proxmox hosts + K3s VM base config |
| Workloads | **Flux CD** | Everything inside K8s — Helm releases, manifests, kustomizations |

### Why Flux CD over ArgoCD

Flux is lighter weight (no UI server), more git-native, and follows "repo is source of truth" more strictly. Grafana dashboards provide Flux sync visibility.

### Repo Structure

The homelab repo lives on **GitHub** (Flux points at GitHub — no self-hosted git dependency for cluster rebuilds).

```
homelab/
├── terraform/
│   ├── proxmox/                # bpg/proxmox provider — infrastructure
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── nodes/
│   │   │   ├── regirock.tf
│   │   │   ├── regice.tf
│   │   │   ├── registeel.tf
│   │   │   ├── regieleki.tf
│   │   │   ├── regidrago.tf
│   │   │   ├── munchlax.tf
│   │   │   ├── pelican-node.tf # Game server VM on pikachu
│   │   │   ├── postgresql-lxc.tf # PostgreSQL database LXC (Ceph HA)
│   │   │   ├── pbs.tf           # Proxmox Backup Server LXC/VM (Ceph HA)
│   │   │   ├── pikachu-lxcs.tf # Homey + Homebridge LXCs
│   │   │   └── netboot.tf     # Netboot.xyz LXC
│   │   └── terraform.tfstate   # Local state initially; migrate to remote state later
│   │
│   ├── unifi/                  # filipowm/unifi provider — networking
│   │   ├── main.tf
│   │   ├── networks.tf
│   │   ├── wireless.tf
│   │   ├── firewall.tf
│   │   └── port-profiles.tf
│   │
│   ├── cloudflare/             # cloudflare/cloudflare provider — DNS & security
│   │   ├── main.tf
│   │   ├── zone.tf
│   │   ├── dns.tf
│   │   └── rules.tf
│   │
│   └── tailscale/              # tailscale/tailscale provider — mesh networking
│       ├── main.tf
│       ├── acls.tf
│       ├── dns.tf
│       └── device-auth.tf
│
├── ansible/                    # Ansible — configuration layer
│   ├── inventory/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   ├── playbooks/
│   │   ├── proxmox-setup.yml
│   │   ├── k3s-prepare.yml
│   │   ├── k3s-install.yml
│   │   ├── postgresql-setup.yml  # PostgreSQL LXC: install, configure, create databases/users
│   │   ├── truenas-setup.yml     # TrueNAS: datasets, shares, users, permissions via REST API
│   │   ├── adguard-setup.yml     # AdGuard Home: DNS rewrites, upstream servers, filters, client settings
│   │   └── pbs-setup.yml         # PBS: installation, datastore config, backup job schedules, retention
│   └── roles/
│
├── kubernetes/                 # Flux — workload layer
│   ├── flux-system/            # Flux bootstrap (auto-generated)
│   ├── infrastructure/
│   │   ├── controllers/        # Traefik, cert-manager, MetalLB, ExternalDNS
│   │   ├── configs/            # ClusterIssuers, MetalLB pools
│   │   └── observability/      # kube-prometheus-stack, Loki, Beszel, Uptime Kuma, Unifi exporter
│   │       ├── beszel/
│   │       ├── pushover-alerts/  # Alertmanager Pushover receiver config
│   │       ├── unifi-exporter/
│   │       └── uptime-kuma/
│   ├── apps/
│   │   ├── adguard/
│   │   ├── bazarr/
│   │   ├── booklore/
│   │   ├── gramps/
│   │   ├── lidarr/
│   │   ├── lidarr-kids/
│   │   ├── lldap/
│   │   ├── oauth2-proxy/
│   │   ├── ollama/
│   │   ├── outline/
│   │   ├── paperless-ai/
│   │   ├── paperless-ngx/
│   │   ├── pelican-panel/
│   │   ├── pocket-id/
│   │   ├── prowlarr/
│   │   ├── radarr/
│   │   ├── recyclarr/
│   │   ├── dbgate/
│   │   ├── scrypted/
│   │   ├── seer/               # Replaces Overseerr
│   │   ├── sonarr/
│   │   ├── sonarr-anime/
│   │   ├── tailscale/
│   │   ├── tautulli/
│   │   └── wizarr/
│   ├── databases/
│   │   └── redis/
│   ├── dev-lab/                # Experimental/career dev workloads (see Section 8)
│   └── repositories/           # HelmRepository and OCIRepository sources
│
├── docs/                       # Documentation
│   ├── superpowers/
│   │   └── specs/
│   ├── runbooks/               # Operational runbooks
│   │   ├── break-glass.md      # Emergency recovery procedures
│   │   ├── in-case-of-death.md # Full handoff documentation
│   │   └── common-tasks.md     # How-tos for routine operations
│   └── architecture/           # Architecture diagrams and decisions
│
├── Taskfile.yml                # Command guardrails
│
└── reference/                  # Old configs for reference
```

### Taskfile

Manual OpenTofu/Ansible runs with documented, consistent commands:

```yaml
# Taskfile.yml
tasks:
  infra:plan:
    desc: Preview Proxmox infrastructure changes
    cmd: tofu plan
    dir: terraform/proxmox

  infra:apply:
    desc: Apply Proxmox infrastructure changes
    cmd: tofu apply
    dir: terraform/proxmox

  network:plan:
    desc: Preview Unifi network changes
    cmd: tofu plan
    dir: terraform/unifi

  network:apply:
    desc: Apply Unifi network changes
    cmd: tofu apply
    dir: terraform/unifi

  cloudflare:plan:
    desc: Preview Cloudflare DNS/security changes
    cmd: tofu plan
    dir: terraform/cloudflare

  cloudflare:apply:
    desc: Apply Cloudflare DNS/security changes
    cmd: tofu apply
    dir: terraform/cloudflare

  tailscale:plan:
    desc: Preview Tailscale ACL/DNS changes
    cmd: tofu plan
    dir: terraform/tailscale

  tailscale:apply:
    desc: Apply Tailscale ACL/DNS changes
    cmd: tofu apply
    dir: terraform/tailscale

  ansible:proxmox:
    desc: Configure Proxmox hosts
    cmd: ansible-playbook playbooks/proxmox-setup.yml
    dir: ansible

  ansible:k3s:
    desc: Prepare and install K3s
    cmd: ansible-playbook playbooks/k3s-install.yml
    dir: ansible

  ansible:postgresql:
    desc: Configure PostgreSQL LXC (install, databases, users)
    cmd: ansible-playbook playbooks/postgresql-setup.yml
    dir: ansible

  ansible:truenas:
    desc: Configure TrueNAS datasets, shares, users, permissions
    cmd: ansible-playbook playbooks/truenas-setup.yml
    dir: ansible

  ansible:adguard:
    desc: Configure AdGuard Home DNS rewrites, filters, settings
    cmd: ansible-playbook playbooks/adguard-setup.yml
    dir: ansible

  ansible:pbs:
    desc: Configure Proxmox Backup Server (datastores, jobs, retention)
    cmd: ansible-playbook playbooks/pbs-setup.yml
    dir: ansible

  flux:bootstrap:
    desc: Bootstrap Flux onto the cluster
    cmd: flux bootstrap github --owner=<github-user> --repository=homelab --path=kubernetes --personal
```

All commands discoverable via `task --list`.

### Namespace Strategy

K8s namespaces group services by function for isolation and NetworkPolicy boundaries:

| Namespace | Contents |
|-----------|----------|
| `flux-system` | Flux controllers (auto-created) |
| `infrastructure` | Traefik, cert-manager, MetalLB, ExternalDNS |
| `observability` | Prometheus, Grafana, Loki, Alertmanager, Beszel, Uptime Kuma, Unifi exporter |
| `auth` | Pocket ID, LLDAP, OAuth2-Proxy |
| `databases` | Redis (cache/session store) |
| `media` | Sonarr, Sonarr-anime, Radarr, Lidarr, Lidarr-kids, Bazarr, Prowlarr, Recyclarr, Seer, Wizarr, Tautulli |
| `apps` | Outline, Booklore, Gramps, Pelican Panel, Paperless-ngx, Paperless-ai, Ollama, Scrypted, DbGate |
| `storage` | democratic-csi |
| `networking` | AdGuard Home, Tailscale |
| `dev-lab` | Development/experimentation workloads (see Section 8) |

### How Changes Flow

| Change type | Workflow |
|-------------|----------|
| Deploy/update a K8s app | Edit manifests under `kubernetes/`, commit, push. Flux auto-deploys in 2-5 min. |
| Change VM resources | Edit `.tf` file, commit, `task infra:apply`. |
| Change network config | Edit `.tf` file in `terraform/unifi/`, commit, `task network:apply`. |
| Change DNS/Cloudflare | Edit `.tf` file in `terraform/cloudflare/`, commit, `task cloudflare:apply`. |
| Change Tailscale ACLs | Edit `.tf` file in `terraform/tailscale/`, commit, `task tailscale:apply`. |
| Update OS/host config | Edit Ansible playbook/role, commit, `task ansible:proxmox`. |
| Change TrueNAS datasets/shares | Edit Ansible vars, commit, `task ansible:truenas`. |
| Change AdGuard DNS config | Edit Ansible vars, commit, `task ansible:adguard`. |
| Something breaks | `git log` to find the change, `git revert`, push. Flux rolls back automatically. |

---

## Section 5: Observability Stack

### Components

| Tool | Purpose | Watches |
|------|---------|---------|
| **Prometheus** | Metrics collection & alerting | K8s nodes, pods, resource usage, app metrics |
| **Grafana** | Dashboards & visualization | Everything — single pane of glass |
| **Loki** | Log aggregation | Pod logs, K3s system logs |
| **Promtail** | Log shipper | Runs on every K3s node, ships logs to Loki |
| **Alertmanager** | Alert routing & dedup | Prometheus alerts -> Pushover |
| **Beszel** | Host-layer monitoring | Proxmox hosts + munchlax TrueNAS VM |
| **Uptime Kuma** | HTTP health checks | Public-facing services, user-perspective availability |

### Deployment

- **kube-prometheus-stack** Helm chart: bundles Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics with ~20 pre-built dashboards.
- **loki-stack** Helm chart: Loki + Promtail deployed separately.
- **Beszel**: Server component in K8s, agents on each Proxmox host and inside munchlax.

### Replaces

- InfluxDB (replaced by Prometheus)
- Standalone Grafana (replaced by kube-prometheus-stack bundled Grafana)

### Monitoring Tiers

**Tier 1 — Infrastructure** (is the house standing?)
- Proxmox host CPU, RAM, disk, temps (Beszel + prometheus-proxmox-exporter)
- Ceph cluster health and capacity
- TrueNAS ZFS pool status, disk health
- K3s node readiness and resource pressure
- Unifi network health (via SNMP or Unifi API exporter)

**Tier 2 — Platform** (are the foundations working?)
- Flux sync status
- Traefik request rates, errors, latency
- cert-manager certificate expiry
- DNS resolution health
- Tailscale connection status

**Tier 3 — Applications** (are the services people use working?)
- HTTP health checks for every exposed service (Uptime Kuma)
- Plex/Tautulli streaming metrics
- AdGuard query rates and block stats
- Per-app resource consumption
- Pelican game server status

### Alerting — Pushover

| Severity | Example | Notification |
|----------|---------|--------------|
| Critical | Node down, Ceph degraded, ZFS errors, cert expiring <7 days | Immediate push, high priority |
| Warning | Pod crash-looping, disk >80%, Flux sync failing | Normal priority push |
| Info | Backup completed, app deployed | Low priority or dashboard only |

### Grafana Dashboard Layout

```
Home Dashboard
├── Cluster Overview        # Node health, resource usage, Ceph status
├── Flux Status             # Sync state of all kustomizations/helmreleases
├── Network                 # Traefik requests, AdGuard stats, Tailscale, Unifi
├── Storage                 # TrueNAS pools, PVC usage, backup status
├── Media                   # Plex streams, Tdarr queue, SABnzbd
├── Gaming                  # Pelican server status
└── Alerts                  # Recent firings, silences, alert history
```

---

## Section 6: Service Inventory & Placement

### Stays on TrueNAS (munchlax) — Media/Storage-Heavy

| Service | Reason |
|---------|--------|
| Plex | QuickSync transcoding + direct media access |
| Tdarr | QuickSync transcoding + direct media access |
| SABnzbd | Downloads land directly on datasets |
| Stash | Direct media access |
| LazyLibrarian | Direct dataset access |
| Romm | Direct dataset access |

### VMs/LXCs on Pikachu — Special Requirements

| Service | Type | Reason |
|---------|------|--------|
| Homey (self-hosted) | LXC | Host networking required |
| Homebridge | LXC | Host networking + USB access |
| Pelican game server | VM (16GB+) | Game instance hosting, managed by Pelican Panel in K8s |

### LXC on Proxmox Host — Network Boot

| Service | Reason |
|---------|--------|
| Netboot.xyz | PXE/TFTP needs management network access |

### Moves to K8s — Everything Else

**Networking & Access**
- Traefik (ingress controller)
- AdGuard Home
- Tailscale (subnet router)

**Auth & Identity**
- Pocket ID (OIDC provider)
- LLDAP (user directory)
- OAuth2-Proxy (Traefik auth middleware)

**Productivity & Knowledge**
- Outline
- Booklore
- Paperless-ngx (document management, OCR, search)
- Paperless-ai (auto-tagging and classification companion for Paperless-ngx)

**AI/ML**
- Ollama (local LLM inference — serves Paperless-ai and other local AI workloads)

**Media Management**
- Seer (replaces Overseerr — migration required)
- Wizarr
- Tautulli
- Prowlarr
- Recyclarr
- Sonarr
- Sonarr (anime instance)
- Radarr
- Lidarr
- Lidarr (kids music instance)
- Bazarr

**Infrastructure Services**
- Redis (in-cluster cache/session store for Outline, Paperless-ngx, etc. — `databases` namespace)
- DbGate (multi-database admin UI — connects to PostgreSQL LXC, Redis, and any dev-lab databases)

**Home & Cameras**
- Scrypted (unified camera bridge — HKSV for Apple Home, RTSP rebroadcast for Homey)

**Genealogy**
- Gramps

**Gaming**
- Pelican Panel (manages game servers on the Pelican VM)

**Monitoring & Ops**
- Grafana (via kube-prometheus-stack)
- Prometheus (via kube-prometheus-stack)
- Loki + Promtail
- Alertmanager (-> Pushover)
- Uptime Kuma
- Beszel (server component)
- Unifi exporter (Prometheus metrics from Unifi controller)

### Document Processing — Paperless-ngx + Local AI

**Paperless-ngx** handles document ingestion, OCR, storage, and search. **Paperless-ai** watches for new documents and sends them to an LLM for automatic tagging, classification, and summarization. **Ollama** runs the LLM locally — no documents leave the network.

| Component | RAM | Storage Class | Notes |
|-----------|-----|---------------|-------|
| Paperless-ngx | ~1GB | `truenas-nfs` (documents), PostgreSQL LXC (db) | Core document management |
| Paperless-ai | ~512MB | — | Stateless companion, calls Ollama API |
| Ollama | 4-6GB limit | `truenas-nfs` (model files) | Serves LLM inference |

**Default model:** Llama 3.2 3B (Q4 quantized) — ~2-3GB RAM, strong at classification and summarization. Upgrade path to Llama 3.1 8B (Q4, ~5GB) if quality is insufficient.

**Node scheduling:** Ollama should prefer regidrago (snorlax, 16GB worker) where there's the most memory headroom. Soft affinity — not a hard requirement.

**Anthropic API fallback:** Paperless-ai supports any OpenAI-compatible API. If local model quality is insufficient for certain document types, it can be pointed at the Anthropic API (via a compatible proxy) without architecture changes. Preference is local-first for privacy.

### Camera Integration — Scrypted

**Scrypted** replaces the separate camera integrations in Homebridge and Homey with a single unified bridge.

**Before:** Unifi Protect → Homebridge plugin → Apple Home, AND Unifi Protect → Homey plugin → Homey (two separate connections, two integrations to maintain).

**After:** Unifi Protect → Scrypted → HomeKit Secure Video (HKSV) for Apple Home, AND RTSP rebroadcast available for Homey.

| Feature | Benefit |
|---------|---------|
| HomeKit Secure Video | Better quality and reliability than Homebridge camera plugin |
| RTSP rebroadcast | Connects to each camera once, serves multiple consumers — reduces Protect controller load |
| Local object detection | Person/vehicle/animal detection without cloud |
| Prebuffering | HKSV clips capture moments *before* motion trigger |

**Deployment:** Runs in K8s (`apps` namespace). Needs network access to Unifi Protect on the IoT/management VLAN but does not need host networking. Software transcoding is sufficient for a handful of cameras. Hardware transcoding via iGPU passthrough is an option if needed later.

**Note:** Homebridge remains as an LXC for non-camera plugins that need host networking or USB access. Its camera responsibilities move to Scrypted. Homey may still use its native Unifi Protect integration for automation triggers — test during implementation whether Scrypted's RTSP rebroadcast can replace that too.

### Retired

| Service | Replacement |
|---------|-------------|
| Portainer | Flux + Grafana |
| Overseerr | Seer |
| Home Assistant | Homey (self-hosted) |
| InfluxDB | Prometheus |
| n8n | Removed |
| Gitea | Removed (homelab repo on GitHub, no longer needed) |
| MinIO | Removed from initial plan (add later if needed) |

---

## Section 7: Secrets & Security

### Secrets Management — SOPS + age

- **age** keypair for encryption (simple, one file, no GPG complexity).
- **SOPS** encrypts only `data` values in K8s Secret manifests — structure stays readable for `git diff`.
- **Flux** has native SOPS integration — decrypts at deploy time using a cluster-stored key.
- Decryption key backed up in password manager.

### Authentication Chain

```
User request -> Traefik -> OAuth2-Proxy (middleware)
                               |
                          Pocket ID (OIDC)
                               |
                          LLDAP (user directory)
```

- LLDAP: user store for Michael, Hannah, and other service users.
- Pocket ID: OpenID Connect authentication.
- OAuth2-Proxy: Traefik middleware annotation — any service needing auth gets one annotation.
- Public services (Wizarr, Booklore, Pocket ID) skip the auth middleware.

### Network Security

- **K8s NetworkPolicies**: Default-deny between namespaces, explicit allows for known traffic (apps -> PostgreSQL LXC IP, apps -> Redis, Traefik -> all app namespaces).
- **VLAN segmentation**: IoT, K8s, management, storage, and guest traffic isolated at the network layer.
- **Guest network**: Internet-only, completely isolated from all other VLANs, rate-limited.
- **Traefik entrypoint separation**: External (81/444) and internal on separate ports.

### Host Security

- SSH key-only authentication on all Proxmox hosts (Ansible-enforced).
- Proxmox web UI accessible only from management VLAN + Tailscale.
- Fail2ban for brute-force protection.
- Automatic security updates via `unattended-upgrades`.

### Backup Security

- SOPS age key + Proxmox root credentials stored in password manager — the only things NOT in the repo.
- TrueNAS encryption keys backed up separately from the pools they protect.

---

## Section 8: Dev Lab

An isolated environment within K8s for career development, experimentation, and learning — spinning up databases, deploying web apps, testing new technologies — without risk to production services.

### Implementation

- **Namespace**: `dev-lab` with its own resource quotas (CPU/memory limits) to prevent experiments from starving production workloads.
- **DNS**: `*.dev.home.mcnees.me` — separate subdomain so it's clear what's dev vs. production.
- **Traefik**: Dedicated IngressRoute entries under the dev subdomain. Same internal entrypoint as production (no public exposure).
- **Storage**: Uses the same `truenas-nfs` storage class. democratic-csi creates datasets under `data/k8s/nfs/` — no special config needed.
- **NetworkPolicies**: Dev lab namespace can reach the PostgreSQL LXC IP (for testing against shared databases), Redis in the databases namespace, and the internet, but not production app namespaces.
- **Auth**: Dev services behind the same OAuth2-Proxy chain — only Michael has access.

### What it enables

- Spin up a PostgreSQL instance and a web app to test a project idea
- Deploy a staging version of a service before promoting to production
- Experiment with new Helm charts or K8s features safely
- Career development: build and deploy portfolio projects in a real K8s environment

### Cleanup

Dev lab resources are not GitOps-managed by default — you can `kubectl apply` directly for quick experiments without committing to the repo. For longer-running dev projects, add them under `kubernetes/dev-lab/` in the GitOps repo.

---

## Section 9: Documentation

### Documentation as a First-Class Deliverable

Documentation lives in the repo under `docs/` and is maintained alongside infrastructure changes.

### Break-Glass Guide (`docs/runbooks/break-glass.md`)

Emergency recovery procedures for when things go wrong. Covers:

- **Cluster won't boot**: How to access Proxmox directly, check Ceph health, restart VMs manually.
- **Flux is broken**: How to bypass GitOps and `kubectl apply` directly to restore services.
- **TrueNAS/munchlax is down**: How to access data, restore from ZFS snapshots, rebuild the VM.
- **Network is down**: How to access Proxmox console without network, reset Unifi gear.
- **Secrets are lost**: How to recover from password manager, re-bootstrap SOPS.
- **Complete rebuild**: Step-by-step instructions to rebuild the entire lab from the repo + backups.

Each scenario includes: symptoms, diagnosis steps, fix commands, and verification.

### In-Case-of-Death Plan (`docs/runbooks/in-case-of-death.md`)

A non-technical guide written for Hannah (or another trusted person) covering:

- **What exists**: Plain-English description of the homelab, what it does, and why it matters for the household (Plex, backups, smart home, etc.).
- **What to keep running**: Which services the household depends on daily (Plex, Time Machine, smart home, internet).
- **How to keep it running**: Simple restart procedures — "if X stops working, do Y." No K8s knowledge required.
- **Who to call**: Contact information for technically-capable friends who could help with complex issues.
- **How to shut it down safely**: If the decision is made to decommission, how to gracefully shut everything down and preserve important data (family photos, documents, backups).
- **Credentials**: Where to find the password manager, master passwords, and recovery keys. Stored securely outside the repo.

### Common Tasks Runbook (`docs/runbooks/common-tasks.md`)

How-tos for routine operations:

- Adding a new service to K8s
- Updating a Helm chart version
- Adding a new user to LLDAP
- Expanding TrueNAS storage
- Adding a new VLAN
- Restoring from backup
- Debugging a failed Flux sync
