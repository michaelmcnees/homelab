# ToolHive Agent Tools Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route Hermes, Codex, Claude, and related local clients through one optimized ToolHive MCP endpoint containing Gmail, Outline, Honeydew, and Linear, with Homey tracked in ToolHive as a pending backend until its OAuth flow is compatible with ToolHive upstream auth.

**Architecture:** Extend the existing `MCPGroup/agent-tools` with compatible remote `MCPServerEntry` backends, keep Homey in `MCPGroup/pending-agent-tools`, and keep the current `VirtualMCPServer/agent-tools` endpoint and optimizer. Then collapse Hermes and local client MCP configuration so they point at only `https://toolhive.home.mcnees.me/mcp`.

**Tech Stack:** Kubernetes, Flux, ToolHive CRDs, Hermes Agent, Codex config TOML, Claude Code MCP CLI, SOPS-managed secrets, Markdown runbooks.

---

## File Structure

- Modify `kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml`: add `MCPServerEntry` resources for Outline, Honeydew, Homey, and Linear; active ToolHive aggregation includes Outline, Honeydew, and Linear, while Homey is tracked in a pending group.
- Modify `kubernetes/apps/hermes/configmap.yaml`: replace direct `outline` and `gmail` MCP entries with one `toolhive` entry.
- Modify `kubernetes/apps/hermes/deployment.yaml`: bump `hermes.mcnees.me/config-revision` so the ConfigMap mounted with `subPath` refreshes.
- Modify `docs/runbooks/toolhive.md`: document all aggregated backends and single-endpoint client model.
- Modify `docs/runbooks/hermes.md`: document Hermes' single ToolHive MCP entry and updated login/test commands.
- Modify `/Users/mmcnees/.codex/config.toml`: remove the direct `[mcp_servers.outline]` block after ToolHive Outline is verified.
- Configure Claude Code with `claude mcp add --transport http --scope user toolhive https://toolhive.home.mcnees.me/mcp`; remove any direct personal-tool entries after verification.

## Task 1: Add Remote Backends To ToolHive

**Files:**
- Modify: `kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml:31`

- [ ] **Step 1: Add Outline, Honeydew, Homey, and Linear MCPServerEntry resources**

In `kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml`, insert this block immediately after the existing Gmail `MCPServerEntry`:

```yaml
---
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPGroup
metadata:
  name: pending-agent-tools
  namespace: toolhive-system
spec:
  description: MCP backends tracked for future ToolHive aggregation work.
---
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPServerEntry
metadata:
  name: outline
  namespace: toolhive-system
spec:
  groupRef:
    name: agent-tools
  remoteUrl: https://docs.mcnees.me/mcp
  transport: streamable-http
---
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPServerEntry
metadata:
  name: honeydew
  namespace: toolhive-system
spec:
  groupRef:
    name: agent-tools
  remoteUrl: https://mcp.honeydewdone.app
  transport: streamable-http
---
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPServerEntry
metadata:
  name: homey
  namespace: toolhive-system
spec:
  groupRef:
    name: pending-agent-tools
  remoteUrl: https://mcp.athom.com
  transport: streamable-http
---
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPServerEntry
metadata:
  name: linear
  namespace: toolhive-system
spec:
  groupRef:
    name: agent-tools
  remoteUrl: https://mcp.linear.app/mcp
  transport: streamable-http
```

- [ ] **Step 2: Render ToolHive manifests**

Run:

```sh
kubectl kustomize kubernetes/infrastructure/controllers/toolhive
```

Expected: command exits `0`, includes `kind: MCPServerEntry` catalog resources named `gmail`, `outline`, `honeydew`, `homey`, and `linear`, and includes `MCPGroup/pending-agent-tools` for Homey.

- [ ] **Step 3: Commit ToolHive backend catalog changes**

Run:

```sh
git add kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml
git commit -m "feat(toolhive): aggregate personal MCP backends"
```

## Task 2: Collapse Hermes MCP Config To ToolHive

**Files:**
- Modify: `kubernetes/apps/hermes/configmap.yaml:13-21`
- Modify: `kubernetes/apps/hermes/deployment.yaml:18`

- [ ] **Step 1: Replace Hermes MCP server list**

Change `kubernetes/apps/hermes/configmap.yaml` from:

