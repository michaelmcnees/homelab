# Phase 3: Service Deployments — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy all application workloads into the K3s cluster across 9 migration waves — starting with a hard Traefik ingress cutover, then migrating services from Mew LXCs and TrueNAS apps to K8s, and finally deploying new services (observability, HDF). Services with data migrations run in parallel with the old instance until verified, then the old instance is destroyed.

**Architecture:** Each K8s service follows the Flux CD GitOps pattern: namespace directory → Kustomization → Deployment/HelmRelease → Service → IngressRoute → Certificate → ConfigMap → SOPS-encrypted Secret. Services needing PostgreSQL connect to metagross (external LXC) via `metagross.internal.svc.cluster.local` DNS. App config/cache PVCs use `local-path` by default on Ceph-backed Talos VM disks. TrueNAS NFS is reserved for bulk/shared datasets such as media, downloads, ROMs, documents, archives, backups, and workloads requiring ReadWriteMany semantics. Plex, Tdarr, and SABnzbd stay on TrueNAS with permanent ExternalService IngressRoutes.

**Tech Stack:** Flux CD v2, Kustomize, SOPS + age, Traefik v3 IngressRoutes, cert-manager, local-path-provisioner, PostgreSQL 16 (metagross LXC), Redis 7 (databases namespace), RustFS, AdGuard Home, kube-prometheus-stack, Loki, Beszel, Uptime Kuma

**Specs:**
- `docs/superpowers/specs/2026-03-11-homelab-redesign-design.md` — master design
- `docs/superpowers/specs/2026-03-13-migration-plan-design.md` — migration waves and stages
- `docs/superpowers/specs/2026-03-16-hdf-services-design.md` — Invoice Ninja, Chatwoot, RustFS

**Depends on:** Phase 2 (Core Platform) — all infrastructure services running: local-path-provisioner, MetalLB, Traefik, cert-manager, ExternalDNS, metagross (PostgreSQL), Redis, LLDAP, Pocket ID, OAuth2-Proxy

**Services intentionally removed from plan** (decided during design review):
- Outline — replaced by Obsidian, data already migrated
- Linkwarden — never deployed, removed from scope
- Actual Budget — previous experiment, removed
- Gramps — removed, may build custom alternative later
- n8n — stays on the legacy path until replaced by Mantle; no Kubernetes migration
- Booklore — upstream repo pulled, no stable fork yet
- Scrypted — too resource-intensive for current Dell hardware (revisit after node upgrade)
- Glances — replaced by Prometheus/Grafana
- InfluxDB — replaced by Prometheus
- Portainer — old K3s cluster artifact

**Services deferred to Phase 4:**
- Tailscale subnet router — networking/remote access, fits Phase 4 (Polish)
- DbGate — database admin tool, low priority
- Netboot.xyz — stays as LXC, no K8s migration needed
- Unifi exporter — Prometheus integration, deploy after observability stack is stable

---

## Conventions

### GitOps Pattern

Every K8s service follows this file structure within its namespace directory:

```
kubernetes/<namespace>/<service-name>/
  deployment.yaml       # or helmrelease.yaml
  service.yaml
  ingress.yaml          # Traefik IngressRoute + optional middleware
  certificate.yaml      # cert-manager Certificate (if TLS needed)
  configmap.yaml        # Non-secret configuration
  secret.sops.yaml      # SOPS-encrypted secrets
  pvc.yaml              # PersistentVolumeClaim (if needed)
  kustomization.yaml    # Lists all resources in this directory
```

### Namespace Kustomization Pattern

Each namespace directory has a top-level `kustomization.yaml` that lists all service subdirectories:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./service-a
  - ./service-b
```

### Flux Kustomization Pattern

Each namespace has a Flux Kustomization in `kubernetes/flux-system/`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <namespace>
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/<namespace>
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

### IngressRoute Pattern

Internal services use entrypoints `web` (80) / `websecure` (443).
External services use entrypoints `web-external` (81) / `websecure-external` (444).

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <service>
  namespace: <namespace>
spec:
  entryPoints:
    - websecure          # or websecure-external for public
  routes:
    - match: Host(`<service>.home.mcnees.me`)
      kind: Rule
      services:
        - name: <service>
          port: <port>
  tls:
    secretName: <service>-tls
```

### ExternalService Pattern

For services running outside K8s (TrueNAS apps, LXCs):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <service>-external
  namespace: <namespace>
spec:
  type: ExternalName
  externalName: <ip-or-hostname>
---
apiVersion: v1
kind: Endpoints
metadata:
  name: <service>-external
  namespace: <namespace>
subsets:
  - addresses:
      - ip: <service-ip>
    ports:
      - port: <service-port>
```

### Data Migration Pattern

For services migrating from LXCs/TrueNAS with data:

1. Deploy new K8s instance (does NOT receive traffic yet — no IngressRoute or IngressRoute points at old instance)
2. Export data from old instance (`pg_dump`, file copy, SQLite export)
3. Import data into new instance (K8s PVC or metagross database)
4. Verify new instance works with imported data
5. Switch IngressRoute to point at new K8s service
6. Monitor for 24 hours
7. Destroy old LXC/container

### Services Behind OAuth2-Proxy

Services without native auth use Traefik ForwardAuth middleware:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: oauth2-proxy
  namespace: auth
spec:
  forwardAuth:
    address: http://oauth2-proxy.auth.svc:4180/oauth2/auth
    trustForwardHeader: true
    authResponseHeaders:
      - X-Auth-Request-User
      - X-Auth-Request-Email
```

Reference this middleware in IngressRoutes:

```yaml
routes:
  - match: Host(`service.home.mcnees.me`)
    kind: Rule
    middlewares:
      - name: oauth2-proxy
        namespace: auth
    services:
      - name: <service>
        port: <port>
```

---

## Wave 1: Ingress Cutover

Create ExternalService IngressRoutes for ALL existing services, then hard-cut DNS and port forwarding from the old Traefik LXC to the new K3s Traefik.

### Task 1: Create ExternalService IngressRoutes for permanent services

**Files:**
- Create: `kubernetes/apps/external-services/plex.yaml`
- Create: `kubernetes/apps/external-services/tdarr.yaml`
- Create: `kubernetes/apps/external-services/sabnzbd.yaml`
- Create: `kubernetes/apps/external-services/homebridge.yaml`
- Create: `kubernetes/apps/external-services/homey.yaml`
- Create: `kubernetes/apps/external-services/pelican-wings.yaml`
- Create: `kubernetes/apps/external-services/truenas.yaml`
- Create: `kubernetes/apps/external-services/proxmox-latios.yaml`
- Create: `kubernetes/apps/external-services/proxmox-latias.yaml`
- Create: `kubernetes/apps/external-services/proxmox-rayquaza.yaml`
- Create: `kubernetes/apps/external-services/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Context:** These are permanent ExternalService routes — they will never be replaced by in-cluster services. Plex, Tdarr, and SABnzbd stay on TrueNAS (snorlax). Homebridge stays as an LXC on latias, Homey stays as an LXC on latios, and Pelican Wings (pelipper) stays as a VM on latias. Proxmox node UIs and TrueNAS UI get routes for convenience. Stash is NOT here — it migrates to K8s in Wave 7 and is in the temporary routes.

- [ ] **Step 1: Create the external-services directory**

```bash
mkdir -p kubernetes/apps/external-services
```

- [ ] **Step 2: Create `kubernetes/apps/external-services/plex.yaml`**

Plex on snorlax (TrueNAS). ExternalService + IngressRoute. Plex has its own auth, no OAuth2-Proxy.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: plex-external
  namespace: apps
spec:
  ports:
    - port: 32400
      targetPort: 32400
---
apiVersion: v1
kind: Endpoints
metadata:
  name: plex-external
  namespace: apps
subsets:
  - addresses:
      - ip: 10.0.0.90  # snorlax IP — update if changed
    ports:
      - port: 32400
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: plex
  namespace: apps
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`plex.home.mcnees.me`)
      kind: Rule
      services:
        - name: plex-external
          port: 32400
  tls:
    secretName: plex-tls
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: plex-tls
  namespace: apps
spec:
  secretName: plex-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - plex.home.mcnees.me
```

- [ ] **Step 3: Create remaining TrueNAS app ExternalService files**

Follow the same pattern for:
- `tdarr.yaml` — snorlax IP, port 8265, host `tdarr.home.mcnees.me`, OAuth2-Proxy middleware (no native auth)
- `sabnzbd.yaml` — snorlax IP, port 8080, host `sabnzbd.home.mcnees.me`, OAuth2-Proxy middleware (no native auth)
Each file follows the plex.yaml pattern but adds the OAuth2-Proxy ForwardAuth middleware reference.

- [ ] **Step 4: Create LXC ExternalService files**

Follow the same pattern for:
- `homebridge.yaml` — latias LXC IP, port 8581, host `homebridge.home.mcnees.me`
- `homey.yaml` — latios LXC IP, port 443, host `homey.home.mcnees.me`
- `pelican-wings.yaml` — pelipper VM IP (latias), port 443, host `wings.home.mcnees.me`

- [ ] **Step 5: Create Proxmox node and TrueNAS UI ExternalService files**

Follow the same pattern for:
- `proxmox-latios.yaml` — latios IP, port 8006 (HTTPS), host `latios.home.mcnees.me`
- `proxmox-latias.yaml` — latias IP, port 8006, host `latias.home.mcnees.me`
- `proxmox-rayquaza.yaml` — rayquaza IP, port 8006, host `rayquaza.home.mcnees.me`
- `truenas.yaml` — snorlax IP, port 443, host `truenas.home.mcnees.me`

Note: Proxmox uses self-signed HTTPS on port 8006. The IngressRoute needs `serversTransport` with `insecureSkipVerify: true` for the backend connection.

- [ ] **Step 6: Create `kubernetes/apps/external-services/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - plex.yaml
  - tdarr.yaml
  - sabnzbd.yaml
  - homebridge.yaml
  - homey.yaml
  - pelican-wings.yaml
  - truenas.yaml
  - proxmox-latios.yaml
  - proxmox-latias.yaml
  - proxmox-rayquaza.yaml
```

- [ ] **Step 7: Update `kubernetes/apps/kustomization.yaml`**

Add `./external-services` to the resources list.

- [ ] **Step 8: Commit**

```bash
git add kubernetes/apps/external-services/ kubernetes/apps/kustomization.yaml
git commit -m "feat: add permanent ExternalService IngressRoutes for TrueNAS apps, LXCs, and Proxmox nodes"
```

### Task 2: Create ExternalService IngressRoutes for temporary services

