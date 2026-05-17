# Syncthing Obsidian Vault Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Syncthing on the homelab K8s cluster with shared NFS vault storage accessible by both Syncthing and Hermes.

**Architecture:** Standalone Syncthing Deployment in `apps` namespace. NFS PV/PVC on TrueNAS (`/mnt/data/reference/obsidian`) mounted by both Syncthing and Hermes pods. Syncthing GUI exposed at `syncthing.home.mcnees.me` behind oauth2-proxy. Sync protocol exposed via MetalLB LoadBalancer.

**Tech Stack:** Kubernetes manifests (Kustomize), Traefik IngressRoute, MetalLB, NFS, Flux CD GitOps

**Spec:** `docs/superpowers/specs/2026-05-17-syncthing-obsidian-vault-design.md`

---

### Task 1: Create NFS PV/PVC and Syncthing Config PVC

**Files:**
- Create: `kubernetes/apps/syncthing/pvc.yaml`

This file contains three resources: the NFS PersistentVolume for the vault, the PVC that binds to it, and a local-path PVC for Syncthing's own config/database.

- [ ] **Step 1: Create the pvc.yaml file**

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: obsidian-vault
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - nfsvers=4.2
    - noatime
  claimRef:
    namespace: apps
    name: obsidian-vault
  nfs:
    server: 10.0.1.1
    path: /mnt/data/reference/obsidian
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: obsidian-vault
  namespace: apps
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  volumeName: obsidian-vault
  resources:
    requests:
      storage: 100Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: syncthing-config
  namespace: apps
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

- [ ] **Step 2: Validate the manifest renders**

Run: `kubectl kustomize kubernetes/apps/syncthing/` will fail because kustomization.yaml doesn't exist yet — that's expected. Instead validate the YAML:

```bash
cat kubernetes/apps/syncthing/pvc.yaml | kubectl apply --dry-run=client -f - 2>&1 | head -20
```

Expected: Three resources validated (PV, PVC, PVC). May warn about missing server — that's fine for dry-run.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/syncthing/pvc.yaml
git commit -m "feat(syncthing): add NFS PV/PVC for obsidian vault and config PVC"
```

---

### Task 2: Create Syncthing Deployment

**Files:**
- Create: `kubernetes/apps/syncthing/deployment.yaml`

- [ ] **Step 1: Create the deployment.yaml file**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: syncthing
  namespace: apps
  labels:
    app.kubernetes.io/name: syncthing
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: syncthing
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: syncthing
    spec:
      enableServiceLinks: false
      securityContext:
        runAsUser: 10000
        runAsGroup: 10000
        fsGroup: 10000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: fix-permissions
          image: busybox:1.37.0
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - chown -R 10000:10000 /var/syncthing/config /var/syncthing/Sync
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            capabilities:
              add:
                - CHOWN
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: config
              mountPath: /var/syncthing/config
            - name: vault
              mountPath: /var/syncthing/Sync
      containers:
        - name: syncthing
          image: syncthing/syncthing:latest
          imagePullPolicy: IfNotPresent
          ports:
            - name: gui
              containerPort: 8384
              protocol: TCP
            - name: sync
              containerPort: 22000
              protocol: TCP
            - name: discovery
              containerPort: 21027
              protocol: UDP
          env:
            - name: STHOMEDIR
              value: /var/syncthing/config
            - name: STGUIADDRESS
              value: 0.0.0.0:8384
          readinessProbe:
            httpGet:
              path: /rest/noauth/health
              port: gui
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /rest/noauth/health
              port: gui
            initialDelaySeconds: 30
            periodSeconds: 30
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /var/syncthing/config
            - name: vault
              mountPath: /var/syncthing/Sync
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: syncthing-config
        - name: vault
          persistentVolumeClaim:
            claimName: obsidian-vault
```

- [ ] **Step 2: Validate the manifest**

```bash
cat kubernetes/apps/syncthing/deployment.yaml | kubectl apply --dry-run=client -f - 2>&1 | head -10
```

