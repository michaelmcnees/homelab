# Tailscale Shared Portal Design

## Context

Kenway access currently depends on Tailscale machine sharing rather than
inviting Kenway into the tailnet as a normal user. That distinction matters:
Tailscale machine sharing is intended for users outside the tailnet, while
Tailscale Services created by the Kubernetes Operator's ProxyGroup model are
tailnet resources controlled by `svc:<name>` grants.

The earlier Kenway Arr design explored per-app Tailscale Ingresses and then a
single shared host with one port per app. That shape works as a transport
escape hatch, but it is not a good user experience and it still leaks
implementation details into the URLs.

The preferred direction is a real-domain portal:

```text
portal.mcnees.me
```

This portal is not public internet access. Public DNS points the hostname at
the portal machine's Tailscale IP, so non-Tailscale clients fail to connect.
Shared Tailscale users can connect because the portal machine is explicitly
shared with them in Tailscale.

The key product decision is that Tailscale is the authentication layer for this
portal. Pocket ID should not be required on this path.

## Relevant Tailscale Constraints

- Tailscale machine sharing is the right primitive for external shared users.
  A shared user accepts access to a specific machine rather than becoming a
  normal user in the owner tailnet.
- Tailscale Kubernetes Operator ProxyGroup ingress creates Tailscale Services.
  That model is useful for tailnet-native access, but it does not match the
  machine-sharing workflow.
- Tailscale LocalAPI can identify the source node/user for an incoming tailnet
  request. This is the primary identity mechanism for `portal.mcnees.me`.
- Tailscale Serve can inject identity headers for tailnet traffic, including
  traffic from external users who accepted a machine share. However, Serve DNS
  names are restricted to the tailnet domain, so Serve identity headers are not
  the primary design for a custom hostname like `portal.mcnees.me`.

References:

- Tailscale machine sharing: https://tailscale.com/docs/features/sharing
- Inviting users vs sharing devices: https://tailscale.com/docs/reference/inviting-vs-sharing
- Tailscale identity and LocalAPI: https://tailscale.com/docs/concepts/tailscale-identity
- Tailscale Serve identity headers and limitations: https://tailscale.com/docs/features/tailscale-serve
- Kubernetes Operator ingress creates Services: https://tailscale.com/docs/kubernetes-operator/ingress

## Goals

- Provide one polished entrypoint for shared users:
  `portal.mcnees.me`.
- Keep the portal internal-only by pointing DNS at a Tailscale IP.
- Use Tailscale identity as authentication for shared users.
- Authorize each shared user against an explicit allowed-apps config.
- Render a small bookmarks dashboard listing only the apps the caller can use.
- Proxy app traffic through subpaths such as `/app/sonarr`.
- Keep shared users out of Pocket ID for these internal-only services.
- Make the sharing layer reusable for more shared users and services later.

## Non-Goals

- Do not expose `portal.mcnees.me` through public Traefik or Cloudflare ingress.
- Do not require Pocket ID for shared Tailscale users.
- Do not invite shared users as normal tailnet users just to access these apps.
- Do not expose the Arr app services directly to Tailscale.
- Do not build a general public SSO portal.
- Do not solve every app's subpath behavior in the first pass if an app needs
  special handling.

## Recommended Approach

Build a small custom portal application and expose it as a dedicated,
shareable Tailscale machine.

The portal owns three responsibilities:

1. Identify the connecting Tailscale user or node through LocalAPI/whois.
2. Authorize that identity against a declarative shared-user/app config.
3. Render the dashboard and reverse-proxy allowed `/app/<name>` routes.

Use public DNS for `portal.mcnees.me` with an `A` record pointing at the
portal machine's Tailscale IPv4 address. Add an `AAAA` record only if the
portal machine's Tailscale IPv6 address is confirmed stable and useful for the
shared-user path.

Use DNS-01 certificate issuance for `portal.mcnees.me` if HTTPS is required.
Because the hostname resolves to a Tailscale IP, HTTP-01 validation should not
be assumed to work from the public internet. If the first iteration uses HTTP,
document clearly that transport is still encrypted by Tailscale's WireGuard
tunnel, but prefer HTTPS for browser polish and fewer mixed-content surprises.

## Components

### Portal App

A small HTTP service, preferably Go for simple static binaries and straightforward
reverse-proxy support.

Responsibilities:

- Serve `GET /` as a dashboard.
- Serve static portal assets under `/_portal/*`.
- Route `/app/<name>` and `/app/<name>/...` to configured upstreams.
- Call Tailscale LocalAPI/whois for the connecting peer identity.
- Enforce per-user app permissions before rendering or proxying.
- Emit structured request logs.

The app must not trust caller-supplied identity headers. If an implementation
later uses Tailscale Serve identity headers, the backend must listen only on
localhost behind Serve, matching Tailscale's documented spoofing guidance.

### Tailscale Portal Machine

A dedicated Tailscale node named `portal` or `shared-portal`.

Requirements:

- It must be a shareable machine in the Tailscale Machines page.
- It must not be a ProxyGroup-backed Tailscale Service.
- It should use a stable Tailscale identity and state so the shared machine and
  DNS record do not churn unnecessarily.
- It should carry a tag such as `tag:homelab-shared-service`.

Implementation options to validate during planning:

- A portal pod with a `tailscaled` sidecar and stable state secret.
- A `tsnet`-based Go portal that owns the Tailscale node directly.
- A standalone operator-created LoadBalancer only if it preserves enough source
  identity for LocalAPI/whois. If it hides the source behind a proxy pod, reject
  it for this design.

### Access Config

