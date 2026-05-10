# Networking

## Current VLAN State

UniFi networks are managed in `terraform/unifi`.

| Network | VLAN | Subnet | Purpose |
| --- | ---: | --- | --- |
| McLan | untagged | `10.0.0.0/22` | Legacy flat network, kept temporarily during migration |
| K8s | 10 | `10.0.10.0/24` | Kubernetes nodes, load balancers, and platform services |
| Trusted | 20 | `10.0.20.0/24` | Primary trusted WiFi clients |
| IoT | 30 | `10.0.30.0/24` | IoT WiFi clients |
| Storage | 40 | `10.0.40.0/24` | Storage/backend traffic |
| Guest | 50 | `10.0.50.0/24` | Guest WiFi |

DHCP on the managed VLANs points clients at AdGuard's Kubernetes VIP: `10.0.10.201`.

Cluster DNS is intentionally pinned to the same VIP in two places:

- `talos/patches/common.yaml` sets Talos host nameservers for node-level resolution.
- `kubernetes/infrastructure/configs/coredns.yaml` makes CoreDNS forward directly to `10.0.10.201`, so pod DNS does not depend on the Talos host resolver path.

Do not regenerate Talos configs for an existing cluster without the original `talos/secrets.yaml`; that file is the Talos cluster identity source. If the local `talos/talosconfig` is replaced with one generated from new secrets, it will not authenticate to the live nodes.

## Wireless

The three production WLANs are imported into OpenTofu as `unifi_wlan.wireless_networks`:

| SSID | Network |
| --- | --- |
| `McNet` | Trusted VLAN 20 |
| `McNet_IoT` | IoT VLAN 30 |
| `McNet Guest` | Guest VLAN 50 |

The WLAN resources intentionally ignore passphrases and provider-noisy rate/MAC-filter fields. Use OpenTofu for SSID-to-network assignment and meaningful security/isolation settings; avoid using it as the source of truth for WiFi secrets.

## Static IP Ownership

UniFi DHCP reservations are managed with `unifi_user.static_ips`.

Proxmox hosts configure their own static IPs, but UniFi still owns matching MAC/IP reservations so DHCP will not hand those addresses to other devices:

| Host | IP |
| --- | --- |
| `latios` | `10.0.3.196` |
| `latias` | `10.0.3.40` |
| `rayquaza` | `10.0.1.100` |

Do not rely on UniFi DHCP to configure Proxmox host networking. The reservations are collision guards only; the hosts remain statically configured.

Proxmox host DNS and intended management addresses are managed in Ansible:

| Setting | Source |
| --- | --- |
| Shared resolver/search config | `ansible/inventory/group_vars/proxmox_hosts.yml` |
| Per-host management address | `ansible/inventory/host_vars/<host>.yml` |
| Host setup playbook | `ansible/playbooks/proxmox-setup.yml` |

The playbook updates `/etc/resolv.conf` to use AdGuard at `10.0.10.201`. Full `/etc/network/interfaces` management is intentionally gated until each host has a confirmed `proxmox_management_bridge_ports` value, because the physical NIC name differs by node and a wrong bridge port can sever Proxmox access.

McLan's active gateway is `10.0.0.1`. Do not use the stale `10.0.0.16` gateway; Proxmox hosts using it cannot return traffic to the newer VLANs.

### Current Proxmox Host IP Conflict

Last UniFi audit found duplicate wired clients claiming two Proxmox host IPs:

| IP | Intended host path | Conflicting path |
| --- | --- | --- |
| `10.0.3.196` | `latios`, MAC `98:b7:85:25:18:03`, USW Flex XG port 4 | `debian`, MAC `d8:43:ae:cb:41:65`, Switch Lite port 11 |
| `10.0.3.40` | `latias`, MAC `b4:96:91:02:27:18`, USW Flex XG port 5 | MAC `34:5a:60:b4:ac:5a`, Switch Lite port 9 |
| `10.0.1.100` | `rayquaza`, MAC `a0:36:9f:64:cd:12`, USW Flex XG port 2 | No duplicate found; UniFi reservation is applied |

The intended split is:

