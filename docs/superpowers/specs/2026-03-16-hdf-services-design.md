# HDF Services Design: Invoice Ninja, Chatwoot, and RustFS

**Date:** 2026-03-16
**Status:** Approved
**Scope:** Add self-hosted Invoice Ninja (billing/invoicing), Chatwoot (client support chat), and RustFS (S3-compatible object storage) to the homelab K3s cluster for Hudsonville Digital Foundry (HDF) client operations.

## Context

Michael runs Hudsonville Digital Foundry (HDF), a web design, hosting, and marketing services business. The goal is to self-host both Invoice Ninja (client billing portal) and Chatwoot (client support chat), with the Chatwoot widget embedded in the Invoice Ninja client dashboard. Both services are publicly accessible under `hudsonvilledigital.com` subdomains and use their own built-in authentication (no OAuth2-Proxy or Pocket ID integration).

Both services require S3-compatible object storage for file uploads, attachments, and generated PDFs. RustFS replaces MinIO (which changed to a restrictive license) as the S3-compatible storage backend, deployed in the `storage` namespace for potential reuse by other services.

## Architecture Overview

```
                         +----------------------------------+
                         |        storage namespace          |
                         |  RustFS (S3-compatible storage)   |
                         |  PVC: flash/k8s/ (bucket data)   |
                         +--------+--------------+----------+
                                  |              |
    +-----------------------------+              +-------------------------------+
    |                                                                            |
    v                                                                            v
+----------------------------------+      +--------------------------------------+
|         hdf namespace            |      |           hdf namespace              |
|  Invoice Ninja (PHP/Laravel)     |      |  Chatwoot (Rails)                    |
|  portal.hudsonvilledigital.com   |      |  support.hudsonvilledigital.com      |
|  - PostgreSQL (metagross)        |      |  - PostgreSQL (metagross)            |
|  - Redis (databases ns, db1)     |      |  - Redis (databases ns, db2)         |
|  - S3 -> RustFS (storage ns)    |      |  - S3 -> RustFS (storage ns)         |
+----------------------------------+      |  - Sidekiq workers                   |
                                          +--------------------------------------+
         Chatwoot widget JS <-- embedded in Invoice Ninja client portal
```

### Namespace: `hdf`

A dedicated namespace for HDF business services, isolated from personal apps. This provides:
- Clean separation of business-critical client-facing services from personal tools
- Easier NetworkPolicy scoping (HDF services only talk to metagross, Redis, RustFS)
- Clear ownership boundary

### Flux Dependency Chain

```
infrastructure --> databases --> storage --> hdf
```

`hdf.yaml` Flux Kustomization depends on `infrastructure`, `databases`, and `storage`.

> **Note:** The `databases.yaml` and `storage.yaml` Flux Kustomizations are created during Phase 2 and Phase 3 respectively. `databases.yaml` is created in Phase 2 (Task 12, Redis). The `storage` Flux Kustomization must exist before RustFS can be deployed — if RustFS is the first service in the `storage` namespace, its Phase 3 task must create `kubernetes/flux-system/storage.yaml` as part of the RustFS deployment.

## Service Specifications

### RustFS (S3-Compatible Object Storage)

**Namespace:** `storage`
**Image:** `rustfs/rustfs:latest` (pin to specific tag once a stable release is identified)
**License:** Apache 2.0

**Deployment:** Single standalone Deployment (not distributed mode). Runs `rustfs server` command.

**Storage:** PVC on `truenas-nfs` (`flash/k8s/`) for all bucket data. This is the authoritative store for S3 objects.

**Service:** ClusterIP only — no public ingress.
- Port 9000: S3 API
- Port 9001: Web console (internal admin access only)

**Environment (SOPS-encrypted Secret):**
- `RUSTFS_ROOT_USER` — admin access key
- `RUSTFS_ROOT_PASSWORD` — admin secret key

