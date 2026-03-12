# Homelab Redesign — Design Spec

## Overview

Full redesign of the McNees homelab, moving from a mix of Proxmox LXCs and TrueNAS apps to an Infrastructure-as-Code architecture with Kubernetes (K3s) as the primary workload platform, GitOps via Flux CD, and comprehensive observability.

### Goals

- **IaC everywhere**: Track all changes in git. Point to a commit when something breaks, revert to fix it.
- **GitOps-driven workloads**: Push a manifest, Flux deploys it. No manual `kubectl apply`.
- **Full observability**: Know about problems before anyone in the house complains.
- **Proper remote access**: Tailscale subnet routing for secure access from anywhere.
- **Selective public exposure**: Wizarr, Booklore, Pocket ID, and other chosen services safely exposed to the internet.

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
| pve4 | **pikachu** | Dell 5050, i7-7700T, 32GB RAM, 250GB NVMe | K3s agent (worker) + LXCs (Homey, Homebridge) |
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
- **Passthrough**: HBA card (all 8x 20TB Exos drives + 2x 1TB NVMe metadata SSDs) + iGPU (QuickSync for Plex/Tdarr)
- **RAM allocation**: ~32GB to munchlax, ~30GB remaining for K3s agent + Proxmox overhead
- **Boot disk**: Ceph-backed (live-migratable, though passthrough pins it to snorlax in practice)

### Other VMs/LXCs (outside K8s)

| Workload | Type | Host | Reason |
|----------|------|------|--------|
| Homey (self-hosted) | LXC | pikachu | Host networking required |
| Homebridge | LXC | pikachu | Host networking + USB access |
| Netboot.xyz | LXC | any Proxmox host | PXE/TFTP needs management network access |

### IaC Tooling for Infrastructure

- **OpenTofu** (bpg/proxmox provider): Declaratively manages all VMs and LXCs — specs, disks, network interfaces, passthrough devices.
- **Ansible**: Configures Proxmox hosts (Ceph, networking, repos, SSH hardening) and K3s VM OS (packages, users, kernel params, K3s bootstrap).

---

## Section 2: Storage Architecture

### Proxmox VM Storage — Ceph

3x 1TB SATA SSDs on charmander/squirtle/bulbasaur form a Ceph pool with 3-way replication (~1TB usable). Used for:

- K3s VM boot disks (HA, live-migratable)
- Munchlax boot disk
- Any other VM/LXC disks

### Kubernetes Persistent Volumes — democratic-csi

**democratic-csi** connects K8s to TrueNAS via its API, dynamically creating ZFS datasets per PVC.

