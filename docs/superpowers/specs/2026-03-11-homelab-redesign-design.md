# Homelab Redesign — Design Spec

## Overview

Full redesign of the McNees homelab, moving from a mix of Proxmox LXCs and TrueNAS apps to an Infrastructure-as-Code architecture with Kubernetes (K3s) as the primary workload platform, GitOps via Flux CD, and comprehensive observability.

### Goals

- **IaC everywhere**: Track all changes in git. Point to a commit when something breaks, revert to fix it.
- **GitOps-driven workloads**: Push a manifest, Flux deploys it. No manual `kubectl apply`.
- **Full observability**: Know about problems before anyone in the house complains.
- **Proper remote access**: Tailscale subnet routing for secure access from anywhere.
- **Selective public exposure**: Wizarr, Pocket ID, and other chosen services safely exposed to the internet.
- **Unifi as Code**: Manage network infrastructure (VLANs, SSIDs, firewall rules) declaratively via OpenTofu.
- **Dev lab**: Isolated environment for career development, experimentation, and learning.
- **Thorough documentation**: Break-glass guide, in-case-of-death plan, and operational runbooks.

### Non-Goals

- Full CI/CD automation for OpenTofu/Ansible (manual with Taskfile guardrails for now).
- Multi-site or cloud hybrid deployment.
- Replacing TrueNAS for storage-heavy workloads.

---

## Section 1: Infrastructure Layer

### Proxmox Cluster — 3 Nodes

| Node | Hostname | Hardware | Role |
|------|----------|----------|------|
| pve1 | **latios** | Custom AMD (Ryzen 7 8700G, MSI Pro B650M-P, 64GB DDR5-5600, Samsung 970 EVO 500GB, EVGA 450BT, Rosewill RSV-Z2700U 2U, Dynatron AM5 cooler), 2.5GbE | K3s server + agent + Ceph OSD + Homey LXC |
| pve2 | **latias** | Custom AMD (same spec as latios), 2.5GbE | K3s server + agent + Pelican VM + Ceph OSD + Homebridge LXC |
| pve3 | **rayquaza** | Custom NAS (formerly snorlax), i3-13100, 64GB RAM, 200GB SSD + HBA card, 10GbE | TrueNAS VM (snorlax) + K3s server + Ceph OSD + metagross LXC |

> **Networking**: All three nodes connect via the Flex XG switch — latios and latias at 2.5GbE, rayquaza at 10GbE.

> **Cold spare**: One Dell 3050 Micro is kept powered off as a DR spare. Mew is decommissioned and sold after migration.

> **No QDevice needed**: With 3 Proxmox nodes, the cluster has native quorum and single-node failure tolerance.

### K3s Cluster — 5 VMs (Bird naming theme)

| K3s VM | Hostname | Runs on | Role | RAM |
|--------|----------|---------|------|-----|
| k3s-server-1 | **articuno** | latios | Control plane | 10GB |
| k3s-server-2 | **zapdos** | latias | Control plane | 10GB |
| k3s-server-3 | **moltres** | rayquaza | Control plane | 10GB |
| k3s-agent-1 | **lugia** | latios | Worker | 40GB |
| k3s-agent-2 | **ho-oh** | latias | Worker | 20GB |

> **Why VMs, not LXCs?** K3s nodes run as VMs intentionally. LXCs share the host kernel, so a misbehaving K8s workload (OOM, bad syscall, cgroup conflict) can take down the Proxmox host and everything else on it. K8s also pushes kernel boundaries hard — iptables, overlay filesystems, containerd, nested cgroups — which works in LXC but runs closer to the edge with each upgrade. VMs contain the blast radius: a kernel panic inside a K3s VM doesn't touch Proxmox. The RAM overhead (~2-3GB per VM for the guest kernel) is acceptable on 64GB nodes. LXCs are the right choice for single-purpose, trusted workloads like PostgreSQL, Homey, and Homebridge where you control exactly what runs.

### PriorityClasses

