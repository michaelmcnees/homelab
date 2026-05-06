# PostgreSQL

`metagross` is the shared PostgreSQL LXC for homelab applications. Kubernetes reaches it through the `metagross` Service in the `internal` namespace.

Application databases managed by Ansible are created with `UTF8` encoding and `C` collation/ctype from `template0`. This matters for OCR and document workloads: PostgreSQL databases created from the metagross default templates may otherwise inherit `SQL_ASCII`, which cannot store Unicode text such as smart quotes from Paperless OCR.

## Monitoring

Prometheus scrapes PostgreSQL metrics from `postgres-exporter` in the `internal` namespace. The exporter connects to metagross with the `postgres_exporter` PostgreSQL role, which is managed by `task ansible:postgresql` and granted the built-in `pg_monitor` role.

Logical backup metrics come from `postgresql-backup-metrics`, which mounts the backup PVC read-only and publishes backup age, retained backup count, latest backup size, total backup export size, and retention window gauges.

## Logical Backups

Kubernetes manages PostgreSQL logical backups with a CronJob:

- CronJob: `internal/postgresql-logical-backup`
- Schedule: `02:30` daily
- Backup PVC: `internal/postgresql-logical-backups`
- TrueNAS dataset/export: `10.0.1.1:/mnt/data/backups/postgresql`
- SSH user on metagross: `pgbackup`
- SSH secret: `internal/postgresql-logical-backup-ssh`
- Retention: 30 days

The CronJob mounts the TrueNAS NFS export, SSHes to metagross, runs PostgreSQL dump commands through the dedicated `pgbackup` user, and writes timestamped backup directories:

```text
/backups/20260506T023000Z/
  globals.sql
  manifest.tsv
  lldap.dump
  pocket_id.dump
  ...
```

Database dumps use PostgreSQL custom format (`pg_dump --format=custom`) so they can be restored with `pg_restore`. `globals.sql` captures roles and other cluster-level objects with `pg_dumpall --globals-only`.

Create a dedicated TrueNAS dataset for these backups before running the first job:

```text
data/backups/postgresql
```

Export it over NFS as `/mnt/data/backups/postgresql`. TrueNAS must allow the Talos node IPs to mount the export. The mount comes from the Kubernetes nodes, not from the Proxmox hosts. Allow either the full Kubernetes VLAN (`10.0.10.0/24`) or the current Talos node IPs on the NFS share before running the first backup job.

Bootstrap checklist:

1. Create TrueNAS dataset `data/backups/postgresql`.
2. Create a dedicated TrueNAS user/group for Kubernetes backup writers:
   - Username: `k8s-backup`
   - UID: `2000`
   - Primary group: `k8s-backup`
   - GID: `2000`
3. Set the dataset owner/group to `k8s-backup:k8s-backup` and grant write access.
4. Create an NFS share for `/mnt/data/backups/postgresql`.
5. Allow Kubernetes node clients, preferably `10.0.10.0/24`.
6. Set the NFS share mapall user/group to `k8s-backup:k8s-backup`, or otherwise preserve UID/GID `2000` write access from clients.
7. Confirm the export from a Proxmox host:

```bash
ssh root@10.0.1.100 showmount -e 10.0.1.1
```

Run a backup manually before risky migrations:

```bash
kubectl --kubeconfig talos/kubeconfig create job \
  --from=cronjob/postgresql-logical-backup \
  postgresql-logical-backup-manual-$(date +%Y%m%d%H%M%S) \
  -n internal
```

Watch the latest backup job:

```bash
kubectl --kubeconfig talos/kubeconfig get jobs -n internal -l app.kubernetes.io/name=postgresql-logical-backup
kubectl --kubeconfig talos/kubeconfig logs -n internal job/<job-name>
```

List recent backups with a temporary helper pod if needed:

```bash
kubectl --kubeconfig talos/kubeconfig run -n internal backup-shell --rm -it --restart=Never \
  --image=alpine:3.22 \
  --overrides='{"spec":{"volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"postgresql-logical-backups"}}],"containers":[{"name":"backup-shell","image":"alpine:3.22","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"backups","mountPath":"/backups"}]}]}}'
```