```yaml
    mcp_servers:
      outline:
        url: https://docs.mcnees.me/mcp
        auth: oauth
        enabled: true
      gmail:
        url: https://toolhive.home.mcnees.me/mcp
        auth: oauth
        enabled: true
```

to:

```yaml
    mcp_servers:
      toolhive:
        url: https://toolhive.home.mcnees.me/mcp
        auth: oauth
        enabled: true
```

- [ ] **Step 2: Bump Hermes config revision**

Change `kubernetes/apps/hermes/deployment.yaml` line 18 from:

```yaml
        hermes.mcnees.me/config-revision: gpt-5.5-outline-toolhive-agent-tools-runtime
```

to:

```yaml
        hermes.mcnees.me/config-revision: gpt-5.5-toolhive-agent-tools-aggregation
```

- [ ] **Step 3: Render Hermes manifests**

Run:

```sh
kubectl kustomize kubernetes/apps/hermes
```

Expected: command exits `0`, rendered `hermes-config` contains only the `toolhive` MCP server, and the rendered Deployment contains `gpt-5.5-toolhive-agent-tools-aggregation`.

- [ ] **Step 4: Commit Hermes config changes**

Run:

```sh
git add kubernetes/apps/hermes/configmap.yaml kubernetes/apps/hermes/deployment.yaml
git commit -m "feat(hermes): use toolhive as the only MCP endpoint"
```

## Task 3: Update Runbooks

**Files:**
- Modify: `docs/runbooks/toolhive.md:48-85`
- Modify: `docs/runbooks/hermes.md:16-19`
- Modify: `docs/runbooks/hermes.md:111-179`

- [ ] **Step 1: Update ToolHive aggregation docs**

In `docs/runbooks/toolhive.md`, replace the existing `## Tool Aggregation` bullet list with:

~~~markdown
## Tool Aggregation

ToolHive aggregates MCP backends so Hermes, Codex, Claude, and other MCP
clients can share one governed endpoint:

- `MCPGroup/agent-tools` defines the shared active backend group.
- `MCPGroup/pending-agent-tools` tracks backends that are known but not active
  in the virtual endpoint yet.
- `MCPServerEntry/gmail` points to Google's remote Workspace MCP endpoint,
  `https://gmailmcp.googleapis.com/mcp/v1`.
- `MCPServerEntry/outline` points to Outline's built-in MCP endpoint,
  `https://docs.mcnees.me/mcp`.
- `MCPServerEntry/honeydew` points to Honeydew's production MCP endpoint,
  `https://mcp.honeydewdone.app`.
- `MCPServerEntry/homey` points to Homey's hosted MCP endpoint,
  `https://mcp.athom.com`, in `MCPGroup/pending-agent-tools`.
- `MCPServerEntry/linear` points to Linear's hosted MCP endpoint,
  `https://mcp.linear.app/mcp`.
- `MCPExternalAuthConfig/gmail-google-upstream-token` injects the Google
  upstream access token as the Gmail backend `Authorization: Bearer` token.
- `MCPExternalAuthConfig/outline-upstream-token`,
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
~~~

- [ ] **Step 2: Update ToolHive client guidance**

In `docs/runbooks/toolhive.md`, replace the `## Hermes Direction` section with:

~~~markdown
## Client Direction

Hermes, Codex, Claude, and similar agent clients should connect to only:

```text
https://toolhive.home.mcnees.me/mcp
```

Avoid adding direct client MCP entries for Gmail, Outline, Honeydew, or Linear
unless a backend is temporarily being debugged outside ToolHive. Homey remains
a direct-client fallback until ToolHive can authenticate it.

Hermes' current mail setup still has two separate paths:

- Himalaya uses Gmail IMAP with an app password.
- Hermes MCP uses ToolHive's shared virtual MCP endpoint, which performs the
  upstream Google OAuth hop for Gmail and aggregates the other authenticated
  personal MCP backends through the same endpoint.
~~~

- [ ] **Step 3: Update Hermes shape section**

In `docs/runbooks/hermes.md`, replace lines 16-19 with:

~~~markdown
- MCP servers:
  - ToolHive at `https://toolhive.home.mcnees.me/mcp`, aggregating Gmail,
    Outline, Honeydew, Linear, and future compatible personal MCP backends
  - Homey is cataloged in ToolHive but remains pending until its OAuth flow is
    compatible with ToolHive upstream auth.