K3s workloads use PriorityClasses to ensure scheduling precedence during resource contention:

| PriorityClass | Value | Use Case |
|---------------|-------|----------|
| `critical` | 1000 | AdGuard, Traefik, auth chain, monitoring — services where downtime is immediately noticed |
| `standard` | 500 | Most application workloads — servarr, Paperless, Homepage, etc. |
| `best-effort` | 100 | Dev lab, batch jobs, non-essential services |

### TrueNAS VM

- **Hostname**: snorlax (formerly munchlax; the physical host was renamed from snorlax to rayquaza)
- **Runs on**: rayquaza (pve3)
- **Passthrough**: HBA card (all 8x 20TB Exos drives) + iGPU (QuickSync for Plex/Tdarr)
- **NVMe metadata drives**: The 2x 1TB M.2 NVMe SSDs are on the motherboard (not HBA-connected). Passed to the TrueNAS VM separately (as virtual disks backed by local storage, or via PCIe/virtio passthrough) to continue serving as the mirrored metadata vdev.
- **RAM allocation**: ~48GB to snorlax (TrueNAS), ~10GB to moltres (K3s server), ~2GB to metagross LXC, remainder for Proxmox overhead
- **Boot disk**: Ceph-backed (live-migratable, though passthrough pins it to rayquaza in practice)

### Pelican Game Server VM

- **Hostname**: pelipper
- **Runs on**: latias
- **Resources**: 20GB RAM. Dedicated VM for game server hosting.
- **Managed by**: Pelican Panel (running in K8s) connects to this node as a remote game server host.
- **Resource budget**: Latias has 64GB total. Proxmox overhead ~2GB + zapdos (K3s server) 10GB + ho-oh (K3s agent) 20GB + pelipper 20GB + Homebridge LXC ~1GB = ~53GB, leaving ~11GB headroom.

### Other VMs/LXCs (outside K8s)

| Workload | Type | Host | Reason |
|----------|------|------|--------|
| PostgreSQL (metagross) | LXC | rayquaza (Ceph HA) | Central database for all apps. Proxmox HA restarts on any node if host fails. See "Database Architecture" below. |
| Homey (self-hosted) | LXC | latios | Host networking required |
| Homebridge | LXC | latias | Host networking + USB access |
| Home Assistant (hass) | VM | latios | Smart home automation — migrated from Mew. Proxmox HA enabled. |
| Proxmox Backup Server (deoxys) | TrueNAS app | rayquaza (snorlax VM) | Runs inside TrueNAS. Backup data on local datasets — no NFS round trip. |
| Netboot.xyz | K8s Deployment | apps namespace | TFTP/HTTP boot server, NFS-backed images |
| Pelican game server (pelipper) | VM | latias | 20GB RAM, runs game instances managed by Pelican Panel |

### Database Architecture — PostgreSQL LXC

A single **PostgreSQL LXC** on Proxmox serves as the central database for all applications that support it. This eliminates SQLite-on-NFS issues, simplifies backups, and gives native disk performance on Ceph-backed storage.

- **Hostname**: metagross
- **Runs on**: rayquaza (Ceph-backed disk = live-migratable, Proxmox HA enabled)
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
| Pocket ID | `DB_CONNECTION_STRING` env var |
| Pelican Panel | Database connection env vars |
| LLDAP | Planned — env var config exists but documentation is sparse. Falls back to SQLite on `local-path` if Postgres doesn't work. |

**Redis** runs as a K8s deployment (not in the LXC). It's a cache/session store, not a durable database — running it in-cluster next to the apps that use it (Paperless-ngx, etc.) minimizes latency. Uses `local-path` storage for optional persistence.

### IaC Tooling for Infrastructure