## Backup Alerts

Prometheus database alerts fire when:

- `postgres-exporter` is not scrapeable.
- `postgres-exporter` cannot connect to metagross PostgreSQL.
- the `openwebui` database disappears from PostgreSQL exporter metrics.
- Redis is down or missing from Redis exporter metrics.
- backup metrics are not scrapeable.
- the CronJob has no successful run.
- the last successful run is older than 36 hours.
- a backup Job fails.
- the backup PVC is over 80% full.
- incomplete `.tmp-*` backup directories remain for more than 1 hour.

The backup PVC fullness alert uses Kubernetes volume stats for `internal/postgresql-logical-backups`. The dashboard also shows exporter-derived logical backup size metrics, which are useful for trend inspection but are not a replacement for PVC capacity alerts.

## Restore One Database

Stop the consuming app before restoring its database. For Kubernetes apps, scale the deployment to zero or suspend the HelmRelease/Kustomization if needed.

Pick a backup timestamp. `latest` is a symlink, but using a concrete timestamp makes the restore repeatable:

```bash
kubectl --kubeconfig talos/kubeconfig run -n internal backup-shell --rm -it --restart=Never \
  --image=alpine:3.22 \
  --overrides='{"spec":{"volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"postgresql-logical-backups"}}],"containers":[{"name":"backup-shell","image":"alpine:3.22","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"backups","mountPath":"/backups","readOnly":true}]}]}}'

ls -la /backups
readlink /backups/latest
cat /backups/latest/manifest.tsv
exit
```

On metagross, mount the backup export read-only and create a safety copy of the current database:

```bash
ssh root@10.0.10.90 'mkdir -p /mnt/postgresql-backups && mountpoint -q /mnt/postgresql-backups || mount -o ro,nfsvers=4.2 10.0.1.1:/mnt/data/backups/postgresql /mnt/postgresql-backups'
ssh root@10.0.10.90 'sudo -u postgres pg_dump --format=custom --file=/tmp/pocket_id-before-restore.dump pocket_id'
```

Restore from the selected backup. Replace `20260506T023000Z`, `pocket_id`, and `--role=pocket_id` for the application you are restoring:

```bash
ssh root@10.0.10.90 'sudo -u postgres pg_restore --dbname=pocket_id --clean --if-exists --no-owner --role=pocket_id /mnt/postgresql-backups/20260506T023000Z/pocket_id.dump'
```

Start the app again and verify logs before deleting the `/tmp/*-before-restore.dump` safety copy.

If ownership needs repair after a restore:

```bash
ssh root@10.0.10.90 'sudo -u postgres psql --dbname=pocket_id --command="REASSIGN OWNED BY postgres TO pocket_id;"'
```

## Test Restore Into Scratch Database

Before trusting a backup after a major migration, restore one dump into a disposable database:

```bash
ssh root@10.0.10.90 'sudo -u postgres createdb --owner=pocket_id pocket_id_restore_test'
ssh root@10.0.10.90 'sudo -u postgres pg_restore --dbname=pocket_id_restore_test --no-owner --role=pocket_id /mnt/postgresql-backups/20260506T023000Z/pocket_id.dump'
ssh root@10.0.10.90 'sudo -u postgres psql --dbname=pocket_id_restore_test --command="\dt"'
ssh root@10.0.10.90 'sudo -u postgres dropdb pocket_id_restore_test'
```

This verifies that the dump file is readable without touching the live application database.

## Restore Roles

Only restore globals during full metagross rebuilds or when roles are missing. Do not run this casually against a healthy server.

```bash
ssh root@10.0.10.90 'sudo -u postgres psql --file=/mnt/postgresql-backups/20260506T023000Z/globals.sql postgres'
```

## Full Rebuild Shape

1. Recreate the metagross LXC with OpenTofu.
2. Run `task ansible:postgresql` to install PostgreSQL, users, databases, and the `pgbackup` SSH user.
3. Restore globals if needed.
4. Restore each application database from the selected timestamped backup directory.
5. Restart dependent apps one at a time.
6. Run a fresh logical backup job and confirm the CronJob records a successful run.