| Link | Role |
| --- | --- |
| USW Flex XG 10Gb path | Current Proxmox management IP on McLan |
| Switch Lite 1Gb path | Future fallback/out-of-band management path, no McLan management IP while inactive |

Remove the McLan management IP from the Switch Lite-side NICs before applying the latios/latias UniFi reservations. The live Proxmox configs currently bridge management through these ports:

| Host | Bridge port |
| --- | --- |
| `latios` | `enp1s0f0` |
| `latias` | `enp1s0f0` |
| `rayquaza` | `enp12s0f1` |

## McLan Decommission Checklist

Last audit found 33 live clients still in `10.0.0.0/22`. Do not disable McLan DHCP or remove the network until these are resolved.

### Keep As Host-Static Or Infrastructure

| IP | Name | Notes |
| --- | --- | --- |
| `10.0.0.17` | Central Command | UniFi console. Move only with a planned controller management change. |
| `10.0.1.1` | TrueNAS | Storage endpoint used by NFS/PVCs and external services. |
| `10.0.1.100` | rayquaza | Proxmox host-static IP. |
| `10.0.3.40` | latias | Proxmox host-static IP. |
| `10.0.3.196` | latios | Proxmox host-static IP. |

### Legacy Services To Retire Or Move

| IP | Name | Expected action |
| --- | --- | --- |
| `10.0.0.18` | AdGuard Home | Old instance; DNS now uses `10.0.10.201`. Retire after confidence window. |
| `10.0.0.21` | traefik | Old edge proxy; retire after all routes use Kubernetes Traefik. |
| `10.0.0.23` | outline | Confirm replacement or retire. |
| `10.0.0.51` | mariadb | Confirm no workloads depend on it, then retire. |
| `10.0.0.60` | hass | Confirm Home Assistant migration path before retiring. |
| `10.0.0.64` | pelican-wings | Move/replace with final Pelican Wings design. |
| `10.0.1.40` | docker | Old Docker host. Retire after remaining temporary external service routes are gone. |
| `10.0.2.0` | pxe-bulbasaur | Retire old node or move if still needed. |
| `10.0.2.2` | pxe-charmander | Retire old node or move if still needed. |
| `10.0.2.3` | pxe-pikachu | Retire old node or move if still needed. |
| `10.0.2.5` | Homebridge | Move to final Homebridge plan. |
| `10.0.2.8` | Homey Server | Move to final Homey plan. |
| `10.0.2.9` | Uptime Kuma | Retire if Kubernetes observability replaces it. |

### Wired Devices To Classify

| IP | Name | Likely action |
| --- | --- | --- |
| `10.0.1.18` | Security | Decide Trusted vs IoT vs dedicated security segment. |
| `10.0.1.51` | HDHomeRun | Usually IoT/media; verify Plex/SAB access needs. |
| `10.0.1.52` | Lutron | IoT. |
| `10.0.3.8` | Samsung | IoT/media. |
| `10.0.3.37` | Basement-TV | IoT/media. |
| `10.0.3.62` | Living-Room | IoT/media. |
| `10.0.3.99` | MichaelcStudio2 | Trusted or wired workstation. |
| `10.0.3.126` | Living-Room | IoT WiFi client with stale lease; should renew into `10.0.30.0/24`. |
| `10.0.3.131` | Officejet Pro 8600 | IoT or Trusted depending on print access needs. |
| `10.0.3.178` | MacBook-Pro-3 | Trusted; renew/move off legacy if still present. |
| `10.0.3.181` | driveway | IoT/security. |
| `10.0.3.250` | office | Verify whether AP/switch/client before moving. |
| `10.0.3.253` | basement | Verify whether AP/switch/client before moving. |

## Decommission Procedure

1. Run a fresh UniFi client audit and confirm McLan is down to expected infrastructure only.
2. Move or retire legacy services and remove temporary external service routes that point at McLan addresses.
3. Move wired client switch ports to the correct native VLANs.
4. Shorten McLan DHCP range or disable McLan DHCP during a maintenance window.
5. Keep McLan itself available as rollback until no active clients use it.
6. Remove McLan only after controller management and any required host-static infrastructure have moved to their final networks.
