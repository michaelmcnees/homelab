# Beszel

Beszel is deployed as the hub in the `observability` namespace and exposed at `https://beszel.home.mcnees.me` through Traefik.

The browser-facing UI route uses the shared OAuth2-Proxy middleware. The `/api` route intentionally bypasses OAuth2-Proxy because Beszel uses PocketBase APIs from the browser, including `/api/collections/users/auth-refresh`; OAuth2-Proxy redirects those API calls to Pocket ID when unauthenticated, which browser fetch treats as a cross-origin CORS failure. Keep the service internal-only and rely on Beszel's own authentication for API access.

The hub stores its PocketBase data on the `beszel-data` local-path PVC. Do not move this database to shared NFS storage unless SQLite locking behavior has been tested first.

## Agents

Beszel agents are installed manually on the hosts being monitored. Start with:

- Proxmox hosts: `latias`, `latios`, `rayquaza`
- TrueNAS VM: `snorlax`

Use the Beszel UI to add each system and copy the generated agent command. SSH-mode agents are the simplest starting point. If WebSocket/token agents are used, keep them on the internal `beszel.home.mcnees.me` route.
