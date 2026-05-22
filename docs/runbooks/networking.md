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

Before importing or applying UniFi reservation changes, run the local state audit:

```bash
scripts/unifi-static-ip-state-audit.sh
```

The audit is read-only and compares `terraform/unifi/static_ips.tf` with local OpenTofu state. Use `docs/runbooks/unifi-import-prep.md` for the import sequence and migration-era entries that need reclassification before any apply.

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

The latest read-only UniFi audit on 2026-05-22 used `unpoller_client_uptime_seconds` and `unpoller_device_info` from Prometheus. It found 11 current McLan client entries plus UniFi infrastructure devices still using `10.0.0.0/22`. Do not disable McLan DHCP or remove the network until these are resolved.

Current UniFi client counts by network:

| Network | Current client entries |
| --- | ---: |
| McLan | 11 |
| K8s | 8 |
| Trusted | 24 |
| IoT | 16 |

### UniFi Infrastructure Still On McLan

| IP | Name | Model | Notes |
| --- | --- | --- | --- |
| `10.0.3.146` | USW Flex XG | USFXG | Core 10Gb switch; keep until network management migration is planned. |
| `10.0.3.216` | Switch Lite | USL16LP | Access switch; keep until switch management migration is planned. |
| `10.0.3.89` | USW-Flex-Mini | USMINI | Access switch; keep until switch management migration is planned. |
| `10.0.3.254` | US-24-G1 | US24 | Access switch; keep until switch management migration is planned. |
| `10.0.3.101` | Kitchen AP | U7PIW | AP management IP; keep until AP management migration is planned. |
| `10.0.3.0` | Office AP | U7PIW | AP management IP; keep until AP management migration is planned. |

### Keep As Host-Static Or Infrastructure

| IP | Name | Current path | Notes |
| --- | --- | --- | --- |
| `10.0.0.17` | Central Command | Switch Lite port 8 | UniFi console. Move only with a planned controller management change. |
| `10.0.1.1` | TrueNAS | USW Flex XG port 2 | Storage endpoint used by NFS/PVCs and external services. |
| `10.0.1.100` | rayquaza | USW Flex XG port 2 | Proxmox host-static IP. |
| `10.0.3.40` | latias | USW Flex XG port 5 | Proxmox host-static IP. |
| `10.0.3.196` | latios | USW Flex XG port 4 | Proxmox host-static IP. |

### Current McLan Clients To Move Or Retire

| IP | Name | MAC | Current path | Expected action |
| --- | --- | --- | --- | --- |
| `10.0.2.3` | pxe-pikachu | `14:b3:1f:1a:3b:51` | US-24-G1 port 6 | Keep while Pikachu remains live. Added to UniFi IaC so it can be imported or created deliberately. |
| `10.0.3.181` | driveway | `e4:38:83:0b:ab:3b` | Switch Lite port 4 | Was expected on IoT after 2026-05-11 cleanup; recheck switch port/VLAN assignment. |
| `10.0.3.250` | office | `74:83:c2:3f:94:22` | Switch Lite port 1 | Classify before assigning a final VLAN. |
| `10.0.3.253` | basement | `74:83:c2:3f:95:e4` | Switch Lite port 6 | Classify before assigning a final VLAN. |
| No current IP label | pxe-latios | `d8:43:ae:cb:41:65` | Switch Lite port 11 | Duplicate/alternate path for latios. Remove McLan management from this NIC before tightening latios reservations. |
| No current IP label | Unknown | `34:5a:60:b4:ac:5a` | Switch Lite port 9 | Duplicate/alternate path for latias. Remove McLan management from this NIC before tightening latias reservations. |

### Moved During 2026-05-11 Cleanup

| IP | Name | Expected action |
| --- | --- | --- |
| `10.0.10.64` | pelican-wings | Active Pelican Wings daemon. External backend for `wings.games.mcnees.me` and game allocations. |
| `10.0.20.99` | MichaelcStudio2 | Trusted wired workstation; USW Flex XG port 3 moved to native Trusted. |
| `10.0.30.8` | Samsung | IoT/media; US-24-G1 port 7 moved to native IoT. |
| `10.0.30.18` | Security | IoT/security; US-24-G1 port 4 moved to native IoT. |
| `10.0.30.37` | Basement-TV | IoT/media; US-24-G1 port 22 moved to native IoT. |
| `10.0.30.51` | HDHomeRun | IoT/media; US-24-G1 port 3 moved to native IoT. |
| `10.0.30.52` | Lutron | IoT; US-24-G1 port 1 moved to native IoT. |
| `10.0.30.62` | Living-Room | IoT/media; US-24-G1 port 5 moved to native IoT. |
| `10.0.30.181` | driveway | IoT/security; DHCP reservation moved to IoT. |

### Legacy Services To Retire Or Move

| IP | Name | Expected action |
| --- | --- | --- |
| `10.0.2.3` | pxe-pikachu | Live old node still visible on US-24-G1 port 6. Keep/import the reservation while Pikachu remains active; retire only after the node is gone or moved. |

### Wired Devices To Classify

| IP | Name | Likely action |
| --- | --- | --- |
| `10.0.3.250` | office | Verify whether AP/switch/client before moving. |
| `10.0.3.253` | basement | Verify whether AP/switch/client before moving. |
| `10.0.30.150` | Unknown `78:20:a5:8e:eb:92` | Current audit shows this on IoT, not McLan. Keep classified as IoT unless a fresh audit says otherwise. |
| `10.0.30.205` | Kiljarl | Current audit shows this on IoT, not McLan. Keep classified as IoT unless a fresh audit says otherwise. |

## Decommission Procedure

1. Run a fresh UniFi client audit and confirm McLan is down to expected infrastructure only.
2. Move or retire legacy services and remove temporary external service routes that point at McLan addresses.
3. Move wired client switch ports to the correct native VLANs.
4. Shorten McLan DHCP range or disable McLan DHCP during a maintenance window.
5. Keep McLan itself available as rollback until no active clients use it.
6. Remove McLan only after controller management and any required host-static infrastructure have moved to their final networks.
