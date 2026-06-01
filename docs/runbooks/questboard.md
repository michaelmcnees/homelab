# Questboard

Questboard runs in the `apps` namespace at
`https://questboard.home.mcnees.me`.

## Architecture

- Image: `ghcr.io/thillygooth/questboard:latest`
- Port: `8099`
- Data: `questboard-data` Ceph RBD PVC mounted at `/data`
- Route: internal Traefik `websecure` entrypoint

The container serves the built frontend with nginx and proxies `/api/*` to the
FastAPI backend in the same pod. The backend stores `state.json` and
`config.json` in `/data`.

## First Run

Open `https://questboard.home.mcnees.me` and complete the setup wizard:

1. Set the number of players.
2. Configure each hero.
3. Pick shared and solo chores.
4. Configure rewards and display settings.

## Signage Client

Once the Optiplex is configured, point its local host vars at Questboard:

```yaml
signage_url: "https://questboard.home.mcnees.me"
```

Then run:

```sh
task ansible:signage-client
```

## Useful Checks

```sh
kubectl --kubeconfig talos/kubeconfig -n apps get deploy questboard
kubectl --kubeconfig talos/kubeconfig -n apps get pvc questboard-data
kubectl --kubeconfig talos/kubeconfig -n apps logs deploy/questboard
```

The health probe uses `/api/state`, which exercises nginx and the FastAPI
backend.
