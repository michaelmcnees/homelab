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
