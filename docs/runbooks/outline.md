# Outline

Outline runs in the `apps` namespace at `https://docs.mcnees.me`.

## Components

- App: `docker.getoutline.com/outlinewiki/outline`
- Database: PostgreSQL database `outline` on metagross
- Redis: shared Redis at `redis-master.databases.svc.cluster.local`, DB index `4`
- File storage: `outline-data` PVC on `local-path`
- Auth: Pocket ID OIDC

## Pocket ID Client

Create an OIDC client in Pocket ID for Outline:

- Redirect URI: `https://docs.mcnees.me/auth/oidc.callback`
- Launch URL: `https://docs.mcnees.me`
- Scopes: `openid profile email`

Save the client ID and client secret into
`kubernetes/apps/outline/secret.sops.yaml`.

## Migration Notes

The legacy route pointed `docs.mcnees.me` at `10.0.0.23:3000`, but that
endpoint was unreachable during the Kubernetes migration scaffold. If the old
LXC becomes reachable again, migrate in this order:

1. Dump the old Outline PostgreSQL database.
2. Restore it into the metagross `outline` database before starting the new pod.
3. Copy old local uploads into the `outline-data` PVC under
   `/var/lib/outline/data`.
4. Start the Kubernetes Deployment and verify OIDC login plus attachment access.

If the old LXC remains unavailable, the Kubernetes deployment can be used as a
fresh Outline instance after the Pocket ID client values are set.
