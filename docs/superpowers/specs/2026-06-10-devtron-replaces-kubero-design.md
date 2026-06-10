# Devtron Replaces Kubero

## Goal

Replace Kubero with a full Devtron OSS installation at `https://cloud.dvflw.co`.

The installation should be GitOps-managed by Flux, use the existing homelab platform services where possible, and avoid the known Devtron external PostgreSQL chart issue where component ConfigMaps render duplicate `PG_DATABASE` keys.

## Current State

Kubero is managed in two places:

- `kubernetes/apps/kubero` deploys the Kubero custom resource, secret, namespace, and Traefik route.
- `kubernetes/infrastructure/controllers/kubero-operator` deploys the Kubero operator from upstream manifests.

The cluster already provides:

- Flux Kustomizations for infrastructure, storage, and apps.
- Traefik `IngressRoute` resources with `websecure-external` for public services.
- cert-manager with a Cloudflare-backed `letsencrypt-production` ClusterIssuer.
- ExternalDNS using Cloudflare, currently filtered to `mcnees.me`.
- Central PostgreSQL on `metagross.internal.svc.cluster.local`.
- RustFS S3-compatible object storage in the `object-storage` namespace.

## Selected Approach

Use a vendored, patched Devtron chart rather than consuming the upstream `devtron/devtron-operator` chart directly.

The Devtron chart currently renders `global.dbConfig` and component `.configs` into the `gitsensor`, `lens`, and `casbin` ConfigMaps. In external PostgreSQL mode, both maps include `PG_DATABASE`, producing duplicate YAML keys. The vendored chart patch will render `global.dbConfig | omit "PG_DATABASE"` for those three component ConfigMaps so each component keeps its own database name.

This keeps Devtron on the central PostgreSQL service while making the chart behavior deterministic under Flux.

## Devtron Installation

Deploy Devtron in a dedicated `devtroncd` namespace using Flux `HelmRelease`.

Enable the full OSS feature set:

- `installer.modules` includes `cicd`.
- `argo-cd.enabled` is `true`.
- Devtron dashboard service is `ClusterIP`.
- `global.storageClass` is `ceph-rbd`.
- `global.externalPostgres.enabled` is `true`.
- `global.externalPostgres.PG_ADDR` points to `metagross.internal.svc.cluster.local`.
- `global.dbConfig.PG_DATABASE` remains `orchestrator`.

Devtron requires these PostgreSQL databases on metagross:

- `orchestrator`
- `lens`
- `git_sensor`
- `casbin`

The chart expects the PostgreSQL username to be `postgres` for external PostgreSQL. Use a SOPS-managed Kubernetes Secret for the external PostgreSQL password and pass it into the Helm values.

## Object Storage

Use existing RustFS instead of Devtron-managed MinIO.

Add a bucket bootstrap job following the existing RustFS pattern:

- Endpoint: `http://rustfs.object-storage.svc.cluster.local:9000`
- Bucket: `devtron`
- Credentials source: existing `object-storage/rustfs-secrets`.

Configure Devtron blob storage as S3-compatible storage:

- `configs.BLOB_STORAGE_PROVIDER=S3`
- `configs.BLOB_STORAGE_S3_ENDPOINT=http://rustfs.object-storage.svc.cluster.local:9000`
- `configs.BLOB_STORAGE_S3_ENDPOINT_INSECURE=true`
- `configs.DEFAULT_BUILD_LOGS_BUCKET=devtron`
- `configs.DEFAULT_CACHE_BUCKET=devtron`
- `configs.DEFAULT_CACHE_BUCKET_REGION=us-east-1`
- `configs.DEFAULT_CD_LOGS_BUCKET_REGION=us-east-1`
- `secrets.BLOB_STORAGE_S3_ACCESS_KEY` and `secrets.BLOB_STORAGE_S3_SECRET_KEY` sourced from SOPS-managed credentials.

## Ingress, TLS, And DNS

Expose Devtron publicly at `cloud.dvflw.co`.

Add a Traefik `IngressRoute` in `devtroncd`:

- EntryPoint: `websecure-external`
- Host rule: `Host("cloud.dvflw.co")`
- Service: `devtron-service`
- Port: `80`
- Middleware: existing `infrastructure/public-chain`
- TLS secret: `devtron-tls`

Add a cert-manager `Certificate` for `cloud.dvflw.co` using `letsencrypt-production`.

Update ExternalDNS to manage the `dvflw.co` zone by adding `dvflw.co` to `domainFilters`. Add an explicit `DNSEndpoint` for `cloud.dvflw.co` targeting `104.14.105.18`, matching the existing public-service pattern for managed public DNS records.

## Kubero Removal

Remove Kubero from Flux source control:

- Remove `./kubero` from `kubernetes/apps/kustomization.yaml`.
- Remove `kubero-operator` from `kubernetes/infrastructure/controllers/kustomization.yaml`.
- Leave the deleted manifests out of Git so Flux prune removes the Kubero app and operator resources.

Before removal, verify no desired workload is still managed by Kubero. If any workloads exist, capture them before pruning.

## Verification

Local verification:

- Render the vendored chart with the Devtron values.
- Confirm `git-sensor-cm`, `lens-cm`, and `casbin-cm` each contain only one `PG_DATABASE`.
- Run Kustomize build for the affected app and infrastructure paths.

Cluster verification:

- Confirm metagross contains the required Devtron databases.
- Confirm the RustFS `devtron` bucket exists.
- Reconcile Flux sources and Kustomizations.
- Confirm the Devtron HelmRelease becomes ready.
- Check Devtron installer status:
  - `kubectl -n devtroncd get installers installer-devtron -o jsonpath='{.status.sync.status}'`
- Confirm `cloud.dvflw.co` resolves through Cloudflare to the homelab public target.
- Confirm the certificate is ready.
- Confirm the Devtron login page loads over HTTPS.
- Retrieve the initial admin password from `devtron-secret` and log in.

## Rollback

Because Flux prune will remove Kubero once its manifests disappear, rollback is a Git revert of the Kubero removal plus a Flux reconcile.

If Devtron fails during installation:

- Suspend or remove the Devtron HelmRelease.
- Leave metagross databases and RustFS bucket intact for inspection unless a clean retry requires dropping them.
- Revert the ExternalDNS `dvflw.co` change only if no other homelab service uses that zone.

## Open Implementation Notes

- The implementation plan should decide where to vendor the chart. A conventional location is `kubernetes/charts/devtron-operator`.
- The implementation plan should define how Devtron PostgreSQL databases are created on metagross. This likely belongs in the existing Ansible PostgreSQL management flow, not an ad hoc Kubernetes Job.
- SOPS secret creation may require local secret values that are not present in the repo. If needed, pause for credentials rather than committing placeholders.
