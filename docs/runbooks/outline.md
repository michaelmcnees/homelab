# Outline

Outline runs in the `apps` namespace at `https://docs.mcnees.me`.

## Components

- App: `docker.getoutline.com/outlinewiki/outline:1.8.1`
- Database: PostgreSQL database `outline` on metagross
- Redis: shared Redis at `redis-master.databases.svc.cluster.local`, DB index `4`
- File storage: RustFS S3 bucket `outline`, signed through `https://s3.mcnees.me`
- Auth: Pocket ID OIDC
- MCP: built-in endpoint at `https://docs.mcnees.me/mcp`

## Pocket ID Client

Create an OIDC client in Pocket ID for Outline:

- Redirect URI: `https://docs.mcnees.me/auth/oidc.callback`
- Launch URL: `https://docs.mcnees.me`
- Scopes: `openid profile email`

Save the client ID and client secret into
`kubernetes/apps/outline/secret.sops.yaml`.

The Kubernetes manifests are included from `kubernetes/apps/kustomization.yaml`.
The old temporary external route should stay removed after cutover.

## Exports and Attachments

Outline signs S3 download URLs using `AWS_S3_UPLOAD_BUCKET_URL`. Keep that
value browser-reachable. The in-cluster RustFS service URL works for pod access
but produces unusable export links such as
`rustfs.object-storage.svc.cluster.local:9000`.

The public S3 route is declared in
`kubernetes/storage/rustfs/public-ingress.yaml` and forwards
`https://s3.mcnees.me` to the RustFS S3 service with path-style bucket URLs.

## MCP

Outline includes a built-in MCP server at:

```text
https://docs.mcnees.me/mcp
```

MCP is controlled at the workspace level under Settings -> AI. Existing
workspaces may have MCP disabled after upgrading, so enable it there only when
you are restoring the legacy Outline MCP path during a Hermes rollback. That
path is kept for recovery and comparison, not as the canonical Hermes notes,
docs, or todo backend.

Default MCP auth uses OAuth. API key auth is also available by generating an
Outline API key and sending it as:

```text
Authorization: Bearer <api-key>
```

## Migration Notes

The legacy route points `docs.mcnees.me` at `10.0.0.23:3000`. Migrate in this
order:

1. Dump the old Outline PostgreSQL database.
2. Restore it into the metagross `outline` database before starting the new pod.
3. Copy old local uploads into the RustFS `outline` bucket, or confirm the old
   instance already used S3-compatible storage and point the new secret at the
   same object data.
4. Start the Kubernetes Deployment and verify OIDC login plus attachment access.
