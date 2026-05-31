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

The `paperless-restic-backup` CronJob runs in the `apps` namespace so it can mount the Paperless PVCs. It mounts `paperless-media`, `paperless-consume`, and `paperless-export` read-only and writes one restic snapshot to the TrueNAS repository at `/mnt/data/backups/restic-homelab`.

- Schedule: `30 4 * * *`
- Host: `paperless`
- Tags: `paperless-media`, `paperless-consume`, `paperless-export`, `homelab`
- Retention: 7 daily, 4 weekly, 6 monthly

The generic `BackupStale` alert covers each Paperless tag after the first successful snapshot is exported by `backup-metrics-exporter`; no Paperless-specific alert is needed.

To run a manual backup:

```bash
kubectl -n apps create job --from=cronjob/paperless-restic-backup paperless-restic-backup-manual
kubectl -n apps wait job/paperless-restic-backup-manual --for=condition=complete --timeout=4h
```

## Backup Result

2026-05-30:

- Manual backup Job: `paperless-restic-backup-manual-20260529`
- Restic snapshot: `6cf2671e`
- Snapshot paths: `/paperless/media`, `/paperless/consume`, `/paperless/export`
- Snapshot tags: `paperless-media`, `paperless-consume`, `paperless-export`, `homelab`
- Snapshot size: 25.333 MiB from 4 files
- Restore test Job: `paperless-restic-restore-test`
- Restore result: restored 12 files/directories, 25.333 MiB, into a throwaway `local-path` PVC
- Cleanup: manual backup Job, temporary restore Job, and temporary restore PVC were deleted after verification

Document files also live on TrueNAS in `data/k8s/apps/paperless/media` until the storage migration completes, so keep TrueNAS snapshots/replication in place during the transition. Paperless exports can be written to `data/k8s/apps/paperless/export` when you want an application-level export in addition to dataset snapshots.

## Migration Note

Do not move Paperless media, consume, or export PVCs to `local-path` as the final migration target. The live cluster currently has no native Ceph RBD/CephFS storage class, and the largest node-local disks are roughly 100Gi while the declared Paperless media PVC is 250Gi. Add native Ceph-backed Kubernetes storage first, then migrate Paperless onto that storage class.
