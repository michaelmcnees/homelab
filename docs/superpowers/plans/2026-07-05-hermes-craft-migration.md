# Hermes Craft Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Hermes' canonical notes, docs, and todo-list backend from Outline to Craft.do through ToolHive without exposing the Craft MCP link in clear text Git.

**Architecture:** Hermes continues to use a single `toolhive` MCP server. ToolHive gets a new `craft` backend that points at an internal `craft-mcp-proxy` Service; the proxy reads the real Craft.do MCP URL from a SOPS-managed Secret and forwards streamable HTTP MCP requests upstream. Outline remains deployed but is removed from the active ToolHive agent backend set.

**Tech Stack:** Kubernetes manifests, ToolHive `MCPServerEntry`/`VirtualMCPServer`, SOPS-encrypted Secret, Python 3.13 Alpine proxy, `unittest`, `kubectl kustomize`.

## Global Constraints

- Treat the Craft.do MCP endpoint URL as sensitive.
- Do not commit the Craft.do MCP endpoint URL in clear text.
- Keep Hermes configured with only the shared `toolhive` MCP server.
- Keep the Outline Kubernetes app deployed during migration for rollback and data reference.
- Do not remove the unrelated `google-craft-export` Google Workspace backend.
- Do not change Hermes model, dashboard, OAuth callback, or Telegram behavior.
- This Craft migration does not introduce additional Hermes callback changes.
  If this branch already contains earlier ToolHive OAuth callback work such as
  a `redirect_port` tweak or callback reuse patch, treat that as pre-existing
  and outside Craft migration scope.

---

## File Structure

- `kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml`: new ConfigMap, Deployment, and Service for the internal Craft MCP proxy.
- `kubernetes/infrastructure/controllers/toolhive/craft-mcp-secret.sops.yaml`: new SOPS-managed Secret containing `CRAFT_MCP_UPSTREAM`.
- `kubernetes/infrastructure/controllers/toolhive/kustomization.yaml`: include the new proxy and secret resources.
- `kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml`: replace the active `outline` backend with a `craft` backend pointing at the proxy Service.
- `tests/toolhive_craft_mcp_proxy_test.py`: unit tests that extract and exercise the proxy server code.
- `tests/toolhive_google_rest_mcp_test.py`: update ToolHive backend assertions so Craft is expected and Outline is no longer canonical.
- `docs/runbooks/hermes.md`: update Hermes' MCP and durable-note policy guidance.
- `docs/runbooks/toolhive.md`: document Craft.do as the notes/docs/todos backend and clarify `google-craft-export`.
- `docs/runbooks/syncthing.md`: update the stale Hermes note-access reference from Outline to Craft.

### Task 1: Add the Craft MCP Proxy

**Files:**
- Create: `kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml`
- Create: `kubernetes/infrastructure/controllers/toolhive/craft-mcp-secret.sops.yaml`
- Modify: `kubernetes/infrastructure/controllers/toolhive/kustomization.yaml`
- Create: `tests/toolhive_craft_mcp_proxy_test.py`

**Interfaces:**
- Consumes: `CRAFT_MCP_UPSTREAM` from Secret `toolhive-system/craft-mcp-upstream`.
- Produces: internal HTTP service `http://craft-mcp-proxy.toolhive-system.svc.cluster.local:8080/mcp` for ToolHive.

- [ ] **Step 1: Write the failing proxy tests**

Create `tests/toolhive_craft_mcp_proxy_test.py`:

