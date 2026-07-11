# Tailscale

The lab uses a hybrid Tailscale model:

- Admin devices get broad lab access through a Kubernetes-managed subnet router.
- Shared users get access only to selected services.
- Shared services should still pass through the normal application auth path unless the app has strong native auth.

Plex, Tdarr, and SABnzbd stay on TrueNAS. Homebridge and Homey stay as LXCs. Tailscale provides reachability; it does not move those workloads.

## Bootstrap

Create a Tailscale OAuth client in the admin console under Trust credentials.

Required operator credential:

- Scopes: `Devices Core: Write`, `Auth Keys: Write`, `Services: Write`
- Tag: `tag:k8s-operator`

Update the tailnet policy before enabling the operator:

```json
{
  "groups": {
    "group:homelab-admins": ["<your-tailscale-login-email>"],
    "group:homelab-shared": ["mike@kenway.me"]
  },
  "tagOwners": {
    "tag:k8s-operator": ["group:homelab-admins"],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:homelab-admin-router": ["tag:k8s-operator"],
    "tag:homelab-shared-service": ["tag:k8s-operator"]
  },
  "autoApprovers": {
    "routes": {
      "10.0.0.0/22": ["tag:homelab-admin-router"],
      "10.0.10.0/24": ["tag:homelab-admin-router"],
      "10.0.20.0/24": ["tag:homelab-admin-router"],
      "10.0.30.0/24": ["tag:homelab-admin-router"],
      "10.0.40.0/24": ["tag:homelab-admin-router"],
      "10.0.50.0/24": ["tag:homelab-admin-router"]
    }
  },
  "grants": [
    {
      "src": ["group:homelab-admins"],
      "dst": ["10.0.0.0/22:*", "10.0.10.0/24:*", "10.0.20.0/24:*", "10.0.30.0/24:*", "10.0.40.0/24:*", "10.0.50.0/24:*"],
      "ip": ["*"]
    },
    {
      "src": ["group:homelab-shared"],
      "dst": ["tag:homelab-shared-service"],
      "ip": ["tcp:443"]
    }
  ]
}
```

Replace the example emails with real Tailscale identities before saving the policy.

Then edit the operator secret:

```bash
SOPS_AGE_KEY_FILE=homelab.age.key sops kubernetes/infrastructure/controllers/tailscale-operator/secret.sops.yaml
```

Set:

- `stringData.client_id`
- `stringData.client_secret`

Enable the HelmRelease by removing `spec.suspend: true` from `kubernetes/infrastructure/controllers/tailscale-operator/helmrelease.yaml`, then reconcile:

```bash
flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure --with-source
```

Validate:

```bash
kubectl --kubeconfig talos/kubeconfig get pods -n tailscale
kubectl --kubeconfig talos/kubeconfig get ingressclass tailscale
```

The operator should also appear as `homelab-k8s-operator` in the Tailscale Machines page.

## Admin Subnet Router

After the operator is healthy, copy `kubernetes/infrastructure/controllers/tailscale-operator/homelab-subnet-router.example.yaml` to `homelab-subnet-router.yaml`, add it to the local `kustomization.yaml`, and reconcile.

The router advertises:

- `10.0.0.0/22`
- `10.0.10.0/24`
- `10.0.20.0/24`
- `10.0.30.0/24`
- `10.0.40.0/24`
- `10.0.50.0/24`

If auto-approval is not active, approve the advertised routes in the Machines page. iOS and iPadOS clients accept subnet routes by default once the tailnet permits them.

After changing tag ownership in the tailnet policy, the operator usually retries automatically. If a `Connector` remains stuck with `requested tags [...] are invalid or not permitted`, force a reconcile:

```bash
kubectl --kubeconfig talos/kubeconfig annotate connector homelab-subnet-router tailscale.mcnees.me/retry-at="$(date -u +%Y%m%d%H%M%S)" --overwrite
```

### High Availability

The subnet router should run with `spec.replicas: 2` so a single worker loss does not remove admin access to lab subnets. Both generated Tailscale devices must advertise the same routes. Route auto-approval should be handled by `tag:homelab-admin-router`, but confirm the generated devices are approved in the Tailscale admin console after changes.

Legacy shared Kenway ingress proxies use the `homelab-shared-ingress` `ProxyGroup` with two replicas. Each Tailscale `Ingress` in `kubernetes/auth/oauth2-proxy-kenway-arr` should set:

```yaml
tailscale.com/proxy-group: homelab-shared-ingress
```

Failover drill:

```bash
kubectl --kubeconfig talos/kubeconfig cordon lugia
kubectl --kubeconfig talos/kubeconfig get pods -n tailscale -o wide
kubectl --kubeconfig talos/kubeconfig delete pod -n tailscale <one-subnet-router-pod>
kubectl --kubeconfig talos/kubeconfig delete pod -n tailscale <one-shared-ingress-proxy-pod>
kubectl --kubeconfig talos/kubeconfig get pods -n tailscale -o wide
kubectl --kubeconfig talos/kubeconfig uncordon lugia
```

During the drill, verify admin subnet access plus the shared portal. Do not leave `lugia` cordoned after the test.

## Shared Services

Tailscale can expose individual Kubernetes workloads using a `tailscale` `Ingress` or `LoadBalancer` service. Use this only when the auth story is explicit.

Default rule:

- Do not expose app pods directly if the app relies on Traefik `oauth2-proxy` middleware for auth.
- Prefer sharing services that have strong native auth, or add a dedicated auth proxy path first.
- Tailscale controls network reachability; Pocket ID/oauth2-proxy controls application access.

