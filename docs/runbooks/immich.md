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
