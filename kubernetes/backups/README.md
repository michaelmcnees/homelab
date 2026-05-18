# Homelab Backups

Central backup pipeline for the homelab cluster. See the design doc:
[`docs/superpowers/specs/2026-05-09-backup-strategy-restic-design.md`](../../docs/superpowers/specs/2026-05-09-backup-strategy-restic-design.md).

## Layout

| File | What |
|---|---|
| `restic-password-secret.sops.yaml` | Repo passphrase, replicated into every namespace that runs a backup job. **Set this first; the value cannot be recovered if lost.** |
| `restic-init-job.yaml` | One-shot Job that runs `restic init` against the NFS repo if not already initialized. Re-runs are idempotent. |
| `backup-metrics-exporter.yaml` | Reads the repo every 5 min, emits `homelab_backup_*` metrics on port 9618. ServiceMonitor included. |
| `backup-alerts.yaml` | `homelab.backups` PrometheusRule group. |
| `mariadb-grimmory-cronjob.yaml` | Example of an app-aware backup (dump-then-restic). |
| `mariadb-grimmory-credentials.sops.yaml` | Read-only DB user for the dump. |
| `adguard-config-backup-cronjob.yaml` | Example of a PVC-mount backup (restic the live PVC contents). |

## Onboarding a new PVC to backups

1. Copy `adguard-config-backup-cronjob.yaml` to a new file named for the PVC.
2. Update three things in the new file:
   - `metadata.name`, `metadata.labels.{app.kubernetes.io/component, homelab.mcnees.me/backup-tag}`
   - `spec.schedule` — pick a slot every 5–10 minutes apart from existing CronJobs to avoid NFS contention
   - The `--tag` and `--host` flags in the script
   - The `volumes.data.persistentVolumeClaim.claimName` — must point at the PVC in the same namespace
3. If the CronJob runs in a namespace that doesn't yet have a `restic-password` Secret, add another stanza to `restic-password-secret.sops.yaml`.
4. Add the new file to `kustomization.yaml`.
5. Commit; Flux applies; first run after the next scheduled time will populate the repo.

## Onboarding a new database

Copy `mariadb-grimmory-cronjob.yaml`. The shape is: dump first to `/tmp/dump`, then `restic backup /tmp/dump`. Adapt `mariadb-dump` to the right tool (`pg_dump`, `mysqldump`, `mongodump`, `redis-cli --rdb`, etc.).

## Recovery

```sh
# List snapshots
kubectl run -it --rm restic-shell \
  --image=restic/restic:0.18.1 --restart=Never \
  --env=RESTIC_REPOSITORY=/mnt/restic \
  --env=RESTIC_PASSWORD=$(kubectl get secret restic-password -n internal -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d) \
  --overrides='{"spec":{"volumes":[{"name":"restic","nfs":{"server":"10.0.1.1","path":"/mnt/data/backups/restic-homelab"}}],"containers":[{"name":"restic-shell","image":"restic/restic:0.18.1","stdin":true,"tty":true,"command":["sh"],"volumeMounts":[{"name":"restic","mountPath":"/mnt/restic"}]}]}}' \
  -n internal -- sh

# Inside:
restic snapshots --tag <workload>
restic restore latest --tag <workload> --target /tmp/restore
```

## Bootstrap order

1. Land `restic-password-secret.sops.yaml` first (encrypt before commit).
2. Flux applies; `restic-init` Job runs and initializes the repo.
3. CronJobs run on next schedule and populate the repo.
4. After ~6 minutes, `backup-metrics-exporter` picks up the snapshots and metrics start flowing.
5. Alerts unmute (the `BackupStale` rule has a 36h threshold so it stays quiet for the first day).

## TrueNAS-side ZFS snapshots

The bulk-data NFS shares (paperless, grimmory, romm libraries, plex media) are **not** backed up by this pipeline — they're covered by ZFS Periodic Snapshot Tasks on TrueNAS. See [docs/runbooks/truenas.md](../../docs/runbooks/truenas.md). Hourly×24 / daily×14 / weekly×8 / monthly×6 on `tank/k8s` and `tank/media`.
