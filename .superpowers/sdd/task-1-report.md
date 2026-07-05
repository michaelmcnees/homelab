# Task 1 Report: Craft MCP Proxy

## Result

Task 1 is complete. I added the internal Craft MCP proxy, encrypted the upstream Craft.do endpoint in SOPS, and wired the new resources into the ToolHive kustomization.

## Files Changed

- `kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml`
- `kubernetes/infrastructure/controllers/toolhive/craft-mcp-secret.sops.yaml`
- `kubernetes/infrastructure/controllers/toolhive/kustomization.yaml`
- `tests/toolhive_craft_mcp_proxy_test.py`

## Verification

- `python3 -m unittest tests.toolhive_craft_mcp_proxy_test -v`
- `kubectl kustomize kubernetes/infrastructure/controllers/toolhive >/tmp/toolhive-render.yaml`
- `rg "mcp.craft.do|BJauyaGbKsA" kubernetes/infrastructure/controllers/toolhive /tmp/toolhive-render.yaml`
- `git diff --check -- kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml kubernetes/infrastructure/controllers/toolhive/craft-mcp-secret.sops.yaml kubernetes/infrastructure/controllers/toolhive/kustomization.yaml tests/toolhive_craft_mcp_proxy_test.py`

## Commit

- `e0f7ced feat(toolhive): add Craft MCP proxy`

## Notes

- The Craft.do MCP URL was kept out of cleartext repo files and only exists encrypted in `craft-mcp-secret.sops.yaml`.
- The unrelated existing edit in `kubernetes/apps/questboard/deployment.yaml` was left untouched.

## Concerns

None.

## Review Fix

### Reviewer finding addressed

`kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml` no longer relies on `response.read(65536)` for stream relay. The proxy now prefers `response.read1(65536)` when the upstream response exposes it, with a fallback to `read(65536)` only for response objects that truly lack `read1()`. That keeps streamable HTTP and SSE-style responses flowing instead of waiting for coalesced buffering.

### What changed

- Switched the relay loop to use `read1(65536)` when available, with a safe fallback for non-stream-style response objects.
- Updated the unit test to use a fake upstream response that provides `read1()` and asserts the relay path uses it rather than `read()`.
- Left the header forwarding and connection handling intact.

### Covering tests run

- `python3 -m unittest tests.toolhive_craft_mcp_proxy_test -v`  
  Result: `Ran 4 tests ... OK`
- `kubectl kustomize kubernetes/infrastructure/controllers/toolhive`  
  Result: rendered successfully with the updated proxy manifest included.
- `rg "mcp.craft.do|BJauyaGbKsA" kubernetes/infrastructure/controllers/toolhive /tmp/toolhive-render.yaml`  
  Result: no matches, so no cleartext Craft URL or token was introduced.

### Files changed

- `kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml`
- `tests/toolhive_craft_mcp_proxy_test.py`
- `.superpowers/sdd/task-1-report.md`