`shared-service-ingress.example.yaml` is a shape reference for direct service exposure. Before using it for a real app, confirm whether it should be protected by native auth or by a dedicated OAuth2-Proxy route.

For services we want Kenway to use, create an explicit Tailscale service tag such as `tag:homelab-shared-service` and keep the tailnet ACL limited to `tcp:443`.

### Shared Portal

The target shared-user path is `portal.mcnees.me`, backed by the custom `tsnet` app in `services/tailscale-shared-portal` and the Kubernetes manifests in `kubernetes/auth/tailscale-shared-portal`.

This path uses Tailscale as authentication. Pocket ID is intentionally not in the request path. The portal authorizes each Tailscale identity against `tailscale-shared-portal-config`, renders only the apps allowed for that identity, and proxies allowed `/app/<name>` paths to in-cluster Services.

Build and push the portal image:

```bash
cd services/tailscale-shared-portal
docker build -t ghcr.io/michaelmcnees/homelab/shared-portal:0.1.0 .
docker push ghcr.io/michaelmcnees/homelab/shared-portal:0.1.0
```

Create a reusable Tailscale auth key in the admin console if the portal has not already enrolled. The key should be reusable, non-ephemeral, and allowed to advertise `tag:homelab-shared-service`. Store it manually in the cluster:

```bash
kubectl --kubeconfig talos/kubeconfig -n auth create secret generic shared-portal-tsnet-auth \
  --from-literal=TS_AUTHKEY='tskey-auth-...'
```

If the portal already has stable state in `tailscale-shared-portal-state`, the auth key is ignored by `tsnet` and can be rotated without changing the machine identity.

Deploy or reconcile:

```bash
flux --kubeconfig talos/kubeconfig reconcile kustomization auth --with-source
```

Wait for the pod and certificate:

```bash
kubectl --kubeconfig talos/kubeconfig -n auth rollout status deploy/tailscale-shared-portal
kubectl --kubeconfig talos/kubeconfig -n auth get certificate tailscale-shared-portal
kubectl --kubeconfig talos/kubeconfig -n auth logs deploy/tailscale-shared-portal
```

Confirm the machine appears in Tailscale as `shared-portal`, then get its Tailscale IPv4 address from the Machines page or with:

```bash
tailscale status | grep shared-portal
```

Create or update public DNS:

```text
portal.mcnees.me A <shared-portal-tailscale-ipv4>
```

Do not proxy this DNS record through Cloudflare and do not create a public Traefik route for it. The record may be public, but it points at a Tailscale IP that only Tailscale clients can reach.

Share the `shared-portal` machine with Kenway from the Tailscale Machines page.

Validate from a shared Tailscale client:

```bash
curl -Ik https://portal.mcnees.me/
curl -Ik https://portal.mcnees.me/app/sonarr/
curl -Ik https://portal.mcnees.me/app/lidarr/
```

Expected behavior:

- `/` returns the dashboard after Tailscale identity is verified.
- Allowed app paths proxy to the Arr app.
- Known users without app access get `404` for that app path.
- Unknown Tailscale identities get `403`.
- Non-Tailscale clients cannot connect to `portal.mcnees.me`.

Before adding another shared user, verify the identity string shown in the portal logs:

```bash
kubectl --kubeconfig talos/kubeconfig -n auth logs deploy/tailscale-shared-portal | jq .
```

Then update `kubernetes/auth/tailscale-shared-portal/configmap.yaml` with the exact Tailscale login name or a stable `node:<id>` key and reconcile `auth`.

### Kenway Arr Access

The old Kenway Arr path used dedicated OAuth2-Proxy reverse proxies in `kubernetes/auth/oauth2-proxy-kenway-arr`. Keep these manifests only until the shared portal is validated end to end.

Do not expose the Arr app services directly with Tailscale. The apps trust local cluster traffic, so direct exposure would bypass the shared portal's authorization layer.

Legacy redirect URLs that were required by the old Pocket ID/OAuth2-Proxy path:

- `https://kenway-sonarr.halfbeak-chimaera.ts.net/oauth2/callback`
- `https://kenway-sonarr-anime.halfbeak-chimaera.ts.net/oauth2/callback`
- `https://kenway-radarr.halfbeak-chimaera.ts.net/oauth2/callback`
- `https://kenway-lidarr.halfbeak-chimaera.ts.net/oauth2/callback`
- `https://kenway-lidarr-kids.halfbeak-chimaera.ts.net/oauth2/callback`
- `https://kenway-bazarr.halfbeak-chimaera.ts.net/oauth2/callback`
- `https://kenway-prowlarr.halfbeak-chimaera.ts.net/oauth2/callback`

Shared URLs:

- `https://kenway-sonarr.halfbeak-chimaera.ts.net`
- `https://kenway-sonarr-anime.halfbeak-chimaera.ts.net`
- `https://kenway-radarr.halfbeak-chimaera.ts.net`
- `https://kenway-lidarr.halfbeak-chimaera.ts.net`
- `https://kenway-lidarr-kids.halfbeak-chimaera.ts.net`
- `https://kenway-bazarr.halfbeak-chimaera.ts.net`
- `https://kenway-prowlarr.halfbeak-chimaera.ts.net`

After `https://portal.mcnees.me/` works for Kenway, remove the old per-app shared Tailscale Services and the `oauth2-proxy-kenway-arr` kustomization from `kubernetes/auth/kustomization.yaml`.

## References

- Tailscale Kubernetes Operator: https://tailscale.com/docs/features/kubernetes-operator/
- Cluster ingress: https://tailscale.com/docs/features/kubernetes-operator/how-to/cluster-ingress
- Subnet routers with the operator: https://tailscale.com/docs/features/kubernetes-operator/how-to/connector
