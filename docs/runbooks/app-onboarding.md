# App Onboarding Checklist

Use this checklist before adding or migrating an application into the Kubernetes app platform.

## Identity

- Service name:
- Namespace:
- Public hostname:
- Internal hostname:
- Owner:

## Exposure

- Route type: public, internal-only, or local-only.
- Ingress hostname:
- TLS secret:
- Auth mode: app-native, oauth2-proxy, Pocket ID/OIDC, public, or none.
- If oauth2-proxy is used, confirm callback and allowed-user/group policy in Pocket ID.

## Data

- PostgreSQL database needed:
- PostgreSQL owner:
- Redis/session needs:
- Local PVCs:
- NFS PVCs:
- Config secrets:
- Bootstrap admin/user steps:

## Operations

- Backup source of truth:
- Restore procedure:
- Health endpoint:
- Logs to check:
- Grafana dashboard impact:
- Alerts needed:
- Decommission criteria for the old service:

## Deployment

1. Add database/users to `ansible/playbooks/postgresql-setup.yml` if needed.
2. Add ignored local secret values to `ansible/inventory/group_vars/postgresql.yml` if needed.
3. Run `task ansible:postgresql` when database state changes.
4. Create Kubernetes manifests under the owning namespace.
5. Render with `kubectl kustomize`.
6. Commit, push, reconcile Flux, and verify rollout.
