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

## Shared Services

Tailscale can expose individual Kubernetes workloads using a `tailscale` `Ingress` or `LoadBalancer` service. Use this only when the auth story is explicit.

Default rule:

- Do not expose app pods directly if the app relies on Traefik `oauth2-proxy` middleware for auth.
- Prefer sharing services that have strong native auth, or add a dedicated auth proxy path first.
- Tailscale controls network reachability; Pocket ID/oauth2-proxy controls application access.

`shared-service-ingress.example.yaml` is a shape reference for direct service exposure. Before using it for a real app, confirm whether it should be protected by native auth or by a dedicated OAuth2-Proxy route.

For services we want Kenway to use, create an explicit Tailscale service tag such as `tag:homelab-shared-service` and keep the tailnet ACL limited to `tcp:443`.

### Kenway Arr Access

Kenway gets Tailscale-only Arr access through dedicated OAuth2-Proxy reverse proxies in `kubernetes/auth/oauth2-proxy-kenway-arr`. These proxies only allow `mike@kenway.me` and forward to the in-cluster Arr services after Pocket ID login.

Do not expose the Arr app services directly with Tailscale. The apps trust local cluster traffic, so direct exposure would bypass the auth layer.

Add these redirect URLs to the Pocket ID OAuth client used by OAuth2-Proxy:

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

## References

- Tailscale Kubernetes Operator: https://tailscale.com/docs/features/kubernetes-operator/
- Cluster ingress: https://tailscale.com/docs/features/kubernetes-operator/how-to/cluster-ingress
- Subnet routers with the operator: https://tailscale.com/docs/features/kubernetes-operator/how-to/connector