| Storage Class | Backend | Use Case |
|---------------|---------|----------|
| `truenas-nfs` | democratic-csi -> TrueNAS NFS | Most workloads (databases, app data, configs). ReadWriteMany. |
| `local-path` | Rancher local-path-provisioner | Ephemeral/cache data that doesn't need cross-node persistence. |

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
│   ├── romm/
│   └── gitea/
├── k8s/                    # democratic-csi managed (auto-creates child datasets)
│   ├── nfs/
│   └── snapshots/
├── backups/
│   ├── proxmox/            # VM/LXC backups via NFS
│   ├── velero/             # K8s backup target
│   └── timemachine/        # macOS Time Machine targets
├── homes/
│   ├── michael/
│   └── hannah/
└── isos/                   # OS images for Proxmox
```

### Backups

- **Proxmox VMs/LXCs**: Built-in Proxmox backup to `nfs-backups` share. Scheduled nightly.
- **K8s workloads**: Velero with TrueNAS-backed S3 target (MinIO). Snapshots both K8s resources and persistent volume data.
- **GitOps repo**: The GitHub repo IS the backup for all K8s manifests. Cluster can be rebuilt from the repo.
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

Firewall rules: trusted clients can reach K8s services and management. IoT reaches only Homey and the internet. Storage VLAN isolated to Proxmox hosts and K3s nodes.

VLAN segmentation is high-value but can be migrated incrementally — not a day-one blocker.

### DNS

| Domain | Resolver | Purpose |
|--------|----------|---------|
| `mcnees.me` | Cloudflare (public) | Externally exposed services |
| `home.mcnees.me` | AdGuard Home (internal) | Internal services |

- **AdGuard Home**: Wildcard `*.home.mcnees.me` -> MetalLB VIP (Traefik).
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
| Infrastructure | **OpenTofu** | Proxmox VMs/LXCs — specs, disks, NICs, passthrough |
| Configuration | **Ansible** | OS-level setup on Proxmox hosts + K3s VM base config |
| Workloads | **Flux CD** | Everything inside K8s — Helm releases, manifests, kustomizations |

### Why Flux CD over ArgoCD

Flux is lighter weight (no UI server), more git-native, and follows "repo is source of truth" more strictly. Grafana dashboards provide Flux sync visibility.

### Repo Structure

The homelab repo lives on **GitHub** (Flux points at GitHub — no self-hosted git dependency for cluster rebuilds).

```
homelab/
├── terraform/                  # OpenTofu — infrastructure layer
│   ├── main.tf                 # Provider config (bpg/proxmox)
│   ├── variables.tf
│   ├── outputs.tf
│   ├── nodes/
│   │   ├── regirock.tf
│   │   ├── regice.tf
│   │   ├── registeel.tf
│   │   ├── regieleki.tf
│   │   ├── regidrago.tf
│   │   ├── munchlax.tf
│   │   └── pikachu-lxcs.tf     # Homey + Homebridge LXCs
│   └── terraform.tfstate       # Local state initially; migrate to MinIO remote state after K8s is running
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
│   │   ├── minio/
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
│   │   └── wizarr/
│   └── repositories/           # HelmRepository and OCIRepository sources
│
├── Taskfile.yml                # Command guardrails
│
├── docs/
│   └── superpowers/
│       └── specs/
│
└── reference/                  # Old configs for reference
```

### Taskfile

Manual OpenTofu/Ansible runs with documented, consistent commands:

```yaml
# Taskfile.yml
tasks:
  infra:plan:
    desc: Preview infrastructure changes
    cmd: tofu plan
    dir: terraform

  infra:apply:
    desc: Apply infrastructure changes
    cmd: tofu apply
    dir: terraform

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
| `storage` | MinIO, democratic-csi |
| `networking` | AdGuard Home, Tailscale |

### How Changes Flow

| Change type | Workflow |
|-------------|----------|
| Deploy/update a K8s app | Edit manifests under `kubernetes/`, commit, push. Flux auto-deploys in 2-5 min. |
| Change VM resources | Edit `.tf` file, commit, `task infra:apply`. |
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
├── Network                 # Traefik requests, AdGuard stats, Tailscale
├── Storage                 # TrueNAS pools, PVC usage, backup status
├── Media                   # Plex streams, Tdarr queue, SABnzbd
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
| Gitea | Personal projects (homelab repo on GitHub) |

### LXCs on Pikachu — Host Networking Required

| Service | Reason |
|---------|--------|
| Homey (self-hosted) | Host networking |
| Homebridge | Host networking + USB access |

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
- MinIO

**Genealogy**
- Gramps

**Gaming**
- Pelican Panel

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
- **VLAN segmentation**: IoT, K8s, management, and storage traffic isolated at the network layer.
- **Traefik entrypoint separation**: External (81/444) and internal on separate ports.

### Host Security

- SSH key-only authentication on all Proxmox hosts (Ansible-enforced).
- Proxmox web UI accessible only from management VLAN + Tailscale.
- Fail2ban for brute-force protection.
- Automatic security updates via `unattended-upgrades`.

### Backup Security

- Velero backups encrypted at rest in MinIO.
- SOPS age key + Proxmox root credentials stored in password manager — the only things NOT in the repo.
- TrueNAS encryption keys backed up separately from the pools they protect.