~~~

- [ ] **Step 4: Replace Hermes MCP Servers section**

In `docs/runbooks/hermes.md`, replace the `## MCP Servers` section through the Gmail `redirect_uri_mismatch` note with:

~~~markdown
## MCP Servers

Hermes is configured with a single remote HTTP MCP server:

- Name: `toolhive`
- Endpoint: `https://toolhive.home.mcnees.me/mcp`
- Auth: OAuth
- Active backends: Gmail, Outline, Honeydew, Linear, and future personal MCP
  backends aggregated by ToolHive
- Pending backend: Homey is cataloged in ToolHive, but remains direct-client
  fallback until ToolHive can model Homey's OAuth `form_post` and
  `client_secret_basic` requirements.

After the ConfigMap is reconciled, authorize ToolHive from Hermes on first use.
Hermes persists MCP OAuth tokens on the `hermes-data` PVC and reuses them
across restarts.

Reload MCP servers from inside Hermes after config changes:

```text
/reload-mcp
```

First-time ToolHive authorization:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec -it deployment/hermes -- \
  sh -lc 'export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:$PATH; hermes mcp login toolhive'
```

Open the printed OAuth URL and complete the flow, then verify:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- \
  sh -lc 'export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:$PATH; hermes mcp test toolhive'
```

Tokens are stored under `/opt/data/mcp-tokens`. Treat those files like
credentials; do not paste or hand-edit their contents.

Gmail's upstream Google OAuth hop is mediated by ToolHive:

- ToolHive endpoint: `https://toolhive.home.mcnees.me/mcp`
- Gmail backend: `https://gmailmcp.googleapis.com/mcp/v1`
- Google scopes: `https://www.googleapis.com/auth/gmail.readonly` and
  `https://www.googleapis.com/auth/gmail.compose`
- Google upstream callback: `https://toolhive.home.mcnees.me/oauth/callback`

If Google returns `redirect_uri_mismatch`, update the OAuth client in the
Google Cloud project to allow the ToolHive callback
`https://toolhive.home.mcnees.me/oauth/callback`, then rerun
`hermes mcp login toolhive`.
~~~

- [ ] **Step 5: Commit runbook updates**

Run:

```sh
git add docs/runbooks/toolhive.md docs/runbooks/hermes.md
git commit -m "docs: document toolhive as the shared MCP endpoint"
```

## Task 4: Reconcile And Verify Cluster State

**Files:**
- No file changes.

- [ ] **Step 1: Reconcile ToolHive manifests**

Run:

```sh
flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure --with-source
```

Expected: reconciliation exits `0`.

- [ ] **Step 2: Verify ToolHive backend resources**

Run:

```sh
kubectl --kubeconfig talos/kubeconfig -n toolhive-system get \
  mcpgroup,mcpserverentry,mcpexternalauthconfig,mcpoidcconfig,virtualmcpserver,embeddingserver
```

Expected: `MCPServerEntry` rows exist for `gmail`, `outline`, `honeydew`, `homey`, and `linear`; `VirtualMCPServer/agent-tools` is `Ready`; active backend count is `4` (`gmail`, `outline`, `honeydew`, `linear`) because `homey` is in `MCPGroup/pending-agent-tools`.

- [ ] **Step 3: Inspect backend health if backend count is not 4**

Run:

```sh
kubectl --kubeconfig talos/kubeconfig -n toolhive-system describe virtualmcpserver agent-tools
```

Expected when healthy: discovered backends list includes the four active names (`gmail`, `outline`, `honeydew`, `linear`). Homey should be valid in `MCPGroup/pending-agent-tools`, not discovered by `VirtualMCPServer/agent-tools`. If an active backend is unavailable or unauthenticated, capture the backend status and continue only after deciding whether to fix auth or temporarily remove that backend.

- [ ] **Step 4: Verify Codex-visible ToolHive discovery**

From this Codex session, run ToolHive discovery for a cross-backend query:

```text
find_tool("Search email, list Honeydew home tasks, query Outline docs, and list Linear issues")
```

Expected: discovery returns tools from more than Gmail. If discovery still only returns Gmail tools, inspect `VirtualMCPServer/agent-tools` logs before removing direct client entries.

## Task 5: Reconcile And Verify Hermes

**Files:**
- No additional file changes beyond Task 2.

