# Media Workflow

The current media apps still run outside Kubernetes and are exposed through temporary `ExternalName`-style service/endpoints manifests in the `apps` namespace.

## Current Routes

- Sonarr: `https://sonarr.home.mcnees.me`, internal service `http://sonarr-external.apps.svc.cluster.local:8989`
- Radarr: `https://radarr.home.mcnees.me`, internal service `http://radarr-external.apps.svc.cluster.local:7878`
- Prowlarr: `https://prowlarr.home.mcnees.me`, internal service `http://prowlarr-external.apps.svc.cluster.local:30050`
- SABnzbd: `https://sabnzbd.home.mcnees.me`, internal service `http://sabnzbd-external.apps.svc.cluster.local:30055`

Sonarr and Radarr were verified reachable from inside the Kubernetes cluster on 2026-05-06. Movies and TV shows were confirmed flowing through the full stack on 2026-05-06: request/search, SABnzbd download, import, and Plex visibility.

## Profile Management

Recyclarr is staged as a suspended Kubernetes CronJob in `kubernetes/apps/recyclarr`. It is intentionally suspended until real Sonarr and Radarr API keys are stored in the SOPS secret.

The first configuration syncs conservative TRaSH-backed baseline profiles:

- Sonarr: WEB-1080p profile, quality definition, and custom formats.
- Radarr: HD Bluray + WEB profile, quality definition, and custom formats.

This gives us repeatable profile management before we migrate the apps themselves into Kubernetes.

## Enable Recyclarr

1. In Sonarr, copy the API key from Settings -> General -> Security.
2. In Radarr, copy the API key from Settings -> General -> Security.
3. Edit the SOPS secret:

```bash
sops kubernetes/apps/recyclarr/secret.sops.yaml
```

