# Phase 2: Core Platform — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the core platform services onto the K3s cluster — persistent storage (democratic-csi, local-path), ingress (MetalLB, Traefik), TLS (cert-manager), DNS automation (ExternalDNS), a centralized PostgreSQL LXC, and the full authentication chain (Redis, LLDAP, Pocket ID, OAuth2-Proxy) — establishing the foundation that all application workloads in Phase 3 will build on.

**Architecture:** Flux CD GitOps deploys everything inside K8s. Each service follows the same pattern: HelmRepository → HelmRelease → SOPS-encrypted secrets → Kustomization wiring. Infrastructure outside K8s (PostgreSQL LXC) is managed by OpenTofu (provisioning) + Ansible (configuration). Services deploy in dependency order: storage → ingress → TLS/DNS → databases → auth.

**Tech Stack:** Flux CD v2, Helm, SOPS + age, democratic-csi, Rancher local-path-provisioner, MetalLB, Traefik v3, cert-manager, ExternalDNS, PostgreSQL 16, Redis 7, LLDAP, Pocket ID, OAuth2-Proxy, OpenTofu, Ansible

**Spec:** `docs/superpowers/specs/2026-03-11-homelab-redesign-design.md`

**Depends on:** Phase 1 (Foundation) — K3s cluster running, Flux bootstrapped, SOPS configured

---

## Chunk 1: Storage, PriorityClasses & Helm Repositories

This chunk deploys PriorityClasses for workload scheduling, the two storage backends (democratic-csi for TrueNAS NFS, local-path-provisioner for node-local), and sets up shared Helm repositories that later chunks reference.

### Task 0: Deploy PriorityClasses

**Files:**
- Create: `kubernetes/infrastructure/configs/priority-classes.yaml`
- Modify: `kubernetes/infrastructure/configs/kustomization.yaml`

**Context:** PriorityClasses define workload scheduling priority. They must exist before any workloads are deployed. Three tiers: `critical` for essential services (Traefik, AdGuard, auth, HDF), `standard` as the default for normal workloads, and `best-effort` for non-critical services that can be evicted under memory pressure (Ollama, Open WebUI).

- [ ] **Step 1: Create `kubernetes/infrastructure/configs/priority-classes.yaml`**

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical
value: 1000
globalDefault: false
description: "Business-critical services (Traefik, AdGuard, auth, HDF)"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: standard
value: 500
globalDefault: true
description: "Standard application workloads"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: best-effort
value: 100
globalDefault: false
description: "Non-critical services that can be evicted under pressure (Ollama, Open WebUI)"
```

- [ ] **Step 2: Update `kubernetes/infrastructure/configs/kustomization.yaml`**

Add `priority-classes.yaml` to the resources list:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - priority-classes.yaml
  # Will be populated:
  # - metallb-config.yaml
  # - cluster-issuers.yaml
```

- [ ] **Step 3: Commit**

```bash
git add kubernetes/infrastructure/configs/priority-classes.yaml kubernetes/infrastructure/configs/kustomization.yaml
git commit -m "feat: add PriorityClasses (critical, standard, best-effort)"
```

- [ ] **Step 4: Push and verify**

```bash
git push
```

Wait for Flux, then:

```bash
kubectl get priorityclass
# Expected:
# critical        1000   false   Business-critical services (Traefik, AdGuard, auth, HDF)
# standard        500    true    Standard application workloads
# best-effort     100    false   Non-critical services that can be evicted under pressure (Ollama, Open WebUI)
# system-cluster-critical   2000000000   ...  (built-in)
# system-node-critical      2000001000   ...  (built-in)
```

---

### Task 1: Add Helm repositories for Phase 2

**Files:**
- Create: `kubernetes/repositories/democratic-csi.yaml`
- Create: `kubernetes/repositories/metallb.yaml`
- Create: `kubernetes/repositories/traefik.yaml`
- Create: `kubernetes/repositories/jetstack.yaml`
- Create: `kubernetes/repositories/bitnami.yaml`
- Modify: `kubernetes/repositories/kustomization.yaml`

**Context:** All HelmRelease resources reference HelmRepository sources. Create them all now so later chunks can reference them without modifying the repositories directory again.

- [ ] **Step 1: Create `kubernetes/repositories/democratic-csi.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: democratic-csi
  namespace: flux-system
spec:
  interval: 24h
  url: https://democratic-csi.github.io/charts/
```

- [ ] **Step 2: Create `kubernetes/repositories/metallb.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: metallb
  namespace: flux-system
spec:
  interval: 24h
  url: https://metallb.github.io/metallb
```

- [ ] **Step 3: Create `kubernetes/repositories/traefik.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 24h
  url: https://traefik.github.io/charts
```

- [ ] **Step 4: Create `kubernetes/repositories/jetstack.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: jetstack
  namespace: flux-system
spec:
  interval: 24h
  url: https://charts.jetstack.io
```

- [ ] **Step 5: Create `kubernetes/repositories/bitnami.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
  namespace: flux-system
spec:
  interval: 24h
  url: https://charts.bitnami.com/bitnami
```

- [ ] **Step 6: Update `kubernetes/repositories/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - democratic-csi.yaml
  - metallb.yaml
  - traefik.yaml
  - jetstack.yaml
  - bitnami.yaml
```

- [ ] **Step 7: Commit**

```bash
git add kubernetes/repositories/
git commit -m "feat: add Helm repositories for Phase 2 platform services"
```

---

### Task 2: Deploy democratic-csi (TrueNAS NFS storage class)

**Files:**
- Create: `kubernetes/infrastructure/controllers/democratic-csi/`
- Create: `kubernetes/infrastructure/controllers/democratic-csi/namespace.yaml`
- Create: `kubernetes/infrastructure/controllers/democratic-csi/helmrelease.yaml`
- Create: `kubernetes/infrastructure/controllers/democratic-csi/secret.sops.yaml`
- Create: `kubernetes/infrastructure/controllers/democratic-csi/kustomization.yaml`
- Modify: `kubernetes/infrastructure/controllers/kustomization.yaml`

**Context:** democratic-csi connects K8s to TrueNAS via its API, dynamically provisioning NFS shares as PVCs. K3s was bootstrapped with `--disable=local-storage`, so no default StorageClass exists yet. democratic-csi provides the `truenas-nfs` StorageClass. The chart needs TrueNAS API credentials and NFS server details.

**Prerequisites you must verify before starting:**
- TrueNAS API key exists (generate one in TrueNAS UI → top-right gear → API Keys)
- TrueNAS dataset `data/k8s/nfs` exists (create manually or via `task ansible:truenas` if playbook is ready)
- NFS service is enabled on TrueNAS
- K3s nodes can reach TrueNAS NFS (port 2049) over the network

- [ ] **Step 1: Create namespace file `kubernetes/infrastructure/controllers/democratic-csi/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: storage
```

- [ ] **Step 2: Create SOPS-encrypted secret `kubernetes/infrastructure/controllers/democratic-csi/secret.sops.yaml`**

First create the unencrypted secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: democratic-csi-truenas
  namespace: storage
stringData:
  # TrueNAS connection details — fill in real values before encrypting
  TRUENAS_API_KEY: "CHANGE_ME"
  TRUENAS_HOST: "10.0.0.74"  # snorlax IP — update to actual TrueNAS VM IP
```

Then encrypt it:

```bash
sops --encrypt --in-place kubernetes/infrastructure/controllers/democratic-csi/secret.sops.yaml
```

- [ ] **Step 3: Create HelmRelease `kubernetes/infrastructure/controllers/democratic-csi/helmrelease.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: democratic-csi-nfs
  namespace: storage
spec:
  interval: 30m
  chart:
    spec:
      chart: democratic-csi
      version: "0.14.x"  # Pin to latest 0.14.x — check https://github.com/democratic-csi/charts/releases
      sourceRef:
        kind: HelmRepository
        name: democratic-csi
        namespace: flux-system
  values:
    csiDriver:
      name: "org.democratic-csi.nfs"

    storageClasses:
      - name: truenas-nfs
        defaultClass: true
        reclaimPolicy: Retain
        volumeBindingMode: Immediate
        allowVolumeExpansion: true
        parameters:
          fsType: nfs
        mountOptions:
          - noatime
          - nfsvers=4

    driver:
      config:
        driver: freenas-nfs
        instance_id: ""
        httpConnection:
          protocol: https
          host: "${TRUENAS_HOST}"
          port: 443
          apiKey: "${TRUENAS_API_KEY}"
          allowInsecure: true  # Self-signed TrueNAS cert
        zfs:
          datasetParentName: data/k8s/nfs
          detachedSnapshotsDatasetParentName: data/k8s/snapshots
          datasetProperties:
            "org.freenas:description": "{{ parameters.[csi.storage.k8s.io/pvc/namespace] }}/{{ parameters.[csi.storage.k8s.io/pvc/name] }}"
        nfs:
          shareHost: "${TRUENAS_HOST}"
          shareAlldirs: false
          shareAllowedHosts: []
          shareAllowedNetworks:
            - "10.0.0.0/16"  # All homelab subnets
          shareMaprootUser: root
          shareMaprootGroup: wheel

  valuesFrom:
    - kind: Secret
      name: democratic-csi-truenas
      valuesKey: TRUENAS_HOST
      targetPath: driver.config.httpConnection.host
    - kind: Secret
      name: democratic-csi-truenas
      valuesKey: TRUENAS_API_KEY
      targetPath: driver.config.httpConnection.apiKey
    - kind: Secret
      name: democratic-csi-truenas
      valuesKey: TRUENAS_HOST
      targetPath: driver.config.nfs.shareHost