- [ ] **Step 1: Reconcile apps manifests**

Run:

```sh
flux --kubeconfig talos/kubeconfig reconcile kustomization apps --with-source
```

Expected: reconciliation exits `0`.

- [ ] **Step 2: Wait for Hermes rollout**

Run:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps rollout status deployment/hermes --timeout=180s
```

Expected: rollout completes successfully.

- [ ] **Step 3: Confirm mounted Hermes config**

Run:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- \
  sh -lc 'sed -n "/mcp_servers:/,/^[^ ]/p" /opt/data/config.yaml'
```

Expected output contains `toolhive:` and does not contain `outline:` or `gmail:`.

- [ ] **Step 4: Authorize ToolHive in Hermes if needed**

Run:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec -it deployment/hermes -- \
  sh -lc 'export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:$PATH; hermes mcp login toolhive'
```

Expected: if Hermes is already authorized, command reports usable auth; otherwise it prints an OAuth URL. Complete the browser flow.

- [ ] **Step 5: Test ToolHive from Hermes**

Run:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- \
  sh -lc 'export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:$PATH; hermes mcp test toolhive'
```

Expected: test succeeds. If it fails with an OAuth or backend-specific error, capture the error without printing token files.

## Task 6: Collapse Local Codex And Claude MCP Config

**Files:**
- Modify: `/Users/mmcnees/.codex/config.toml:130-131`
- Potentially modifies Claude Code user MCP config through the `claude mcp` CLI.

- [ ] **Step 1: Remove Codex direct Outline config**

Edit `/Users/mmcnees/.codex/config.toml` and delete:

```toml
[mcp_servers.outline]
url = "https://docs.mcnees.me/mcp"
```

Keep:

```toml
[mcp_servers.toolhive]
url = "https://toolhive.home.mcnees.me/mcp"
```

- [ ] **Step 2: Verify Codex config no longer includes direct Outline**

Run:

```sh
rg -n "\\[mcp_servers\\.outline\\]|docs\\.mcnees\\.me/mcp|\\[mcp_servers\\.toolhive\\]|toolhive\\.home\\.mcnees\\.me/mcp" /Users/mmcnees/.codex/config.toml
```

Expected: output includes only the ToolHive entry and no direct Outline entry.

- [ ] **Step 3: Add ToolHive to Claude Code user MCP config**

Run:

```sh
claude mcp add --transport http --scope user toolhive https://toolhive.home.mcnees.me/mcp
```

Expected: command exits `0` and reports the `toolhive` server was added or updated.

- [ ] **Step 4: List Claude MCP servers with a timeout**

Run:

```sh
ruby -rtimeout -e 'Timeout.timeout(20) { exec("claude", "mcp", "list") }'
```

Expected: output includes `toolhive`. If the command exits nonzero because the health check timed out, use:

```sh
claude mcp get toolhive
```

Expected: `claude mcp get toolhive` reports an HTTP MCP server at `https://toolhive.home.mcnees.me/mcp`.

- [ ] **Step 5: Remove known direct personal-tool Claude entries if present**

For each direct entry found by the previous step, run the matching remove command:

```sh
claude mcp remove outline
claude mcp remove gmail
claude mcp remove honeydew
claude mcp remove linear
```

Expected: only entries that exist are removed. Do not remove unrelated MCP
servers such as GitHub, Cloudflare, browser, local development servers, or
Homey while it remains the direct-client fallback.

- [ ] **Step 6: Record local config result in final summary**

Because `/Users/mmcnees/.codex/config.toml` and Claude Code user MCP config live outside the repo, do not commit these changes. Include the exact local changes in the final response.

## Task 7: Final Verification And Cleanup

**Files:**
- No required file changes.

- [ ] **Step 1: Check git status**

Run:

```sh
git status --short
```

Expected: clean repo, unless implementation intentionally stops before committing a failed or blocked task.

- [ ] **Step 2: Confirm recent commits**

Run:

```sh
git log --oneline -5
```

Expected: includes commits for ToolHive backend catalog, Hermes config, and runbook docs.

- [ ] **Step 3: Summarize verification**

Final response should include:

- ToolHive backend count and readiness.
- Hermes rollout and `hermes mcp test toolhive` result.
- Whether Codex direct Outline config was removed.
- Whether Claude Code has `toolhive` configured.
- Any backend-specific auth issues that remain.
