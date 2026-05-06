# Paperless-ngx

Paperless-ngx runs in the `apps` namespace at `https://paperless.home.mcnees.me`.

## Storage

- Database: PostgreSQL database `paperless` on metagross.
- Redis: shared Redis broker at `redis-master.databases.svc.cluster.local`, DB index `2`.
- Data PVC: `paperless-data`, local-path, for search index, classifier, and app-local state.
- Media PVC: `paperless-media`, TrueNAS NFS, for original and archived documents.
- Consume PVC: `paperless-consume`, TrueNAS NFS, for the watched import directory.
- Export PVC: `paperless-export`, TrueNAS NFS, for Paperless document exports.

Create these TrueNAS datasets before first production use. The preferred path is now `task ansible:truenas`; see [truenas.md](truenas.md).

```text
data/k8s/apps/paperless/media
data/k8s/apps/paperless/consume
data/k8s/apps/paperless/export
```

The parent datasets `data/k8s`, `data/k8s/apps`, and `data/k8s/apps/paperless` are also managed by the TrueNAS Ansible playbook.

Export them over NFS and allow Kubernetes node clients. The manifests expect these export paths:

```text
10.0.1.1:/mnt/data/k8s/apps/paperless/media
10.0.1.1:/mnt/data/k8s/apps/paperless/consume
10.0.1.1:/mnt/data/k8s/apps/paperless/export
```

Set ownership or NFS mapall so UID/GID `2000` can read and write the exports. The deployment sets `USERMAP_UID=2000` and `USERMAP_GID=2000`.

Paperless is intentionally not added to the root `kubernetes/apps/kustomization.yaml` until these NFS exports exist. After the datasets and shares are ready, add `./paperless-ngx` to that file, commit, push, and reconcile the `apps` Flux Kustomization.

## Bootstrap

The initial admin username, admin email, admin password, database password, and `PAPERLESS_SECRET_KEY` live in the SOPS-encrypted `paperless-ngx-secrets` Secret.

Paperless creates the initial admin user on startup when `PAPERLESS_ADMIN_USER` and `PAPERLESS_ADMIN_PASSWORD` are present. It does not update that user's password after the user already exists.

## Verification

```bash
kubectl --kubeconfig talos/kubeconfig get pods -n apps -l app.kubernetes.io/name=paperless-ngx
kubectl --kubeconfig talos/kubeconfig logs -n apps deployment/paperless-ngx --tail=100
```

Open `https://paperless.home.mcnees.me`, sign in with the bootstrap admin, and upload a test PDF. Confirm the document is consumed, OCR completes, and the file appears in the document list.

## Backup And Restore

PostgreSQL is covered by the metagross logical backup job.

Document files live on TrueNAS in `data/k8s/apps/paperless/media`, so include that dataset in TrueNAS snapshots/replication. Paperless exports can be written to `data/k8s/apps/paperless/export` when you want an application-level export in addition to dataset snapshots.