**Files:**
- Create: `kubernetes/apps/external-services/temporary/` directory with per-service YAML files
- Modify: `kubernetes/apps/external-services/kustomization.yaml`

**Context:** These routes proxy to services still running on Mew LXCs or Docker containers. They get removed as each service migrates to K8s in later waves. Every existing service with a Traefik route today needs one here.

- [ ] **Step 1: Create temporary ExternalService routes**

Create `kubernetes/apps/external-services/temporary/` directory. Create one YAML file per service following the ExternalService pattern. Each points at the service's current Mew LXC IP.

Services needing temporary routes (update IPs from Mew LXC assignments):
- `adguard.yaml` — AdGuard Home LXC, port 3000, host `adguard.home.mcnees.me`
- `sonarr.yaml` — Docker LXC, port 8989, host `sonarr.home.mcnees.me`, OAuth2-Proxy
- `sonarr-anime.yaml` — Docker LXC, port 8990, host `sonarr-anime.home.mcnees.me`, OAuth2-Proxy
- `radarr.yaml` — Docker LXC, port 7878, host `radarr.home.mcnees.me`, OAuth2-Proxy
- `prowlarr.yaml` — Docker LXC, port 9696, host `prowlarr.home.mcnees.me`, OAuth2-Proxy
- `bazarr.yaml` — Docker LXC, port 6767, host `bazarr.home.mcnees.me`, OAuth2-Proxy
- `recyclarr.yaml` — no web UI, skip
- `seer.yaml` — Overseerr LXC, port 5055, host `seer.home.mcnees.me` (has own auth)
- `wizarr.yaml` — Wizarr LXC, port 5690, host `wizarr.home.mcnees.me` (has own auth)
- `tautulli.yaml` — Tautulli LXC, port 8181, host `tautulli.home.mcnees.me`, OAuth2-Proxy
- `lldap.yaml` — LLDAP LXC (old, pre-migration), port 17170, host `lldap.home.mcnees.me`
- `pocket-id.yaml` — Pocket ID LXC (old), port 443, host `id.mcnees.me`
- `ollama.yaml` — Ollama LXC, port 11434, host `ollama.home.mcnees.me`
- `openwebui.yaml` — Open WebUI LXC, port 3000, host `chat.home.mcnees.me` (has own auth)
- `uptime-kuma.yaml` — Uptime Kuma LXC, port 3001, host `status.home.mcnees.me`, OAuth2-Proxy
- `beszel.yaml` — Beszel LXC, port 8090, host `beszel.home.mcnees.me`, OAuth2-Proxy
- `grafana.yaml` — Grafana LXC, port 3000, host `grafana.home.mcnees.me` (has own auth / will use Pocket ID)
- `pelican-panel.yaml` — Pelican Panel LXC, port 443, host `panel.home.mcnees.me` (has own auth)
- `romm.yaml` — TrueNAS app (until Wave 8 migration), snorlax IP, port 8080, host `romm.home.mcnees.me` (has own auth)
- `lazylibrarian.yaml` — LazyLibrarian LXC, port 5299, host `books.home.mcnees.me`, OAuth2-Proxy
- `stash.yaml` — TrueNAS app on snorlax, port 9999, host `stash.home.mcnees.me`, OAuth2-Proxy

Create a `kustomization.yaml` in the temporary directory listing all files.

- [ ] **Step 2: Update parent kustomization**

Add `./temporary` to `kubernetes/apps/external-services/kustomization.yaml` resources.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/external-services/temporary/
git commit -m "feat: add temporary ExternalService IngressRoutes for services pending migration"
```

### Task 3: Execute Traefik hard cutover

**Files:** None (operational task — DNS and network changes)

**Context:** With all IngressRoutes created, switch traffic from the old Traefik LXC to the new K3s Traefik. This is the point of no return — old Traefik stops receiving traffic.

- [ ] **Step 1: Verify all IngressRoutes are synced**

```bash
flux get kustomizations
kubectl get ingressroutes -A
```

Verify every service has a working IngressRoute. Test a few by curling through the new Traefik MetalLB VIP directly:

```bash
curl -k --resolve plex.home.mcnees.me:443:<METALLB_VIP> https://plex.home.mcnees.me
```

- [ ] **Step 2: Update AdGuard DNS rewrite**

In the AdGuard Home admin UI (or via Ansible if the playbook is ready):
- Change `*.home.mcnees.me` DNS rewrite from old Traefik LXC IP to new Traefik MetalLB VIP

This cuts over ALL internal traffic instantly.

- [ ] **Step 3: Update Unifi port forwarding**

In Unifi controller:
- Change port forwarding rules for ports 80/443 from old Traefik LXC IP to new Traefik MetalLB VIP (external entrypoints 81/444)

This cuts over ALL external traffic.

- [ ] **Step 4: Verify all services accessible**

Test each service from both internal and external perspectives:
- Internal: Browse to `service.home.mcnees.me` from a device on the network
- External: Browse from a phone on cellular (or use Tailscale exit node)

- [ ] **Step 5: Keep old Traefik LXC running but idle**

Do NOT destroy the old Traefik LXC yet. If something is broken, reverting the DNS rewrite and port forwarding restores service in seconds. Destroy after 48 hours of stable operation.

---

## Wave 2: DNS (AdGuard Home)

Deploy AdGuard Home to K8s with data migration from the existing LXC, then cut over DHCP DNS settings.

### Task 4: Deploy AdGuard Home to K8s

**Files:**
- Create: `kubernetes/networking/adguard/deployment.yaml`
- Create: `kubernetes/networking/adguard/service.yaml`
- Create: `kubernetes/networking/adguard/ingress.yaml`
- Create: `kubernetes/networking/adguard/certificate.yaml`
- Create: `kubernetes/networking/adguard/configmap.yaml`
- Create: `kubernetes/networking/adguard/pvc.yaml`
- Create: `kubernetes/networking/adguard/kustomization.yaml`
- Create: `kubernetes/networking/kustomization.yaml`
- Create: `kubernetes/flux-system/networking.yaml`
- Modify: `kubernetes/flux-system/kustomization.yaml`

**Context:** AdGuard Home is deployed as a K8s Deployment with a MetalLB LoadBalancer Service for DNS (UDP/TCP 53) and a separate ClusterIP + IngressRoute for the web admin UI (port 3000). DNS rewrites, blocklists, upstream servers, and client configurations are migrated from the existing LXC.

- [ ] **Step 1: Create Flux Kustomization for networking namespace**

Create `kubernetes/flux-system/networking.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: networking
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/networking
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

Add `networking.yaml` to `kubernetes/flux-system/kustomization.yaml` resources list.

- [ ] **Step 2: Create AdGuard Home PVC**

Create `kubernetes/networking/adguard/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: adguard-config
  namespace: networking
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: adguard-work
  namespace: networking
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

- [ ] **Step 3: Create AdGuard Home Deployment**

Create `kubernetes/networking/adguard/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: adguard
  namespace: networking
  labels:
    app.kubernetes.io/name: adguard
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: adguard
  template:
    metadata:
      labels:
        app.kubernetes.io/name: adguard
    spec:
      containers:
        - name: adguard
          image: adguard/adguardhome:v0.107.52
          ports:
            - name: dns-tcp
              containerPort: 53
              protocol: TCP
            - name: dns-udp
              containerPort: 53
              protocol: UDP
            - name: http
              containerPort: 3000
              protocol: TCP
          volumeMounts:
            - name: config
              mountPath: /opt/adguardhome/conf
            - name: work
              mountPath: /opt/adguardhome/work
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 512Mi
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: adguard-config
        - name: work
          persistentVolumeClaim:
            claimName: adguard-work
```

- [ ] **Step 4: Create AdGuard Home Services**

Create `kubernetes/networking/adguard/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: adguard-dns
  namespace: networking
  annotations:
    metallb.universe.tf/loadBalancerIPs: "10.0.0.201"  # Dedicated DNS VIP
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  ports:
    - name: dns-tcp
      port: 53
      targetPort: dns-tcp
      protocol: TCP
    - name: dns-udp
      port: 53
      targetPort: dns-udp
      protocol: UDP
  selector:
    app.kubernetes.io/name: adguard
---
apiVersion: v1
kind: Service
metadata:
  name: adguard-http
  namespace: networking
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 3000
      targetPort: http
  selector:
    app.kubernetes.io/name: adguard
```

- [ ] **Step 5: Create IngressRoute and Certificate**

Create `kubernetes/networking/adguard/ingress.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: adguard
  namespace: networking
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`adguard.home.mcnees.me`)
      kind: Rule
      services:
        - name: adguard-http
          port: 3000
  tls:
    secretName: adguard-tls
```

Create `kubernetes/networking/adguard/certificate.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: adguard-tls
  namespace: networking
spec:
  secretName: adguard-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - adguard.home.mcnees.me
```

- [ ] **Step 6: Create kustomization files**

Create `kubernetes/networking/adguard/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - certificate.yaml
```

Create `kubernetes/networking/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./adguard
```

- [ ] **Step 7: Commit and verify deployment**

```bash
git add kubernetes/networking/ kubernetes/flux-system/networking.yaml kubernetes/flux-system/kustomization.yaml
git commit -m "feat: deploy AdGuard Home to K8s networking namespace"
```

Wait for Flux to sync. Verify:

```bash
kubectl get pods -n networking
kubectl get svc -n networking
```

Confirm the LoadBalancer service has IP `10.0.0.201`.

### Task 5: Migrate AdGuard Home data and cut over DNS

**Files:** None (operational task — data migration and network changes)

**Context:** Export configuration from the existing AdGuard Home LXC and import into the new K8s instance. Then update Unifi DHCP to hand out the new DNS server IP.

- [ ] **Step 1: Export AdGuard Home config from old LXC**

SSH into the AdGuard Home LXC on Mew:

```bash
# Copy the config file
scp root@<adguard-lxc-ip>:/opt/AdGuardHome/AdGuardHome.yaml /tmp/adguard-config-backup.yaml
```

Key settings to preserve:
- DNS rewrites (wildcard `*.home.mcnees.me` and any specific entries)
- Upstream DNS servers
- Blocklists (filter URLs)
- Client settings and tags
- Query log and stats retention settings

- [ ] **Step 2: Import config into new K8s AdGuard Home**

Copy the config file into the K8s PVC:

```bash
# Find the pod name
POD=$(kubectl get pod -n networking -l app.kubernetes.io/name=adguard -o jsonpath='{.items[0].metadata.name}')

# Copy config (back up the existing one first)
kubectl cp /tmp/adguard-config-backup.yaml networking/$POD:/opt/adguardhome/conf/AdGuardHome.yaml