4. Replace `CHANGE_ME_SONARR_API_KEY` and `CHANGE_ME_RADARR_API_KEY`.
5. Save the file, commit it, push, and reconcile `apps`.
6. Run one manual sync job:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps create job --from=cronjob/recyclarr recyclarr-manual-$(date +%Y%m%d%H%M%S)
kubectl --kubeconfig talos/kubeconfig -n apps logs job/<job-name> -f
```

7. If the sync output is clean, set `spec.suspend: false` on the CronJob to run nightly.

## Stability Checks

Before migrating Sonarr/Radarr into Kubernetes, validate:

- Root folders point at the intended media paths.
- Download clients use stable internal addresses.
- Prowlarr applications are synced to Sonarr/Radarr.
- Profiles are managed by Recyclarr rather than hand-edited drift.
- One Sonarr test series and one Radarr test movie can search, send to SABnzbd, import, and appear in Plex.

## Kubernetes Migration

Initial in-cluster Sonarr and Radarr scaffolding was deployed on 2026-05-06 in the `media` namespace. Traffic still goes to the legacy external services until the temporary Kubernetes routes are validated and the primary routes are cut over.

Created PostgreSQL databases on metagross:

- Sonarr: `sonarr_main`, `sonarr_log`
- Radarr: `radarr_main`, `radarr_log`

Created Kubernetes resources:

- Namespace and Flux Kustomization: `media`
- Services: `media/sonarr`, `media/radarr`
- Config PVCs: `sonarr-config`, `radarr-config`
- Shared media PVC: `media-library`, backed by `10.0.1.1:/mnt/data/media`
- Temporary validation routes: `sonarr-k8s.home.mcnees.me`, `radarr-k8s.home.mcnees.me`

Backups were imported on 2026-05-06:

- Sonarr backup: `sonarr_backup_v4.0.16.2944_2026.05.06_14.02.42.zip`
- Radarr backup: `radarr_backup_v6.0.4.10291_2026.05.06_14.02.53.zip`
- Imported files: `config.xml` and the SQLite backup database into each app's config PVC.
- The SQLite backups were loaded into the PostgreSQL main databases with `pgloader --with "quote identifiers" --with "data only"` after the apps created the PostgreSQL schema. A normal in-app backup restore does not populate PostgreSQL once the app is already running with PostgreSQL environment variables.
- Config PVC ownership and app runtime identity were aligned to UID/GID `568`, matching the TrueNAS media dataset owner seen on the `/media` NFS mount.
- Sonarr is pinned to `ghcr.io/linuxserver/sonarr:4.0.16.2944-ls298`.
- Radarr is pinned to `ghcr.io/linuxserver/radarr:6.0.4.10291-ls288`.
- PostgreSQL verification counts matched the backups: Sonarr has 1 download client, 4 indexers, 1 root folder, and 352 series; Radarr has 1 download client, 4 indexers, 1 root folder, and 1132 movies.
- Both apps started against their PostgreSQL main/log databases and returned `{"status":"OK"}` from in-cluster `/ping` checks.

Prowlarr migration started on 2026-05-06:

- Prowlarr backup: `prowlarr_backup_v2.3.4.5307_2026.05.06_17.54.21.zip`
- Prowlarr is pinned to `ghcr.io/linuxserver/prowlarr:nightly-version-2.3.4.5307`.
- The SQLite backup was loaded into `prowlarr_main` with `pgloader --with "quote identifiers" --with "data only"` after the app created its PostgreSQL schema.
- PostgreSQL verification counts matched the backup: 6 applications, 3 indexers, 1 download client, and 0 tags.
- Routes: `prowlarr.home.mcnees.me`, with temporary alias `prowlarr-k8s.home.mcnees.me`

Sonarr Anime, Lidarr, Lidarr Kids, and Bazarr were migrated on 2026-05-06:

- Backups:
  - Sonarr Anime: `sonarr_backup_v4.0.16.2944_2026.05.06_18.38.24.zip`
  - Lidarr: `lidarr_backup_v3.1.0.4875_2026.05.06_18.37.34.zip`
  - Lidarr Kids: `lidarr_backup_v3.1.0.4875_2026.05.06_18.38.11.zip`
  - Bazarr: `bazarr_backup_v1.5.5_2026.05.06_18.39.38.zip`
- Kubernetes resources live under `kubernetes/media/{sonarr-anime,lidarr,lidarr-kids,bazarr}`.
- The old temporary external routes for these four services were removed from `kubernetes/apps/external-services/temporary/kustomization.yaml`; the primary hostnames now route to the `media` namespace.
- Bazarr requires a UTF-8 PostgreSQL database. If recreating it manually, use `TEMPLATE template0 ENCODING 'UTF8'`.
- Sonarr Anime, Lidarr Kids, and Bazarr were imported with `pgloader --with "quote identifiers" --with "data only"` after the apps created PostgreSQL schemas.
- Regular Lidarr's backup is large enough to exhaust the current pgloader image heap. It was imported by exporting the SQLite backup to CSV per table, loading those files into `lidarr_main` as the `postgres` user with `session_replication_role = replica`, and resetting sequences afterwards.
- After restoring Sonarr Anime and Lidarr Kids, update their SABnzbd download-client host from the raw endpoint IP to `sabnzbd-external.apps.svc.cluster.local` and clear stale `DownloadClientStatus` rows so health checks re-evaluate cleanly.
- Sonarr Anime has one root folder under `/media/library/anime/` and two restored series still stored directly under `/media/`; both paths are backed by the shared `media-library` mount.
- Verification counts after import:
  - Sonarr Anime: 18 series, 4 indexers, 1 download client
  - Lidarr: 297 artists, 15,304 albums, 473,940 tracks, 4 indexers, 1 download client
  - Lidarr Kids: 8 artists, 210 albums, 4 indexers, 1 download client
  - Bazarr: 293 shows, 943 movies, 25,115 episode rows
- In-cluster smoke checks returned HTTP 200 for Sonarr Anime `/ping`, Lidarr `/ping`, Lidarr Kids `/ping`, and Bazarr `/`.

Remaining cutover checks:

1. Validate Sonarr Anime, Lidarr, Lidarr Kids, and Bazarr from the browser through the primary hostnames.
2. Confirm Bazarr can still talk to the in-cluster Sonarr/Radarr services and update any restored localhost app URLs if needed.
3. Shut down the old Docker host only after browser checks pass for all migrated services.
