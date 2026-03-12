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

### TrueNAS VM

- **Hostname**: munchlax
- **Runs on**: snorlax (pve5)
- **Passthrough**: HBA card (all 8x 20TB Exos drives) + iGPU (QuickSync for Plex/Tdarr)
- **NVMe metadata drives**: The 2x 1TB M.2 NVMe SSDs are on the motherboard (not HBA-connected). Passed to the TrueNAS VM separately (as virtual disks backed by local storage, or via PCIe/virtio passthrough) to continue serving as the mirrored metadata vdev.
- **RAM allocation**: ~32GB to munchlax, ~30GB remaining for K3s agent + Proxmox overhead
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
| Homey (self-hosted) | LXC | pikachu | Host networking required |
| Homebridge | LXC | pikachu | Host networking + USB access |
| Netboot.xyz | LXC | any Proxmox host | PXE/TFTP needs management network access |
| Pelican game server | VM | pikachu | 16GB+ RAM, runs game instances managed by Pelican Panel |

### IaC Tooling for Infrastructure

- **OpenTofu** (bpg/proxmox provider): Declaratively manages all VMs and LXCs — specs, disks, network interfaces, passthrough devices.
- **OpenTofu** (filipowm/unifi provider): Manages Unifi network infrastructure — VLANs, SSIDs, firewall rules, port profiles. See Section 3 for details.
- **Ansible**: Configures Proxmox hosts (Ceph, networking, repos, SSH hardening) and K3s VM OS (packages, users, kernel params, K3s bootstrap).

---

## Section 2: Storage Architecture

### Proxmox VM Storage — Ceph

3x 1TB SATA SSDs on charmander/squirtle/bulbasaur form a Ceph pool with 3-way replication (~1TB usable). Used for:

- K3s VM boot disks (HA, live-migratable)
- Munchlax boot disk
- Pelican VM boot disk
- Any other VM/LXC disks

### Kubernetes Persistent Volumes — democratic-csi

**democratic-csi** connects K8s to TrueNAS via its API, dynamically creating ZFS datasets per PVC.

| Storage Class | Backend | Use Case |
|---------------|---------|----------|
| `truenas-nfs` | democratic-csi -> TrueNAS NFS | Most workloads (databases, app data, configs). ReadWriteMany. |
| `local-path` | Rancher local-path-provisioner | Ephemeral/cache data that doesn't need cross-node persistence. |