# Restart the pod to load new config
kubectl rollout restart deployment/adguard -n networking
```

- [ ] **Step 3: Update the wildcard DNS rewrite**

In the new AdGuard Home web UI at `https://adguard.home.mcnees.me` (access via the old Traefik temporarily, or port-forward):

Update the `*.home.mcnees.me` DNS rewrite to point at the Traefik MetalLB VIP (should already be done from Wave 1, verify here).

- [ ] **Step 4: Shorten DHCP lease time**

In Unifi controller, temporarily shorten the DHCP lease time to 5 minutes. This ensures all clients pick up the new DNS server quickly after the cutover.

- [ ] **Step 5: Update Unifi DHCP DNS server**

In Unifi controller:
- Change the DNS server handed out via DHCP from old AdGuard LXC IP to `10.0.0.201` (new AdGuard MetalLB VIP)

- [ ] **Step 6: Verify DNS resolution**

From a client device:
```bash
nslookup google.com 10.0.0.201
nslookup plex.home.mcnees.me 10.0.0.201
```

Verify the AdGuard query log shows incoming queries.

- [ ] **Step 7: Restore normal DHCP lease time**

After all clients have picked up the new DNS, restore the DHCP lease time to its normal value (typically 24 hours).

- [ ] **Step 8: Monitor for 24 hours, then destroy old LXC**

Keep the old AdGuard LXC running but not serving DNS. If issues arise, revert the DHCP DNS setting. After 24 hours of stable operation, destroy the old LXC.

---

## Wave 3: Servarr Stack

Migrate the servarr Docker containers from the Docker LXC to K8s, converting SQLite databases to PostgreSQL on metagross.

### Task 6: Create databases on metagross for servarr apps

**Files:** None (operational task — Ansible playbook execution)

**Context:** Each *arr app needs its own PostgreSQL database on metagross. The apps support built-in SQLite-to-PostgreSQL migration on first boot when pointed at an empty PostgreSQL database.

- [ ] **Step 1: Add servarr databases to the PostgreSQL playbook vars**

Update the Ansible inventory or playbook vars to include these databases (add to the existing list from Phase 2):

```yaml
postgresql_databases:
  # Existing from Phase 2:
  - { name: pocket_id, owner: pocket_id }
  - { name: pelican, owner: pelican }
  - { name: romm, owner: romm }
  - { name: outline, owner: outline }
  - { name: invoice_ninja, owner: invoice_ninja }
  - { name: chatwoot, owner: chatwoot }
  # New for Phase 3:
  - { name: paperless, owner: paperless }
  # Servarr:
  - { name: sonarr_main, owner: sonarr }
  - { name: sonarr_log, owner: sonarr }
  - { name: sonarr_anime_main, owner: sonarr_anime }
  - { name: sonarr_anime_log, owner: sonarr_anime }
  - { name: radarr_main, owner: radarr }
  - { name: radarr_log, owner: radarr }
  - { name: prowlarr_main, owner: prowlarr }
  - { name: prowlarr_log, owner: prowlarr }
  - { name: bazarr, owner: bazarr }
  - { name: lidarr_main, owner: lidarr }
  - { name: lidarr_log, owner: lidarr }
  - { name: lidarr_kids_main, owner: lidarr_kids }
  - { name: lidarr_kids_log, owner: lidarr_kids }
```

Note: Sonarr and Radarr use separate main and log databases. Prowlarr follows the same pattern.

- [ ] **Step 2: Run the PostgreSQL playbook**

```bash
task ansible:postgresql
```

Verify databases are created:

```bash
ssh metagross "sudo -u postgres psql -c '\l'"
```

- [ ] **Step 3: Commit inventory changes**

```bash
git add ansible/
git commit -m "feat: add servarr PostgreSQL databases to metagross playbook"
```

### Task 7: Deploy servarr apps to K8s

**Files:**
- Create: `kubernetes/media/sonarr/` (deployment, service, ingress, certificate, configmap, secret.sops, pvc, kustomization)
- Create: `kubernetes/media/sonarr-anime/` (same structure)
- Create: `kubernetes/media/radarr/` (same structure)
- Create: `kubernetes/media/prowlarr/` (same structure)
- Create: `kubernetes/media/bazarr/` (same structure)
- Create: `kubernetes/media/lidarr/` (same structure)
- Create: `kubernetes/media/lidarr-kids/` (same structure)
- Create: `kubernetes/media/recyclarr/` (deployment, configmap, kustomization — no ingress needed)
- Create: `kubernetes/media/kustomization.yaml`
- Create: `kubernetes/flux-system/media.yaml`
- Modify: `kubernetes/flux-system/kustomization.yaml`

**Context:** Each *arr app is deployed as a Deployment with:
- PostgreSQL connection env vars pointing at metagross (with `POSTGRES__MAINDB` and `POSTGRES__LOGDB` for Sonarr/Radarr/Prowlarr)
- TrueNAS NFS bulk mount for media access at `/media` (the TRaSH Guides hardlink structure)
- `local-path` PVC for config at `/config`
- OAuth2-Proxy ForwardAuth middleware (none of the *arr apps have native auth)
- IngressRoute on internal entrypoint

The *arr apps will automatically detect the empty PostgreSQL databases and migrate from SQLite on first boot. The SQLite databases from the Docker LXC need to be copied to the `/config` PVC before first boot so the migration tool can find them.

- [ ] **Step 1: Create Flux Kustomization for media namespace**

Create `kubernetes/flux-system/media.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: media
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/media
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

- [ ] **Step 2: Create Sonarr deployment**

Create `kubernetes/media/sonarr/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sonarr
  namespace: media
  labels:
    app.kubernetes.io/name: sonarr
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: sonarr
  template:
    metadata:
      labels:
        app.kubernetes.io/name: sonarr
    spec:
      containers:
        - name: sonarr
          image: ghcr.io/onedr0p/sonarr:4
          ports:
            - name: http
              containerPort: 8989
          env:
            - name: SONARR__AUTH__METHOD
              value: External
            - name: SONARR__AUTH__REQUIRED
              value: DisabledForLocalAddresses
            - name: SONARR__POSTGRES__HOST
              value: metagross.internal.svc.cluster.local
            - name: SONARR__POSTGRES__PORT
              value: "5432"
            - name: SONARR__POSTGRES__MAINDB
              value: sonarr_main
            - name: SONARR__POSTGRES__LOGDB
              value: sonarr_log
          envFrom:
            - secretRef:
                name: sonarr-secrets
          volumeMounts:
            - name: config
              mountPath: /config
            - name: media
              mountPath: /media
          readinessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 30
          livenessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 30
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 1Gi
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: sonarr-config
        - name: media
          persistentVolumeClaim:
            claimName: sonarr-media
```

Create `kubernetes/media/sonarr/secret.sops.yaml` (encrypt with SOPS):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sonarr-secrets
  namespace: media
type: Opaque
stringData:
  SONARR__POSTGRES__USER: sonarr
  SONARR__POSTGRES__PASSWORD: <generated-password>
  SONARR__AUTH__APIKEY: <generated-api-key>
```

Create `kubernetes/media/sonarr/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sonarr-config
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sonarr-media
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: truenas-bulk # Future TrueNAS NFS class/static PV for media datasets.
  resources:
    requests:
      storage: 1Ti
```

Create service, ingress (with OAuth2-Proxy middleware), certificate, and kustomization files following the conventions above.

- [ ] **Step 3: Replicate the pattern for sonarr-anime, radarr, prowlarr, bazarr**

Each follows the same structure as Sonarr with:
- **sonarr-anime**: Same image, different databases (`sonarr_anime_main`, `sonarr_anime_log`), port 8989, host `sonarr-anime.home.mcnees.me`
- **radarr**: Image `ghcr.io/onedr0p/radarr:5`, databases (`radarr_main`, `radarr_log`), port 7878, host `radarr.home.mcnees.me`
- **prowlarr**: Image `ghcr.io/onedr0p/prowlarr:1`, databases (`prowlarr_main`, `prowlarr_log`), port 9696, host `prowlarr.home.mcnees.me`. No media PVC needed (indexer only).
- **bazarr**: Image `ghcr.io/onedr0p/bazarr:1`, database `bazarr`, port 6767, host `bazarr.home.mcnees.me`. Uses `POSTGRES_HOST` etc. (different env var pattern from *arr apps).
- **lidarr**: Image `ghcr.io/onedr0p/lidarr:2`, databases (`lidarr_main`, `lidarr_log`), port 8686, host `lidarr.home.mcnees.me`. Same env var pattern as Sonarr/Radarr.
- **lidarr-kids**: Same image as lidarr, databases (`lidarr_kids_main`, `lidarr_kids_log`), port 8686, host `lidarr-kids.home.mcnees.me`. Separate deployment for kids' music library.

All get OAuth2-Proxy middleware on their IngressRoutes. All share the same `sonarr-media` PVC (or reference the same TrueNAS media dataset via separate PVCs).

- [ ] **Step 4: Deploy Recyclarr**

Create `kubernetes/media/recyclarr/deployment.yaml`:

Recyclarr runs as a CronJob (not a Deployment) — it syncs TRaSH Guide custom formats and quality profiles to Sonarr/Radarr on a schedule.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: recyclarr
  namespace: media
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: recyclarr
              image: ghcr.io/recyclarr/recyclarr:7
              args: ["sync"]
              volumeMounts:
                - name: config
                  mountPath: /config
          restartPolicy: OnFailure
          volumes:
            - name: config
              persistentVolumeClaim:
                claimName: recyclarr-config
```

Recyclarr configuration (`recyclarr.yml`) goes in a ConfigMap mounted to `/config`. It references Sonarr/Radarr API URLs (`http://sonarr.media.svc:8989`) and API keys.

- [ ] **Step 5: Create namespace kustomization**

Create `kubernetes/media/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./sonarr
  - ./sonarr-anime
  - ./radarr
  - ./prowlarr
  - ./bazarr
  - ./lidarr
  - ./lidarr-kids
  - ./recyclarr
```

- [ ] **Step 6: Commit**

```bash
git add kubernetes/media/ kubernetes/flux-system/media.yaml kubernetes/flux-system/kustomization.yaml
git commit -m "feat: deploy servarr stack to K8s media namespace with PostgreSQL on metagross"
```

### Task 8: Migrate servarr data from Docker LXC

**Files:** None (operational task)

**Context:** Copy SQLite databases and config from the Docker LXC's Docker volumes to the K8s PVCs. The *arr apps will detect SQLite files alongside PostgreSQL config and run the built-in migration tool.

