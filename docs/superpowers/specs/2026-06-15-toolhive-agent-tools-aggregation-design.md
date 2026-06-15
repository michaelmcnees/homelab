# ToolHive Agent Tools Aggregation Design

## Context

ToolHive is already deployed in `toolhive-system` and exposes the shared
virtual MCP endpoint at:

```text
https://toolhive.home.mcnees.me/mcp
```

The current virtual MCP server is healthy and aggregates one backend:
Google's remote Gmail MCP server. Hermes and Codex can both reach ToolHive, but
both still have direct MCP wiring outside ToolHive:

- Hermes points Gmail at ToolHive and Outline directly at
  `https://docs.mcnees.me/mcp`.
- Codex points at ToolHive and also has a direct `outline` MCP server.
- Cursor has a direct Linear MCP configuration through `mcp-remote`.

The goal is to reduce MCP tool context by making ToolHive the single MCP
front door for Hermes, Codex, Claude, and similar clients.

## Goals

- Keep one shared ToolHive endpoint for personal agent tools.
- Aggregate compatible personal remote MCP servers into ToolHive's active
  `agent-tools` group, and keep incompatible known backends in a pending group.
- Let ToolHive's optimizer decide which tools are returned to MCP clients.
- Remove direct client-side MCP wiring once the matching ToolHive backend is
  verified, except for explicitly pending backends such as Homey.
- Keep credentials out of plaintext manifests.

## Non-Goals

- Do not split personal tools into multiple ToolHive virtual endpoints.
- Do not build a custom Homey MCP adapter; Homey already has a remote MCP
  endpoint at `https://mcp.athom.com`.
- Do not replace first-party OAuth with static tokens unless a backend cannot
  work through ToolHive's OAuth/discovery path.
- Do not expose Hermes publicly or change its dashboard security model.

## Architecture

Use the existing `MCPGroup/agent-tools` and
`VirtualMCPServer/agent-tools` for backends ToolHive can actively
authenticate. Keep incompatible backends in a separate pending group until
their auth path is understood.

Add remote MCP catalog entries for the personal tools:

| Name | Remote URL | Transport | Notes |
| --- | --- | --- | --- |
| `gmail` | `https://gmailmcp.googleapis.com/mcp/v1` | `streamable-http` | Existing Google Workspace backend with upstream token injection |
| `outline` | `https://docs.mcnees.me/mcp` | `streamable-http` | Outline built-in MCP endpoint |
| `honeydew` | `https://mcp.honeydewdone.app` | `streamable-http` | Honeydew production MCP endpoint at host root |
| `homey` | `https://mcp.athom.com` | `streamable-http` | Homey remote MCP endpoint at host root; tracked in `MCPGroup/pending-agent-tools` until ToolHive can model its `form_post` and `client_secret_basic` OAuth requirements |
| `linear` | `https://mcp.linear.app/mcp` | `streamable-http` | Linear hosted MCP endpoint |

Keep the existing `VirtualMCPServer` configuration:

- Incoming client auth remains OIDC through ToolHive's embedded auth server.
- Tool conflict resolution remains prefix-based using
  `{workload}_{tool}`.
- The optimizer remains enabled with `maxToolsToReturn: 8`.
- Outgoing auth remains discovered by default.

Gmail continues to use `MCPExternalAuthConfig/gmail-google-upstream-token`.
Outline, Honeydew, and Linear use backend-specific upstream token injection
from their ToolHive OAuth providers. Homey is a backend-specific follow-up
rather than a reason to weaken the shared gateway design.

## Client Configuration

Hermes should have one MCP server entry, pointed at ToolHive:

```yaml
mcp_servers:
  toolhive:
    url: https://toolhive.home.mcnees.me/mcp
    auth: oauth
    enabled: true
```

Codex should keep only the `toolhive` MCP server for these personal tools.
The direct `outline` entry can be removed after ToolHive validates the Outline
backend.

Claude and other clients should similarly connect to only:

```text
https://toolhive.home.mcnees.me/mcp
```

Any existing direct Linear, Honeydew, Outline, or Gmail MCP wiring should be
removed after ToolHive discovery and auth are verified. Direct Homey wiring
remains acceptable until ToolHive can authenticate Homey's MCP endpoint.

## Auth And Secrets

The existing ToolHive secret material remains the source for:

- ToolHive signing key
- ToolHive HMAC secret
- Google OAuth client secret

No new secret is required for the first aggregation pass. OAuth-backed remote
MCP servers should perform their own authorization through ToolHive's client
flow. If a backend later needs a static API key or bearer token, add a
dedicated SOPS-managed secret and reference it with `MCPExternalAuthConfig` or
`headerForward.addHeadersFromSecret`.

## Rollout Plan

1. Add the new `MCPServerEntry` resources to
   `kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml`.
2. Render the ToolHive kustomization locally with `kubectl kustomize`.
3. Reconcile ToolHive through Flux.
4. Confirm `VirtualMCPServer/agent-tools` reports seven active backends and
   `MCPServerEntry/homey` is valid in `MCPGroup/pending-agent-tools`.
5. Use ToolHive discovery from Codex to confirm tools from the aggregated
   backends are visible.
6. Update Hermes so it only points at ToolHive, and bump the deployment config
   revision so the subPath-mounted ConfigMap refreshes.
7. Remove direct Codex `outline` MCP configuration once ToolHive Outline works.
8. Update runbooks with the new single-endpoint operating model.

## Verification

Use these checks:

```sh
kubectl --kubeconfig talos/kubeconfig -n toolhive-system get \
  mcpgroup,mcpserverentry,mcpexternalauthconfig,mcpoidcconfig,virtualmcpserver,embeddingserver

kubectl --kubeconfig talos/kubeconfig -n toolhive-system describe virtualmcpserver agent-tools
```

Expected result:

- `MCPServerEntry` resources for `gmail`, `gmail-develop-for-good`,
  `gmail-hoa`, `gmail-craft-export`, `outline`, `honeydew`, `homey`, and
  `linear` are valid.
- `VirtualMCPServer/agent-tools` is ready.
- Backend count is `7` for the active virtual endpoint.
- ToolHive discovery returns tools from multiple backends without direct
  client-side MCP entries.

Hermes verification:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- \
  sh -lc 'export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:$PATH; hermes mcp test toolhive'
```

## Risks

- Remote OAuth brokering may not work uniformly for every backend on the first
  pass.
- Some backends may require first-use interactive authorization from each
  client identity.
- Tool name conflicts should be handled by the current prefix strategy, but
  prompts and docs need to use the prefixed names when referring to exact
  tools.
- The active backend count may temporarily show fewer than seven if a remote
  service is degraded or rejects unauthenticated health checks.

## Decisions

- Use one ToolHive virtual endpoint for all personal tools.
- Keep the existing `agent-tools` group for active backends, and use
  `pending-agent-tools` for known backends that should not be exposed through
  the virtual endpoint yet.
- Treat Homey as a pending remote MCP backend at `https://mcp.athom.com` until
  ToolHive can model its OAuth requirements.
- Make static token injection a fallback, not the default design.