**Buckets:** Created via a post-install Job using `rustfs/mc` (MinIO-compatible CLI):
- `invoice-ninja` — PDFs, logos, uploads
- `chatwoot` — attachments, avatars
- Per-service access keys with bucket-scoped IAM policies

**Health probes:**
- Readiness: `httpGet /health` port 9000
- Liveness: `httpGet /health` port 9000

**Resource requests:** 512Mi RAM (limit 1Gi), 100m CPU.

### Invoice Ninja

**Namespace:** `hdf`
**Image:** `invoiceninja/invoiceninja:5` (official Docker image, PHP/Laravel)
**Domain:** `portal.hudsonvilledigital.com`

**Deployment:** Single Deployment (web server + queue worker).

**Storage:** PVC on `truenas-nfs` for `/var/www/app/public/storage` (local file cache). With S3 configured, most files go to RustFS.

**Ingress:** IngressRoute on external Traefik entrypoint, TLS via cert-manager Certificate resource (Cloudflare DNS-01 ClusterIssuer).

**Auth:** Built-in Invoice Ninja authentication. No OAuth2-Proxy or Pocket ID.

**Database:** `invoice_ninja` on metagross (PostgreSQL LXC).

**Environment (SOPS-encrypted Secret + ConfigMap):**
- `DB_TYPE=pgsql`
- `DB_HOST=metagross.internal`
- `DB_DATABASE=invoice_ninja`
- `DB_USERNAME`, `DB_PASSWORD` — SOPS-encrypted
- `QUEUE_CONNECTION=redis`
- `REDIS_HOST=redis.databases.svc`
- `REDIS_PORT=6379`
- `REDIS_DB=1`
- `FILESYSTEM_DISK=s3`
- `AWS_ENDPOINT=http://rustfs.storage.svc:9000`
- `AWS_BUCKET=invoice-ninja`
- `AWS_DEFAULT_REGION=us-east-1` (required by AWS SDK even for non-AWS S3)
- `AWS_USE_PATH_STYLE_ENDPOINT=true` (required for S3-compatible stores)
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` — SOPS-encrypted
- `APP_URL=https://portal.hudsonvilledigital.com`
- `APP_KEY` — Laravel encryption key, SOPS-encrypted (generate via `php artisan key:generate --show`, must be `base64:...` format)

**Init job:** `php artisan migrate --force` on first deploy.

**Health probes:**
- Readiness: `httpGet /api/v1/ping` port 80, `initialDelaySeconds: 30`
- Liveness: `httpGet /api/v1/ping` port 80

### Chatwoot

**Namespace:** `hdf`
**Image:** `chatwoot/chatwoot:v3` (official Docker image, Rails)
**Domain:** `support.hudsonvilledigital.com`

**Deployments:**
- **web** — Runs `bundle exec rails s` (Puma web server)
- **worker** — Runs `bundle exec sidekiq` (background jobs: emails, webhooks, notifications)
- Both share the same image and config, different entrypoint commands.

**Storage:** PVC on `truenas-nfs` for local file cache. With S3 configured, most attachments go to RustFS.

**Ingress:** IngressRoute on external Traefik entrypoint, TLS via cert-manager Certificate resource. Requires WebSocket support for live chat (Traefik handles this natively).

**Auth:** Built-in Chatwoot authentication. No OAuth2-Proxy or Pocket ID.

**Database:** `chatwoot` on metagross (PostgreSQL LXC).

**Environment (SOPS-encrypted Secret + ConfigMap):**
- `DATABASE_URL=postgres://chatwoot:pass@metagross.internal:5432/chatwoot`
- `REDIS_URL=redis://redis.databases.svc:6379/2`
- `ACTIVE_STORAGE_SERVICE=amazon`
- `S3_BUCKET_NAME=chatwoot`
- `AWS_ENDPOINT=http://rustfs.storage.svc:9000`
- `AWS_REGION=us-east-1` (required by AWS SDK even for non-AWS S3)
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` — SOPS-encrypted
- `FRONTEND_URL=https://support.hudsonvilledigital.com`
- `SECRET_KEY_BASE` — Rails secret, SOPS-encrypted (generate via `openssl rand -hex 64`)
- `RAILS_ENV=production`