- [ ] **Step 1: Stop the Docker containers on the LXC**

```bash
ssh root@<docker-lxc-ip> "cd /opt/docker && docker compose stop sonarr radarr prowlarr bazarr sonarr-anime"
```

- [ ] **Step 2: Copy SQLite databases and config to K8s PVCs**

For each service, scale down the K8s deployment and copy data into the config PVC with a temporary helper pod or an init/import job. Config PVCs use `local-path`, so do not assume a directly accessible TrueNAS dataset path.

```bash
# Scale down the K8s deployment
kubectl scale deployment sonarr -n media --replicas=0

# Copy config from Docker LXC to local
scp -r root@<docker-lxc-ip>:/opt/docker/sonarr/config/ /tmp/sonarr-config/

# Copy into the local-path PVC via a temporary pod that mounts the claim.
# Exact helper pod manifest depends on the app PVC name.
kubectl cp /tmp/sonarr-config/sonarr.db media/<helper-pod>:/config/sonarr.db
kubectl cp /tmp/sonarr-config/config.xml media/<helper-pod>:/config/config.xml
```

Repeat for sonarr-anime, radarr, prowlarr, bazarr.

- [ ] **Step 3: Scale up and trigger migration**

```bash
kubectl scale deployment sonarr -n media --replicas=1
```

Watch logs for the SQLite-to-PostgreSQL migration:

```bash
kubectl logs -n media -l app.kubernetes.io/name=sonarr -f
```

The app should detect both SQLite and PostgreSQL config, run the migration, and start normally.

- [ ] **Step 4: Verify each service**

For each *arr app:
- Browse to its web UI
- Verify library data is intact (series, movies, indexers, quality profiles, custom formats)
- Verify media root folders point to the correct NFS paths
- Trigger a manual search to verify indexer connectivity

- [ ] **Step 5: Remove temporary ExternalService routes**

Delete the temporary ExternalService files for each migrated service from `kubernetes/apps/external-services/temporary/`.

```bash
rm kubernetes/apps/external-services/temporary/{sonarr,sonarr-anime,radarr,prowlarr,bazarr}.yaml
# Update the temporary kustomization.yaml to remove these entries
git add -A && git commit -m "cleanup: remove temporary ExternalService routes for migrated servarr apps"
```

- [ ] **Step 6: Monitor for 24 hours, then clean up Docker containers**

After stable operation, remove the servarr containers from the Docker LXC:

```bash
ssh root@<docker-lxc-ip> "cd /opt/docker && docker compose rm -f sonarr radarr prowlarr bazarr sonarr-anime"
```

### Task 9: Deploy Seer, Wizarr, and Tdarr-related routes

**Files:**
- Create: `kubernetes/media/seer/` (deployment, service, ingress, certificate, pvc, kustomization)
- Create: `kubernetes/media/wizarr/` (deployment, service, ingress, certificate, pvc, kustomization)
- Modify: `kubernetes/media/kustomization.yaml`

**Context:** Seer replaces Overseerr (imports data on first boot). Wizarr is a fresh deploy. Both have their own auth — no OAuth2-Proxy needed.

- [ ] **Step 1: Deploy Seer**

Create `kubernetes/media/seer/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seer
  namespace: media
  labels:
    app.kubernetes.io/name: seer
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: seer
  template:
    metadata:
      labels:
        app.kubernetes.io/name: seer
    spec:
      containers:
        - name: seer
          image: ghcr.io/fallenbagel/jellyseerr:2
          ports:
            - name: http
              containerPort: 5055
          volumeMounts:
            - name: config
              mountPath: /app/config
          readinessProbe:
            httpGet:
              path: /api/v1/status
              port: http
            initialDelaySeconds: 20
          livenessProbe:
            httpGet:
              path: /api/v1/status
              port: http
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 512Mi
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: seer-config
```

IngressRoute on internal entrypoint, host `seer.home.mcnees.me`. No OAuth2-Proxy middleware.

- [ ] **Step 2: Migrate Overseerr data to Seer**

Before starting Seer, copy the Overseerr config/database from the old LXC:

```bash
# Scale down Seer
kubectl scale deployment seer -n media --replicas=0

# Copy Overseerr database
scp root@<overseerr-lxc-ip>:/opt/overseerr/config/db/db.sqlite3 /tmp/overseerr-db.sqlite3

SEER_POD=$(kubectl get pod -n media -l app.kubernetes.io/name=seer -o jsonpath='{.items[0].metadata.name}')
kubectl cp /tmp/overseerr-db.sqlite3 media/$SEER_POD:/app/config/db/db.sqlite3

# Scale back up — Seer will import Overseerr data
kubectl scale deployment seer -n media --replicas=1
```

- [ ] **Step 3: Deploy Wizarr (fresh)**

Create `kubernetes/media/wizarr/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wizarr
  namespace: media
  labels:
    app.kubernetes.io/name: wizarr
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: wizarr
  template:
    metadata:
      labels:
        app.kubernetes.io/name: wizarr
    spec:
      containers:
        - name: wizarr
          image: ghcr.io/wizarrrr/wizarr:4
          ports:
            - name: http
              containerPort: 5690
          volumeMounts:
            - name: data
              mountPath: /data/database
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
          resources:
            requests:
              memory: 128Mi
              cpu: 50m
            limits:
              memory: 256Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: wizarr-data
```

IngressRoute on external entrypoint (`websecure-external`), host `wizarr.mcnees.me` — Wizarr is publicly accessible for Plex invite links.

- [ ] **Step 4: Update media kustomization and commit**

```yaml
# Add to kubernetes/media/kustomization.yaml resources:
  - ./seer
  - ./wizarr
```

```bash
git add kubernetes/media/
git commit -m "feat: deploy Seer (Overseerr replacement) and Wizarr to media namespace"
```

- [ ] **Step 5: Remove temporary ExternalService routes and destroy old LXCs**

Remove `seer.yaml`, `wizarr.yaml` from temporary directory. After 24 hours, destroy old Overseerr and Wizarr LXCs on Mew.

---

## Wave 4: Auth Cutover

Migrate LLDAP data and Pocket ID database from old LXCs to the new K8s instances (deployed in Phase 2).

### Task 10: Migrate LLDAP data

**Files:** None (operational task)

**Context:** LLDAP in the old LXC uses SQLite. The new K8s LLDAP instance (deployed in Phase 2) needs to receive the user/group data. LLDAP supports data export/import via its GraphQL API.

- [ ] **Step 1: Export users and groups from old LLDAP**

Use the LLDAP GraphQL API or ldapsearch to export all users and groups:

```bash
# Export via ldapsearch (LDIF format)
ldapsearch -H ldap://<old-lldap-ip>:3890 -D "cn=admin,dc=mcnees,dc=me" -w '<admin-password>' -b "dc=mcnees,dc=me" > /tmp/lldap-export.ldif
```

Alternatively, use the LLDAP web UI to note all users, groups, and group memberships.

- [ ] **Step 2: Import into new K8s LLDAP**

The new LLDAP instance (Phase 2, `auth` namespace) should be running but empty. Import users via:

```bash
# Import via ldapadd
ldapadd -H ldap://<new-lldap-service-ip>:3890 -D "cn=admin,dc=mcnees,dc=me" -w '<new-admin-password>' -f /tmp/lldap-export.ldif
```

Or recreate users/groups manually via the LLDAP web UI if the count is small.

- [ ] **Step 3: Verify users and groups**

Log into the new LLDAP web UI. Verify all users, groups, and group memberships match the old instance.

- [ ] **Step 4: Test Pocket ID authentication**

Pocket ID (Phase 2) should already be configured to use the new LLDAP. Test a login flow through Pocket ID to verify LLDAP integration works with the migrated user data.

- [ ] **Step 5: Remove temporary LLDAP ExternalService route**

Delete `lldap.yaml` from the temporary directory. The new LLDAP in `auth` namespace has its own IngressRoute from Phase 2.

### Task 11: Migrate Pocket ID database

**Files:** None (operational task)

**Context:** The old Pocket ID LXC uses a PostgreSQL database (`pocket_id`) in the old PostgreSQL LXC on Mew. The Phase 2 K8s Pocket ID was deployed pointing at metagross with an EMPTY database (initial setup only). This migration replaces that empty database with the production data from the old LXC, preserving all OIDC client registrations.

- [ ] **Step 1: Dump database from old PostgreSQL LXC**

```bash
ssh root@<old-postgres-lxc-ip> "sudo -u postgres pg_dump --format=custom pocket_id" > /tmp/pocket_id.dump
```

- [ ] **Step 2: Restore to metagross**

```bash
scp /tmp/pocket_id.dump root@<metagross-ip>:/tmp/
ssh root@<metagross-ip> "sudo -u postgres pg_restore --dbname=pocket_id --clean --if-exists /tmp/pocket_id.dump"
```

- [ ] **Step 3: Verify Pocket ID works with migrated data**

The K8s Pocket ID deployment (Phase 2) already points at metagross. After the database restore, restart the Pocket ID pod:

```bash
kubectl rollout restart deployment/pocket-id -n auth
```

Test login flows. Verify all OIDC client registrations are intact (Proxmox, etc.).

- [ ] **Step 4: Update all OIDC clients**

Services configured to use the old Pocket ID LXC URL need to be updated to point at the new K8s Pocket ID URL (`id.mcnees.me` or `pocket-id.home.mcnees.me`). This includes:
- Proxmox SSO configuration (on each node)
- Any other services already using Pocket ID

- [ ] **Step 5: Remove temporary Pocket ID ExternalService route**

Delete `pocket-id.yaml` from the temporary directory. Destroy old Pocket ID LXC on Mew after 24 hours.

---

## Wave 5: Observability

Deploy the monitoring stack — all fresh installs, no data migration.

### Task 12: Deploy kube-prometheus-stack

**Files:**
- Create: `kubernetes/observability/kube-prometheus-stack/helmrelease.yaml`
- Create: `kubernetes/observability/kube-prometheus-stack/secret.sops.yaml`
- Create: `kubernetes/observability/kube-prometheus-stack/kustomization.yaml`
- Create: `kubernetes/observability/kustomization.yaml`
- Create: `kubernetes/flux-system/observability.yaml`
- Modify: `kubernetes/flux-system/kustomization.yaml`
- Create: `kubernetes/repositories/prometheus-community.yaml`
- Modify: `kubernetes/repositories/kustomization.yaml`

**Context:** kube-prometheus-stack bundles Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics. Grafana gets an IngressRoute with Pocket ID OIDC integration for auth.

- [ ] **Step 1: Create Flux Kustomization for observability namespace**

