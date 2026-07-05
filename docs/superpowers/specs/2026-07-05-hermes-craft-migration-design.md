# Hermes Craft Migration

## Context

Hermes currently reaches personal productivity systems through a single MCP
server entry named `toolhive`. ToolHive aggregates Google Workspace, Honeydew,
Linear, Outline, and Homey backends behind
`https://toolhive.home.mcnees.me/mcp`.

Outline is still deployed at `https://docs.mcnees.me`, and ToolHive currently
exposes its built-in MCP endpoint as the `outline` backend. Hermes runbook
policy says active durable-note jobs should write canonical notes and rules to
Outline.

Michael is moving notes, docs, and todo lists from Outline to Craft.do. Craft
provides an MCP endpoint URL. Treat that URL as sensitive unless Craft
documents it as non-secret.

## Goals

- Make Craft.do the canonical Hermes backend for notes, docs, and todo lists.
- Keep Hermes configured with only the shared `toolhive` MCP server.
- Stop exposing Outline as an active Hermes-discoverable docs backend.
- Keep the Outline app deployed during migration for rollback and data
  reference.
- Avoid committing the Craft MCP link in clear text if ToolHive supports a
  secret-backed configuration path.

## Non-Goals

- Decommissioning the Outline Kubernetes app.
- Migrating all existing Outline content into Craft.
- Removing the `google-craft-export` Google Workspace backend; that name refers
  to an unrelated Google account and is not Craft.do.
- Changing Hermes model, dashboard, OAuth callback, or Telegram behavior.

## Recommended Approach

Add a new ToolHive backend named `craft` that points to Craft.do's MCP endpoint,
then remove the `outline` backend from the active `agent-tools` group. Hermes
continues to connect to only `toolhive`, so no Hermes ConfigMap server entry
change is expected.

Implementation must first confirm whether `MCPServerEntry` supports referencing
the remote URL from a Kubernetes Secret. If supported, store the Craft MCP URL
in a SOPS-managed secret and reference it from the `craft` backend. If not
supported, add a small in-cluster proxy whose upstream Craft URL comes from a
SOPS secret; ToolHive points at the proxy's internal route.

## Components

- `MCPServerEntry/craft`: new ToolHive backend for Craft.do.
- `MCPServerEntry/outline`: removed from the active `agent-tools` group, or
  deleted if no pending/rollback group is useful.
- Craft URL secret: stores the full Craft MCP URL without clear-text Git
  exposure when the selected ToolHive path allows it.
- Hermes runbook: updates canonical durable-note policy from Outline to Craft.
- ToolHive runbook: documents Craft as the notes/docs/todos backend and clarifies
  that `google-craft-export` is unrelated.
- Syncthing runbook: updates the stale Hermes note access guidance from Outline
  to Craft.
- Tests: update ToolHive config assertions so Craft is expected and Outline is
  not treated as a canonical active backend.

## Data Flow

1. Hermes sends MCP requests to `https://toolhive.home.mcnees.me/mcp`.
2. ToolHive discovers and optimizes available tools across active backends.
3. Notes, docs, and todo-list requests route to the `craft` backend.
4. Outline remains available as an app outside Hermes' active ToolHive backend
   set during the migration period.

## Error Handling

- If Craft authentication or discovery fails, leave Outline deployed and either
  re-add `outline` to ToolHive temporarily or use Outline manually while fixing
  Craft.
- If ToolHive cannot store the Craft endpoint securely, use the proxy fallback
  rather than committing the sensitive MCP link.
- If Hermes has stale ToolHive OAuth/client tokens that still expose older
  backend metadata, rerun the documented Hermes ToolHive authorization flow and
  verify with `hermes mcp test toolhive`.

## Testing

- Render ToolHive manifests with `kubectl kustomize
  kubernetes/infrastructure/controllers/toolhive`.
- Run the existing Google REST MCP unit tests after updating ToolHive backend
  assertions.
- Reconcile ToolHive and verify `MCPServerEntry/craft` and
  `VirtualMCPServer/agent-tools` readiness.
- From Hermes, run `hermes mcp test toolhive` as the `hermes` user.
- Confirm Hermes can discover Craft tools and that docs/runbooks no longer tell
  active durable-note jobs to write canonical notes to Outline.

## Open Decisions Resolved

- Craft means Craft.do, not the existing `google-craft-export` Google account.
- Hermes should keep using the single ToolHive endpoint.
- Outline should remain deployed for now but should stop being the canonical
  Hermes docs backend.
