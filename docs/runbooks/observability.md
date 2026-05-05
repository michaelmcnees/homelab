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

## Logs

Loki is deployed in single-binary mode for cluster logs. Grafana gets Loki as a datasource from the `grafana-loki-datasource` ConfigMap.

Alloy ships pod logs to Loki with `loki.source.kubernetes`, which tails container logs through the Kubernetes API. This avoids hostPath mounts, privileged containers, root filesystem access, and DaemonSet requirements while the cluster is still running baseline Pod Security. Alloy relabels Kubernetes discovery metadata into `namespace`, `pod`, `container`, and `job` labels for Grafana queries.

Loki's local ingestion rate is raised above the chart default to absorb the startup burst when Alloy opens log streams for all existing pods.

## Current Tradeoffs

Node-exporter is disabled in `kube-prometheus-stack` because it requires host namespaces, hostPath mounts, and host ports. The cluster baseline Pod Security policy rejects those by default. Re-enable it only after explicitly deciding whether the `observability` namespace should receive a scoped Pod Security exception for host-level metrics.

Prometheus is currently using ephemeral pod storage. A first attempt with a `local-path` PVC exposed ownership issues on `/prometheus/queries.active`. Revisit persistent Prometheus storage as a focused follow-up, ideally by testing the chart/operator-supported security context and local-path ownership behavior in isolation.