Create `kubernetes/flux-system/observability.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: observability
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/observability
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

Add `observability.yaml` to `kubernetes/flux-system/kustomization.yaml` resources list.

Create `kubernetes/observability/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./kube-prometheus-stack
```

- [ ] **Step 2: Add Helm repository**

Create `kubernetes/repositories/prometheus-community.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: flux-system
spec:
  interval: 24h
  url: https://prometheus-community.github.io/helm-charts
```

Add to `kubernetes/repositories/kustomization.yaml`.

- [ ] **Step 3: Create HelmRelease**

Create `kubernetes/observability/kube-prometheus-stack/helmrelease.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: kube-prometheus-stack
      version: "65.x"  # Pin to latest stable
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
        namespace: flux-system
  values:
    grafana:
      enabled: true
      ingress:
        enabled: false  # We use Traefik IngressRoute instead
      env:
        GF_SERVER_ROOT_URL: https://grafana.home.mcnees.me
        GF_AUTH_GENERIC_OAUTH_ENABLED: "true"
        GF_AUTH_GENERIC_OAUTH_NAME: "Pocket ID"
        GF_AUTH_GENERIC_OAUTH_CLIENT_ID: grafana
        GF_AUTH_GENERIC_OAUTH_SCOPES: openid profile email
        GF_AUTH_GENERIC_OAUTH_AUTH_URL: https://id.mcnees.me/authorize
        GF_AUTH_GENERIC_OAUTH_TOKEN_URL: https://id.mcnees.me/api/oidc/token
        GF_AUTH_GENERIC_OAUTH_API_URL: https://id.mcnees.me/api/oidc/userinfo
      envFromSecret: grafana-secrets
      persistence:
        enabled: true
        storageClassName: local-path
        size: 5Gi
    prometheus:
      prometheusSpec:
        retention: 30d
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: local-path
              resources:
                requests:
                  storage: 50Gi
    alertmanager:
      alertmanagerSpec:
        storage:
          volumeClaimTemplate:
            spec:
              storageClassName: local-path
              resources:
                requests:
                  storage: 1Gi
```

Create SOPS secret for Grafana OAuth client secret and admin password.

- [ ] **Step 4: Create Grafana IngressRoute**

Create a separate ingress manifest for Grafana (since the Helm chart's built-in ingress doesn't support Traefik IngressRoute CRDs):

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: observability
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`grafana.home.mcnees.me`)
      kind: Rule
      services:
        - name: kube-prometheus-stack-grafana
          port: 80
  tls:
    secretName: grafana-tls
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-tls
  namespace: observability
spec:
  secretName: grafana-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - grafana.home.mcnees.me
```

- [ ] **Step 5: Commit and verify**

```bash
git add kubernetes/observability/ kubernetes/flux-system/observability.yaml kubernetes/flux-system/kustomization.yaml kubernetes/repositories/prometheus-community.yaml
git commit -m "feat: deploy kube-prometheus-stack with Grafana OIDC via Pocket ID"
```

Verify pods are running, Grafana is accessible, Prometheus is scraping targets.

### Task 13: Deploy Loki + Promtail

**Files:**
- Create: `kubernetes/observability/loki/helmrelease.yaml`
- Create: `kubernetes/observability/loki/kustomization.yaml`
- Create: `kubernetes/repositories/grafana.yaml`
- Modify: `kubernetes/repositories/kustomization.yaml`
- Modify: `kubernetes/observability/kustomization.yaml`

**Context:** Loki aggregates logs from all pods. Promtail runs as a DaemonSet shipping logs to Loki. Grafana (already deployed) is configured with Loki as a data source.

- [ ] **Step 1: Add Grafana Helm repository**

Create `kubernetes/repositories/grafana.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: grafana
  namespace: flux-system
spec:
  interval: 24h
  url: https://grafana.github.io/helm-charts
```

- [ ] **Step 2: Create Loki HelmRelease**

Deploy Loki in single-binary mode (monolithic) — appropriate for homelab scale.

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: loki
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: loki
      version: "6.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
  values:
    deploymentMode: SingleBinary
    loki:
      auth_enabled: false
      storage:
        type: filesystem
      commonConfig:
        replication_factor: 1
    singleBinary:
      replicas: 1
      persistence:
        storageClass: local-path
        size: 20Gi
    gateway:
      enabled: false
    chunksCache:
      enabled: false
    resultsCache:
      enabled: false
```

- [ ] **Step 3: Deploy Promtail**

Create a separate HelmRelease for Promtail (or include in the Loki chart if bundled):

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: promtail
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: promtail
      version: "6.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
  values:
    config:
      clients:
        - url: http://loki.observability.svc:3100/loki/api/v1/push
```

- [ ] **Step 4: Add Loki data source to Grafana**

This can be done via Grafana provisioning (ConfigMap) or manually in the Grafana UI:
- URL: `http://loki.observability.svc:3100`

- [ ] **Step 5: Commit**

```bash
git add kubernetes/observability/loki/ kubernetes/repositories/grafana.yaml
git commit -m "feat: deploy Loki and Promtail for centralized log aggregation"
```

### Task 14: Deploy Beszel

**Files:**
- Create: `kubernetes/observability/beszel/deployment.yaml`
- Create: `kubernetes/observability/beszel/service.yaml`
- Create: `kubernetes/observability/beszel/ingress.yaml`
- Create: `kubernetes/observability/beszel/certificate.yaml`
- Create: `kubernetes/observability/beszel/pvc.yaml`
- Create: `kubernetes/observability/beszel/kustomization.yaml`
- Modify: `kubernetes/observability/kustomization.yaml`

**Context:** Beszel is a lightweight host monitoring tool. The server runs in K8s, agents run on each Proxmox host and inside snorlax (TrueNAS VM). Agents are installed manually on hosts (not managed by Flux).

- [ ] **Step 1: Create Beszel deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: beszel
  namespace: observability
  labels:
    app.kubernetes.io/name: beszel
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: beszel
  template:
    metadata:
      labels:
        app.kubernetes.io/name: beszel
    spec:
      containers:
        - name: beszel
          image: henrygd/beszel:0.8
          ports:
            - name: http
              containerPort: 8090
          volumeMounts:
            - name: data
              mountPath: /beszel_data
          readinessProbe:
            httpGet:
              path: /api/health
              port: http
          livenessProbe:
            httpGet:
              path: /api/health
              port: http
          resources:
            requests:
              memory: 128Mi
              cpu: 50m
            limits:
              memory: 256Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: beszel-data
```

IngressRoute on internal entrypoint, host `beszel.home.mcnees.me`, OAuth2-Proxy middleware.

- [ ] **Step 2: Create PVC, Service, IngressRoute, Certificate, kustomization**

Follow the standard conventions. PVC uses `local-path` (SQLite database — NFS causes locking issues), 1Gi.

- [ ] **Step 3: Commit and deploy**

```bash
git add kubernetes/observability/beszel/
git commit -m "feat: deploy Beszel server for host monitoring"
```

- [ ] **Step 4: Install Beszel agents on Proxmox hosts**

SSH into each Proxmox host and snorlax (TrueNAS VM), install the Beszel agent pointing at the K8s Beszel server URL. This is a manual step per host.

### Task 15: Deploy Uptime Kuma

**Files:**
- Create: `kubernetes/observability/uptime-kuma/deployment.yaml`
- Create: `kubernetes/observability/uptime-kuma/service.yaml`
- Create: `kubernetes/observability/uptime-kuma/ingress.yaml`
- Create: `kubernetes/observability/uptime-kuma/certificate.yaml`
- Create: `kubernetes/observability/uptime-kuma/pvc.yaml`
- Create: `kubernetes/observability/uptime-kuma/kustomization.yaml`
- Modify: `kubernetes/observability/kustomization.yaml`

**Context:** Fresh deploy. Uptime Kuma provides HTTP health checks for public-facing services and user-perspective availability.

- [ ] **Step 1: Create Uptime Kuma deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uptime-kuma
  namespace: observability
  labels:
    app.kubernetes.io/name: uptime-kuma
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: uptime-kuma
  template:
    metadata:
      labels:
        app.kubernetes.io/name: uptime-kuma
    spec:
      containers:
        - name: uptime-kuma
          image: louislam/uptime-kuma:1
          ports:
            - name: http
              containerPort: 3001
          volumeMounts:
            - name: data
              mountPath: /app/data
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
          resources:
            requests:
              memory: 128Mi
              cpu: 50m
            limits:
              memory: 512Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: uptime-kuma-data
```

PVC uses `local-path` (SQLite database — NFS causes locking issues), 2Gi.

IngressRoute on internal entrypoint, host `status.home.mcnees.me`, OAuth2-Proxy middleware.

- [ ] **Step 2: Create supporting files, commit, and deploy**

```bash
git add kubernetes/observability/uptime-kuma/
git commit -m "feat: deploy Uptime Kuma for service health monitoring"
```

- [ ] **Step 3: Remove temporary ExternalService routes for monitoring services**

Delete `grafana.yaml`, `beszel.yaml`, `uptime-kuma.yaml` from the temporary directory. Destroy old LXCs on Mew after 24 hours.

```bash
git add -A && git commit -m "cleanup: remove temporary ExternalService routes for monitoring services"
```

---

## Wave 6: AI & Dashboard

Deploy Ollama, Open WebUI, Homepage, Paperless-ngx, and Paperless-ai — all fresh installs.

### Task 16: Deploy Ollama

**Files:**
- Create: `kubernetes/apps/ollama/deployment.yaml`
- Create: `kubernetes/apps/ollama/service.yaml`
- Create: `kubernetes/apps/ollama/pvc.yaml`
- Create: `kubernetes/apps/ollama/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Context:** Ollama serves LLM models. No ingress needed — Open WebUI talks to it via cluster DNS. Models stored on NFS PVC. Schedule on lugia (latios agent, 40GB RAM) for memory headroom if possible.

- [ ] **Step 1: Create Ollama deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: apps
  labels:
    app.kubernetes.io/name: ollama
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ollama
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ollama
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - lugia  # latios agent — most memory headroom (40GB)
      containers:
        - name: ollama
          image: ollama/ollama:0.5
          ports:
            - name: http
              containerPort: 11434
          volumeMounts:
            - name: models
              mountPath: /root/.ollama
          readinessProbe:
            httpGet:
              path: /api/tags
              port: http
            initialDelaySeconds: 10
          livenessProbe:
            httpGet:
              path: /api/tags
              port: http
          resources:
            requests:
              memory: 2Gi
              cpu: 500m
            limits:
              memory: 8Gi
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ollama-models
```

