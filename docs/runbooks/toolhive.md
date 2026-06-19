# ToolHive

ToolHive is deployed as a Kubernetes operator in the `toolhive-system`
namespace. This initial install is a pilot for central MCP management and
exposes a shared virtual MCP route for agent access.

## Components

- Helm chart source: `kubernetes/repositories/toolhive.yaml`
- CRD release: `kubernetes/infrastructure/controllers/toolhive/helmrelease-crds.yaml`
- Operator release: `kubernetes/infrastructure/controllers/toolhive/helmrelease.yaml`
- Namespace: `toolhive-system`
- Version: `0.29.3`
- Shared virtual MCP endpoint: `https://toolhive.home.mcnees.me/mcp`

The operator is configured with namespace-scoped RBAC for `toolhive-system`
only. Keep backend MCP resources and virtual MCP gateways in that namespace
unless the operator RBAC scope is intentionally expanded.

## Operations

Check Flux and Helm status:

```sh
flux --kubeconfig talos/kubeconfig get helmrelease -n toolhive-system
kubectl --kubeconfig talos/kubeconfig -n toolhive-system get pods
```

Check installed ToolHive API resources:

```sh
kubectl --kubeconfig talos/kubeconfig api-resources --api-group=toolhive.stacklok.dev
```

Check operator logs:

```sh
kubectl --kubeconfig talos/kubeconfig -n toolhive-system logs deploy/toolhive-operator
```

Check ToolHive aggregation resources:

```sh
kubectl --kubeconfig talos/kubeconfig -n toolhive-system get \
  mcpgroup,mcpserverentry,mcpexternalauthconfig,mcpoidcconfig,virtualmcpserver,svc,ingressroute
```

## Tool Aggregation

ToolHive aggregates MCP backends so Hermes, Codex, Claude, and other MCP
clients can share the same governed endpoint:

- `MCPGroup/agent-tools` defines the shared backend group.
- Gmail backends point to Google's remote Workspace MCP endpoint,
  `https://gmailmcp.googleapis.com/mcp/v1`:
  - `MCPServerEntry/gmail` is the personal Gmail account.
  - `MCPServerEntry/gmail-develop-for-good` is the Develop for Good account,
    currently in `MCPGroup/pending-agent-tools`.
  - `MCPServerEntry/gmail-hoa` is the HOA account, currently in
    `MCPGroup/pending-agent-tools`.
  - `MCPServerEntry/gmail-craft-export` is the Craft Export account,
    currently in `MCPGroup/pending-agent-tools`.
- `MCPServerEntry/outline` points to Outline at
  `https://docs.mcnees.me/mcp`, but is currently in
  `MCPGroup/pending-agent-tools`.
- `MCPServerEntry/honeydew` points to Honeydew at
  `https://mcp.honeydewdone.app`.
- `MCPServerEntry/homey` points to Homey at `https://mcp.athom.com`.
- `MCPServerEntry/linear` points to Linear at
  `https://mcp.linear.app/mcp`.
- `MCPExternalAuthConfig/gmail-google-upstream-token` injects the Google
  upstream token for the personal Gmail backend.
- `MCPExternalAuthConfig/gmail-develop-for-good-google-upstream-token`,
  `MCPExternalAuthConfig/gmail-hoa-google-upstream-token`, and
  `MCPExternalAuthConfig/gmail-craft-export-google-upstream-token` inject the
  matching Google upstream token for the additional Gmail backends, but their
  matching Google upstream providers are not listed in the active
  `VirtualMCPServer/agent-tools` auth server while those backends are pending.
- `MCPExternalAuthConfig/outline-upstream-token`,
  `MCPExternalAuthConfig/homey-upstream-token`,
  `MCPExternalAuthConfig/honeydew-upstream-token`, and
  `MCPExternalAuthConfig/linear-upstream-token` inject the matching upstream
  OAuth token for those backends.
- `VirtualMCPServer/agent-tools` publishes
  `https://toolhive.home.mcnees.me/mcp`.
- `VirtualMCPServer/agent-tools` enables ToolHive's optimizer so MCP clients
  can discover and call relevant tools on demand instead of receiving every
  backend tool definition up front.
- `Secret/gmail-mcp-auth` stores the Google upstream client secret and stable
  ToolHive signing/HMAC material. It is managed by
  `gmail-mcp-secret.sops.yaml`.

Outline and the additional Gmail accounts are cataloged as
`MCPServerEntry` resources, but they are not active in the virtual server yet.
Honeydew, Linear, and Homey are active and intentionally chain after Gmail
during first-time client auth. Outline is pending because its authorization
server rejected ToolHive's dynamically registered client during OAuth. Homey is
experimental because its OAuth metadata only advertises a `form_post` response
mode and `client_secret_basic` token authentication; ToolHive has no explicit
token endpoint auth method field, so token exchange may still fail.
The additional Gmail accounts are pending because
multiple active Google upstream providers can create a repeated consent chain
during first-time client auth. Keep only the personal `google` upstream
provider in `VirtualMCPServer/agent-tools` until multi-account Gmail auth is
reintroduced intentionally. Google upstream auth intentionally does not set a
`prompt` override, so a single active Gmail provider does not force account
selection or a fresh consent screen on every authorization hop.

The Google OAuth client used by ToolHive must allow this redirect URI:

```text
https://toolhive.home.mcnees.me/oauth/callback
```

The Gmail upstream providers request these Gmail API scopes:

- `https://www.googleapis.com/auth/gmail.readonly`
- `https://www.googleapis.com/auth/gmail.compose`
- `https://www.googleapis.com/auth/gmail.modify`
- `https://www.googleapis.com/auth/gmail.labels`

`gmail.modify` and `gmail.labels` are required because Google's Gmail MCP
server exposes label and thread/message mutation tools, not just read and draft
tools. Existing Google grants may need a fresh consent flow after scope
changes.

ToolHive's embedded auth server stores OAuth server state in a dedicated
password-protected Valkey instance:

- Deployment: `toolhive-system/toolhive-auth-valkey`
- Service: `toolhive-auth-valkey.toolhive-system.svc.cluster.local:6379`
- Password Secret: `toolhive-system/toolhive-auth-redis`

This keeps dynamically registered MCP clients and upstream provider grants
available across VMCP pod restarts. If `find_tool` returns no backend tools and
VMCP logs mention `upstream token not found`, rerun client OAuth to rebuild the
upstream grants.

If the current client is still an installed-app client, create or switch to a
Google Cloud "Web application" OAuth client with that redirect URI, then update
`gmail-mcp-secret.sops.yaml` and the inline `clientId` in `toolhive-mcp.yaml`.

## Client Direction

Hermes, Codex, Claude, and similar MCP clients should connect only to
`https://toolhive.home.mcnees.me/mcp`.

Avoid direct client MCP entries for Gmail unless temporarily debugging outside
ToolHive. Honeydew, Linear, Homey, and Outline are still direct-client
fallbacks until ToolHive can authenticate them reliably.

Hermes' current mail setup has two separate paths:

- Himalaya uses Gmail IMAP with an app password.
- Hermes MCP uses ToolHive's shared virtual MCP endpoint, which performs the
  upstream Google OAuth hop for each Gmail backend and aggregates the other
  authenticated personal MCP backends.
- Hermes registers its own MCP client callback as
  `http://127.0.0.1:47035/callback`; keep a matching `kubectl port-forward`
  open during first-time `hermes mcp login toolhive`.