```

- [ ] **Step 4: Create `kubernetes/infrastructure/controllers/democratic-csi/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secret.sops.yaml
  - helmrelease.yaml
```

- [ ] **Step 5: Update `kubernetes/infrastructure/controllers/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - democratic-csi
  # Will be populated as controllers are added:
  # - metallb
  # - traefik
  # - cert-manager
  # - external-dns
```

- [ ] **Step 6: Commit**

```bash
git add kubernetes/infrastructure/controllers/democratic-csi/ kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "feat: add democratic-csi NFS storage class via TrueNAS"
```

- [ ] **Step 7: Push and verify Flux deploys democratic-csi**

```bash
git push
```

Wait 2-5 minutes for Flux to reconcile, then verify:

```bash
flux get helmrelease -n storage
# Expected: democratic-csi-nfs  True  Release reconciliation succeeded

kubectl get storageclass
# Expected: truenas-nfs (default)   org.democratic-csi.nfs   ...

kubectl get pods -n storage
# Expected: democratic-csi controller and node pods running
```

- [ ] **Step 8: Test PVC creation and deletion**

Create a test PVC:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: truenas-nfs
EOF
```

Verify it binds:

```bash
kubectl get pvc test-nfs-pvc -n default
# Expected: STATUS = Bound
```

Verify dataset was created on TrueNAS:

```bash
# SSH to TrueNAS or check the web UI
# Expected: new dataset under data/k8s/nfs/
```

Clean up:

```bash
kubectl delete pvc test-nfs-pvc -n default
```

---

### Task 3: Deploy local-path-provisioner

**Files:**
- Create: `kubernetes/infrastructure/controllers/local-path-provisioner/`
- Create: `kubernetes/infrastructure/controllers/local-path-provisioner/helmrelease.yaml`
- Create: `kubernetes/infrastructure/controllers/local-path-provisioner/kustomization.yaml`
- Modify: `kubernetes/infrastructure/controllers/kustomization.yaml`

**Context:** K3s was bootstrapped with `--disable=local-storage`, so Rancher's built-in local-path-provisioner is not running. We deploy it explicitly as a Helm chart so Flux manages it. `local-path` is used for Redis persistence, LLDAP SQLite fallback, and anything with NFS/locking issues. Storage path is `/opt/local-path-provisioner` on each K3s node (backed by Ceph via the VM's boot disk).

- [ ] **Step 1: Add local-path-provisioner HelmRepository `kubernetes/repositories/local-path-provisioner.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: local-path-provisioner
  namespace: flux-system
spec:
  interval: 24h
  url: https://charts.containeroo.ch
```

- [ ] **Step 2: Update `kubernetes/repositories/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - democratic-csi.yaml
  - local-path-provisioner.yaml
  - metallb.yaml
  - traefik.yaml
  - jetstack.yaml
  - bitnami.yaml
  - external-dns.yaml
```

- [ ] **Step 3: Create HelmRelease `kubernetes/infrastructure/controllers/local-path-provisioner/helmrelease.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: local-path-provisioner
  namespace: storage
spec:
  interval: 30m
  chart:
    spec:
      chart: local-path-provisioner
      version: "0.0.x"  # Check https://github.com/containeroo/helm-charts for latest
      sourceRef:
        kind: HelmRepository
        name: local-path-provisioner
        namespace: flux-system
  values:
    storageClass:
      name: local-path
      defaultClass: false  # truenas-nfs is the default
      reclaimPolicy: Retain
    nodePathMap:
      - node: DEFAULT_PATH_FOR_NON_LISTED_NODES
        paths:
          - /opt/local-path-provisioner
```

- [ ] **Step 4: Create `kubernetes/infrastructure/controllers/local-path-provisioner/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
```

- [ ] **Step 5: Update `kubernetes/infrastructure/controllers/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - democratic-csi
  - local-path-provisioner
  # Will be populated as controllers are added:
  # - metallb
  # - traefik
  # - cert-manager
  # - external-dns
```

- [ ] **Step 6: Commit**

```bash
git add kubernetes/repositories/local-path-provisioner.yaml kubernetes/repositories/kustomization.yaml kubernetes/infrastructure/controllers/local-path-provisioner/ kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "feat: add local-path-provisioner for node-local storage"
```

- [ ] **Step 7: Push and verify**

```bash
git push
```

Wait for Flux, then:

```bash
flux get helmrelease -n storage
# Expected: local-path-provisioner  True  Release reconciliation succeeded

kubectl get storageclass
# Expected:
# local-path      rancher.io/local-path   ...
# truenas-nfs (default)   org.democratic-csi.nfs   ...
```

- [ ] **Step 8: Test local-path PVC**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-local-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-path
---
apiVersion: v1
kind: Pod
metadata:
  name: test-local-pod
  namespace: default
