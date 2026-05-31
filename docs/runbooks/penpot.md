# Penpot

Penpot runs in the `apps` namespace from the official Penpot Helm chart.

## Access

- URL: https://design.mcnees.me
- Ingress: `kubernetes/apps/penpot/ingress.yaml`
- Workloads: `penpot-frontend`, `penpot-backend`, `penpot-exporter`, and `penpot-mcp`

## Dependencies

- PostgreSQL database: `penpot` on `metagross.internal.svc.cluster.local`
- PostgreSQL owner: `penpot`
- Redis database: `redis-master.databases.svc.cluster.local:6379/5`
- Asset storage: RustFS S3 bucket `penpot`
- Secrets: `kubernetes/apps/penpot/secret.sops.yaml`

## Bootstrap

1. Ensure `pg_password_penpot` in `ansible/inventory/group_vars/postgresql.yml` matches `PENPOT_DATABASE_PASSWORD` in the Penpot SOPS secret.
2. Reconcile `kubernetes/storage/rustfs` or run the `rustfs-create-bucket-penpot` Job to create the `penpot` bucket.
3. Run `task ansible:postgresql` to create the `penpot` role and database.
4. Commit and push the Kubernetes manifests, then reconcile Flux.

## Verification

```bash
kubectl --kubeconfig talos/kubeconfig -n apps get helmrelease penpot
kubectl --kubeconfig talos/kubeconfig -n apps get pods -l app.kubernetes.io/instance=penpot
kubectl --kubeconfig talos/kubeconfig -n apps logs deploy/penpot-backend
```

The frontend should load at `https://design.mcnees.me` after the HelmRelease is ready. Registration is enabled with email verification disabled, and Penpot logs emails instead of sending SMTP mail.