Expected: `deployment.apps/syncthing created (dry run)`

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/syncthing/deployment.yaml
git commit -m "feat(syncthing): add deployment with NFS vault and config volumes"
```

---

### Task 3: Create Services (ClusterIP + LoadBalancer)

**Files:**
- Create: `kubernetes/apps/syncthing/service.yaml`
- Create: `kubernetes/apps/syncthing/service-sync.yaml`

- [ ] **Step 1: Create the ClusterIP service for GUI**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: syncthing
  namespace: apps
  labels:
    app.kubernetes.io/name: syncthing
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: syncthing
  ports:
    - name: gui
      port: 8384
      targetPort: gui
      protocol: TCP
```

- [ ] **Step 2: Create the LoadBalancer service for sync protocol**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: syncthing-sync
  namespace: apps
  labels:
    app.kubernetes.io/name: syncthing
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: syncthing
  ports:
    - name: sync
      port: 22000
      targetPort: sync
      protocol: TCP
    - name: discovery
      port: 21027
      targetPort: discovery
      protocol: UDP
```

- [ ] **Step 3: Validate both manifests**

```bash
cat kubernetes/apps/syncthing/service.yaml | kubectl apply --dry-run=client -f - 2>&1
cat kubernetes/apps/syncthing/service-sync.yaml | kubectl apply --dry-run=client -f - 2>&1
```

Expected: Both `service/syncthing created (dry run)` and `service/syncthing-sync created (dry run)`

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/syncthing/service.yaml kubernetes/apps/syncthing/service-sync.yaml
git commit -m "feat(syncthing): add ClusterIP and LoadBalancer services"
```

---

### Task 4: Create IngressRoute

**Files:**
- Create: `kubernetes/apps/syncthing/ingress.yaml`

- [ ] **Step 1: Create the IngressRoute with oauth2-proxy middleware**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: syncthing
  namespace: apps
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`syncthing.home.mcnees.me`)
      kind: Rule
      middlewares:
        - name: oauth2-proxy
          namespace: auth
      services:
        - name: syncthing
          port: 8384
  tls:
    secretName: legacy-home-wildcard-tls
```

- [ ] **Step 2: Commit**

```bash
git add kubernetes/apps/syncthing/ingress.yaml
git commit -m "feat(syncthing): add IngressRoute with oauth2-proxy auth"
```

---

### Task 5: Create Kustomization and Register in Apps

**Files:**
- Create: `kubernetes/apps/syncthing/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml:17` (add `./syncthing` to resources list)

- [ ] **Step 1: Create the Syncthing kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - service-sync.yaml
  - ingress.yaml
```

- [ ] **Step 2: Add Syncthing to the apps kustomization**

In `kubernetes/apps/kustomization.yaml`, add `- ./syncthing` to the resources list. Insert alphabetically between `./recyclarr` and `./uptime-kuma`:

```yaml
  - ./recyclarr
  - ./syncthing
  - ./uptime-kuma
```

- [ ] **Step 3: Validate the full kustomize render**

```bash
kubectl kustomize kubernetes/apps/syncthing/
```

Expected: All 6 resources render (PV, 2x PVC, Deployment, 2x Service, IngressRoute). No errors.

- [ ] **Step 4: Validate the parent apps kustomization still renders**

```bash
kubectl kustomize kubernetes/apps/ 2>&1 | head -5
```

Expected: Renders without errors. First few lines show namespace resource.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/syncthing/kustomization.yaml kubernetes/apps/kustomization.yaml
git commit -m "feat(syncthing): add kustomization and register in apps namespace"
```

---

### Task 6: Modify Hermes Deployment for Vault Access

**Files:**
- Modify: `kubernetes/apps/hermes/deployment.yaml:31` (init container chown command)
- Modify: `kubernetes/apps/hermes/deployment.yaml:40-43` (init container volumeMounts)
- Modify: `kubernetes/apps/hermes/deployment.yaml:123-131` (container volumeMounts)
- Modify: `kubernetes/apps/hermes/deployment.yaml:132-141` (volumes)

- [ ] **Step 1: Update init container chown command to include obsidian mount**

In `kubernetes/apps/hermes/deployment.yaml`, change line 31 from:

```yaml
            - chown -R 10000:10000 /opt/data /workspace
```

to:

```yaml
            - chown -R 10000:10000 /opt/data /workspace /workspace/obsidian
```

- [ ] **Step 2: Add obsidian-vault volumeMount to init container**

In the init container `volumeMounts` section (after line 43), add:

```yaml
            - name: obsidian-vault
              mountPath: /workspace/obsidian