spec:
  containers:
    - name: test
      image: busybox:1.36
      command: ["sh", "-c", "echo 'local-path works' > /data/test.txt && cat /data/test.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-local-pvc
EOF
```

Verify:

```bash
kubectl wait --for=condition=Ready pod/test-local-pod -n default --timeout=60s
kubectl logs test-local-pod -n default
# Expected: "local-path works"

kubectl get pvc test-local-pvc -n default
# Expected: STATUS = Bound
```

Clean up:

```bash
kubectl delete pod test-local-pod -n default
kubectl delete pvc test-local-pvc -n default
```

---

### Chunk 1 Checklist

- [ ] PriorityClasses deployed: `critical` (1000), `standard` (500, globalDefault), `best-effort` (100)
- [ ] HelmRepositories created for all Phase 2 services (democratic-csi, local-path-provisioner, metallb, traefik, jetstack, bitnami)
- [ ] democratic-csi deployed, `truenas-nfs` StorageClass is default, test PVC binds and creates TrueNAS dataset
- [ ] local-path-provisioner deployed, `local-path` StorageClass available (not default), test PVC works
- [ ] Both storage classes visible via `kubectl get storageclass`

---

## Chunk 2: Ingress — MetalLB & Traefik

This chunk deploys MetalLB for LoadBalancer IP allocation and Traefik as the ingress controller with separate internal and external entrypoints.

### Task 4: Deploy MetalLB

**Files:**
- Create: `kubernetes/infrastructure/controllers/metallb/`
- Create: `kubernetes/infrastructure/controllers/metallb/namespace.yaml`
- Create: `kubernetes/infrastructure/controllers/metallb/helmrelease.yaml`
- Create: `kubernetes/infrastructure/controllers/metallb/kustomization.yaml`
- Create: `kubernetes/infrastructure/configs/metallb-config.yaml`
- Modify: `kubernetes/infrastructure/controllers/kustomization.yaml`
- Modify: `kubernetes/infrastructure/configs/kustomization.yaml`

**Context:** K3s was bootstrapped with `--disable=servicelb`, so there is no LoadBalancer controller. MetalLB provides stable IPs from the management VLAN (10.0.0.0/24). The spec defines a dedicated K8s VLAN (10.0.10.0/24), but VLAN segmentation is deferred to Phase 4 — K3s VMs currently sit on the management VLAN alongside Proxmox hosts. When VLANs are implemented, update the MetalLB IP pool to use the K8s VLAN range. MetalLB runs in L2 mode (ARP announcements) since the homelab doesn't have BGP routers.

- [ ] **Step 1: Create `kubernetes/infrastructure/controllers/metallb/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: infrastructure
```

- [ ] **Step 2: Create `kubernetes/infrastructure/controllers/metallb/helmrelease.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: metallb
  namespace: infrastructure
spec:
  interval: 30m
  chart:
    spec:
      chart: metallb
      version: "0.14.x"  # Check https://github.com/metallb/metallb/releases
      sourceRef:
        kind: HelmRepository
        name: metallb
        namespace: flux-system
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
  values: {}  # Default values are fine — configuration is via CRDs
```

- [ ] **Step 3: Create `kubernetes/infrastructure/controllers/metallb/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
```

- [ ] **Step 4: Create MetalLB IP pool and L2 advertisement `kubernetes/infrastructure/configs/metallb-config.yaml`**

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: infrastructure
spec:
  addresses:
    - 10.0.0.200-10.0.0.220  # Reserve a range outside DHCP scope — adjust to your network
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: infrastructure
spec:
  ipAddressPools:
    - homelab-pool
```

- [ ] **Step 5: Update `kubernetes/infrastructure/controllers/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - democratic-csi
  - local-path-provisioner
  - metallb
  # Will be populated as controllers are added:
  # - traefik
  # - cert-manager
  # - external-dns
```

- [ ] **Step 6: Update `kubernetes/infrastructure/configs/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - metallb-config.yaml
  # Will be populated:
  # - cluster-issuers.yaml
```

- [ ] **Step 7: Commit**

```bash
git add kubernetes/infrastructure/controllers/metallb/ kubernetes/infrastructure/controllers/kustomization.yaml kubernetes/infrastructure/configs/metallb-config.yaml kubernetes/infrastructure/configs/kustomization.yaml
git commit -m "feat: add MetalLB L2 load balancer with IP pool"
```

- [ ] **Step 8: Push and verify**

```bash
git push
```

Wait for Flux:

```bash
flux get helmrelease -n infrastructure
# Expected: metallb  True  Release reconciliation succeeded

kubectl get pods -n infrastructure
# Expected: metallb-controller and metallb-speaker pods running

kubectl get ipaddresspool -n infrastructure
# Expected: homelab-pool  10.0.0.200-10.0.0.220
```

---

### Task 5: Deploy Traefik

**Files:**
- Create: `kubernetes/infrastructure/controllers/traefik/`
- Create: `kubernetes/infrastructure/controllers/traefik/helmrelease.yaml`
- Create: `kubernetes/infrastructure/controllers/traefik/kustomization.yaml`
- Modify: `kubernetes/infrastructure/controllers/kustomization.yaml`

**Context:** Traefik is the K8s ingress controller. It gets a MetalLB LoadBalancer IP. The spec defines two entrypoint types: external (ports 81/444 — router forwards 80/443 → 81/444) and internal (standard ports, isolated from external). Traefik uses IngressRoute CRDs for routing. The external entrypoint uses non-standard ports because the router handles 80/443 and NAT-forwards to 81/444 on the Traefik LB IP.

- [ ] **Step 1: Create `kubernetes/infrastructure/controllers/traefik/helmrelease.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
  namespace: infrastructure
spec:
  interval: 30m
  dependsOn:
    - name: metallb
      namespace: infrastructure
  chart:
    spec:
      chart: traefik
      version: "34.x.x"  # Check https://github.com/traefik/traefik-helm-chart/releases — major version tracks Traefik v3
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: flux-system
  values:
    # Deploy as DaemonSet for HA across all nodes
    deployment:
      kind: DaemonSet

    # Entrypoints
    ports:
      # Internal HTTP (standard ports for internal-only services)
      web:
        port: 8000
        exposedPort: 80
        protocol: TCP

      # Internal HTTPS
      websecure:
        port: 8443
        exposedPort: 443
        protocol: TCP
        tls:
          enabled: true

      # External HTTP (router NAT 80 → 81)
      web-external:
        port: 8081
        exposedPort: 81
        protocol: TCP

      # External HTTPS (router NAT 443 → 444)
      websecure-external:
        port: 8444
        exposedPort: 444
        protocol: TCP
        tls:
          enabled: true

    # Single LoadBalancer service — MetalLB assigns the IP
    service:
      type: LoadBalancer
      annotations:
        metallb.universe.tf/loadBalancerIPs: "10.0.0.200"  # First IP in our MetalLB pool

    # Enable IngressRoute CRD provider
    providers:
      kubernetesCRD:
        enabled: true
        allowCrossNamespace: true
      kubernetesIngress:
        enabled: true

    # Disable the Traefik dashboard publicly — access via port-forward
    ingressRoute:
      dashboard:
        enabled: false

    # Logging
    logs:
      general:
        level: INFO
      access:
        enabled: true

    # Resource limits
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        memory: 256Mi
```

- [ ] **Step 2: Create `kubernetes/infrastructure/controllers/traefik/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
```

- [ ] **Step 3: Update `kubernetes/infrastructure/controllers/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - democratic-csi
  - local-path-provisioner
  - metallb
  - traefik
  # Will be populated as controllers are added:
  # - cert-manager
  # - external-dns
```

- [ ] **Step 4: Commit**

```bash
git add kubernetes/infrastructure/controllers/traefik/ kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "feat: add Traefik ingress controller with internal/external entrypoints"
```

- [ ] **Step 5: Push and verify**

```bash
git push
```

Wait for Flux:

```bash
flux get helmrelease -n infrastructure
# Expected: traefik  True  Release reconciliation succeeded

kubectl get pods -n infrastructure -l app.kubernetes.io/name=traefik
# Expected: traefik pods running on each node (DaemonSet)

kubectl get svc -n infrastructure traefik
# Expected: TYPE=LoadBalancer  EXTERNAL-IP=10.0.0.200  PORTS=80,443,81,444
```

- [ ] **Step 6: Verify Traefik responds**

```bash
curl -v http://10.0.0.200
# Expected: HTTP 404 (Traefik default backend — no routes configured yet)

curl -v http://10.0.0.200:81
# Expected: HTTP 404 (external entrypoint — no routes yet)
```

---

### Chunk 2 Checklist

- [ ] MetalLB deployed with L2 advertisement and IP pool (10.0.0.200-10.0.0.220)
- [ ] Traefik deployed as DaemonSet with MetalLB LoadBalancer IP 10.0.0.200
- [ ] Four entrypoints configured: web (80), websecure (443), web-external (81), websecure-external (444)
- [ ] `curl http://10.0.0.200` returns HTTP 404 (Traefik running, no routes)

---

## Chunk 3: TLS & DNS — cert-manager & ExternalDNS

This chunk deploys cert-manager for automated Let's Encrypt TLS certificates (via Cloudflare DNS-01 challenge) and ExternalDNS for automatic Cloudflare DNS record management.

### Task 6: Deploy cert-manager

**Files:**
- Create: `kubernetes/infrastructure/controllers/cert-manager/`
- Create: `kubernetes/infrastructure/controllers/cert-manager/helmrelease.yaml`
- Create: `kubernetes/infrastructure/controllers/cert-manager/secret.sops.yaml`
- Create: `kubernetes/infrastructure/controllers/cert-manager/kustomization.yaml`
- Modify: `kubernetes/infrastructure/controllers/kustomization.yaml`

**Context:** cert-manager issues TLS certificates from Let's Encrypt using the DNS-01 challenge via Cloudflare. This works for both internal (`*.home.mcnees.me`) and external (`*.mcnees.me`) services since it validates domain ownership via DNS, not HTTP. Requires a Cloudflare API token with DNS edit permissions for the `mcnees.me` zone.

**Prerequisites:**
- Cloudflare API token with permissions: Zone → DNS → Edit, Zone → Zone → Read (scoped to mcnees.me zone)

- [ ] **Step 1: Create SOPS-encrypted Cloudflare API token `kubernetes/infrastructure/controllers/cert-manager/secret.sops.yaml`**

Create the unencrypted secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: infrastructure
stringData:
  api-token: "CHANGE_ME"  # Cloudflare API token — fill in before encrypting
```

Encrypt:

```bash
sops --encrypt --in-place kubernetes/infrastructure/controllers/cert-manager/secret.sops.yaml
```

- [ ] **Step 2: Create `kubernetes/infrastructure/controllers/cert-manager/helmrelease.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager
  namespace: infrastructure
spec:
  interval: 30m
  chart:
    spec:
      chart: cert-manager
      version: "v1.17.x"  # Check https://github.com/cert-manager/cert-manager/releases
      sourceRef:
        kind: HelmRepository
        name: jetstack
        namespace: flux-system
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
  values:
    installCRDs: true

    # Tell cert-manager to look for ClusterIssuer secrets in the infrastructure namespace
    # (where we deploy cert-manager and its secrets), not the default cert-manager namespace
    global:
      leaderElection:
        namespace: infrastructure
    extraArgs:
      - "--cluster-resource-namespace=infrastructure"

    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        memory: 256Mi
```

- [ ] **Step 3: Create `kubernetes/infrastructure/controllers/cert-manager/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - secret.sops.yaml
  - helmrelease.yaml
```

- [ ] **Step 4: Update `kubernetes/infrastructure/controllers/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - democratic-csi
  - local-path-provisioner
  - metallb
  - traefik
  - cert-manager
  # Will be populated:
  # - external-dns
```

- [ ] **Step 5: Commit**

```bash
git add kubernetes/infrastructure/controllers/cert-manager/ kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "feat: add cert-manager with Cloudflare API token"
```

- [ ] **Step 6: Push and verify cert-manager is running**

```bash
git push
```

Wait for Flux:

```bash
flux get helmrelease -n infrastructure
# Expected: cert-manager  True  Release reconciliation succeeded

kubectl get pods -n infrastructure -l app.kubernetes.io/name=cert-manager
# Expected: cert-manager, cert-manager-cainjector, cert-manager-webhook pods running
```

---

### Task 7: Create ClusterIssuers

**Files:**
- Create: `kubernetes/infrastructure/configs/cluster-issuers.yaml`
- Modify: `kubernetes/infrastructure/configs/kustomization.yaml`

**Context:** ClusterIssuers define how cert-manager requests certificates. We create two: a Let's Encrypt staging issuer (for testing without hitting rate limits) and a production issuer. Both use Cloudflare DNS-01 challenge.

- [ ] **Step 1: Create `kubernetes/infrastructure/configs/cluster-issuers.yaml`**

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: michael@mcnees.me  # Update with your email for Let's Encrypt notifications
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: michael@mcnees.me  # Update with your email
    privateKeySecretRef:
      name: letsencrypt-production
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

- [ ] **Step 2: Update `kubernetes/infrastructure/configs/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - metallb-config.yaml
  - cluster-issuers.yaml
```

- [ ] **Step 3: Commit**

```bash
git add kubernetes/infrastructure/configs/cluster-issuers.yaml kubernetes/infrastructure/configs/kustomization.yaml
git commit -m "feat: add Let's Encrypt ClusterIssuers (staging + production)"
```

- [ ] **Step 4: Push and verify ClusterIssuers are ready**

```bash
git push
```

Wait for Flux:

```bash
kubectl get clusterissuer
# Expected:
# letsencrypt-staging      True    ...
# letsencrypt-production   True    ...
```

**Note:** The cert-manager HelmRelease sets `--cluster-resource-namespace=infrastructure` so ClusterIssuers find the `cloudflare-api-token` secret in the `infrastructure` namespace. If ClusterIssuers show `Ready: False`, check `kubectl describe clusterissuer letsencrypt-staging` for secret reference errors.

- [ ] **Step 5: Test certificate issuance (staging)**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: infrastructure
spec:
  secretName: test-cert-tls
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
  dnsNames:
    - test.home.mcnees.me
EOF
```

Wait and check:

```bash
kubectl get certificate test-cert -n infrastructure -w
# Expected: READY = True (may take 1-3 minutes for DNS-01 challenge)

kubectl describe certificate test-cert -n infrastructure
# Check Events for any errors
```

Clean up:

```bash
kubectl delete certificate test-cert -n infrastructure
kubectl delete secret test-cert-tls -n infrastructure
```

---

### Task 8: Deploy ExternalDNS

**Files:**
- Create: `kubernetes/infrastructure/controllers/external-dns/`
- Create: `kubernetes/infrastructure/controllers/external-dns/helmrelease.yaml`
- Create: `kubernetes/infrastructure/controllers/external-dns/secret.sops.yaml`
- Create: `kubernetes/infrastructure/controllers/external-dns/kustomization.yaml`
- Modify: `kubernetes/infrastructure/controllers/kustomization.yaml`

**Context:** ExternalDNS watches K8s Ingress/IngressRoute resources and automatically creates/updates Cloudflare DNS records. It manages A records for `*.mcnees.me` pointing to the Traefik LoadBalancer IP. Internal services (`*.home.mcnees.me`) are handled by AdGuard Home's wildcard DNS rewrite, not ExternalDNS. We use the upstream external-dns chart (not Bitnami) with the `traefik-proxy` source to natively watch Traefik IngressRoute CRDs.

**Prerequisites:**
- Same Cloudflare API token as cert-manager (or a separate one with DNS edit permissions)

- [ ] **Step 1: Add ExternalDNS HelmRepository `kubernetes/repositories/external-dns.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: external-dns
  namespace: flux-system
spec:
  interval: 24h
  url: https://kubernetes-sigs.github.io/external-dns/
```

Update `kubernetes/repositories/kustomization.yaml` to include `- external-dns.yaml`.

- [ ] **Step 2: Create SOPS-encrypted secret `kubernetes/infrastructure/controllers/external-dns/secret.sops.yaml`**

Create unencrypted:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: external-dns-cloudflare
  namespace: infrastructure
stringData:
  cloudflare-api-token: "CHANGE_ME"  # Same Cloudflare API token — fill in before encrypting
```

Encrypt:

```bash
sops --encrypt --in-place kubernetes/infrastructure/controllers/external-dns/secret.sops.yaml
```

- [ ] **Step 3: Create `kubernetes/infrastructure/controllers/external-dns/helmrelease.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: external-dns
  namespace: infrastructure
spec:
  interval: 30m
  chart:
    spec:
      chart: external-dns
      version: "1.15.x"  # Check https://github.com/kubernetes-sigs/external-dns/releases
      sourceRef:
        kind: HelmRepository
        name: external-dns
        namespace: flux-system
  values:
    provider:
      name: cloudflare

    domainFilters:
      - mcnees.me

    policy: sync
    registry: txt
    txtOwnerId: homelab-k8s
    txtPrefix: "_externaldns."

    # Watch Traefik IngressRoute CRDs — this is what makes ExternalDNS
    # pick up DNS names from IngressRoute resources (not just standard Ingress)
    sources:
      - traefik-proxy
      - ingress
      - service

    env:
      - name: CF_API_TOKEN
        valueFrom:
          secretKeyRef:
            name: external-dns-cloudflare
            key: cloudflare-api-token

    resources:
      requests:
        cpu: 25m
        memory: 64Mi
      limits:
        memory: 128Mi
```

- [ ] **Step 4: Create `kubernetes/infrastructure/controllers/external-dns/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - secret.sops.yaml
  - helmrelease.yaml
```

- [ ] **Step 5: Update `kubernetes/infrastructure/controllers/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - democratic-csi
  - local-path-provisioner
  - metallb
  - traefik
  - cert-manager
  - external-dns
```

- [ ] **Step 6: Commit**

```bash
git add kubernetes/repositories/external-dns.yaml kubernetes/repositories/kustomization.yaml kubernetes/infrastructure/controllers/external-dns/ kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "feat: add ExternalDNS for automatic Cloudflare DNS management"
```

- [ ] **Step 7: Push and verify**

```bash
git push
```

Wait for Flux:

```bash
flux get helmrelease -n infrastructure
# Expected: external-dns  True  Release reconciliation succeeded

kubectl get pods -n infrastructure -l app.kubernetes.io/name=external-dns
# Expected: external-dns pod running

kubectl logs -n infrastructure -l app.kubernetes.io/name=external-dns --tail=20
# Expected: No errors, "All records are already up to date" or similar
```

---

### Chunk 3 Checklist

- [ ] cert-manager deployed, CRDs installed, pods running
- [ ] ClusterIssuers created: `letsencrypt-staging` and `letsencrypt-production`, both Ready
- [ ] Test certificate issued via staging issuer, then cleaned up
- [ ] ExternalDNS deployed, connected to Cloudflare, no errors in logs

---

## Chunk 4: PostgreSQL LXC — OpenTofu & Ansible

This chunk provisions a PostgreSQL LXC on Proxmox via OpenTofu and configures it with Ansible (PostgreSQL installation, pg_hba.conf, databases, users). This is infrastructure outside K8s — managed by OpenTofu + Ansible, not Flux.

### Task 9: Add PostgreSQL LXC to OpenTofu

**Files:**
- Create: `terraform/proxmox/modules/lxc/main.tf`
- Create: `terraform/proxmox/modules/lxc/variables.tf`
- Create: `terraform/proxmox/modules/lxc/outputs.tf`
- Create: `terraform/proxmox/postgresql-lxc.tf`
- Modify: `terraform/proxmox/outputs.tf`

**Context:** The PostgreSQL LXC (metagross) runs on rayquaza alongside the snorlax TrueNAS VM, with Ceph HA so it can be live-migrated and auto-restarted on host failure. It gets 2 vCPU, 4GB RAM, and a Ceph-backed disk.

- [ ] **Step 1: Create LXC module `terraform/proxmox/modules/lxc/variables.tf`**

```hcl
variable "lxc_hostname" {
  description = "LXC container hostname"
  type        = string
}

variable "target_node" {
  description = "Proxmox node to create the LXC on"
  type        = string
}

variable "lxc_id" {
  description = "Proxmox VMID for the LXC"
  type        = number
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory in MB"
  type        = number
  default     = 2048
}

variable "swap" {
  description = "Swap in MB"
  type        = number
  default     = 512
}

variable "disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 20
}

