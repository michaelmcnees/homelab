# Task 3 Report

Status: DONE_WITH_CONCERNS

## Summary

Updated the task runbooks to name Craft.do as Hermes' canonical notes, docs,
and todo-list backend, to describe the internal Craft MCP proxy path in
ToolHive, and to reword the Outline runbook so its MCP section is explicitly a
legacy Hermes rollback path rather than active guidance.

## Changes

- `docs/runbooks/hermes.md`
  - Replaced Outline references in the MCP summary, active backends list, and
    durable-note policy with Craft.do guidance.
  - Kept Honeydew, Linear, and Homey auth notes aligned with the brief.
- `docs/runbooks/toolhive.md`
  - Replaced the Outline MCP backend entry with `MCPServerEntry/craft`.
  - Reworded upstream token notes to describe Craft.do secrets.
  - Updated the active backend paragraph to call Craft.do the canonical notes
    backend and distinguish `google-craft-export` from Craft.do.
- `docs/runbooks/syncthing.md`
  - Replaced the Hermes notes/docs guidance with Craft.do through ToolHive.
- `docs/runbooks/outline.md`
  - Reworded the MCP section so the remaining Outline endpoint reference is
    framed as legacy rollback-only guidance for Hermes, not the canonical
    Hermes notes/docs/todo backend.

## Verification

- `rg -n "canonical notes.*Outline|Use Outline MCP|Outline MCP|docs.mcnees.me/mcp|outline-upstream-token" ...` on the touched runbooks and ToolHive controller paths initially found `docs/runbooks/outline.md`; that match has been reworded as intentional legacy/rollback-only Outline documentation for Hermes rather than active canonical guidance.
- `python3 -m unittest tests.toolhive_google_rest_mcp_test tests.toolhive_craft_mcp_proxy_test -v`: passed, 11 tests.
- `kubectl kustomize /Users/mmcnees/Developer/homelab/kubernetes/infrastructure/controllers/toolhive`: succeeded.
- `flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure --with-source`: succeeded.
- `rg -n "canonical notes.*Outline|Use Outline MCP|Outline MCP|docs.mcnees.me/mcp|outline-upstream-token" docs/runbooks kubernetes/infrastructure/controllers/toolhive tests`: the only remaining match in scope was `docs/runbooks/outline.md`, and it is now intentional legacy/rollback-only Outline documentation for Hermes rather than active canonical guidance.

## Live Cluster Findings

- `kubectl --kubeconfig talos/kubeconfig -n toolhive-system rollout status deploy/craft-mcp-proxy --timeout=120s` failed with `deployments.apps "craft-mcp-proxy" not found`.
- `kubectl --kubeconfig talos/kubeconfig -n toolhive-system get mcpserverentry craft` failed with `mcpserverentries.toolhive.stacklok.dev "craft" not found`.
- `kubectl --kubeconfig talos/kubeconfig -n toolhive-system describe virtualmcpserver agent-tools` still shows `outline` as an active upstream provider in the live resource.
- `kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- sh -lc 'su hermes -s /bin/sh -c "export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:$PATH; hermes mcp test toolhive"'` did not complete in headless mode; Hermes requested OAuth authorization and then timed out because the callback port could not bind.

## Commit

- `81a4b17` `docs(hermes): document Craft as canonical notes backend`

## Notes

- I left the unrelated `kubernetes/apps/questboard/deployment.yaml` edit untouched.
- I did not modify ToolHive YAML or tests in this task.

## Review Fix Note

Fixed the Craft MCP proxy so it strips client `Authorization` before forwarding,
returns a generic `Bad Gateway` body on upstream failures, and logs only a
redacted server-side error class/path. Updated the Craft proxy tests to cover
header stripping and the generic 502 response, and rewrote the ToolHive runbook
so ToolHive is the normal client path while Outline direct MCP is rollback or
data-reference only.

Verified with `python3 -m unittest tests.toolhive_craft_mcp_proxy_test tests.toolhive_google_rest_mcp_test -v`, `kubectl kustomize kubernetes/infrastructure/controllers/toolhive >/tmp/toolhive-render.yaml`, and the requested `rg` scans.

## Review Fix Note

Updated the Craft migration plan snippets so the proxy example strips client
`Authorization` before forwarding, returns only a generic `Bad Gateway` on
upstream failures, and no longer shows raw exception text. Also clarified in
the Craft migration plan and design that any existing Hermes ToolHive OAuth
callback work on this branch is pre-existing and outside the Craft migration
scope.