PVC on TrueNAS NFS bulk/shared storage, 50Gi for model storage.

- [ ] **Step 2: Create Service (ClusterIP only)**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: apps
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 11434
      targetPort: http
  selector:
    app.kubernetes.io/name: ollama
```

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/ollama/
git commit -m "feat: deploy Ollama for local LLM inference"
```

### Task 17: Deploy Open WebUI

**Files:**
- Create: `kubernetes/apps/open-webui/deployment.yaml`
- Create: `kubernetes/apps/open-webui/service.yaml`
- Create: `kubernetes/apps/open-webui/ingress.yaml`
- Create: `kubernetes/apps/open-webui/certificate.yaml`
- Create: `kubernetes/apps/open-webui/pvc.yaml`
- Create: `kubernetes/apps/open-webui/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Context:** Open WebUI provides a chat interface for Ollama. Has its own auth — no OAuth2-Proxy needed.

- [ ] **Step 1: Create Open WebUI deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: apps
  labels:
    app.kubernetes.io/name: open-webui
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: open-webui
  template:
    metadata:
      labels:
        app.kubernetes.io/name: open-webui
    spec:
      containers:
        - name: open-webui
          image: ghcr.io/open-webui/open-webui:v0.5
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: OLLAMA_BASE_URL
              value: http://ollama.apps.svc:11434
          volumeMounts:
            - name: data
              mountPath: /app/backend/data
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 15
          livenessProbe:
            httpGet:
              path: /health
              port: http
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 1Gi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: open-webui-data
```

IngressRoute on internal entrypoint, host `chat.home.mcnees.me`.

- [ ] **Step 2: Create supporting files, commit, and deploy**

```bash
git add kubernetes/apps/open-webui/
git commit -m "feat: deploy Open WebUI with Ollama backend"
```

- [ ] **Step 3: Remove temporary ExternalService routes**

Delete `ollama.yaml` and `openwebui.yaml` from temporary directory. Destroy old LXCs on Mew.

### Task 18: Deploy Homepage

**Files:**
- Create: `kubernetes/apps/homepage/deployment.yaml`
- Create: `kubernetes/apps/homepage/service.yaml`
- Create: `kubernetes/apps/homepage/ingress.yaml`
- Create: `kubernetes/apps/homepage/certificate.yaml`
- Create: `kubernetes/apps/homepage/configmap.yaml`
- Create: `kubernetes/apps/homepage/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Context:** Homepage is a static dashboard. Configuration is entirely via ConfigMap (services.yaml, settings.yaml, widgets.yaml, bookmarks.yaml). No persistent storage needed.

- [ ] **Step 1: Create Homepage deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homepage
  namespace: apps
  labels:
    app.kubernetes.io/name: homepage
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: homepage
  template:
    metadata:
      labels:
        app.kubernetes.io/name: homepage
    spec:
      containers:
        - name: homepage
          image: ghcr.io/gethomepage/homepage:v0.9
          ports:
            - name: http
              containerPort: 3000
          volumeMounts:
            - name: config
              mountPath: /app/config
          readinessProbe:
            httpGet:
              path: /
              port: http
          livenessProbe:
            httpGet:
              path: /
              port: http
          resources:
            requests:
              memory: 128Mi
              cpu: 50m
            limits:
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: homepage-config
```

Create ConfigMap with `services.yaml`, `settings.yaml`, `widgets.yaml`, `bookmarks.yaml` listing all homelab services with their URLs and icons.

IngressRoute on internal entrypoint, host `home.mcnees.me` or `dashboard.home.mcnees.me`.

- [ ] **Step 2: Commit and deploy**

```bash
git add kubernetes/apps/homepage/
git commit -m "feat: deploy Homepage dashboard"
```

### Task 19: Deploy Paperless-ngx

**Files:**
- Create: `kubernetes/apps/paperless-ngx/deployment.yaml`
- Create: `kubernetes/apps/paperless-ngx/service.yaml`
- Create: `kubernetes/apps/paperless-ngx/ingress.yaml`
- Create: `kubernetes/apps/paperless-ngx/certificate.yaml`
- Create: `kubernetes/apps/paperless-ngx/configmap.yaml`
- Create: `kubernetes/apps/paperless-ngx/secret.sops.yaml`
- Create: `kubernetes/apps/paperless-ngx/pvc.yaml`
- Create: `kubernetes/apps/paperless-ngx/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Context:** Paperless-ngx is a document management system with OCR and full-text search. Uses PostgreSQL on metagross, Redis in the `databases` namespace (DB 0, default), and NFS for document storage. Fresh deploy — no existing data to migrate.

- [ ] **Step 1: Add paperless database to metagross**

Add to the PostgreSQL playbook vars:

```yaml
  - { name: paperless, owner: paperless }
```

Run: `task ansible:postgresql`

- [ ] **Step 2: Create Paperless-ngx deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless-ngx
  namespace: apps
  labels:
    app.kubernetes.io/name: paperless-ngx
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: paperless-ngx
  template:
    metadata:
      labels:
        app.kubernetes.io/name: paperless-ngx
    spec:
      containers:
        - name: paperless-ngx
          image: ghcr.io/paperless-ngx/paperless-ngx:2
          ports:
            - name: http
              containerPort: 8000
          env:
            - name: PAPERLESS_DBENGINE
              value: postgresql
            - name: PAPERLESS_DBHOST
              value: metagross.internal.svc.cluster.local
            - name: PAPERLESS_DBPORT
              value: "5432"
            - name: PAPERLESS_DBNAME
              value: paperless
            - name: PAPERLESS_REDIS
              value: redis://redis.databases.svc:6379/0
            - name: PAPERLESS_URL
              value: https://paperless.home.mcnees.me
            - name: PAPERLESS_OCR_LANGUAGE
              value: eng
            - name: PAPERLESS_CONSUMER_POLLING
              value: "30"
            - name: PAPERLESS_TIKA_ENABLED
              value: "false"
          envFrom:
            - secretRef:
                name: paperless-ngx-secrets
          volumeMounts:
            - name: data
              mountPath: /usr/src/paperless/data
            - name: media
              mountPath: /usr/src/paperless/media
            - name: consume
              mountPath: /usr/src/paperless/consume
            - name: export
              mountPath: /usr/src/paperless/export
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 30
          livenessProbe:
            httpGet:
              path: /
              port: http
          resources:
            requests:
              memory: 512Mi
              cpu: 200m
            limits:
              memory: 2Gi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: paperless-data
        - name: media
          persistentVolumeClaim:
            claimName: paperless-media
        - name: consume
          persistentVolumeClaim:
            claimName: paperless-consume
        - name: export
          persistentVolumeClaim:
            claimName: paperless-export
```

Secret (SOPS): `PAPERLESS_DBUSER`, `PAPERLESS_DBPASS`, `PAPERLESS_SECRET_KEY` (generate via `openssl rand -hex 32`), `PAPERLESS_ADMIN_USER`, `PAPERLESS_ADMIN_PASSWORD`

PVCs:
- `paperless-data` — `local-path`, 5Gi (index, thumbnails, classifier)
- `paperless-media` — TrueNAS NFS bulk/shared storage, 50Gi (original + archived documents)
- `paperless-consume` — TrueNAS NFS bulk/shared storage, 5Gi (inbox for new documents)
- `paperless-export` — TrueNAS NFS bulk/shared storage, 10Gi (document export backups)

IngressRoute on internal entrypoint, host `paperless.home.mcnees.me`. Paperless has its own auth.

- [ ] **Step 3: Commit and deploy**

```bash
git add kubernetes/apps/paperless-ngx/ ansible/
git commit -m "feat: deploy Paperless-ngx document management with PostgreSQL on metagross"
```

- [ ] **Step 4: Create admin account and verify**

Access `https://paperless.home.mcnees.me`. The `PAPERLESS_ADMIN_USER` and `PAPERLESS_ADMIN_PASSWORD` env vars create the initial superuser. Upload a test document and verify OCR processing.

### Task 20: Deploy Paperless-ai

**Files:**
- Create: `kubernetes/apps/paperless-ai/deployment.yaml`
- Create: `kubernetes/apps/paperless-ai/service.yaml`
- Create: `kubernetes/apps/paperless-ai/configmap.yaml`
- Create: `kubernetes/apps/paperless-ai/secret.sops.yaml`
- Create: `kubernetes/apps/paperless-ai/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Context:** Paperless-ai is a companion app that auto-tags and classifies documents using Ollama. It connects to both Paperless-ngx (API) and Ollama (inference). No ingress needed — it runs as a background worker polling Paperless-ngx for new documents.

- [ ] **Step 1: Create Paperless-ai deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless-ai
  namespace: apps
  labels:
    app.kubernetes.io/name: paperless-ai
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: paperless-ai
  template:
    metadata:
      labels:
        app.kubernetes.io/name: paperless-ai
    spec:
      containers:
        - name: paperless-ai
          image: clusterpedia/paperless-ai:v2
          envFrom:
            - configMapRef:
                name: paperless-ai-config
            - secretRef:
                name: paperless-ai-secrets
          resources:
            requests:
              memory: 128Mi
              cpu: 50m
            limits:
              memory: 256Mi
```

ConfigMap:
```yaml
PAPERLESS_API_URL: http://paperless-ngx.apps.svc:8000
OLLAMA_API_URL: http://ollama.apps.svc:11434
AI_MODEL: llama3.2
```

Secret (SOPS): `PAPERLESS_API_TOKEN` (generate from Paperless-ngx admin UI after Task 19)

No ingress, no PVC — stateless worker.

- [ ] **Step 2: Commit and deploy**

```bash
git add kubernetes/apps/paperless-ai/
git commit -m "feat: deploy Paperless-ai auto-tagger with Ollama backend"
```

- [ ] **Step 3: Verify auto-tagging**

Upload a document to Paperless-ngx. Watch Paperless-ai logs for classification activity:

```bash
kubectl logs -n apps -l app.kubernetes.io/name=paperless-ai -f
```

Verify the document gets auto-tagged/classified.

---

## Wave 7: Media Extended

Migrate Tautulli and RomM (data migrations), deploy LazyLibrarian/Readarr and Stash (fresh).

### Task 21: Deploy and migrate Tautulli

**Files:**
- Create: `kubernetes/media/tautulli/deployment.yaml`
- Create: `kubernetes/media/tautulli/service.yaml`
- Create: `kubernetes/media/tautulli/ingress.yaml`
- Create: `kubernetes/media/tautulli/certificate.yaml`
- Create: `kubernetes/media/tautulli/pvc.yaml`
- Create: `kubernetes/media/tautulli/kustomization.yaml`
- Modify: `kubernetes/media/kustomization.yaml`