Why democratic-csi over Longhorn: The Dell nodes have limited local storage (250GB NVMe minus Proxmox). Longhorn would compete for that space. democratic-csi puts all persistent data on TrueNAS's massive ZFS pool — K3s nodes stay stateless compute. Simpler, more storage, fewer moving parts.

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
│   ├── proxmox/            # VM/LXC backups via NFS
│   └── timemachine/        # macOS Time Machine targets
├── homes/
│   ├── michael/
│   └── hannah/
└── isos/                   # OS images for Proxmox
```

### Backups

- **Proxmox VMs/LXCs**: Built-in Proxmox backup to `nfs-backups` share on TrueNAS. Scheduled nightly.
- **K8s persistent data**: Protected by TrueNAS ZFS snapshots (automated hourly/daily/weekly retention). democratic-csi creates per-PVC datasets, so each service's data gets independent snapshot coverage.
- **GitOps repo**: The GitHub repo IS the backup for all K8s manifests and configuration. Cluster can be rebuilt entirely from the repo.
- **TrueNAS ZFS**: Automated snapshot schedule (hourly/daily/weekly retention) via built-in snapshot tasks.

Future consideration: Add K8s-native backup/restore tooling if the need arises.

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
└── unifi/                  # filipowm/unifi provider — network infra
    ├── main.tf
    ├── networks.tf         # VLANs, subnets
    ├── wireless.tf         # SSIDs, VLAN mappings
    ├── firewall.tf         # Inter-VLAN rules
    └── port-profiles.tf    # Switch port configs
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
| Infrastructure | **OpenTofu** | Proxmox VMs/LXCs + Unifi networking — specs, disks, NICs, passthrough, VLANs, SSIDs, firewall |
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
│   │   │   ├── pikachu-lxcs.tf # Homey + Homebridge LXCs
│   │   │   └── netboot.tf     # Netboot.xyz LXC
│   │   └── terraform.tfstate   # Local state initially; migrate to remote state later
│   │
│   └── unifi/                  # filipowm/unifi provider — networking
│       ├── main.tf
│       ├── networks.tf
│       ├── wireless.tf
│       ├── firewall.tf
│       └── port-profiles.tf
│
├── ansible/                    # Ansible — configuration layer
│   ├── inventory/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   ├── playbooks/
│   │   ├── proxmox-setup.yml
│   │   ├── k3s-prepare.yml
│   │   └── k3s-install.yml
│   └── roles/
│
├── kubernetes/                 # Flux — workload layer
│   ├── flux-system/            # Flux bootstrap (auto-generated)
│   ├── infrastructure/
│   │   ├── controllers/        # Traefik, cert-manager, MetalLB, ExternalDNS
│   │   ├── configs/            # ClusterIssuers, MetalLB pools
│   │   └── observability/      # kube-prometheus-stack, Loki, Beszel, Uptime Kuma
│   ├── apps/
│   │   ├── adguard/
│   │   ├── bazarr/
│   │   ├── beszel/
│   │   ├── booklore/
│   │   ├── gramps/
│   │   ├── lidarr/
│   │   ├── lidarr-kids/
│   │   ├── lldap/
│   │   ├── mariadb/
│   │   ├── oauth2-proxy/
│   │   ├── outline/
│   │   ├── pelican-panel/
│   │   ├── pocket-id/
│   │   ├── postgresql/
│   │   ├── prowlarr/
│   │   ├── pushover-alerts/    # Alertmanager config for Pushover
│   │   ├── radarr/
│   │   ├── recyclarr/
│   │   ├── redis/
│   │   ├── seer/               # Replaces Overseerr
│   │   ├── sonarr/
│   │   ├── sonarr-anime/
│   │   ├── tailscale/
│   │   ├── tautulli/
│   │   ├── uptime-kuma/
│   │   ├── unifi-exporter/
│   │   └── wizarr/
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

  ansible:proxmox:
    desc: Configure Proxmox hosts
    cmd: ansible-playbook playbooks/proxmox-setup.yml
    dir: ansible

  ansible:k3s:
    desc: Prepare and install K3s
    cmd: ansible-playbook playbooks/k3s-install.yml
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
| `databases` | PostgreSQL, MariaDB, Redis |
| `media` | Sonarr, Sonarr-anime, Radarr, Lidarr, Lidarr-kids, Bazarr, Prowlarr, Recyclarr, Seer, Wizarr, Tautulli |
| `apps` | Outline, Booklore, Gramps, Pelican Panel |
| `storage` | democratic-csi |
| `networking` | AdGuard Home, Tailscale |
| `dev-lab` | Development/experimentation workloads (see Section 8) |

### How Changes Flow

| Change type | Workflow |
|-------------|----------|
| Deploy/update a K8s app | Edit manifests under `kubernetes/`, commit, push. Flux auto-deploys in 2-5 min. |
| Change VM resources | Edit `.tf` file, commit, `task infra:apply`. |
| Change network config | Edit `.tf` file in `terraform/unifi/`, commit, `task network:apply`. |
| Update OS/host config | Edit Ansible playbook/role, commit, `task ansible:proxmox`. |
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
- PostgreSQL
- MariaDB
- Redis

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

- **K8s NetworkPolicies**: Default-deny between namespaces, explicit allows for known traffic (apps -> PostgreSQL, Traefik -> all app namespaces).
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
- **NetworkPolicies**: Dev lab namespace can reach databases namespace (for testing against shared databases) and the internet, but not production app namespaces.
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
