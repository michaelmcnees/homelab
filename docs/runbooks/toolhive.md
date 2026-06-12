# ToolHive

ToolHive is deployed as a Kubernetes operator in the `toolhive-system`
namespace. This initial install is a pilot for central MCP management and does
exposes a Gmail virtual MCP route for shared agent access.

## Components

- Helm chart source: `kubernetes/repositories/toolhive.yaml`
- CRD release: `kubernetes/infrastructure/controllers/toolhive/helmrelease-crds.yaml`
- Operator release: `kubernetes/infrastructure/controllers/toolhive/helmrelease.yaml`
- Namespace: `toolhive-system`
- Version: `0.29.3`
- Gmail virtual MCP endpoint: `https://gmail-mcp.home.mcnees.me/mcp`

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

Check Gmail aggregation resources:

```sh
kubectl --kubeconfig talos/kubeconfig -n toolhive-system get \
  mcpgroup,mcpserverentry,mcpexternalauthconfig,mcpoidcconfig,virtualmcpserver,svc,ingressroute
```

## Gmail Aggregation

Gmail is aggregated through ToolHive so Hermes, Codex, Claude, and other MCP
clients can eventually share the same governed endpoint:

- `MCPServerEntry/gmail` points to Google's remote Workspace MCP endpoint,
  `https://gmailmcp.googleapis.com/mcp/v1`.
- `MCPExternalAuthConfig/gmail-google-upstream-token` injects the Google
  upstream access token as the backend `Authorization: Bearer` token.
- `VirtualMCPServer/gmail-mcp` publishes
  `https://gmail-mcp.home.mcnees.me/mcp`.
- `Secret/gmail-mcp-auth` stores the Google upstream client secret and stable
  ToolHive signing/HMAC material. It is managed by
  `gmail-mcp-secret.sops.yaml`.

The Google OAuth client used by ToolHive must allow this redirect URI:

```text
https://gmail-mcp.home.mcnees.me/oauth/callback
```

If the current client is still an installed-app client, create or switch to a
Google Cloud "Web application" OAuth client with that redirect URI, then update
`gmail-mcp-secret.sops.yaml` and the inline `clientId` in `gmail-mcp.yaml`.

## Hermes Direction

ToolHive is useful for centralizing MCP access for Hermes, Codex, Claude, and
other clients. Hermes' current mail setup has two separate paths:

- Himalaya uses Gmail IMAP with an app password.
- Hermes MCP uses ToolHive's Gmail virtual MCP endpoint, which performs the
  upstream Google OAuth hop and forwards to Google's first-party Workspace MCP
  endpoint.
