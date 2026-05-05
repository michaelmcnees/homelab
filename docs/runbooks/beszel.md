# Beszel

Beszel is deployed as the hub in the `observability` namespace and exposed at `https://beszel.home.mcnees.me` through Traefik and the shared OAuth2-Proxy middleware.

The hub stores its PocketBase data on the `beszel-data` local-path PVC. Do not move this database to shared NFS storage unless SQLite locking behavior has been tested first.

## Agents

Beszel agents are installed manually on the hosts being monitored. Start with:

- Proxmox hosts: `latias`, `latios`, `rayquaza`
- TrueNAS VM: `snorlax`

Use the Beszel UI to add each system and copy the generated agent command. Prefer SSH-mode agents first, because the public UI route is protected by OAuth2-Proxy and token/WebSocket agents would need an unauthenticated agent callback path or a separate internal-only route.

If WebSocket agents are needed later, add an internal-only route for agent traffic rather than weakening the browser-facing OAuth2-Proxy route.
