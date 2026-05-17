# Syncthing Obsidian Vault Design

**Date:** 2026-05-17
**Status:** Approved
**Scope:** Deploy Syncthing on the homelab K8s cluster as the canonical sync layer for an Obsidian vault, replacing Obsidian Sync. Hermes gets direct read/write access to the vault via shared NFS storage.

## Context

Michael is migrating off Obsidian Sync to a self-hosted Syncthing instance. The vault is the foundation of a larger life automation system where Hermes (the always-on AI agent) reads and writes notes directly. Sync targets are macOS and iOS (via Möbius Sync), configured post-deploy.

This is Phase 0 of the Hermes life automation pipeline. Obsidian Sync stays active in parallel during validation.

## Architecture Overview

```
macOS / iOS (Möbius Sync)
        │
        ▼  Syncthing protocol (port 22000 TCP)
┌──────────────────────┐
│   Syncthing Pod      │
│   (apps namespace)   │──── NFS PVC (obsidian-vault) ────┐
│   GUI: 8384          │                                   │
└──────────────────────┘                                   ▼
                                                    TrueNAS NFS
                                              /mnt/data/reference/obsidian
┌──────────────────────┐                                   │
│   Hermes Pod         │                                   │
│   (apps namespace)   │──── NFS PVC (obsidian-vault) ────┘
│   mount: /workspace/ │
│          obsidian    │
└──────────────────────┘
```

### Namespace: `apps`

Syncthing deploys alongside Hermes in the `apps` namespace. Both pods mount the same NFS-backed PVC. No new namespace or Flux Kustomization needed.

### Flux Dependency Chain (unchanged)

```
infrastructure --> databases --> storage --> apps
```

No new dependencies. Syncthing has no database or external service requirements.

## Storage

### NFS PersistentVolume: `obsidian-vault`

Canonical vault lives on TrueNAS at `/mnt/data/reference/obsidian`. This NFS share must be created on TrueNAS before deployment.

| Field | Value |
|-------|-------|
| Name | `obsidian-vault` |
| Capacity | 100Gi |
| Access Mode | ReadWriteMany |
| Storage Class | `""` (manual) |
| Reclaim Policy | Retain |
| NFS Server | 10.0.1.1 |
| NFS Path | /mnt/data/reference/obsidian |
| Mount Options | nfsvers=4.2, noatime |

PVC in `apps` namespace binds by `volumeName: obsidian-vault`.

### Syncthing Config PVC: `syncthing-config`

Syncthing's own database, device keys, and certificates. Separate from the vault so config persists independently.

| Field | Value |
|-------|-------|
| Name | `syncthing-config` |
| Capacity | 5Gi |
| Access Mode | ReadWriteOnce |
| Storage Class | local-path |

### Mount Points

| Pod | PVC | Mount Path | Purpose |
|-----|-----|------------|---------|
| Syncthing | obsidian-vault | /var/syncthing/Sync | Vault data (Syncthing default sync folder) |
| Syncthing | syncthing-config | /var/syncthing/config | Syncthing DB, certs, device keys |
| Hermes | obsidian-vault | /workspace/obsidian | Vault read/write access |

### Permissions

Both Syncthing and Hermes run as UID 10000 / GID 10000 via Kubernetes `securityContext`. Init container fixes NFS ownership on startup (same busybox chown pattern as Hermes).

## Syncthing Deployment

**Image:** `syncthing/syncthing:latest`
**Replicas:** 1
**Strategy:** Recreate

### Ports

| Name | Port | Protocol | Purpose |
|------|------|----------|---------|
| gui | 8384 | TCP | Web GUI |
| sync | 22000 | TCP | Sync protocol |
| discovery | 21027 | UDP | Local discovery |

### Security Context

```yaml
securityContext:
  runAsUser: 10000
  runAsGroup: 10000
  fsGroup: 10000
```

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| STHOMEDIR | /var/syncthing/config | Explicit config directory path |
| STGUIADDRESS | 0.0.0.0:8384 | Bind GUI to all interfaces |

### Health Probes

- Readiness: HTTP GET `/rest/noauth/health` on port 8384, initial delay 10s
- Liveness: HTTP GET `/rest/noauth/health` on port 8384, initial delay 30s

### Resources

| | CPU | Memory |
|---|-----|--------|
| Requests | 100m | 128Mi |
| Limits | 1000m | 512Mi |

Syncthing is lightweight for small vaults. Adjust if vault grows large.

### Init Container

Busybox init container runs `chown -R 10000:10000` on both `/var/syncthing/config` and `/var/syncthing/Sync` to fix NFS permissions.

## Networking

### Service: `syncthing` (ClusterIP)

Exposes GUI port 8384 for Traefik ingress.

### Service: `syncthing-sync` (LoadBalancer)

MetalLB LoadBalancer for sync protocol. Allocates a VIP from the `10.0.10.200-10.0.10.239` pool.

| Port | Protocol | Purpose |
|------|----------|---------|
| 22000 | TCP | Sync protocol (LAN direct connections) |
| 21027 | UDP | Local discovery |

### IngressRoute

| Field | Value |
|-------|-------|
| Host | `syncthing.home.mcnees.me` |
| Entry Point | websecure |
| Target Service | syncthing:8384 |
| Middleware | oauth2-proxy (namespace: auth) |
| TLS Secret | legacy-home-wildcard-tls |

### Remote Sync (Off-LAN)

Syncthing's default behavior handles remote sync without additional configuration:
- **LAN:** Direct connection via local discovery + MetalLB VIP
- **Remote:** Falls back to Syncthing public relay servers (end-to-end encrypted)
- No port forwarding or Tailscale required for basic functionality
- Can add port forwarding for 22000/TCP later if relay speed is insufficient

## Hermes Modification

Add one NFS volume mount to the existing Hermes deployment. No other changes.

**New volume:**
```yaml
- name: obsidian-vault
  persistentVolumeClaim:
    claimName: obsidian-vault
```

**New volumeMount:**
```yaml
- name: obsidian-vault
  mountPath: /workspace/obsidian
```

Hermes init container updated to also chown `/workspace/obsidian`.

## File Structure

```
kubernetes/apps/syncthing/
├── kustomization.yaml
├── deployment.yaml
├── service.yaml          # ClusterIP for GUI
├── service-sync.yaml     # LoadBalancer for sync protocol
├── ingress.yaml          # IngressRoute + oauth2-proxy
└── pvc.yaml              # syncthing-config PVC + obsidian-vault PV/PVC

kubernetes/apps/hermes/
├── deployment.yaml       # Modified: add obsidian-vault volume + mount
└── (other files unchanged)

kubernetes/apps/kustomization.yaml  # Add ./syncthing to resources
```

## Verification Criteria

1. **GUI accessible:** `syncthing.home.mcnees.me` loads behind oauth2-proxy auth
2. **Vault visible:** Syncthing GUI shows the obsidian folder as a configured shared folder
3. **Hermes access:** Write a test file from Hermes pod (`kubectl exec hermes -- touch /workspace/obsidian/test.md`), confirm it appears in Syncthing's folder view
4. **Persistence:** Delete Syncthing pod, wait for reschedule, verify config and vault data intact
5. **Sync readiness:** Syncthing device ID visible in GUI, ready for client pairing (pairing itself is post-deploy)

## What This Design Does NOT Cover

- Vault content migration (manual post-deploy)
- Obsidian Sync cancellation (parallel until validated)
- macOS/iOS client setup and device pairing
- Syncthing folder configuration beyond the default shared folder
- Hermes automation logic for reading/writing vault content
