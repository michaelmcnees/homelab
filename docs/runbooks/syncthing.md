# Syncthing

## Overview

Syncthing provides file synchronization for the Obsidian vault. The canonical vault lives on TrueNAS NFS at `/mnt/data/reference/obsidian`. Both Syncthing and Hermes mount this path.

## Access

- **GUI:** https://syncthing.home.mcnees.me (behind oauth2-proxy)
- **Sync protocol:** MetalLB VIP on port 22000 (TCP) and 21027 (UDP)
- **Namespace:** apps

## Storage

| Volume | Type | Path | Purpose |
|--------|------|------|---------|
| obsidian-vault | NFS (TrueNAS) | /mnt/data/reference/obsidian | Canonical vault data |
| syncthing-config | local-path | — | Syncthing DB, certs, device keys |

## Device Pairing

1. Open GUI at https://syncthing.home.mcnees.me
2. Copy device ID from Actions → Show ID
3. On remote device, add the device ID
4. Accept the device on the Syncthing GUI when prompted
5. Share the "Default Folder" with the new device

## Hermes Integration

Hermes mounts the vault at `/workspace/obsidian` (read/write). Files written by Hermes appear in Syncthing automatically and sync to connected devices.

## Troubleshooting

### Vault not syncing
1. Check Syncthing GUI for connection status and errors
2. Verify NFS mount: `kubectl exec -n apps deploy/syncthing -- ls /var/syncthing/Sync`
3. Check pod logs: `kubectl logs -n apps deploy/syncthing`

### Permission errors
Both Syncthing and Hermes run as UID/GID 10000. The init container fixes NFS permissions on startup. If permissions drift, restart the pod.

### Remote sync slow
Default uses Syncthing relay servers for off-LAN sync. For faster remote sync, port-forward 22000/TCP on the router to the MetalLB VIP.

## Prerequisites

The NFS share `/mnt/data/reference/obsidian` must exist on TrueNAS (10.0.1.1) before deploying. Create it via TrueNAS GUI or API with appropriate NFS export settings for the K8s VLAN (10.0.10.0/24).