**SMTP (for agent notifications, conversation assignments, password resets):**
- `MAILER_SENDER_EMAIL`, `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` — configure if email notifications are needed. Chatwoot functions without SMTP but will not send any email notifications.

**Init job:** `bundle exec rails db:chatwoot_prepare` on first deploy (migrations + seeds).

**Health probes:**
- Readiness: `tcpSocket` port 3000, `initialDelaySeconds: 30`
- Liveness: `tcpSocket` port 3000

### Chatwoot Widget Integration

After deploying Chatwoot, create an "inbox" in the Chatwoot admin UI. This generates a JavaScript snippet that gets added to Invoice Ninja's client portal. This is a **manual configuration step** — not automated in K8s manifests.

## Redis Usage

Both services share the existing Redis instance in the `databases` namespace, using different database numbers.

**Redis DB allocation table** (canonical — update this when adding new consumers):

| DB | Service | Purpose |
|----|---------|---------|
| 0 | Outline, Paperless-ngx | Default (session/cache) |
| 1 | Invoice Ninja | Queue jobs |
| 2 | Chatwoot | Sidekiq jobs + caching |

Redis auth is disabled (internal-only, NetworkPolicy-protected).

## TLS and DNS

The existing Cloudflare DNS-01 ClusterIssuer handles `hudsonvilledigital.com` subdomains using the same Cloudflare API token that manages `mcnees.me`. No additional ClusterIssuer needed.

ExternalDNS creates DNS records for:
- `portal.hudsonvilledigital.com` -> Traefik LoadBalancer IP
- `support.hudsonvilledigital.com` -> Traefik LoadBalancer IP

## PostgreSQL Databases

Two new databases added to the metagross PostgreSQL playbook:
- `invoice_ninja` — with dedicated user
- `chatwoot` — with dedicated user

These are added to the existing Phase 2 Task 11 (PostgreSQL playbook) database list alongside `pocket_id`, `pelican`, `n8n`, `romm`, and `outline`.

## Migration Wave Placement

These are **new deployments** (not migrations from existing infrastructure). They are added as **Wave 12** in the migration spec, after the existing 11 waves.

**Wave 12: HDF Services**
- Depends on: RustFS (storage namespace), Redis (databases namespace), PostgreSQL databases on metagross
- Deployment order: RustFS -> Invoice Ninja -> Chatwoot -> widget integration (manual)

## Impact on Existing Plans

1. **Redesign spec** — Add Invoice Ninja, Chatwoot, RustFS to service inventory. Add `hdf` namespace. Add `hudsonvilledigital.com` to cert-manager scope. Add databases to metagross list.
2. **Migration spec** — Add Wave 12.
3. **Phase 2 plan** — Add `invoice_ninja` and `chatwoot` to PostgreSQL playbook database list (Task 11).
4. **Phase 3 plan** (not yet written) — RustFS deployment as part of storage namespace. HDF services as their own chunk.

## GitOps Repository Structure

```
kubernetes/
  storage/
    rustfs/
      helmrelease.yaml        # or deployment.yaml if no Helm chart used
      job-create-buckets.yaml  # post-install bucket + IAM provisioning
      kustomization.yaml
    kustomization.yaml          # namespace-level kustomization
  hdf/
    invoice-ninja/
      deployment.yaml
      service.yaml
      ingress.yaml
      certificate.yaml
      configmap.yaml
      secret.sops.yaml
      pvc.yaml
      kustomization.yaml
    chatwoot/
      deployment-web.yaml
      deployment-worker.yaml
      service.yaml
      ingress.yaml
      certificate.yaml
      configmap.yaml
      secret.sops.yaml
      pvc.yaml
      kustomization.yaml
    kustomization.yaml          # namespace-level kustomization
  flux-system/
    storage.yaml                # Flux Kustomization for storage namespace
    hdf.yaml                    # Flux Kustomization for hdf namespace
```
