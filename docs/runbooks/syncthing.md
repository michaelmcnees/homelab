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

### Changes written by Hermes not syncing
NFS does not support inotify, so Syncthing's filesystem watcher cannot detect changes. The rescan interval (`rescanIntervalS`) is set to 60 seconds in the running config. If outbound sync seems stalled, trigger a manual rescan:
```bash
API_KEY=$(kubectl exec -n apps deploy/syncthing -- grep apikey /var/syncthing/config/config.xml | sed 's/.*<apikey>\(.*\)<\/apikey>.*/\1/')
FOLDER_ID=$(kubectl exec -n apps deploy/syncthing -- grep 'folder id=' /var/syncthing/config/config.xml | head -1 | sed 's/.*id="\([^"]*\)".*/\1/')
kubectl exec -n apps deploy/syncthing -- wget -qO- --header="X-API-Key: $API_KEY" --post-data '' "http://localhost:8384/rest/db/scan?folder=$FOLDER_ID"
```

### Remote sync slow
Default uses Syncthing relay servers for off-LAN sync. For faster remote sync, port-forward 22000/TCP on the router to the MetalLB VIP.

## Prerequisites

The NFS share `/mnt/data/reference/obsidian` must exist on TrueNAS (10.0.1.1) before deploying. Create it via TrueNAS GUI or API with appropriate NFS export settings for the K8s VLAN (10.0.10.0/24).