```python
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml"


def extract_server(source):
    lines = source.read_text().splitlines()
    start = None
    for index, line in enumerate(lines):
        if line == "  server.py: |":
            start = index + 1
            break
    if start is None:
        raise AssertionError("server.py block not found")

    body = []
    for line in lines[start:]:
        if line == "---":
            break
        if line.startswith("    "):
            body.append(line[4:])
        elif line:
            raise AssertionError(f"unexpected server.py indentation: {line!r}")
        else:
            body.append("")
    return "\n".join(body) + "\n"


def load_server():
    path = Path(tempfile.mkdtemp()) / "server.py"
    path.write_text(extract_server(SOURCE))
    spec = importlib.util.spec_from_file_location("toolhive_craft_mcp_proxy", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class CraftMcpProxyTest(unittest.TestCase):
    def setUp(self):
        self.server = load_server()

    def test_upstream_url_requires_secret_env(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "CRAFT_MCP_UPSTREAM"):
                self.server.upstream_url("/mcp")

    def test_upstream_url_preserves_request_path_and_query(self):
        with mock.patch.dict(
            os.environ,
            {"CRAFT_MCP_UPSTREAM": "https://mcp.example.test/links/token/mcp"},
            clear=True,
        ):
            result = self.server.upstream_url("/mcp?session=abc")

        self.assertEqual("https://mcp.example.test/links/token/mcp?session=abc", result)

    def test_hop_by_hop_headers_are_not_forwarded(self):
        headers = self.server.forward_headers(
            {
                "Authorization": "Bearer incoming-token",
                "Connection": "keep-alive",
                "Host": "craft-mcp-proxy",
                "Content-Type": "application/json",
            }
        )

        self.assertEqual("application/json", headers["Content-Type"])
        self.assertNotIn("Authorization", headers)
        self.assertNotIn("Connection", headers)
        self.assertNotIn("Host", headers)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the failing proxy tests**

Run:

```sh
python -m unittest tests.toolhive_craft_mcp_proxy_test -v
```

Expected: fails because `kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml` does not exist yet.

- [ ] **Step 3: Add the proxy manifest**

Create `kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: craft-mcp-proxy
  namespace: toolhive-system