- **OpenTofu** (bpg/proxmox provider): Declaratively manages all VMs and LXCs — specs, disks, network interfaces, passthrough devices.
- **OpenTofu** (filipowm/unifi provider): Manages Unifi network infrastructure — VLANs, SSIDs, firewall rules, port profiles. See Section 3 for details.
- **OpenTofu** (cloudflare/cloudflare provider): Manages Cloudflare zone settings, DNS records (MX, SPF, DKIM, etc. that ExternalDNS doesn't handle), page rules, and WAF rules.
- **OpenTofu** (tailscale/tailscale provider): Manages Tailscale ACL policies, DNS settings, device authorization rules, and subnet route approvals.
- **Ansible**: Configures Proxmox hosts (Ceph, networking, repos, SSH hardening), K3s VM OS (packages, users, kernel params, K3s bootstrap), PostgreSQL LXC (installation, configuration, database/user creation), TrueNAS (datasets, shares, users, permissions via REST API), and AdGuard Home (DNS rewrites, upstream servers, filtering lists, client settings via REST API).

---

## Section 2: Storage Architecture

### Proxmox VM Storage — Ceph

SATA SSDs across latios, latias, and rayquaza form a Ceph pool with 3-way replication. Used for:

- K3s VM boot disks (HA, live-migratable)
- Snorlax (TrueNAS) boot disk
- Pelipper (Pelican) VM boot disk
- PostgreSQL LXC disk (HA, live-migratable — critical shared database)
- Any other VM/LXC disks

### Kubernetes Persistent Volumes — local-path on Ceph-backed VM disks

Kubernetes uses Rancher `local-path` as the default StorageClass. Talos VM disks live on Proxmox `ceph-nvme`, so `local-path` data is physically backed by the replicated Proxmox Ceph pool even though Kubernetes treats each PVC as node-local `ReadWriteOnce` storage.

| Storage Class | Backend | Use Case |
|---------------|---------|----------|
| `local-path` | Rancher local-path-provisioner on Talos VM disks backed by Proxmox `ceph-nvme` | **Default.** App config, caches, single-pod service data, Redis persistence, and anything with NFS/locking sensitivity. ReadWriteOnce and node-bound at the Kubernetes layer. |
| TrueNAS NFS | Static or future dynamic NFS shares from snorlax | Bulk/shared datasets: media, downloads, ROM libraries, document archives, backups, and workloads that truly need ReadWriteMany semantics. |

This intentionally avoids a `flash/k8s` default PVC pool. The scarce resource is bulk drive capacity, while the Proxmox Ceph pool already gives the Talos VM disks replicated fast storage. If node-bound PVCs become painful later, add a real Kubernetes Ceph CSI layer deliberately rather than treating TrueNAS as the default app PVC backend.

### Storage Class Selection Guide

With databases externalized to the PostgreSQL LXC, most K8s apps only need config/cache PVCs. Those should use `local-path` unless the workload explicitly needs shared filesystem access or bulk capacity.

| Use `local-path` | Use TrueNAS NFS |
|-------------------|-------------------|
| Redis (optional persistence) | Paperless-ngx document storage |
| App config and caches | Ollama model files |
| SQLite or NFS/locking-sensitive data | Media references, bulk downloads |
| Single-pod service data that can tolerate node-bound PVCs | ROM libraries, documents, archives |

**Why this is simpler now:** The *arr apps, Paperless-ngx, Pocket ID, and Pelican Panel all use the PostgreSQL LXC for their databases. Their K8s PVCs mostly store config files and cache, which fit well on `local-path`.

**Tradeoff:** `local-path` PVCs are node-bound at the Kubernetes layer. A pod using one of these PVCs can restart on the same node automatically, but moving the workload to another node requires operational recovery or a future migration to Ceph CSI/NFS.

### Storage Tiering — Optane, L2ARC, and SSD Pool

> This section has been revised by `docs/superpowers/specs/2026-03-14-storage-tiering-design.md`. The old `flash/k8s` default PVC pool is no longer planned; TrueNAS focuses on bulk/shared/backup storage.

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
├── k8s-bulk/               # optional K8s bulk/shared NFS datasets
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

- **Hostname**: deoxys
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
- **K8s persistent data**: Default app PVCs live on Talos VM disks and are protected through Proxmox/PBS VM backups plus app-level exports where needed. TrueNAS-backed bulk/shared datasets use ZFS snapshots.
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
- Publicly exposed services (Pocket ID, Wizarr, Pelican Panel, Pelican Wings, and selected HDF services) go through the external Traefik entrypoint via Cloudflare, not Tailscale. Pelican Panel uses `games.mcnees.me`, Wings API/control uses `wings.games.mcnees.me`, and game allocations may use `games.mcnees.me:<port>` direct TCP/UDP exposure. Local infrastructure UIs such as TrueNAS, Proxmox, Homebridge, SABnzbd, and Tdarr remain internal-only under `home.mcnees.me`.

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
│   │   │   ├── articuno.tf       # K3s server on latios
│   │   │   ├── zapdos.tf         # K3s server on latias
│   │   │   ├── moltres.tf        # K3s server on rayquaza
│   │   │   ├── lugia.tf          # K3s agent on latios
│   │   │   ├── ho-oh.tf          # K3s agent on latias
│   │   │   ├── snorlax.tf        # TrueNAS VM on rayquaza
│   │   │   ├── pelipper.tf       # Pelican game server VM on latias
│   │   │   ├── metagross.tf      # PostgreSQL database LXC (Ceph HA)
│   │   │   ├── deoxys.tf         # Proxmox Backup Server LXC/VM (Ceph HA)
│   │   │   ├── homey-lxc.tf      # Homey LXC on latios
│   │   │   ├── homebridge-lxc.tf # Homebridge LXC on latias
│   │   │   └── netboot.tf        # Netboot.xyz LXC
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
│   │   └── configs/            # ClusterIssuers, MetalLB pools
│   ├── observability/
│   │   ├── kube-prometheus-stack/
│   │   ├── loki/
│   │   ├── beszel/
│   │   ├── uptime-kuma/
│   │   └── pushover-alerts/
│   ├── apps/
│   │   ├── adguard/
│   │   ├── bazarr/
│   │   ├── homepage/
│   │   ├── lidarr/
│   │   ├── lidarr-kids/
│   │   ├── lldap/
│   │   ├── oauth2-proxy/
│   │   ├── ollama/
│   │   ├── paperless-gpt/
│   │   ├── paperless-ngx/
│   │   ├── pelican-panel/
│   │   ├── pocket-id/
│   │   ├── prowlarr/
│   │   ├── radarr/
│   │   ├── recyclarr/
│   │   ├── seer/               # Replaces Overseerr
│   │   ├── sonarr/
│   │   ├── sonarr-anime/
│   │   ├── stash/
│   │   ├── tailscale/
│   │   ├── tautulli/
│   │   └── wizarr/
│   ├── databases/
│   │   └── redis/
│   ├── hdf/                   # HDF business services
│   │   ├── invoice-ninja/
│   │   ├── chatwoot/
│   │   └── kustomization.yaml
│   ├── storage/               # S3-compatible storage
│   │   └── rustfs/
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
| `observability` | Prometheus, Grafana, Loki, Alertmanager, Beszel, Uptime Kuma |
| `auth` | Pocket ID, LLDAP, OAuth2-Proxy |
| `databases` | Redis (cache/session store) |
| `media` | Sonarr, Sonarr-anime, Radarr, Lidarr, Lidarr-kids, Bazarr, Prowlarr, Recyclarr, Seer, Wizarr, Tautulli |
| `apps` | Mantle, Pelican Panel, Paperless-ngx, Paperless-GPT, Ollama, Homepage, Stash, Netboot.xyz |
| `hdf` | Invoice Ninja, Chatwoot (Hudsonville Digital Foundry client services) |
| `storage` | local-path provisioner, future TrueNAS NFS mounts, RustFS (S3-compatible object storage) |
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
| **Beszel** | Host-layer monitoring | Proxmox hosts + snorlax TrueNAS VM |
| **Uptime Kuma** | HTTP health checks | Public-facing services, user-perspective availability |

### Deployment

- **kube-prometheus-stack** Helm chart: bundles Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics with ~20 pre-built dashboards.
- **loki-stack** Helm chart: Loki + Promtail deployed separately.
- **Beszel**: Server component in K8s, agents on each Proxmox host and inside snorlax (TrueNAS).

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

### Stays on TrueNAS (snorlax) — Media/Storage-Heavy

| Service | Reason |
|---------|--------|
| Plex | QuickSync transcoding + direct media access |
| Tdarr | QuickSync transcoding + direct media access |
| SABnzbd | Downloads land directly on datasets |

### LXCs/VMs with Special Requirements

| Service | Type | Host | Reason |
|---------|------|------|--------|
| Homey (self-hosted) | LXC (1GB) | latios | Host networking required |
| Homebridge | LXC (1GB) | latias | Host networking + USB access |
| Pelican game server (pelipper) | VM (20GB) | latias | Game instance hosting, managed by Pelican Panel in K8s |
| PostgreSQL (metagross) | LXC (2GB) | rayquaza | Central database, Ceph HA |

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
- Paperless-ngx (document management, OCR, search)
- Paperless-GPT (auto-tagging, metadata, and OCR companion for Paperless-ngx)
- Homepage (dashboard)

**AI/ML**
- Ollama (local LLM inference - serves Paperless-GPT and other local AI workloads)

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
- Redis (in-cluster cache/session store for Paperless-ngx, etc. — `databases` namespace)

**Gaming**
- Pelican Panel (manages game servers on the Pelican VM)

**Monitoring & Ops**
- Grafana (via kube-prometheus-stack)
- Prometheus (via kube-prometheus-stack)
- Loki + Promtail
- Alertmanager (-> Pushover)
- Uptime Kuma
- Beszel (server component)

### Document Processing — Paperless-ngx + Local AI

**Paperless-ngx** handles document ingestion, OCR, storage, and search. **Paperless-GPT** watches tagged documents and sends them to an LLM for automatic titles, tags, correspondents, document types, and optional OCR assistance. **Ollama** runs the LLM locally — no documents leave the network.

| Component | RAM | Storage Class | Notes |
|-----------|-----|---------------|-------|
| Paperless-ngx | ~1GB | `truenas-nfs` (documents), PostgreSQL LXC (db) | Core document management |
| Paperless-GPT | ~256-512MB | `local-path` (prompt templates) | Companion web UI, calls Paperless and Ollama APIs |
| Ollama | 4-6GB limit | `truenas-nfs` (model files) | Serves LLM inference |

**Default model:** Llama 3.2 3B (Q4 quantized) — ~2-3GB RAM, strong at classification and summarization. Upgrade path to Llama 3.1 8B (Q4, ~5GB) if quality is insufficient.

**Node scheduling:** Ollama should prefer lugia (latios, 40GB worker) where there's the most memory headroom. Soft affinity — not a hard requirement.

**Anthropic API fallback:** Paperless-GPT supports Anthropic directly. If local model quality is insufficient for certain document types, it can be pointed at Claude without architecture changes. Preference is local-first for privacy.

### Retired

| Service | Replacement |
|---------|-------------|
| Portainer | Flux + Grafana |
| Overseerr | Seer |
| InfluxDB | Prometheus |
| n8n | Replaced by Mantle |
| Scrypted | Removed |
| Outline | Removed |
| Linkwarden | Removed |
| Actual Budget | Removed |
| Booklore | Removed |
| Glances | Removed |
| Gitea | Removed (homelab repo on GitHub, no longer needed) |
| MinIO | Replaced by RustFS (Apache 2.0 license) |

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
- Public services (Wizarr, Pocket ID) skip the auth middleware.

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
- **Storage**: Uses `local-path` by default. Add a TrueNAS NFS mount only for experiments that need shared filesystem semantics or bulk datasets.
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
- **TrueNAS/snorlax is down**: How to access data, restore from ZFS snapshots, rebuild the VM.
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