```

- [ ] **Step 3: Add obsidian-vault volumeMount to hermes container**

In the hermes container `volumeMounts` section (after the workspace mount at line 131), add:

```yaml
            - name: obsidian-vault
              mountPath: /workspace/obsidian
```

- [ ] **Step 4: Add obsidian-vault volume to pod spec**

In the `volumes` section (after the workspace volume at line 141), add:

```yaml
        - name: obsidian-vault
          persistentVolumeClaim:
            claimName: obsidian-vault
```

- [ ] **Step 5: Validate the modified Hermes manifests render**

```bash
kubectl kustomize kubernetes/apps/hermes/
```

Expected: Renders without error. Deployment shows 4 volumes (config, data, workspace, obsidian-vault) and container has 4 volumeMounts.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/hermes/deployment.yaml
git commit -m "feat(hermes): mount obsidian vault NFS volume at /workspace/obsidian"
```

---

### Task 7: Add Syncthing Runbook

**Files:**
- Create: `docs/runbooks/syncthing.md`

- [ ] **Step 1: Create the runbook**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/syncthing.md
git commit -m "docs: add syncthing runbook with access, pairing, and troubleshooting"
```

---

### Task 8: Pre-Deploy Manual Step — Create TrueNAS NFS Share

This is a manual step. The NFS share must exist before Flux can reconcile the PV.

- [ ] **Step 1: Create the NFS dataset and share on TrueNAS**

Log into TrueNAS at `10.0.1.1`. Create:
- Dataset: `data/reference/obsidian` (or `data/reference` parent first if it doesn't exist)
- NFS share: export `/mnt/data/reference/obsidian` to `10.0.10.0/24` (K8s VLAN) with `maproot=root` or appropriate permissions for UID 10000

This is done via TrueNAS GUI — not automatable from this repo.

- [ ] **Step 2: Verify NFS mount from a cluster node**

```bash
# From any K8s node or a test pod:
kubectl run nfs-test --rm -it --image=busybox:1.37.0 --restart=Never -- sh -c "mount -t nfs -o nfsvers=4.2,noatime 10.0.1.1:/mnt/data/reference/obsidian /mnt && ls -la /mnt && umount /mnt"
```

Expected: Mount succeeds, directory is empty and writable.

---

### Task 9: Deploy and Verify

- [ ] **Step 1: Push branch and let Flux reconcile (or manually apply)**

```bash
git push origin HEAD
```

If testing before merge, manually apply:

```bash
kubectl apply -k kubernetes/apps/syncthing/
```

- [ ] **Step 2: Verify pods are running**

```bash
kubectl get pods -n apps -l app.kubernetes.io/name=syncthing
```

Expected: `syncthing-<hash> 1/1 Running`

- [ ] **Step 3: Verify GUI is reachable**

Open `https://syncthing.home.mcnees.me` in a browser. Should redirect through oauth2-proxy, then show Syncthing dashboard.

- [ ] **Step 4: Verify vault path from Syncthing pod**

```bash
kubectl exec -n apps deploy/syncthing -- ls -la /var/syncthing/Sync
```

Expected: Empty directory, owned by 10000:10000.

- [ ] **Step 5: Verify Hermes can write to vault**

```bash
kubectl exec -n apps deploy/hermes -- sh -c "echo 'test from hermes' > /workspace/obsidian/hermes-test.md"
kubectl exec -n apps deploy/syncthing -- cat /var/syncthing/Sync/hermes-test.md
```

Expected: Second command outputs `test from hermes`. Same file visible in both pods.

- [ ] **Step 6: Verify persistence across restart**

```bash
kubectl rollout restart deployment/syncthing -n apps
kubectl rollout status deployment/syncthing -n apps
kubectl exec -n apps deploy/syncthing -- cat /var/syncthing/Sync/hermes-test.md
```

Expected: After rollout completes, test file still present.

- [ ] **Step 7: Verify LoadBalancer VIP assigned**

```bash
kubectl get svc syncthing-sync -n apps
```

Expected: `EXTERNAL-IP` shows an IP from `10.0.10.200-239` range.

- [ ] **Step 8: Clean up test file**

```bash
kubectl exec -n apps deploy/hermes -- rm /workspace/obsidian/hermes-test.md
```

- [ ] **Step 9: Commit any final adjustments and note device ID**

Check Syncthing GUI → Actions → Show ID. Record the device ID for future client pairing.