**Context:** Tautulli monitors Plex viewing activity. Uses SQLite — migrate the database file from the old LXC.

- [ ] **Step 1: Create Tautulli deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tautulli
  namespace: media
  labels:
    app.kubernetes.io/name: tautulli
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: tautulli
  template:
    metadata:
      labels:
        app.kubernetes.io/name: tautulli
    spec:
      containers:
        - name: tautulli
          image: ghcr.io/onedr0p/tautulli:2
          ports:
            - name: http
              containerPort: 8181
          volumeMounts:
            - name: config
              mountPath: /config
          readinessProbe:
            httpGet:
              path: /status
              port: http
            initialDelaySeconds: 15
          livenessProbe:
            httpGet:
              path: /status
              port: http
          resources:
            requests:
              memory: 128Mi
              cpu: 50m
            limits:
              memory: 512Mi
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: tautulli-config
```

IngressRoute on internal entrypoint, host `tautulli.home.mcnees.me`, OAuth2-Proxy middleware.

- [ ] **Step 2: Migrate Tautulli data**

```bash
# Scale down first
kubectl scale deployment tautulli -n media --replicas=0

# Copy entire config directory from old LXC (includes tautulli.db, config.ini, and logs)
scp -r root@<tautulli-lxc-ip>:/opt/Tautulli/ /tmp/tautulli-config/

# Copy to PVC (scale up a temp pod or use NFS mount directly)
# Then scale back up
kubectl scale deployment tautulli -n media --replicas=1
```

- [ ] **Step 3: Verify and commit**

```bash
git add kubernetes/media/tautulli/
git commit -m "feat: deploy Tautulli with data migration from old LXC"
```

### Task 22: Deploy and migrate RomM

**Files:**
- Create: `kubernetes/media/romm/deployment.yaml`
- Create: `kubernetes/media/romm/service.yaml`
- Create: `kubernetes/media/romm/ingress.yaml`
- Create: `kubernetes/media/romm/certificate.yaml`
- Create: `kubernetes/media/romm/secret.sops.yaml`
- Create: `kubernetes/media/romm/configmap.yaml`
- Create: `kubernetes/media/romm/pvc.yaml`
- Create: `kubernetes/media/romm/kustomization.yaml`
- Modify: `kubernetes/media/kustomization.yaml`

**Context:** RomM is a ROM collection manager. Currently on TrueNAS with its own PostgreSQL container. Migrate PostgreSQL data to metagross, deploy to K8s with NFS access to ROM library.

- [ ] **Step 1: Migrate RomM PostgreSQL database**

```bash
# Dump from TrueNAS RomM's PostgreSQL container
ssh root@<snorlax-ip> "docker exec romm-db pg_dump -U romm romm --format=custom" > /tmp/romm.dump

# Restore to metagross
scp /tmp/romm.dump root@<metagross-ip>:/tmp/
ssh root@<metagross-ip> "sudo -u postgres pg_restore --dbname=romm --clean --if-exists /tmp/romm.dump"
```

- [ ] **Step 2: Create RomM deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: romm
  namespace: media
  labels:
    app.kubernetes.io/name: romm
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: romm
  template:
    metadata:
      labels:
        app.kubernetes.io/name: romm
    spec:
      containers:
        - name: romm
          image: rommapp/romm:3
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - secretRef:
                name: romm-secrets
            - configMapRef:
                name: romm-config
          volumeMounts:
            - name: library
              mountPath: /romm/library
            - name: assets
              mountPath: /romm/assets
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 15
          livenessProbe:
            httpGet:
              path: /
              port: http
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 512Mi
      volumes:
        - name: library
          persistentVolumeClaim:
            claimName: romm-library
        - name: assets
          persistentVolumeClaim:
            claimName: romm-assets
```

ConfigMap:
```yaml
DB_HOST: metagross.internal.svc.cluster.local
DB_PORT: "5432"
DB_NAME: romm
```

Secret (SOPS): `DB_USER`, `DB_PASSWD`, `ROMM_AUTH_SECRET_KEY`

PVCs: `romm-library` on TrueNAS NFS bulk/shared storage (ROM files), `romm-assets` on `local-path` (cover art, metadata).

IngressRoute on internal entrypoint, host `romm.home.mcnees.me`. RomM has its own auth.

- [ ] **Step 3: Verify and commit**

Verify ROM library is visible, metadata matches. Then:

```bash
git add kubernetes/media/romm/
git commit -m "feat: deploy RomM with PostgreSQL migration to metagross"
```

Stop the old TrueNAS RomM app after verification.

### Task 23: Deploy LazyLibrarian (or Readarr alternative)

**Files:**
- Create: `kubernetes/media/lazylibrarian/` (or `kubernetes/media/readarr/`)
- Modify: `kubernetes/media/kustomization.yaml`

**Context:** Fresh deploy. If using Readarr instead, follow the same pattern as Sonarr/Radarr (PostgreSQL on metagross, OAuth2-Proxy).

- [ ] **Step 1: Decide between LazyLibrarian and Readarr**

Evaluate at deployment time. If Readarr:
- Image: `ghcr.io/onedr0p/readarr:0.4`
- PostgreSQL databases on metagross (`readarr_main`, `readarr_log`)
- OAuth2-Proxy middleware
- Same env var pattern as other *arr apps

If LazyLibrarian:
- Image: `lscr.io/linuxserver/lazylibrarian:latest` (pin version)
- SQLite on NFS PVC
- OAuth2-Proxy middleware

- [ ] **Step 2: Create deployment files and commit**

Follow the established pattern for whichever app is chosen.

### Task 24: Deploy Stash (or alternative)

**Files:**
- Create: `kubernetes/media/stash/` (or alternative)
- Modify: `kubernetes/media/kustomization.yaml`

**Context:** Fresh deploy. Stash is a media organizer. Needs NFS access to media library on HDD pool.

- [ ] **Step 1: Create Stash deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stash
  namespace: media
  labels:
    app.kubernetes.io/name: stash
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: stash
  template:
    metadata:
      labels:
        app.kubernetes.io/name: stash
    spec:
      containers:
        - name: stash
          image: stashapp/stash:v0.27
          ports:
            - name: http
              containerPort: 9999
          volumeMounts:
            - name: config
              mountPath: /root/.stash
            - name: media
              mountPath: /media
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 15
          livenessProbe:
            httpGet:
              path: /
              port: http
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 1Gi
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: stash-config
        - name: media
          persistentVolumeClaim:
            claimName: stash-media
```

PVCs: `stash-config` on `local-path`, `stash-media` on TrueNAS NFS bulk/shared storage.
IngressRoute on internal entrypoint, host `stash.home.mcnees.me`, OAuth2-Proxy middleware.

- [ ] **Step 2: Commit and deploy**

```bash
git add kubernetes/media/stash/
git commit -m "feat: deploy Stash media organizer"
```

- [ ] **Step 3: Remove remaining temporary ExternalService routes**

Delete `tautulli.yaml`, `romm.yaml`, `lazylibrarian.yaml`, `stash.yaml` from temporary directory. Destroy old LXCs/TrueNAS apps.

---

## Wave 8: Hosting

Migrate Pelican Panel to K8s with PostgreSQL data migration.

### Task 25: Deploy and migrate Pelican Panel

**Files:**
- Create: `kubernetes/apps/pelican-panel/deployment.yaml`
- Create: `kubernetes/apps/pelican-panel/service.yaml`
- Create: `kubernetes/apps/pelican-panel/ingress.yaml`
- Create: `kubernetes/apps/pelican-panel/certificate.yaml`
- Create: `kubernetes/apps/pelican-panel/secret.sops.yaml`
- Create: `kubernetes/apps/pelican-panel/configmap.yaml`
- Create: `kubernetes/apps/pelican-panel/pvc.yaml`
- Create: `kubernetes/apps/pelican-panel/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Context:** Pelican Panel (management UI) moves to K8s. Pelican Wings (game server daemon) stays as a VM (pelipper) on latias. Panel connects to metagross for its database and to Wings over the network.

- [ ] **Step 1: Migrate Pelican database to metagross**

```bash
# Dump from old PostgreSQL LXC (if not already migrated in Stage 3)
ssh root@<old-postgres-lxc-ip> "sudo -u postgres pg_dump --format=custom pelican" > /tmp/pelican.dump

# Restore to metagross
scp /tmp/pelican.dump root@<metagross-ip>:/tmp/
ssh root@<metagross-ip> "sudo -u postgres pg_restore --dbname=pelican --clean --if-exists /tmp/pelican.dump"
```

- [ ] **Step 2: Create Pelican Panel deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pelican-panel
  namespace: apps
  labels:
    app.kubernetes.io/name: pelican-panel
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: pelican-panel
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pelican-panel
    spec:
      containers:
        - name: pelican-panel
          image: ghcr.io/pelican-dev/panel:v1
          ports:
            - name: http
              containerPort: 80
          envFrom:
            - secretRef:
                name: pelican-panel-secrets
            - configMapRef:
                name: pelican-panel-config
          volumeMounts:
            - name: data
              mountPath: /app/storage
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 30
          livenessProbe:
            httpGet:
              path: /
              port: http
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 512Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: pelican-panel-data
```

ConfigMap: `DB_HOST=metagross.internal.svc.cluster.local`, `DB_PORT=5432`, `DB_DATABASE=pelican`, `APP_URL=https://panel.home.mcnees.me`

Secret (SOPS): `DB_USERNAME`, `DB_PASSWORD`, `APP_KEY`, `HASHIDS_SALT`

IngressRoute on internal entrypoint, host `panel.home.mcnees.me`. Pelican has its own auth.

- [ ] **Step 3: Update Wings configuration**

After the Panel migrates, update the Wings LXC configuration to point at the new Panel URL if needed.

- [ ] **Step 4: Verify and commit**

```bash
git add kubernetes/apps/pelican-panel/
git commit -m "feat: deploy Pelican Panel with PostgreSQL migration to metagross"
```

Remove `pelican-panel.yaml` from temporary directory. Destroy old Pelican Panel LXC on Mew after 24 hours.

---

## Wave 9: HDF Services

Deploy RustFS, Invoice Ninja, and Chatwoot for Hudsonville Digital Foundry. All fresh deploys.

### Task 26: Deploy RustFS