variable "storage_pool" {
  description = "Storage pool for LXC disk"
  type        = string
}

variable "ip_address" {
  description = "Static IP in CIDR notation (e.g., 10.0.0.90/24)"
  type        = string
}

variable "gateway" {
  description = "Default gateway"
  type        = string
}

variable "dns_servers" {
  description = "DNS servers (space-separated)"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for root access"
  type        = string
}

variable "template" {
  description = "LXC template (e.g., local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst)"
  type        = string
}

variable "tags" {
  description = "Tags for the LXC"
  type        = list(string)
  default     = []
}

variable "start_on_boot" {
  description = "Start LXC on Proxmox boot"
  type        = bool
  default     = true
}

variable "ha_enabled" {
  description = "Enable Proxmox HA for this LXC"
  type        = bool
  default     = false
}

variable "ha_group" {
  description = "HA group name"
  type        = string
  default     = ""
}
```

- [ ] **Step 2: Create LXC module `terraform/proxmox/modules/lxc/main.tf`**

```hcl
resource "proxmox_virtual_environment_container" "lxc" {
  node_name = var.target_node
  vm_id     = var.lxc_id

  initialization {
    hostname = var.lxc_hostname

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    dns {
      servers = split(" ", var.dns_servers)
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = var.swap
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.disk_size
  }

  operating_system {
    template_file_id = var.template
    type             = "ubuntu"
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  features {
    nesting = true
  }

  started      = true
  start_on_boot = var.start_on_boot

  tags = var.tags
}

resource "proxmox_virtual_environment_haresource" "ha" {
  count = var.ha_enabled ? 1 : 0

  resource_id = "ct:${proxmox_virtual_environment_container.lxc.vm_id}"
  state       = "started"
  group       = var.ha_group != "" ? var.ha_group : null
}
```

- [ ] **Step 3: Create LXC module `terraform/proxmox/modules/lxc/outputs.tf`**

```hcl
output "id" {
  description = "Proxmox LXC VMID"
  value       = proxmox_virtual_environment_container.lxc.vm_id
}

output "hostname" {
  description = "LXC hostname"
  value       = var.lxc_hostname
}

output "ip_address" {
  description = "LXC IP address (CIDR)"
  value       = var.ip_address
}
```

- [ ] **Step 4: Create `terraform/proxmox/postgresql-lxc.tf`**

```hcl
variable "lxc_template" {
  description = "LXC template file ID (e.g., local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst)"
  type        = string
  default     = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

module "postgresql_lxc" {
  source = "./modules/lxc"

  lxc_hostname   = "metagross"
  target_node    = "rayquaza"  # pve3 — Ceph HA will migrate if needed
  lxc_id         = 200
  cores          = 2
  memory         = 4096  # 4GB — spec says 2-4GB
  swap           = 1024
  disk_size      = 20    # PostgreSQL data is small for homelab workloads
  storage_pool   = var.vm_default_storage  # Ceph
  ip_address     = "10.0.0.90/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  template       = var.lxc_template
  tags           = ["postgresql", "database", "terraform", "ha"]
  start_on_boot  = true
  ha_enabled     = true
}
```

- [ ] **Step 5: Add PostgreSQL LXC output to `terraform/proxmox/outputs.tf`**

Append to existing outputs.tf:

```hcl
output "postgresql_lxc_ip" {
  description = "PostgreSQL LXC IP address"
  value       = module.postgresql_lxc.ip_address
}
```

- [ ] **Step 6: Commit**

```bash
git add terraform/proxmox/modules/lxc/ terraform/proxmox/postgresql-lxc.tf terraform/proxmox/outputs.tf
git commit -m "feat: add PostgreSQL LXC definition with reusable LXC module"
```

- [ ] **Step 7: Plan and apply**

```bash
task infra:plan
# Review output — should show 1 new LXC resource

task infra:apply
# Confirm when prompted
```

- [ ] **Step 8: Verify LXC is running**

```bash
ssh root@10.0.0.90 hostname
# Expected: metagross
```

---

### Task 10: Add PostgreSQL LXC to Ansible inventory

**Files:**
- Modify: `ansible/inventory/hosts.yml`

- [ ] **Step 1: Add PostgreSQL LXC group to `ansible/inventory/hosts.yml`**

Add a new group after the existing `k3s_cluster` group:

```yaml
    postgresql:
      hosts:
        metagross:  # Update if you chose a different Pokémon name
          ansible_host: 10.0.0.90
          ansible_user: root
```

- [ ] **Step 2: Commit**

```bash
git add ansible/inventory/hosts.yml
git commit -m "feat: add PostgreSQL LXC to Ansible inventory"
```

---

### Task 11: Create PostgreSQL Ansible playbook

**Files:**
- Create: `ansible/playbooks/postgresql-setup.yml`

**Context:** This playbook installs PostgreSQL 16, configures `pg_hba.conf` to allow connections from the K8s VLAN (10.0.0.0/24), and creates databases + users for all apps listed in the spec. Each app gets its own database and user. Passwords are passed as Ansible variables (from `group_vars` or command-line `--extra-vars`).

- [ ] **Step 1: Create `ansible/playbooks/postgresql-setup.yml`**

```yaml
---
- name: Configure PostgreSQL LXC
  hosts: postgresql
  become: true

  vars:
    postgresql_version: "16"
    postgresql_listen_addresses: "*"
    postgresql_port: 5432
    # Network that can connect — K8s nodes, other LXCs on the management VLAN
    postgresql_allowed_network: "10.0.0.0/24"

    # Database definitions — each app gets its own DB and user
    # Passwords should be provided via group_vars or --extra-vars
    postgresql_databases:
      - name: sonarr
        owner: sonarr
      - name: sonarr_anime
        owner: sonarr_anime
      - name: radarr
        owner: radarr
      - name: lidarr
        owner: lidarr
      - name: lidarr_kids
        owner: lidarr_kids
      - name: prowlarr
        owner: prowlarr
      - name: bazarr
        owner: bazarr
      - name: paperless
        owner: paperless
      - name: gramps
        owner: gramps
      - name: pocket_id
        owner: pocket_id
      - name: pelican
        owner: pelican
      - name: invoice_ninja
        owner: invoice_ninja
      - name: chatwoot
        owner: chatwoot

  tasks:
    # --- Install PostgreSQL ---
    - name: Install prerequisites
      apt:
        name:
          - gnupg2
          - lsb-release
          - python3-psycopg2  # Required for Ansible postgresql modules
        state: present
        update_cache: true

    - name: Add PostgreSQL APT repository key
      ansible.builtin.get_url:
        url: https://www.postgresql.org/media/keys/ACCC4CF8.asc
        dest: /usr/share/keyrings/postgresql-archive-keyring.asc
        mode: '0644'

    - name: Add PostgreSQL APT repository
      ansible.builtin.apt_repository:
        repo: "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.asc] https://apt.postgresql.org/pub/repos/apt {{ ansible_distribution_release }}-pgdg main"
        state: present
        filename: pgdg

    - name: Install PostgreSQL
      apt:
        name:
          - "postgresql-{{ postgresql_version }}"
          - "postgresql-client-{{ postgresql_version }}"
        state: present
        update_cache: true

    # --- Configure PostgreSQL ---
    - name: Configure listen_addresses
      lineinfile:
        path: "/etc/postgresql/{{ postgresql_version }}/main/postgresql.conf"
        regexp: "^#?listen_addresses"
        line: "listen_addresses = '{{ postgresql_listen_addresses }}'"
      notify: Restart PostgreSQL

    - name: Configure pg_hba.conf — allow K8s and LXC network
      blockinfile:
        path: "/etc/postgresql/{{ postgresql_version }}/main/pg_hba.conf"
        marker: "# {mark} ANSIBLE MANAGED — homelab network access"
        block: |
          # Allow password auth from the homelab network
          host    all    all    {{ postgresql_allowed_network }}    scram-sha-256
      notify: Restart PostgreSQL

    - name: Ensure PostgreSQL is started and enabled
      systemd:
        name: postgresql
        state: started
        enabled: true

    # --- Create databases and users ---
    - name: Create PostgreSQL users
      become_user: postgres
      community.postgresql.postgresql_user:
        name: "{{ item.owner }}"
        password: "{{ lookup('vars', 'pg_password_' + item.owner) }}"
        state: present
      loop: "{{ postgresql_databases }}"
      no_log: true

    - name: Create PostgreSQL databases
      become_user: postgres
      community.postgresql.postgresql_db:
        name: "{{ item.name }}"
        owner: "{{ item.owner }}"
        state: present
      loop: "{{ postgresql_databases }}"

    # --- Backup cron ---
    - name: Create pg_dump backup script
      copy:
        dest: /usr/local/bin/pg-backup.sh
        mode: '0755'
        content: |
          #!/bin/bash
          # Logical backup of all databases to NFS mount
          BACKUP_DIR="/mnt/backups/postgresql"
          TIMESTAMP=$(date +%Y%m%d_%H%M%S)
          mkdir -p "$BACKUP_DIR"

          # Dump each database
          for db in $(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';"); do
            db=$(echo "$db" | xargs)  # trim whitespace
            sudo -u postgres pg_dump "$db" | gzip > "$BACKUP_DIR/${db}_${TIMESTAMP}.sql.gz"
          done

          # Prune backups older than 14 days
          find "$BACKUP_DIR" -name "*.sql.gz" -mtime +14 -delete

    - name: Add NFS mount for backups
      mount:
        path: /mnt/backups/postgresql
        src: "10.0.0.74:/mnt/data/backups/postgresql"  # TrueNAS snorlax IP — update if different
        fstype: nfs
        opts: "nfsvers=4,noatime"
        state: mounted

    - name: Schedule nightly pg_dump
      cron:
        name: "PostgreSQL nightly backup"
        minute: "30"
        hour: "2"
        job: "/usr/local/bin/pg-backup.sh"
        user: root

  handlers:
    - name: Restart PostgreSQL
      systemd:
        name: postgresql
        state: restarted
```

- [ ] **Step 2: Create password variables example file `ansible/inventory/group_vars/postgresql.yml.example`**

```yaml
---
# PostgreSQL user passwords — copy to postgresql.yml and fill in real passwords
# Generate with: openssl rand -base64 24
# postgresql.yml is gitignored
pg_password_sonarr: "CHANGE_ME"
pg_password_sonarr_anime: "CHANGE_ME"
pg_password_radarr: "CHANGE_ME"
pg_password_lidarr: "CHANGE_ME"
pg_password_lidarr_kids: "CHANGE_ME"
pg_password_prowlarr: "CHANGE_ME"
pg_password_bazarr: "CHANGE_ME"
pg_password_paperless: "CHANGE_ME"
pg_password_gramps: "CHANGE_ME"
pg_password_pocket_id: "CHANGE_ME"
pg_password_pelican: "CHANGE_ME"
pg_password_invoice_ninja: "CHANGE_ME"
pg_password_chatwoot: "CHANGE_ME"
```

- [ ] **Step 3: Add postgresql.yml to `.gitignore`**

Add this line to `.gitignore`:

```
ansible/inventory/group_vars/postgresql.yml
```

- [ ] **Step 4: Commit**

```bash
git add ansible/playbooks/postgresql-setup.yml ansible/inventory/group_vars/postgresql.yml.example .gitignore
git commit -m "feat: add PostgreSQL LXC Ansible playbook with database/user creation"
```

- [ ] **Step 5: Generate real passwords and run the playbook**

```bash
# Copy example and generate passwords
cp ansible/inventory/group_vars/postgresql.yml.example ansible/inventory/group_vars/postgresql.yml
# Edit postgresql.yml — replace each CHANGE_ME with output of: openssl rand -base64 24

# Run the playbook
task ansible:postgresql
```

- [ ] **Step 6: Verify PostgreSQL is running and accepting connections**

```bash
# From your workstation (or any K3s node)
psql -h 10.0.0.90 -U sonarr -d sonarr -c "SELECT 1;"
# Expected: prompts for password, then returns "1"

# Verify all databases exist
ssh root@10.0.0.90 "sudo -u postgres psql -c '\l'"
# Expected: lists sonarr, sonarr_anime, radarr, lidarr, lidarr_kids, prowlarr, bazarr, paperless, gramps, pocket_id, pelican, invoice_ninja, chatwoot
```

- [ ] **Step 7: Add Taskfile entries for Phase 2 IaC tasks**

Add to `Taskfile.yml` (these were defined in the spec but not yet added):

```yaml
  ansible:truenas:
    desc: Configure TrueNAS datasets, shares, users, permissions
    dir: ansible
    cmd: ansible-playbook playbooks/truenas-setup.yml

  ansible:adguard:
    desc: Configure AdGuard Home DNS rewrites, filters, settings
    dir: ansible
    cmd: ansible-playbook playbooks/adguard-setup.yml

  ansible:pbs:
    desc: Configure Proxmox Backup Server (datastores, jobs, retention)
    dir: ansible
    cmd: ansible-playbook playbooks/pbs-setup.yml

  cloudflare:init:
    desc: Initialize OpenTofu for Cloudflare
    dir: terraform/cloudflare
    cmd: tofu init

  cloudflare:plan:
    desc: Preview Cloudflare DNS/security changes
    dir: terraform/cloudflare
    cmd: tofu plan

  cloudflare:apply:
    desc: Apply Cloudflare DNS/security changes
    dir: terraform/cloudflare
    cmd: tofu apply

  tailscale:init:
    desc: Initialize OpenTofu for Tailscale
    dir: terraform/tailscale
    cmd: tofu init

  tailscale:plan:
    desc: Preview Tailscale ACL/DNS changes
    dir: terraform/tailscale
    cmd: tofu plan

  tailscale:apply:
    desc: Apply Tailscale ACL/DNS changes
    dir: terraform/tailscale
    cmd: tofu apply
```

- [ ] **Step 8: Commit Taskfile updates**

```bash
git add Taskfile.yml
git commit -m "feat: add Taskfile entries for TrueNAS, AdGuard, PBS, Cloudflare, Tailscale"
```

---

### Chunk 4 Checklist

- [ ] Reusable LXC OpenTofu module created (`terraform/proxmox/modules/lxc/`)
- [ ] PostgreSQL LXC provisioned on Proxmox with Ceph HA (VMID 200, IP 10.0.0.90)
- [ ] PostgreSQL LXC added to Ansible inventory
- [ ] PostgreSQL 16 installed and configured (listening on all interfaces, scram-sha-256 auth)
- [ ] All 13 app databases and users created (removed outline; added invoice_ninja, chatwoot)
- [ ] pg_dump nightly backup cron configured, writing to TrueNAS NFS
- [ ] Connectivity verified from K8s network to PostgreSQL
- [ ] Taskfile updated with remaining Phase 2 IaC tasks

---

## Chunk 5: Auth Chain — Redis, LLDAP, Pocket ID, OAuth2-Proxy

This chunk deploys the full authentication chain: Redis (session/cache store), LLDAP (user directory), Pocket ID (OIDC provider), and OAuth2-Proxy (Traefik auth middleware). These deploy as K8s workloads via Flux.

### Task 12: Deploy Redis

**Files:**
- Create: `kubernetes/databases/redis/`
- Create: `kubernetes/databases/redis/namespace.yaml`
- Create: `kubernetes/databases/redis/helmrelease.yaml`
- Create: `kubernetes/databases/redis/kustomization.yaml`
- Modify: `kubernetes/databases/kustomization.yaml`

**Context:** Redis is an in-cluster cache/session store used by Outline, Paperless-ngx, and auth components. It's NOT a durable database — persistence is optional (using `local-path` for AOF/RDB). Runs in the `databases` namespace. We need a Flux Kustomization for databases in `kubernetes/flux-system/`.

- [ ] **Step 1: Create Flux Kustomization for databases `kubernetes/flux-system/databases.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: databases
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/databases
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

- [ ] **Step 2: Create `kubernetes/databases/redis/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: databases
```

- [ ] **Step 3: Create `kubernetes/databases/redis/helmrelease.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: redis
  namespace: databases
spec:
  interval: 30m
  chart:
    spec:
      chart: redis
      version: "20.x.x"  # Check https://github.com/bitnami/charts/tree/main/bitnami/redis
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: flux-system
  values:
    architecture: standalone  # Single instance is fine for homelab

    auth:
      enabled: false  # Internal-only cache, no auth needed — NetworkPolicies handle isolation

    master:
      persistence:
        enabled: true
        storageClass: local-path
        size: 1Gi

      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          memory: 256Mi

    replica:
      replicaCount: 0  # Standalone — no replicas

    metrics:
      enabled: true  # Prometheus metrics for Phase 4 observability
```

- [ ] **Step 4: Create `kubernetes/databases/redis/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
```

- [ ] **Step 5: Update `kubernetes/databases/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - redis
```

- [ ] **Step 6: Register databases Kustomization with Flux**

Flux only discovers Kustomizations that are referenced from its bootstrap path. Add `databases.yaml` to `kubernetes/flux-system/kustomization.yaml`:

```yaml
# Add to the resources list in kubernetes/flux-system/kustomization.yaml
# (alongside the existing infrastructure.yaml and apps.yaml entries)
  - databases.yaml
```

- [ ] **Step 7: Commit**

```bash
git add kubernetes/flux-system/databases.yaml kubernetes/flux-system/kustomization.yaml kubernetes/databases/
git commit -m "feat: add Redis to databases namespace with local-path persistence"
```

- [ ] **Step 8: Push and verify**

```bash
git push
```

Wait for Flux:

```bash
flux get kustomization databases
# Expected: databases  True  Applied revision: main@sha1:...

flux get helmrelease -n databases
# Expected: redis  True  Release reconciliation succeeded

kubectl get pods -n databases
# Expected: redis-master-0 running
```

---

### Task 13: Deploy LLDAP (user directory)

**Files:**
- Create: `kubernetes/auth/`
- Create: `kubernetes/auth/kustomization.yaml`
- Create: `kubernetes/auth/lldap/namespace.yaml`
- Create: `kubernetes/auth/lldap/deployment.yaml`
- Create: `kubernetes/auth/lldap/service.yaml`
- Create: `kubernetes/auth/lldap/secret.sops.yaml`
- Create: `kubernetes/auth/lldap/kustomization.yaml`
- Create: `kubernetes/flux-system/auth.yaml`
- Modify: `kubernetes/flux-system/kustomization.yaml`

**Context:** LLDAP is a lightweight LDAP server that serves as the user directory. It stores users (Michael, Hannah, service accounts) that Pocket ID authenticates against. LLDAP exposes an LDAP interface (port 3890) and a web UI (port 17170). The spec mentions it might use PostgreSQL but documentation is sparse — start with SQLite on `local-path` as the safe default. Auth services live under `kubernetes/auth/` (not `kubernetes/apps/`) to match the `auth` namespace.

- [ ] **Step 1: Create Flux Kustomization for auth namespace `kubernetes/flux-system/auth.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: auth
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/auth
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
    - name: databases
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

- [ ] **Step 2: Create auth directory structure**

```bash
mkdir -p kubernetes/auth/lldap kubernetes/auth/pocket-id kubernetes/auth/oauth2-proxy
```

- [ ] **Step 3: Create `kubernetes/auth/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - lldap
  # Will be populated:
  # - pocket-id
  # - oauth2-proxy
```

- [ ] **Step 4: Create `kubernetes/auth/lldap/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: auth
```

- [ ] **Step 5: Create SOPS secret `kubernetes/auth/lldap/secret.sops.yaml`**

Create unencrypted:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: lldap-secret
  namespace: auth
stringData:
  LLDAP_JWT_SECRET: "CHANGE_ME"      # Generate: openssl rand -base64 32
  LLDAP_LDAP_USER_PASS: "CHANGE_ME"  # Admin password for LLDAP web UI
```

Encrypt:

```bash
sops --encrypt --in-place kubernetes/auth/lldap/secret.sops.yaml
```

- [ ] **Step 6: Create `kubernetes/auth/lldap/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lldap
  namespace: auth
  labels:
    app.kubernetes.io/name: lldap
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: lldap
  template:
    metadata:
      labels:
        app.kubernetes.io/name: lldap
    spec:
      containers:
        - name: lldap
          image: lldap/lldap:v0.6  # Check https://github.com/lldap/lldap/releases
          ports:
            - name: ldap
              containerPort: 3890
              protocol: TCP
            - name: web
              containerPort: 17170
              protocol: TCP
          env:
            - name: LLDAP_LDAP_BASE_DN
              value: "dc=home,dc=mcnees,dc=me"
            - name: LLDAP_LDAP_USER_DN
              value: "admin"
            - name: LLDAP_HTTP_URL
              value: "https://lldap.home.mcnees.me"
            - name: LLDAP_JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: lldap-secret
                  key: LLDAP_JWT_SECRET
            - name: LLDAP_LDAP_USER_PASS
              valueFrom:
                secretKeyRef:
                  name: lldap-secret
                  key: LLDAP_LDAP_USER_PASS
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            httpGet:
              path: /
              port: web
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: web
            initialDelaySeconds: 15
            periodSeconds: 30
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 256Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: lldap-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lldap-data
  namespace: auth
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path  # SQLite — safe default
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 7: Create `kubernetes/auth/lldap/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: lldap
  namespace: auth
spec:
  selector:
    app.kubernetes.io/name: lldap
  ports:
    - name: ldap
      port: 389
      targetPort: 3890
      protocol: TCP
    - name: web
      port: 17170
      targetPort: 17170
      protocol: TCP
```

- [ ] **Step 8: Create `kubernetes/auth/lldap/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secret.sops.yaml
  - deployment.yaml
  - service.yaml
```

- [ ] **Step 9: Register auth Kustomization with Flux**

Add `auth.yaml` to `kubernetes/flux-system/kustomization.yaml` resources list (alongside `infrastructure.yaml`, `apps.yaml`, `databases.yaml`).

- [ ] **Step 10: Commit**

```bash
git add kubernetes/flux-system/auth.yaml kubernetes/flux-system/kustomization.yaml kubernetes/auth/
git commit -m "feat: add LLDAP user directory in auth namespace"
```

- [ ] **Step 11: Push and verify**

```bash
git push
```

Wait for Flux:

```bash
flux get kustomization auth
# Expected: auth  True  Applied revision: main@sha1:...

kubectl get pods -n auth
# Expected: lldap pod running

kubectl get svc -n auth lldap
# Expected: ports 389 and 17170 available
```

---

### Task 14: Deploy Pocket ID (OIDC provider)

**Files:**
- Create: `kubernetes/auth/pocket-id/`
- Create: `kubernetes/auth/pocket-id/deployment.yaml`
- Create: `kubernetes/auth/pocket-id/service.yaml`
- Create: `kubernetes/auth/pocket-id/ingress.yaml`
- Create: `kubernetes/auth/pocket-id/secret.sops.yaml`
- Create: `kubernetes/auth/pocket-id/kustomization.yaml`
- Modify: `kubernetes/auth/kustomization.yaml`

**Context:** Pocket ID is the OIDC (OpenID Connect) provider. Users authenticate through Pocket ID, which validates credentials against LLDAP. Pocket ID uses the PostgreSQL LXC for its database. It needs to be publicly accessible (for SSO login redirects), so it gets an IngressRoute on the external entrypoint.

- [ ] **Step 1: Create SOPS secret `kubernetes/auth/pocket-id/secret.sops.yaml`**

Create unencrypted:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pocket-id-secret
  namespace: auth
stringData:
  DB_CONNECTION_STRING: "postgresql://pocket_id:CHANGE_ME@10.0.0.90:5432/pocket_id?sslmode=disable"
```

Encrypt:

```bash
sops --encrypt --in-place kubernetes/auth/pocket-id/secret.sops.yaml
```

- [ ] **Step 2: Create `kubernetes/auth/pocket-id/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pocket-id
  namespace: auth
  labels:
    app.kubernetes.io/name: pocket-id
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: pocket-id
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pocket-id
    spec:
      containers:
        - name: pocket-id
          image: stonith404/pocket-id:v1.1.0  # Pin to specific version — check https://github.com/stonith404/pocket-id/releases
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
          env:
            - name: PUBLIC_APP_URL
              value: "https://id.mcnees.me"
            - name: DB_PROVIDER
              value: "postgres"
            - name: DB_CONNECTION_STRING
              valueFrom:
                secretKeyRef:
                  name: pocket-id-secret
                  key: DB_CONNECTION_STRING
          volumeMounts:
            - name: data
              mountPath: /app/data
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 15
            periodSeconds: 30
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 256Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: pocket-id-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pocket-id-data
  namespace: auth
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: truenas-nfs
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 3: Create `kubernetes/auth/pocket-id/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pocket-id
  namespace: auth
spec:
  selector:
    app.kubernetes.io/name: pocket-id
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
```

- [ ] **Step 4: Create IngressRoute `kubernetes/auth/pocket-id/ingress.yaml`**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: pocket-id
  namespace: auth
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  entryPoints:
    - websecure           # Internal access
    - websecure-external  # Public access (for SSO redirects)
  routes:
    - match: Host(`id.mcnees.me`)
      kind: Rule
      services:
        - name: pocket-id
          port: 80
  tls:
    secretName: pocket-id-tls
    domains:
      - main: id.mcnees.me
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pocket-id-cert
  namespace: auth
spec:
  secretName: pocket-id-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - id.mcnees.me
```

- [ ] **Step 5: Create `kubernetes/auth/pocket-id/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - secret.sops.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 6: Update `kubernetes/auth/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - lldap
  - pocket-id
  # Will be populated:
  # - oauth2-proxy
```

- [ ] **Step 7: Commit**

```bash
git add kubernetes/auth/pocket-id/ kubernetes/auth/kustomization.yaml
git commit -m "feat: add Pocket ID OIDC provider with PostgreSQL backend"
```

- [ ] **Step 8: Push and verify**

```bash
git push
```

Wait for Flux:

```bash
kubectl get pods -n auth
# Expected: pocket-id pod running alongside lldap

kubectl get certificate -n auth
# Expected: pocket-id-cert  True (may take a few minutes for Let's Encrypt)
```

- [ ] **Step 9: Configure Pocket ID — initial setup**

Access Pocket ID at `https://id.mcnees.me` (or via port-forward: `kubectl port-forward -n auth svc/pocket-id 8080:80`).

1. Complete first-run setup wizard
2. Configure LDAP connection to LLDAP:
   - Host: `lldap.auth.svc.cluster.local`
   - Port: `389`
   - Base DN: `dc=home,dc=mcnees,dc=me`
   - Bind DN: `uid=admin,ou=people,dc=home,dc=mcnees,dc=me`
   - Bind Password: (LLDAP admin password from secret)
3. Create an OIDC client for OAuth2-Proxy (note the client ID and secret — needed in Task 15)

**Bootstrap note:** During the fresh lab bootstrap, LLDAP creates the built-in
`admin` user without an email address. Pocket ID's LDAP sync requires every
synced user to have an email address, so set an email on that bootstrap admin
before expecting `SyncLdap` to succeed. In the current PostgreSQL-backed LLDAP
deployment this was done by updating only the non-sensitive `users.email` and
`users.lowercase_email` fields for `user_id = 'admin'` to `admin@mcnees.me`,
then restarting LLDAP and Pocket ID. After that, Pocket ID imported the
`lldap_admin` group membership cleanly. Real users should be created in LLDAP
with email addresses from the start.

---

### Task 15: Deploy OAuth2-Proxy (Traefik auth middleware)

**Files:**
- Create: `kubernetes/auth/oauth2-proxy/`
- Create: `kubernetes/auth/oauth2-proxy/deployment.yaml`
- Create: `kubernetes/auth/oauth2-proxy/service.yaml`
- Create: `kubernetes/auth/oauth2-proxy/middleware.yaml`
- Create: `kubernetes/auth/oauth2-proxy/secret.sops.yaml`
- Create: `kubernetes/auth/oauth2-proxy/kustomization.yaml`
- Modify: `kubernetes/auth/kustomization.yaml`

**Context:** OAuth2-Proxy sits as Traefik ForwardAuth middleware. Any service needing auth adds one Traefik middleware annotation. OAuth2-Proxy redirects unauthenticated users to Pocket ID for OIDC login, then sets auth headers for the backend service. Uses Redis for session storage.

- [ ] **Step 1: Create SOPS secret `kubernetes/auth/oauth2-proxy/secret.sops.yaml`**

Create unencrypted:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: oauth2-proxy-secret
  namespace: auth
stringData:
  # Generate cookie secret: openssl rand -base64 32 | tr -- '+/' '-_'
  OAUTH2_PROXY_COOKIE_SECRET: "CHANGE_ME"
  # From Pocket ID OIDC client setup (Task 14 Step 9)
  OAUTH2_PROXY_CLIENT_ID: "CHANGE_ME"
  OAUTH2_PROXY_CLIENT_SECRET: "CHANGE_ME"
```

Encrypt:

```bash
sops --encrypt --in-place kubernetes/auth/oauth2-proxy/secret.sops.yaml
```

- [ ] **Step 2: Create `kubernetes/auth/oauth2-proxy/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth2-proxy
  namespace: auth
  labels:
    app.kubernetes.io/name: oauth2-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: oauth2-proxy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: oauth2-proxy
    spec:
      containers:
        - name: oauth2-proxy
          image: quay.io/oauth2-proxy/oauth2-proxy:v7.7.1  # Check https://github.com/oauth2-proxy/oauth2-proxy/releases
          args:
            - --http-address=0.0.0.0:4180
            - --provider=oidc
            - --oidc-issuer-url=https://id.mcnees.me
            - --cookie-domain=.mcnees.me
            - --cookie-secure=true
            - --cookie-samesite=lax
            - --email-domain=*
            - --upstream=static://202
            - --reverse-proxy=true
            - --set-xauthrequest=true
            - --set-authorization-header=true
            - --session-store-type=redis
            - --redis-connection-url=redis://redis-master.databases.svc.cluster.local:6379
            - --skip-provider-button=true
          ports:
            - name: http
              containerPort: 4180
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
          env:
            - name: OAUTH2_PROXY_COOKIE_SECRET
              valueFrom:
                secretKeyRef:
                  name: oauth2-proxy-secret
                  key: OAUTH2_PROXY_COOKIE_SECRET
            - name: OAUTH2_PROXY_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: oauth2-proxy-secret
                  key: OAUTH2_PROXY_CLIENT_ID
            - name: OAUTH2_PROXY_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: oauth2-proxy-secret
                  key: OAUTH2_PROXY_CLIENT_SECRET
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              memory: 128Mi
```

- [ ] **Step 3: Create `kubernetes/auth/oauth2-proxy/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: oauth2-proxy
  namespace: auth
spec:
  selector:
    app.kubernetes.io/name: oauth2-proxy
  ports:
    - name: http
      port: 4180
      targetPort: 4180
      protocol: TCP
```

- [ ] **Step 4: Create Traefik ForwardAuth middleware and callback IngressRoute `kubernetes/auth/oauth2-proxy/middleware.yaml`**

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: oauth2-proxy
  namespace: auth
spec:
  forwardAuth:
    address: http://oauth2-proxy.auth.svc.cluster.local:4180/oauth2/auth
    trustForwardHeader: true
    authResponseHeaders:
      - X-Auth-Request-User
      - X-Auth-Request-Email
      - X-Auth-Request-Groups
      - Authorization
---
# OAuth2-Proxy needs its own route to handle OIDC callback redirects.
# Without this, the auth redirect loop will fail.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: oauth2-proxy
  namespace: auth
spec:
  entryPoints:
    - websecure
    - websecure-external
  routes:
    - match: Host(`auth.mcnees.me`) || PathPrefix(`/oauth2`)
      kind: Rule
      services:
        - name: oauth2-proxy
          port: 4180
  tls:
    secretName: oauth2-proxy-tls
    domains:
      - main: auth.mcnees.me
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: oauth2-proxy-cert
  namespace: auth
spec:
  secretName: oauth2-proxy-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - auth.mcnees.me
```

- [ ] **Step 5: Create `kubernetes/auth/oauth2-proxy/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - secret.sops.yaml
  - deployment.yaml
  - service.yaml
  - middleware.yaml
```

- [ ] **Step 6: Update `kubernetes/auth/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - lldap
  - pocket-id
  - oauth2-proxy
```

- [ ] **Step 7: Commit**

```bash
git add kubernetes/auth/oauth2-proxy/ kubernetes/auth/kustomization.yaml
git commit -m "feat: add OAuth2-Proxy with Traefik ForwardAuth middleware"
```

- [ ] **Step 8: Push and verify the full auth chain**

```bash
git push
```

Wait for Flux:

```bash
kubectl get pods -n auth
# Expected: lldap, pocket-id, oauth2-proxy pods all running

kubectl get middleware -n auth
# Expected: oauth2-proxy middleware created
```

- [ ] **Step 9: Create LLDAP IngressRoute for admin access**

Create `kubernetes/auth/lldap/ingress.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: lldap
  namespace: auth
spec:
  entryPoints:
    - websecure  # Internal only
  routes:
    - match: Host(`lldap.home.mcnees.me`)
      kind: Rule
      services:
        - name: lldap
          port: 17170
  tls:
    secretName: lldap-tls
    domains:
      - main: lldap.home.mcnees.me
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: lldap-cert
  namespace: auth
spec:
  secretName: lldap-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - lldap.home.mcnees.me
```

**Auth boundary:** Do not attach the OAuth2-Proxy middleware to LLDAP. LLDAP is
the user directory Pocket ID depends on, so protecting it with the same auth
chain creates an avoidable recovery loop. Keep it on the internal `websecure`
entrypoint with TLS and rely on local-network access plus LLDAP's own admin
login.

Update `kubernetes/auth/lldap/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secret.sops.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 10: Commit and push**

```bash
git add kubernetes/auth/lldap/ingress.yaml kubernetes/auth/lldap/kustomization.yaml
git commit -m "feat: add local-only LLDAP IngressRoute"
git push
```

- [ ] **Step 11: End-to-end auth test**

1. Configure AdGuard Home: Add DNS rewrite `*.home.mcnees.me` → `10.0.0.200` (Traefik LB IP)
2. Open `https://lldap.home.mcnees.me` in a browser
3. Expected flow: Browser → internal Traefik `websecure` entrypoint → LLDAP web UI
4. Create users in LLDAP: Michael, Hannah

---

### Chunk 5 Checklist

- [ ] Redis deployed in `databases` namespace with `local-path` persistence
- [ ] LLDAP deployed in `auth` namespace with SQLite on `local-path`
- [ ] Pocket ID deployed in `auth` namespace with PostgreSQL backend, accessible at `https://id.mcnees.me`
- [ ] OAuth2-Proxy deployed with Traefik ForwardAuth middleware
- [ ] LLDAP web UI accessible at `https://lldap.home.mcnees.me` on internal Traefik TLS without OAuth2-Proxy middleware
- [ ] Full auth chain works against a non-directory test service: user → Traefik → OAuth2-Proxy → Pocket ID OIDC → LLDAP credentials → authenticated
- [ ] Users created in LLDAP (Michael, Hannah)

---

## Phase 2 Completion Checklist

When all chunks are complete, verify the full platform stack:

- [ ] **PriorityClasses**: `critical`, `standard` (default), `best-effort` deployed
- [ ] **Storage**: `truenas-nfs` (default) and `local-path` StorageClasses operational
- [ ] **Ingress**: MetalLB assigning IPs, Traefik routing requests on internal (80/443) and external (81/444) entrypoints
- [ ] **TLS**: cert-manager issuing Let's Encrypt certificates via Cloudflare DNS-01
- [ ] **DNS**: ExternalDNS managing Cloudflare records for public services
- [ ] **Database**: PostgreSQL LXC (metagross) running, all 13 app databases created, connectable from K8s network
- [ ] **Cache**: Redis in-cluster for session/cache workloads
- [ ] **Auth**: LLDAP → Pocket ID → OAuth2-Proxy chain fully functional
- [ ] **GitOps**: All infrastructure services managed by Flux, no manual `kubectl apply` needed
- [ ] **Taskfile**: All IaC commands documented and discoverable via `task --list`

**Next:** Phase 3 (Service Migrations) — migrate all services from existing LXCs/TrueNAS apps to K8s, one by one.
