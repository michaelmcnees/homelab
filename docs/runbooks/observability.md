# Observability

## Grafana Auth

Grafana is exposed at `https://grafana.home.mcnees.me` through Traefik and the shared `oauth2-proxy` middleware.

The auth flow is:

1. Browser requests `grafana.home.mcnees.me`.
2. Traefik asks OAuth2-Proxy to authorize the request.
3. OAuth2-Proxy validates the Pocket ID session.
4. OAuth2-Proxy returns identity headers to Traefik, including `X-Auth-Request-Email`.
5. Traefik forwards those headers to Grafana.
6. Grafana auth-proxy mode uses `X-Auth-Request-Email` as the user identity and auto-creates the user.

Current bootstrap behavior assigns auto-created Grafana users the Admin org role. Tighten this after the lab is fully bootstrapped by mapping Pocket ID groups to Grafana roles or by disabling auto-admin assignment.

## Current Tradeoffs

Node-exporter is disabled in `kube-prometheus-stack` because it requires host namespaces, hostPath mounts, and host ports. The cluster baseline Pod Security policy rejects those by default. Re-enable it only after explicitly deciding whether the `observability` namespace should receive a scoped Pod Security exception for host-level metrics.

Prometheus is currently using ephemeral pod storage. A first attempt with a `local-path` PVC exposed ownership issues on `/prometheus/queries.active`. Revisit persistent Prometheus storage as a focused follow-up, ideally by testing the chart/operator-supported security context and local-path ownership behavior in isolation.