**Files:**
- Create: `kubernetes/storage/rustfs/deployment.yaml`
- Create: `kubernetes/storage/rustfs/service.yaml`
- Create: `kubernetes/storage/rustfs/secret.sops.yaml`
- Create: `kubernetes/storage/rustfs/pvc.yaml`
- Create: `kubernetes/storage/rustfs/job-create-buckets.yaml`
- Create: `kubernetes/storage/rustfs/kustomization.yaml`
- Create: `kubernetes/storage/kustomization.yaml`
- Create: `kubernetes/flux-system/storage.yaml`
- Modify: `kubernetes/flux-system/kustomization.yaml`

**Context:** S3-compatible object storage for Invoice Ninja and Chatwoot file uploads. Internal-only, no public ingress. See `docs/superpowers/specs/2026-03-16-hdf-services-design.md` for full spec.

- [ ] **Step 1: Create Flux Kustomization for storage namespace**

Create `kubernetes/flux-system/storage.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: storage
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/storage
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

- [ ] **Step 2: Create RustFS deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustfs
  namespace: storage
  labels:
    app.kubernetes.io/name: rustfs
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: rustfs
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rustfs
    spec:
      containers:
        - name: rustfs
          image: rustfs/rustfs:latest  # Pin to specific tag before deploying
          args: ["server", "/data"]
          ports:
            - name: s3
              containerPort: 9000
            - name: console
              containerPort: 9001
          envFrom:
            - secretRef:
                name: rustfs-secrets
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            httpGet:
              path: /health
              port: s3
          livenessProbe:
            httpGet:
              path: /health
              port: s3
          resources:
            requests:
              memory: 512Mi
              cpu: 100m
            limits:
              memory: 1Gi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustfs-data
```

Secret (SOPS): `RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD`

PVC: `rustfs-data` on TrueNAS NFS bulk/shared storage, 50Gi.

Service: ClusterIP only (ports 9000, 9001).

- [ ] **Step 3: Create bucket provisioning Job**

Create `kubernetes/storage/rustfs/job-create-buckets.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: rustfs-create-buckets
  namespace: storage
spec:
  template:
    spec:
      containers:
        - name: mc
          image: minio/mc:latest
          command:
            - /bin/sh
            - -c
            - |
              mc alias set rustfs http://rustfs.storage.svc:9000 $RUSTFS_ROOT_USER $RUSTFS_ROOT_PASSWORD
              mc mb --ignore-existing rustfs/invoice-ninja
              mc mb --ignore-existing rustfs/chatwoot
          envFrom:
            - secretRef:
                name: rustfs-secrets
      restartPolicy: OnFailure
```

- [ ] **Step 4: Commit and deploy**

```bash
git add kubernetes/storage/ kubernetes/flux-system/storage.yaml kubernetes/flux-system/kustomization.yaml
git commit -m "feat: deploy RustFS S3-compatible object storage with bucket provisioning"
```

### Task 27: Deploy Invoice Ninja

**Files:**
- Create: `kubernetes/hdf/invoice-ninja/deployment.yaml`
- Create: `kubernetes/hdf/invoice-ninja/service.yaml`
- Create: `kubernetes/hdf/invoice-ninja/ingress.yaml`
- Create: `kubernetes/hdf/invoice-ninja/certificate.yaml`
- Create: `kubernetes/hdf/invoice-ninja/configmap.yaml`
- Create: `kubernetes/hdf/invoice-ninja/secret.sops.yaml`
- Create: `kubernetes/hdf/invoice-ninja/pvc.yaml`
- Create: `kubernetes/hdf/invoice-ninja/kustomization.yaml`
- Create: `kubernetes/hdf/kustomization.yaml`
- Create: `kubernetes/flux-system/hdf.yaml`
- Modify: `kubernetes/flux-system/kustomization.yaml`

**Context:** See `docs/superpowers/specs/2026-03-16-hdf-services-design.md` for full spec. Public-facing at `portal.hudsonvilledigital.com`.

- [ ] **Step 1: Create Flux Kustomization for hdf namespace**

Create `kubernetes/flux-system/hdf.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hdf
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/hdf
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
    - name: databases
    - name: storage
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

- [ ] **Step 2: Create Invoice Ninja database on metagross**

Run the PostgreSQL playbook (if not already run with the `invoice_ninja` database in the list):

```bash
task ansible:postgresql
```

- [ ] **Step 3: Create Invoice Ninja deployment**

Follow the spec exactly. Key env vars:
- `DB_TYPE=pgsql`, `DB_HOST=metagross.internal.svc.cluster.local`, `DB_DATABASE=invoice_ninja`
- `REDIS_HOST=redis.databases.svc`, `REDIS_PORT=6379`, `REDIS_DB=1`
- `FILESYSTEM_DISK=s3`, `AWS_ENDPOINT=http://rustfs.storage.svc:9000`
- `AWS_DEFAULT_REGION=us-east-1`, `AWS_USE_PATH_STYLE_ENDPOINT=true`
- `APP_URL=https://portal.hudsonvilledigital.com`
- `APP_KEY` — generate via `php artisan key:generate --show` (base64 format)

IngressRoute on EXTERNAL entrypoint (`websecure-external`), host `portal.hudsonvilledigital.com`.

Init Job: `php artisan migrate --force`

- [ ] **Step 4: Commit and deploy**

```bash
git add kubernetes/hdf/invoice-ninja/
git commit -m "feat: deploy Invoice Ninja for HDF client billing"
```

### Task 28: Deploy Chatwoot

**Files:**
- Create: `kubernetes/hdf/chatwoot/deployment-web.yaml`
- Create: `kubernetes/hdf/chatwoot/deployment-worker.yaml`
- Create: `kubernetes/hdf/chatwoot/service.yaml`
- Create: `kubernetes/hdf/chatwoot/ingress.yaml`
- Create: `kubernetes/hdf/chatwoot/certificate.yaml`
- Create: `kubernetes/hdf/chatwoot/configmap.yaml`
- Create: `kubernetes/hdf/chatwoot/secret.sops.yaml`
- Create: `kubernetes/hdf/chatwoot/pvc.yaml`
- Create: `kubernetes/hdf/chatwoot/kustomization.yaml`
- Modify: `kubernetes/hdf/kustomization.yaml`

**Context:** See `docs/superpowers/specs/2026-03-16-hdf-services-design.md` for full spec. Two deployments (web + Sidekiq worker), public at `support.hudsonvilledigital.com`.

- [ ] **Step 1: Create Chatwoot database on metagross**

Run the PostgreSQL playbook (if not already run with the `chatwoot` database).

- [ ] **Step 2: Create Chatwoot web deployment**

Follow the spec. Key env vars:
- `DATABASE_URL=postgres://chatwoot:pass@metagross.internal.svc.cluster.local:5432/chatwoot`
- `REDIS_URL=redis://redis.databases.svc:6379/2`
- `ACTIVE_STORAGE_SERVICE=amazon`, `S3_BUCKET_NAME=chatwoot`
- `AWS_ENDPOINT=http://rustfs.storage.svc:9000`, `AWS_REGION=us-east-1`
- `FRONTEND_URL=https://support.hudsonvilledigital.com`
- `SECRET_KEY_BASE` — generate via `openssl rand -hex 64`

- [ ] **Step 3: Create Chatwoot worker deployment**

Same image, same env vars, different command: `bundle exec sidekiq`

- [ ] **Step 4: Create IngressRoute**

IngressRoute on EXTERNAL entrypoint (`websecure-external`), host `support.hudsonvilledigital.com`. WebSocket support is handled natively by Traefik.

Init Job: `bundle exec rails db:chatwoot_prepare`

- [ ] **Step 5: Commit and deploy**

```bash
git add kubernetes/hdf/chatwoot/ kubernetes/hdf/kustomization.yaml kubernetes/flux-system/hdf.yaml kubernetes/flux-system/kustomization.yaml
git commit -m "feat: deploy Chatwoot for HDF client support"
```

### Task 29: Configure Chatwoot widget in Invoice Ninja

**Files:** None (manual configuration task)

- [ ] **Step 1: Create Chatwoot inbox**

In Chatwoot admin UI (`support.hudsonvilledigital.com`):
1. Create a new "Website" inbox
2. Configure the inbox name and greeting
3. Copy the generated JavaScript widget snippet

- [ ] **Step 2: Add widget to Invoice Ninja client portal**

Add the Chatwoot JavaScript snippet to Invoice Ninja's client portal. This may require:
- Custom Invoice Ninja theme/template modification
- Or adding the script via Invoice Ninja's "Custom CSS/JS" settings if available

- [ ] **Step 3: Verify widget appears and functions**

Load the Invoice Ninja client portal in a browser. Verify the Chatwoot widget appears and messages flow to the Chatwoot agent dashboard.

---

## Post-Migration Cleanup

### Task 30: Clean up temporary ExternalService routes

**Files:**
- Remove: `kubernetes/apps/external-services/temporary/` (entire directory)
- Modify: `kubernetes/apps/external-services/kustomization.yaml`

**Context:** After all waves complete, the temporary directory should be empty (routes were removed wave-by-wave). This task removes the directory itself.

- [ ] **Step 1: Verify temporary directory is empty**

```bash
ls kubernetes/apps/external-services/temporary/
```

Should only contain `kustomization.yaml` with no resources.

- [ ] **Step 2: Remove the temporary directory**

```bash
rm -rf kubernetes/apps/external-services/temporary/
# Update parent kustomization to remove the ./temporary reference
git add -A && git commit -m "cleanup: remove empty temporary ExternalService directory"
```

### Task 31: Destroy old LXCs and clean up Mew

**Files:** None (operational task)

**Context:** After all services are migrated and verified stable, destroy the remaining old LXCs on Mew. This frees Mew for repurposing or decommissioning.

- [ ] **Step 1: Inventory remaining LXCs on Mew**

```bash
ssh root@mew "pct list"
```

All should be stopped/unused at this point.

- [ ] **Step 2: Take final PBS backups of each LXC**

Before destruction, ensure PBS has a recent backup of each LXC (safety net).

- [ ] **Step 3: Destroy LXCs**

```bash
# For each remaining LXC:
ssh root@mew "pct destroy <VMID> --purge"
```

- [ ] **Step 4: Destroy old PostgreSQL LXC**

The old PostgreSQL LXC on Mew should have no remaining consumers. Verify, then destroy.

- [ ] **Step 5: Destroy old Traefik LXC**

Should have been idle since Wave 1. Destroy.

- [ ] **Step 6: Verify no remaining legacy Docker containers**

Any legacy Docker containers from the old Dell nodes should have been migrated or decommissioned during migration. Verify nothing remains.

- [ ] **Step 7: Document completion**

Update the Obsidian Homelab Overview note and migration execution roadmap to reflect Phase 3 completion.
