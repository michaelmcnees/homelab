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

`kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml` no longer buffers the entire upstream response with `response.read()`. The proxy now sends upstream headers first, then relays the body in 64 KiB chunks to `wfile`, which keeps streamable HTTP and SSE-style responses flowing instead of waiting for the upstream to finish.

### What changed

- Replaced the single buffering read with chunked relay logic in the Craft MCP proxy handler.
- Preserved upstream response headers while omitting hop-by-hop headers.
- Added a focused unit test that mocks the upstream response and verifies multiple incremental reads and writes occur without buffering the whole body.

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
