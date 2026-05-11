# Mantle

Mantle is the lab's n8n replacement candidate. This is the `dvflw/mantle` project, not the hosted product at `mantle.work`.

## Deployment

- Namespace: `apps`
- URL: `https://mantle.home.mcnees.me`
- Image: `ghcr.io/dvflw/mantle:latest`
- Database: Postgres database `mantle` on metagross
- Auth edge: Pocket ID via the shared `oauth2-proxy` middleware
- Metrics: disabled for now because `/metrics` returns `401` when Mantle auth is enabled.

Mantle is a single Go binary with Postgres persistence. The pod runs `mantle init` as an init container before starting `mantle serve`.

## Secrets

The SOPS secret `kubernetes/apps/mantle/secret.sops.yaml` contains:

- `MANTLE_DATABASE_URL`
- `MANTLE_ENCRYPTION_KEY`

The encryption key must be 32 bytes encoded as 64 hex characters. Do not rotate it casually after credentials have been created, because Mantle uses it to decrypt stored connector secrets.

## Known Upstream Follow-Up

GitHub issue `dvflw/mantle#136` tracks publishing versioned GHCR images. Until that is fixed, the homelab deployment uses `latest`.

GitHub issue `dvflw/mantle#138` tracks `/readyz` flapping when worker/reaper liveness is temporarily degraded. The homelab deployment uses `/healthz` for Kubernetes readiness until Mantle has a less noisy readiness contract.

GitHub issue `dvflw/mantle#139` tracks authenticated `/metrics`. Re-enable `servicemonitor.yaml` in `kubernetes/apps/mantle/kustomization.yaml` after Mantle supports unauthenticated health/metrics paths or a Prometheus bearer-token configuration.