data:
  server.py: |
    import os
    import urllib.parse
    import urllib.request
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    HOP_BY_HOP_HEADERS = {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "host",
    }

    def upstream_url(path):
        upstream = os.environ.get("CRAFT_MCP_UPSTREAM", "").strip()
        if not upstream:
            raise RuntimeError("CRAFT_MCP_UPSTREAM is required")
        parsed = urllib.parse.urlsplit(upstream)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise RuntimeError("CRAFT_MCP_UPSTREAM must be an absolute HTTP(S) URL")
        incoming = urllib.parse.urlsplit(path)
        base = urllib.parse.urlsplit(upstream)
        return urllib.parse.urlunsplit(
            (base.scheme, base.netloc, base.path, incoming.query, "")
        )

    def forward_headers(headers):
        forwarded = {}
        for key, value in headers.items():
            if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "authorization":
                forwarded[key] = value
        return forwarded

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.proxy()

        def do_POST(self):
            self.proxy()

        def proxy(self):
            try:
                length = int(self.headers.get("Content-Length", "0") or "0")
                body = self.rfile.read(length) if length else None
                request = urllib.request.Request(
                    upstream_url(self.path),
                    data=body,
                    method=self.command,
                    headers=forward_headers(self.headers),
                )
                with urllib.request.urlopen(request, timeout=120) as response:
                    self.send_response(response.status)
                    for key, value in response.headers.items():
                        if key.lower() not in HOP_BY_HOP_HEADERS:
                            self.send_header(key, value)
                    self.end_headers()
                    reader = getattr(response, "read1", response.read)
                    while True:
                        chunk = reader(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
            except Exception as exc:
                print(f"proxy error: {exc.__class__.__name__} on {self.path}", flush=True)
                body = b"Bad Gateway"
                self.send_response(502)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        def log_message(self, fmt, *args):
            print(fmt % args, flush=True)

    if __name__ == "__main__":
        port = int(os.environ.get("PORT", "8080"))
        ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: craft-mcp-proxy
  namespace: toolhive-system
  labels:
    app.kubernetes.io/name: craft-mcp-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: craft-mcp-proxy
  template:
    metadata:
      annotations:
        craft-mcp-proxy.mcnees.me/config-revision: initial
      labels:
        app.kubernetes.io/name: craft-mcp-proxy
    spec:
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: craft-mcp-proxy
          image: python:3.13-alpine
          imagePullPolicy: IfNotPresent
          command:
            - python
            - /app/server.py
          env:
            - name: CRAFT_MCP_UPSTREAM
              valueFrom:
                secretKeyRef:
                  name: craft-mcp-upstream
                  key: CRAFT_MCP_UPSTREAM
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 15
            periodSeconds: 30
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: app
              mountPath: /app
              readOnly: true
      volumes:
        - name: app
          configMap:
            name: craft-mcp-proxy
---
apiVersion: v1
kind: Service
metadata:
  name: craft-mcp-proxy
  namespace: toolhive-system
  labels:
    app.kubernetes.io/name: craft-mcp-proxy
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: craft-mcp-proxy
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
```

- [ ] **Step 4: Add the encrypted Craft upstream Secret**

Create `kubernetes/infrastructure/controllers/toolhive/craft-mcp-secret.sops.yaml` as a SOPS-encrypted Secret. Start with this structure in the `sops` editor, set `CRAFT_MCP_UPSTREAM` to the Craft.do MCP endpoint from the approved migration request in this thread, then save directly from `sops`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: craft-mcp-upstream
  namespace: toolhive-system
stringData:
  CRAFT_MCP_UPSTREAM: set-this-only-inside-sops
```

Run:

```sh
SOPS_AGE_KEY_FILE=homelab.age.key sops kubernetes/infrastructure/controllers/toolhive/craft-mcp-secret.sops.yaml
```

Expected: after save, `CRAFT_MCP_UPSTREAM` is encrypted as `ENC[...]`, and the clear-text Craft.do URL does not appear in the file.

- [ ] **Step 5: Include new resources in kustomization**

Modify `kubernetes/infrastructure/controllers/toolhive/kustomization.yaml` so the resources list is:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - events-rbac.yaml
  - helmrelease-crds.yaml
  - helmrelease.yaml
  - gmail-mcp-secret.sops.yaml
  - gmail-rest-mcp.yaml
  - craft-mcp-secret.sops.yaml
  - craft-mcp-proxy.yaml
  - toolhive-auth-redis-secret.sops.yaml
  - toolhive-auth-valkey.yaml
  - toolhive-mcp.yaml
```

- [ ] **Step 6: Run proxy tests and manifest render**

Run:

```sh
python -m unittest tests.toolhive_craft_mcp_proxy_test -v
kubectl kustomize kubernetes/infrastructure/controllers/toolhive >/tmp/toolhive-render.yaml
rg "<Craft endpoint host or link token>" kubernetes/infrastructure/controllers/toolhive /tmp/toolhive-render.yaml
```

Expected: unittest passes; kustomize exits `0`; `rg` exits `1` because the Craft.do URL is not visible in Git or rendered manifests before SOPS decryption.

- [ ] **Step 7: Commit Task 1**

Run:

```sh
git add kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml \
  kubernetes/infrastructure/controllers/toolhive/craft-mcp-secret.sops.yaml \
  kubernetes/infrastructure/controllers/toolhive/kustomization.yaml \
  tests/toolhive_craft_mcp_proxy_test.py
git commit -m "feat(toolhive): add Craft MCP proxy"
```

Expected: commit succeeds with only the proxy, encrypted secret, kustomization, and proxy tests.

### Task 2: Switch ToolHive From Outline to Craft

**Files:**
- Modify: `kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml`
- Modify: `tests/toolhive_google_rest_mcp_test.py`

**Interfaces:**
- Consumes: internal proxy service from Task 1 at `http://craft-mcp-proxy.toolhive-system.svc.cluster.local:8080/mcp`.
- Produces: active ToolHive backend `MCPServerEntry/craft`.

- [ ] **Step 1: Update the failing backend assertions**

Modify `test_toolhive_uses_google_workspace_backend_names` in `tests/toolhive_google_rest_mcp_test.py` so the end of the test reads:

```python
        for name in (
            "gmail",
            "gmail-develop-for-good",
            "gmail-hoa",
            "gmail-craft-export",
        ):
            self.assertNotIn(f"kind: MCPServerEntry\nmetadata:\n  name: {name}\n", config)

        self.assertIn("kind: MCPServerEntry\nmetadata:\n  name: craft\n", config)
        self.assertIn(
            "remoteUrl: http://craft-mcp-proxy.toolhive-system.svc.cluster.local:8080/mcp",
            config,
        )
        self.assertNotIn("kind: MCPServerEntry\nmetadata:\n  name: outline\n", config)
        self.assertNotIn("pending-agent-tools", config)
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
python -m unittest tests.toolhive_google_rest_mcp_test -v
```

Expected: fails because `MCPServerEntry/craft` is not present and `MCPServerEntry/outline` still exists.

- [ ] **Step 3: Replace Outline with Craft in ToolHive**

In `kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml`, delete these resources entirely:

```yaml
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPExternalAuthConfig
metadata:
  name: outline-upstream-token
  namespace: toolhive-system
spec:
  type: upstreamInject
  upstreamInject:
    providerName: outline
---
```

```yaml
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
  externalAuthConfigRef:
    name: outline-upstream-token
---
```

Also remove this upstream provider block from `VirtualMCPServer.spec.authServerConfig.upstreamProviders`:

```yaml
      - name: outline
        type: oauth2
        oauth2Config:
          authorizationEndpoint: https://docs.mcnees.me/oauth/authorize
          tokenEndpoint: https://docs.mcnees.me/oauth/token
          clientId: izto0734m5xy2xegind3
          redirectUri: https://toolhive.home.mcnees.me/oauth/callback
          scopes:
            - read
            - write
```

Insert this `MCPServerEntry` after `MCPServerEntry/google-craft-export`:

```yaml
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPServerEntry
metadata:
  name: craft
  namespace: toolhive-system
spec:
  groupRef:
    name: agent-tools
  remoteUrl: http://craft-mcp-proxy.toolhive-system.svc.cluster.local:8080/mcp
  transport: streamable-http
---
```

- [ ] **Step 4: Run tests and render ToolHive**

Run:

```sh
python -m unittest tests.toolhive_google_rest_mcp_test tests.toolhive_craft_mcp_proxy_test -v
kubectl kustomize kubernetes/infrastructure/controllers/toolhive >/tmp/toolhive-render.yaml
rg "name: craft|craft-mcp-proxy|name: outline|outline-upstream-token|docs.mcnees.me/mcp" /tmp/toolhive-render.yaml
```

Expected: tests pass; kustomize exits `0`; `rg` shows Craft/proxy resources and does not show Outline MCP backend material.

- [ ] **Step 5: Commit Task 2**

Run:

```sh
git add kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml \
  tests/toolhive_google_rest_mcp_test.py
git commit -m "feat(toolhive): route agent docs to Craft"
```

Expected: commit succeeds with only ToolHive backend and test assertion changes.

### Task 3: Update Docs and Verify the Cluster

**Files:**
- Modify: `docs/runbooks/hermes.md`
- Modify: `docs/runbooks/toolhive.md`
- Modify: `docs/runbooks/syncthing.md`

**Interfaces:**
- Consumes: `MCPServerEntry/craft` from Task 2.
- Produces: operator guidance that names Craft.do as Hermes' canonical notes/docs/todos backend.

- [ ] **Step 1: Update Hermes runbook**

In `docs/runbooks/hermes.md`, change the component summary bullet from:

```markdown
- Tooling: single ToolHive MCP entry aggregating Gmail, Google Calendar,
    Google Workspace, Honeydew, Linear, Outline, and Homey backends.
```

to:

```markdown
- Tooling: single ToolHive MCP entry aggregating Gmail, Google Calendar,
    Google Workspace, Craft.do, Honeydew, Linear, and Homey backends.
```

Change the MCP active backend bullets from:

```markdown
- Active backends: Google personal, Google Develop for Good, Google HOA,
  Google Craft Export, Honeydew, Linear, Outline, Homey
```

to:

```markdown
- Active backends: Google personal, Google Develop for Good, Google HOA,
  Google Craft Export, Craft.do, Honeydew, Linear, Homey
```

Replace the Outline OAuth note with:

```markdown
- Craft.do is reached through the internal `craft-mcp-proxy` service so the
  sensitive Craft MCP endpoint URL stays in a SOPS-managed Kubernetes Secret
  instead of clear-text Git. Honeydew, Linear, and Homey are active and
  intentionally chain after Google during first-time client auth. Homey is
  experimental because it advertises only OAuth `form_post` response mode and
  `client_secret_basic` token auth.
```

Replace the durable-note policy paragraph with:

```markdown
Active durable-note jobs should write canonical notes, docs, todo lists, and
rules to Craft.do through ToolHive. Obsidian and Outline are legacy only;
paused jobs may retain old references for migration history, but active jobs
must either use Craft tools or report that no durable note was written.
```

- [ ] **Step 2: Update ToolHive runbook**

In `docs/runbooks/toolhive.md`, replace:

```markdown
- `MCPServerEntry/outline` points to Outline at
  `https://docs.mcnees.me/mcp`.
```

with:

```markdown
- `MCPServerEntry/craft` points to the internal Craft.do proxy at
  `http://craft-mcp-proxy.toolhive-system.svc.cluster.local:8080/mcp`.
  The proxy reads the real Craft MCP endpoint from
  `Secret/craft-mcp-upstream`.
```

Replace:

```markdown
- `MCPExternalAuthConfig/outline-upstream-token`,
  `MCPExternalAuthConfig/homey-upstream-token`,
  `MCPExternalAuthConfig/honeydew-upstream-token`, and
  `MCPExternalAuthConfig/linear-upstream-token` inject the matching upstream
  OAuth token for those backends.
```

with:

```markdown
- `MCPExternalAuthConfig/homey-upstream-token`,
  `MCPExternalAuthConfig/honeydew-upstream-token`, and
  `MCPExternalAuthConfig/linear-upstream-token` inject the matching upstream
  OAuth token for those backends. Craft.do authentication is embedded in the
  Craft MCP endpoint URL and held in `Secret/craft-mcp-upstream`.
```

Replace the paragraph beginning `All four Google Workspace accounts are active`
with:

```markdown
All four Google Workspace accounts are active in `MCPGroup/agent-tools`.
Craft.do, Honeydew, Linear, and Homey are also active. Craft.do is the
canonical notes, docs, and todo-list backend for Hermes. The similarly named
`google-craft-export` backend is only a Google Workspace account and is not the
Craft.do integration. Homey is experimental because its OAuth metadata only
advertises a `form_post` response mode and `client_secret_basic` token
authentication; ToolHive has no explicit token endpoint auth method field, so
token exchange may still fail.
```

- [ ] **Step 3: Update Syncthing runbook**

In `docs/runbooks/syncthing.md`, replace:

```markdown
Hermes no longer mounts the Obsidian vault. Use Outline MCP for Hermes-accessible notes and docs.
```

with:

```markdown
Hermes no longer mounts the Obsidian vault. Use Craft.do through ToolHive for Hermes-accessible notes, docs, and todo lists.
```

- [ ] **Step 4: Run docs and config scans**

Run:

```sh
rg -n "canonical notes.*Outline|Use Outline MCP|Outline MCP|docs.mcnees.me/mcp|outline-upstream-token" docs/runbooks kubernetes/infrastructure/controllers/toolhive tests
python -m unittest tests.toolhive_google_rest_mcp_test tests.toolhive_craft_mcp_proxy_test -v
kubectl kustomize kubernetes/infrastructure/controllers/toolhive >/tmp/toolhive-render.yaml
```

Expected: `rg` shows no stale active/canonical Outline guidance or ToolHive Outline MCP backend references; tests pass; kustomize exits `0`.

- [ ] **Step 5: Reconcile and verify live resources**

Run:

```sh
flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure --with-source
kubectl --kubeconfig talos/kubeconfig -n toolhive-system rollout status deploy/craft-mcp-proxy --timeout=120s
kubectl --kubeconfig talos/kubeconfig -n toolhive-system get mcpserverentry craft
kubectl --kubeconfig talos/kubeconfig -n toolhive-system describe virtualmcpserver agent-tools
```

Expected: reconcile succeeds; proxy deployment rolls out; `MCPServerEntry/craft` exists; `VirtualMCPServer/agent-tools` is ready.

- [ ] **Step 6: Verify Hermes ToolHive access**

Run:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- sh -lc 'su hermes -s /bin/sh -c "export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:\$PATH; hermes mcp test toolhive"'
```

Expected: command exits `0` and ToolHive discovery includes Craft tools. If Hermes still sees stale Outline tools, rerun `hermes mcp login toolhive` using the callback port-forward flow documented in `docs/runbooks/hermes.md`.

- [ ] **Step 7: Commit Task 3**

Run:

```sh
git add docs/runbooks/hermes.md docs/runbooks/toolhive.md docs/runbooks/syncthing.md
git commit -m "docs(hermes): document Craft as canonical notes backend"
```

Expected: commit succeeds with only runbook changes.

## Rollback

If Craft discovery or proxying fails after deployment:

1. Re-add `MCPExternalAuthConfig/outline-upstream-token`, `MCPServerEntry/outline`, and the Outline upstream provider block from Task 2.
2. Remove or leave unused `MCPServerEntry/craft`.
3. Reconcile ToolHive.
4. Run `hermes mcp test toolhive`.
5. Update runbooks back to temporary Outline guidance only if rollback lasts beyond the troubleshooting session.