Use a declarative config map. Keep the shape simple:

```yaml
users:
  mike@kenway.me:
    displayName: Mike
    apps:
      - sonarr
      - radarr
      - prowlarr

apps:
  sonarr:
    label: Sonarr
    path: /app/sonarr
    upstream: http://sonarr.media.svc.cluster.local:8989
  radarr:
    label: Radarr
    path: /app/radarr
    upstream: http://radarr.media.svc.cluster.local:7878
```

The matching key should be the Tailscale login name when available. If shared
machine identity data differs for external users, add explicit support for
stable node IDs or DNS names before rollout rather than weakening matching to
display names.

### DNS And Certificates

`portal.mcnees.me` points to the portal machine's Tailscale IP.

Expected behavior:

- Tailscale-connected shared user: hostname resolves, connection succeeds.
- Non-Tailscale user: hostname resolves to a non-routable Tailscale IP from
  their perspective, connection fails.

If HTTPS is used, issue the certificate with DNS-01 through the existing
Cloudflare/cert-manager pattern. Do not put the portal behind public Traefik
just to obtain a certificate.

## Request Flow

### Dashboard

1. Browser requests `GET /`.
2. Portal identifies the Tailscale caller through LocalAPI/whois.
3. Portal looks up the caller in the shared-user config.
4. If authorized, portal renders a compact dashboard with only allowed apps.
5. If not authorized, portal returns `403`.

### App Proxy

1. Browser requests `GET /app/sonarr/...`.
2. Portal identifies the Tailscale caller.
3. Portal confirms the caller has `sonarr` access.
4. Portal strips the `/app/sonarr` prefix according to app config.
5. Portal proxies the request to `sonarr.media.svc.cluster.local:8989`.
6. Response streams back through the portal.

For `/app/<name>` without a trailing slash, redirect to `/app/<name>/`.

## Subpath Compatibility

The desired user-facing shape is subpaths:

```text
https://portal.mcnees.me/app/sonarr
https://portal.mcnees.me/app/radarr
```

The Arr apps may need explicit URL base configuration to behave correctly under
subpaths. The implementation plan must include a compatibility spike before
changing production app settings.

Rules for the spike:

- Test each target app under `/app/<name>/` without changing global app config.
- Prefer proxy headers and prefix handling if the app supports them.
- Do not globally change an Arr app's URL base if that breaks existing internal
  routes.
- If a specific app cannot safely run under a subpath, use a portal-controlled
  compatibility fallback for that app, such as an app-specific shared hostname
  or hidden port, while keeping the dashboard as the main entrypoint.

## Security Model

- Tailscale connectivity is authentication.
- The portal config is authorization.
- The portal machine is the only shared Tailscale machine for these apps.
- The portal app should be the only component allowed to reach shared app
  upstreams on behalf of shared users.
- Unknown Tailscale identity returns `403`.
- Known identity without app access returns `404` for app paths, so unauthorized
  app names are not confirmed.
- LocalAPI/whois failure returns `503`.
- Upstream failure returns `502`.
- All decisions are logged with identity, app, method, path, decision, and
  status. Do not log cookies or sensitive headers.

## Operations

Manual operating steps:

1. Deploy the portal machine.
2. Confirm the Tailscale IP.
3. Create or update the public DNS record for `portal.mcnees.me`.
4. Share the portal machine with each external user from the Tailscale Machines
   page.
5. Add each shared user to the portal config with explicit app permissions.

Rollback:

- Remove or disable the portal DNS record.
- Stop sharing the portal machine.
- Remove the portal app deployment.
- Existing internal app routes remain unaffected.

The earlier `oauth2-proxy-kenway-arr` manifests should be retired once the
portal is verified, because this design proxies directly to in-cluster app
Services after Tailscale authorization.

## Testing

Unit tests:

- Config parsing.
- Identity matching.
- Dashboard app filtering.
- Authorization decisions.
- Path normalization and prefix stripping.

Handler tests:

- `/` for known and unknown users.
- `/app/<name>` redirects to trailing slash.
- Authorized app proxy path.
- Unauthorized app path returns `404`.
- Unknown app path returns `404`.
- LocalAPI failure returns `503`.
- Upstream failure returns `502`.

Cluster validation:

- Render manifests with `kubectl kustomize`.
- Server-side dry-run the portal manifests.
- Confirm the portal machine appears in Tailscale.
- Confirm `portal.mcnees.me` resolves to the Tailscale IP.
- From an unshared/non-Tailscale client, confirm the portal is unreachable.
- From a shared Tailscale user, confirm the dashboard renders and only allowed
  apps appear.
- Confirm an unauthorized app path is denied.

## Risks

- The Kubernetes Operator LoadBalancer path may not preserve enough source
  identity for LocalAPI/whois. If so, use a sidecar or `tsnet` implementation.
- HTTPS on a custom hostname needs DNS-01 certificate management because the
  host is intentionally not reachable from the public internet.
- Some Arr apps may not behave cleanly under subpaths without URL base changes.
- Tailscale machine sharing and DNS records depend on stable Tailscale machine
  identity; ephemeral node behavior would be bad here.
- External shared-user identity fields should be verified before relying on one
  string shape in config.

## Decisions

- `portal.mcnees.me` is Tailscale-only.
- Public DNS may point at a Tailscale IP.
- Tailscale, not Pocket ID, authenticates shared users.
- Authorization is a declarative shared-user/app config.
- The portal should support multiple shared users from day one.
- The preferred user experience is a dashboard plus `/app/<name>` subpaths.
- Per-app hostnames or ports are compatibility fallbacks, not the target UX.
