# Outline

Outline runs in the `apps` namespace at `https://docs.mcnees.me`.

## Components

- App: `docker.getoutline.com/outlinewiki/outline`
- Database: PostgreSQL database `outline` on metagross
- Redis: shared Redis at `redis-master.databases.svc.cluster.local`, DB index `4`
- File storage: RustFS S3 bucket `outline`
- Auth: Pocket ID OIDC

## Pocket ID Client

Create an OIDC client in Pocket ID for Outline:

- Redirect URI: `https://docs.mcnees.me/auth/oidc.callback`
- Launch URL: `https://docs.mcnees.me`
- Scopes: `openid profile email`

Save the client ID and client secret into
`kubernetes/apps/outline/secret.sops.yaml`.

The Kubernetes manifests are intentionally not included from
`kubernetes/apps/kustomization.yaml` until the live LXC data is migrated. The
temporary external route keeps `docs.mcnees.me` pointed at the existing LXC.

## Migration Notes

The legacy route points `docs.mcnees.me` at `10.0.0.23:3000`. Migrate in this
order:

1. Dump the old Outline PostgreSQL database.
2. Restore it into the metagross `outline` database before starting the new pod.
3. Copy old local uploads into the RustFS `outline` bucket, or confirm the old
   instance already used S3-compatible storage and point the new secret at the
   same object data.
4. Add `./outline` to `kubernetes/apps/kustomization.yaml` and remove
   `outline.yaml` from `kubernetes/apps/external-services/temporary/kustomization.yaml`.
5. Start the Kubernetes Deployment and verify OIDC login plus attachment access.
