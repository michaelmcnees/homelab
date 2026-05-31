# Immich

Immich runs in the `apps` namespace at `https://photos.mcnees.me`.

## Components

- App: `ghcr.io/immich-app/immich-server:v2.6.3`
- Machine learning: `ghcr.io/immich-app/immich-machine-learning:v2.6.3`
- Database: dedicated `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`
- Redis-compatible queue/cache: dedicated `valkey/valkey`
- Library storage: TrueNAS NFS PVC `immich-library` mounted at `/data`
- Auth: Immich's built-in login flow

The route is intentionally not behind oauth2-proxy because the Immich mobile apps need to talk directly to the Immich API.

## Required TrueNAS Dataset

Create this dataset and NFS export before or immediately after the Flux rollout:

```text
/mnt/data/k8s/apps/immich/library
```

Export it to the Kubernetes VLAN with NFSv4 access. The Kubernetes PV expects `10.0.1.1:/mnt/data/k8s/apps/immich/library`.

## First Login

Open `https://photos.mcnees.me` and complete Immich's admin account setup. After setup, install the Immich mobile app and point it at `https://photos.mcnees.me`.

## Data Notes

Immich media lives on the TrueNAS-backed `immich-library` PV. The Postgres database intentionally uses a `local-path` PVC because Immich's database storage should stay on a normal POSIX filesystem rather than an NFS share.

## Storage

- `immich-library`: unused photo/video library rehearsal volume on TrueNAS NFS.
- `immich-postgres-data`: app database PVC on `local-path`.
- `immich-ml-cache`: machine-learning cache PVC on `local-path`.

## Backup

The `immich-library-restic-backup` CronJob runs in the `apps` namespace so it can mount the `immich-library` PVC. It mounts the library read-only and writes snapshots to the TrueNAS restic repository at `/mnt/data/backups/restic-homelab`.

Schedule: `15 8 * * *`

Snapshots use:

- tag: `immich-library`
- tag: `homelab`
- host: `immich`

The generic `BackupStale` alert covers the `immich-library` tag after the first successful snapshot is exported by `backup-metrics-exporter`; no Immich-specific alert is needed.

## Rehearsal Rule

Immich is not in use yet, so it can be used as a safe backup/restore and storage migration rehearsal before production app data moves.

Before migrating production workloads:

1. Create a successful Immich library backup on TrueNAS.
2. Restore that backup into a temporary PVC.
3. If desired, move the unused `immich-library` PVC to the selected Ceph-backed class to prove the copy and rollback steps.
4. Record the observed backup, restore, and storage-class behavior for the Paperless migration.

Example restore rehearsal:

```bash
kubectl -n apps create job --from=cronjob/immich-library-restic-backup immich-library-restic-backup-manual
kubectl -n apps wait job/immich-library-restic-backup-manual --for=condition=complete --timeout=4h
kubectl -n apps apply -f /tmp/immich-library-restic-restore-test.yaml
kubectl -n apps wait job/immich-library-restic-restore-test --for=condition=complete --timeout=4h
```

The restore test Job should mount the `restic-password` secret, the TrueNAS restic repository at `/mnt/data/backups/restic-homelab`, and a throwaway target PVC, then run:

```bash
restic restore latest --tag immich-library --host immich --target /restore
```

Run the restore test container as a non-root user, such as UID/GID `1000`, with `fsGroup: 1000`. Running restore as root can make restic treat blocked ownership changes as fatal on restore targets that do not allow `lchown`. Delete the throwaway restore Job and PVC after confirming restic can restore the latest `immich-library` snapshot.

## Rehearsal Result

2026-05-30:

- Manual backup Job: `immich-library-restic-backup-manual-20260529`
- Restic snapshot: `1059b4d8`
- Snapshot size: 80.244 MiB from 11 files
- Restore test Job: `immich-library-restic-restore-test`
- Restore result: restored 18 files/directories, 80.244 MiB, into a throwaway `local-path` PVC
- Cleanup: temporary restore Job and PVC were deleted after verification

The first restore attempt ran as root and failed because restic treated blocked `lchown` calls as fatal. The successful restore ran as UID/GID `1000` with `fsGroup: 1000`.
