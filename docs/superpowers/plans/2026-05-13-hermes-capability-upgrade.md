# Hermes Capability Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Hermes useful as a persistent household/work assistant by adding email, memory, repo-aware context, and a controlled tool surface.

**Architecture:** Hermes remains a single in-cluster gateway deployment in the `apps` namespace with state on the existing `hermes-data` and `hermes-workspace` PVCs. Repo-managed ConfigMaps define non-secret configuration, SOPS stores credentials, and manual steps are limited to OAuth/app-password bootstrapping and interactive provider logins that cannot safely be represented in Git. External capabilities are added in phases with least-privilege tool exposure.

**Tech Stack:** Hermes Agent, Kubernetes/Flux, SOPS, ConfigMaps, PVCs, Himalaya CLI, IMAP/SMTP, optional Honcho memory provider, MCP, Telegram, OpenAI Codex/OAuth, OpenRouter/OpenAI fallback keys.

---

## Current State

- Hermes manifests live in `kubernetes/apps/hermes/`.
- Runtime image is `nousresearch/hermes-agent:latest`.
- Command is `hermes gateway run`.
- Dashboard is exposed at `https://hermes.home.mcnees.me` through the internal Traefik entrypoint and `oauth2-proxy`.
- Persistent state lives on:
  - `hermes-data` mounted at `/opt/data`.
  - `hermes-workspace` mounted at `/workspace`.
- Config is mounted at `/opt/data/config.yaml`.
- Default model provider is `openai-codex` with `gpt-5.3-codex`.
- Telegram token and allowed users are stored in `kubernetes/apps/hermes/secret.sops.yaml`.
- Codex OAuth is manually created inside the pod and persisted on `hermes-data`.

## Repo vs Manual Boundary

### Repo-managed

- Hermes config structure and non-secret defaults.
- Deployment resource requests/limits, probes, volumes, and environment variables.
- SOPS secret keys and secret references.
- A custom tool image or initContainer strategy for installing Himalaya and other stable CLIs.
- Workspace/context files mounted or seeded into `/workspace`.
- MCP server declarations with minimal tool filters.
- Runbooks for account setup and troubleshooting.
- Optional service manifests for memory providers if self-hosted.

### Manual

- Email account app password or OAuth consent flow.
- Codex OAuth login command inside the Hermes pod.
- Honcho Cloud API key, if using hosted Honcho.
- Telegram BotFather setup and allowed user IDs.
- Any third-party account authorization that requires browser consent.
- Final approval of which tools are allowed to send email, mutate GitHub, or touch home automation.

## Recommended Capability Order

1. Baseline configuration and safety rails.
2. File/project context and durable built-in memory.
3. Email via Himalaya in read-only mode.
4. Email sending after manual approval workflow is documented.
5. External memory provider, preferably Honcho if we want cross-session user modeling beyond files.
6. MCP integrations for GitHub/issues and narrow filesystem access.
7. Household integrations, starting read-only before write actions.
8. Observability and alerting for Hermes failures, latency, and tool errors.

---

### Task 1: Pin and document Hermes runtime

**Files:**
- Modify: `kubernetes/apps/hermes/deployment.yaml`
- Modify: `docs/runbooks/hermes.md`

- [ ] **Step 1: Replace `latest` with a pinned image tag**

First inspect upstream tags and choose either a tested version tag or an immutable digest. If upstream only publishes `latest`, skip the manifest edit and create a follow-up issue for a homelab-owned image. When a tag or digest exists, replace `image: nousresearch/hermes-agent:latest` in `kubernetes/apps/hermes/deployment.yaml` with the tested tag or digest.

If upstream does not publish stable tags suitable for pinning, record that in the runbook and create a follow-up issue to build a pinned internal image.

- [ ] **Step 2: Document runtime ownership**

Add to `docs/runbooks/hermes.md`:

```markdown
## Runtime Pinning

Hermes should not run `latest` long term. Use a tested pinned upstream tag or a homelab-built image that includes required CLI tools such as Himalaya. Changing the image should be treated like an app upgrade and verified from Telegram plus the dashboard.
```

- [ ] **Step 3: Verify**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps rollout status deployment/hermes
kubectl --kubeconfig talos/kubeconfig -n apps logs deployment/hermes --tail=100
```

Expected: deployment rolls out and the gateway starts without config or auth errors.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/hermes/deployment.yaml docs/runbooks/hermes.md
git commit -m "Pin Hermes runtime"
git push
```

### Task 2: Add repo-managed Hermes context files

**Files:**
- Create: `kubernetes/apps/hermes/context-configmap.yaml`
- Modify: `kubernetes/apps/hermes/kustomization.yaml`
- Modify: `kubernetes/apps/hermes/deployment.yaml`
- Modify: `docs/runbooks/hermes.md`

- [ ] **Step 1: Create context ConfigMap**

Create `kubernetes/apps/hermes/context-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-context
  namespace: apps
data:
  HERMES.md: |
    # Hermes Homelab Context

    You are running inside Michael's homelab Kubernetes cluster.

    Important boundaries:
    - Ask before sending email, changing DNS, changing network settings, or touching production data.
    - Prefer read-only inspection before mutation.
    - Use GitOps for Kubernetes changes; do not hand-edit live resources except during explicit break-glass recovery.
    - Secrets belong in SOPS, not chat transcripts or plain ConfigMaps.
    - The shared workspace is /workspace.
```

- [ ] **Step 2: Include the ConfigMap in Kustomize**

Modify `kubernetes/apps/hermes/kustomization.yaml`:

```yaml
resources:
  - configmap.yaml
  - context-configmap.yaml
  - pvc.yaml
  - secret.sops.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 3: Mount context into `/workspace`**

Add this volume mount to the Hermes container:

```yaml
- name: context
  mountPath: /workspace/HERMES.md
  subPath: HERMES.md
  readOnly: true
```

Add this volume:

```yaml
- name: context
  configMap:
    name: hermes-context
```

- [ ] **Step 4: Verify context is visible**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- \
  sh -lc 'test -f /workspace/HERMES.md && sed -n "1,80p" /workspace/HERMES.md'
```

Expected: the context file exists and contains the safety boundaries.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/hermes/
git commit -m "Add Hermes homelab context"
git push
```

### Task 3: Add durable built-in memory files

**Files:**
- Create: `kubernetes/apps/hermes/memory-seed-configmap.yaml`
- Modify: `kubernetes/apps/hermes/kustomization.yaml`
- Modify: `kubernetes/apps/hermes/deployment.yaml`
- Modify: `docs/runbooks/hermes.md`

- [ ] **Step 1: Seed default memory files without overwriting PVC state**

Create `kubernetes/apps/hermes/memory-seed-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-memory-seed
  namespace: apps
data:
  MEMORY.md: |
    # Hermes Memory

    Initial seed. Hermes may append or refine memories in its data directory.

  USER.md: |
    # User Profile Seed

    Michael prefers practical, repo-backed automation, GitOps-first infrastructure, and explicit manual boundaries for secrets and account authorization.
```

- [ ] **Step 2: Add an initContainer copy-once seed**

Add an initContainer after `fix-data-permissions`:

```yaml
- name: seed-memory-files
  image: busybox:1.37.0
  imagePullPolicy: IfNotPresent
  command:
    - sh
    - -c
    - |
      set -eu
      for file in MEMORY.md USER.md; do
        if [ ! -f "/opt/data/${file}" ]; then
          cp "/seed/${file}" "/opt/data/${file}"
          chown 10000:10000 "/opt/data/${file}"
        fi
      done
  securityContext:
    runAsUser: 0
    allowPrivilegeEscalation: false
    capabilities:
      add:
        - CHOWN
    seccompProfile:
      type: RuntimeDefault
  volumeMounts:
    - name: data
      mountPath: /opt/data
    - name: memory-seed
      mountPath: /seed
      readOnly: true
```

Add this volume:

```yaml
- name: memory-seed
  configMap:
    name: hermes-memory-seed
```

- [ ] **Step 3: Verify memory files exist**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- \
  sh -lc 'ls -l /opt/data/MEMORY.md /opt/data/USER.md'
```

Expected: both files exist on the PVC and are not overwritten on restart.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/hermes/
git commit -m "Seed Hermes memory files"
git push
```

### Task 4: Add Himalaya email CLI support

**Files:**
- Create: `kubernetes/apps/hermes/himalaya-secret.sops.yaml`
- Modify: `kubernetes/apps/hermes/kustomization.yaml`
- Modify: `kubernetes/apps/hermes/deployment.yaml`
- Modify: `kubernetes/apps/hermes/secret.sops.yaml`
- Modify: `docs/runbooks/hermes.md`

- [ ] **Step 1: Choose installation strategy**

Preferred: build a homelab-owned Hermes image that includes Himalaya, `jq`, and other stable CLIs.

Fallback: use an initContainer to place a pinned Himalaya binary in a shared `/tools/bin` emptyDir and prepend it to `PATH`.

Do not curl installer scripts at every pod startup.

- [ ] **Step 2: Add encrypted Himalaya config**

Create `kubernetes/apps/hermes/himalaya-secret.sops.yaml` with `sops` so mailbox details and auth commands are encrypted:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hermes-himalaya-config
  namespace: apps
type: Opaque
stringData:
  config.toml: |
    [accounts.homelab]
    email = "assistant@example.com"

    folder.aliases.inbox = "INBOX"
    folder.aliases.sent = "Sent"
    folder.aliases.drafts = "Drafts"
    folder.aliases.trash = "Trash"

    backend.type = "imap"
    backend.host = "imap.example.com"
    backend.port = 993
    backend.login = "assistant@example.com"
    backend.auth.type = "password"
    backend.auth.cmd = "cat /run/secrets/himalaya-password"

    message.send.backend.type = "smtp"
    message.send.backend.host = "smtp.example.com"
    message.send.backend.port = 587
    message.send.backend.encryption.type = "start-tls"
    message.send.backend.login = "assistant@example.com"
    message.send.backend.auth.type = "password"
    message.send.backend.auth.cmd = "cat /run/secrets/himalaya-password"
```

Replace the example account and hosts while editing through SOPS. Keep this file encrypted before committing.

- [ ] **Step 3: Add SOPS secret keys**

Add this key to `kubernetes/apps/hermes/secret.sops.yaml`:

```yaml
HIMALAYA_PASSWORD: ENC[...]
```

- [ ] **Step 4: Mount config and password**

Mount Himalaya config at:

```yaml
- name: himalaya-config
  mountPath: /opt/data/.config/himalaya/config.toml
  subPath: config.toml
  readOnly: true
```

Mount password from the secret:

```yaml
- name: himalaya-password
  mountPath: /run/secrets/himalaya-password
  subPath: HIMALAYA_PASSWORD
  readOnly: true
```

Set:

```yaml
- name: XDG_CONFIG_HOME
  value: /opt/data/.config
```

- [ ] **Step 5: Start read-only**

Document that Hermes may list/read/search email first. Sending email requires explicit human confirmation until we decide otherwise.

- [ ] **Step 6: Verify**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- \
  sh -lc 'himalaya --version && himalaya envelope list --account homelab --page-size 5 --output json'
```

Expected: Himalaya prints a version and returns a small JSON envelope list.

- [ ] **Step 7: Commit**

```bash
git add kubernetes/apps/hermes/ docs/runbooks/hermes.md
git commit -m "Add Hermes email tooling"
git push
```

### Task 5: Add optional Honcho memory provider

**Files:**
- Modify: `kubernetes/apps/hermes/configmap.yaml`
- Modify: `kubernetes/apps/hermes/secret.sops.yaml`
- Modify: `docs/runbooks/hermes.md`

- [ ] **Step 1: Decide hosted vs self-hosted**

Start with hosted Honcho if we want a fast validation path. Self-host Honcho only after we confirm Hermes memory is useful enough to justify operating another database-backed service.

- [ ] **Step 2: Add provider config**

Add to Hermes config:

```yaml
memory:
  provider: honcho
```

Add a `honcho.json` file through SOPS or a Secret-mounted file:

```json
{
  "apiKey": "stored-in-sops",
  "peerName": "michael",
  "aiPeer": "hermes-homelab",
  "workspace": "homelab"
}
```

- [ ] **Step 3: Manual API key setup**

Manual:

1. Create Honcho API key or deploy a self-hosted Honcho endpoint.
2. Store the key in `kubernetes/apps/hermes/secret.sops.yaml`.
3. Reconcile `apps`.

- [ ] **Step 4: Verify**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- \
  /opt/hermes/.venv/bin/hermes memory status
```

Expected: built-in memory is active and Honcho is the external provider.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/hermes/ docs/runbooks/hermes.md
git commit -m "Configure Hermes external memory"
git push
```

### Task 6: Add MCP servers with minimal tool filters

**Files:**
- Modify: `kubernetes/apps/hermes/configmap.yaml`
- Modify: `kubernetes/apps/hermes/secret.sops.yaml`
- Modify: `docs/runbooks/hermes.md`

- [ ] **Step 1: Add filesystem MCP for `/workspace` only**

Add to `config.yaml`:

```yaml
mcp_servers:
  workspace_fs:
    command: "npx"
    args:
      - "-y"
      - "@modelcontextprotocol/server-filesystem"
      - "/workspace"
    tools:
      include:
        - read_file
        - list_directory
        - search_files
      prompts: false
      resources: false
```

- [ ] **Step 2: Add GitHub MCP as issue-only**

Add:

```yaml
mcp_servers:
  github:
    command: "npx"
    args:
      - "-y"
      - "@modelcontextprotocol/server-github"
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}"
    tools:
      include:
        - list_issues
        - create_issue
        - update_issue
      prompts: false
      resources: false
```

- [ ] **Step 3: Add token manually**

Manual:

1. Create a GitHub PAT with the narrowest repo/issue scope that works.
2. Store it in `kubernetes/apps/hermes/secret.sops.yaml`.
3. Restart Hermes.

- [ ] **Step 4: Verify**

Inside Hermes, run:

```text
/reload-mcp
/tools list
```

Expected: `mcp-workspace_fs` and `mcp-github` toolsets appear with only the expected tools.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/hermes/ docs/runbooks/hermes.md
git commit -m "Add limited MCP tools for Hermes"
git push
```

### Task 7: Add observability for Hermes tools

**Files:**
- Modify: `kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-ai-dashboard.yaml`
- Modify: `kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-ai-network-alerts.yaml`
- Modify: `docs/runbooks/observability.md`
- Modify: `docs/runbooks/hermes.md`

- [ ] **Step 1: Add dashboard panels**

Add Loki panels filtered to `namespace="apps", app="hermes"` for:

- tool errors
- email/Himalaya errors
- MCP connection failures
- provider timeout/retry messages
- Telegram delivery failures

- [ ] **Step 2: Add alerts**

Create or extend alerts for:

- Hermes pod crashlooping for 10 minutes.
- Hermes logs show repeated provider timeouts for 15 minutes.
- Hermes logs show repeated email authentication failures for 15 minutes.
- Hermes dashboard route returns non-2xx/3xx through blackbox probing for 10 minutes.

- [ ] **Step 3: Verify**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig -n flux-system reconcile kustomization infrastructure
kubectl --kubeconfig talos/kubeconfig -n observability get prometheusrule | rg hermes
```

Expected: new/updated rules apply and Grafana dashboard JSON imports successfully.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/infrastructure/observability docs/runbooks
git commit -m "Add Hermes tool observability"
git push
```

## Manual Checklist

- [ ] Choose the email account Hermes should use.
- [ ] Create an app password or OAuth client for that account.
- [ ] Decide whether Hermes is allowed to send email automatically or only draft email.
- [ ] Re-run Codex OAuth in the pod if the PVC is ever recreated.
- [ ] Decide whether Honcho Cloud is acceptable or whether memory must stay self-hosted.
- [ ] Create a narrow GitHub PAT if MCP issue access is desired.
- [ ] Approve exact MCP tool whitelist before enabling mutation tools.

## Open Questions

- Should Hermes use your primary email account, a delegated assistant mailbox, or an HDF mailbox?
- Should outbound email be disabled initially, draft-only, or send-after-confirmation?
- Is hosted Honcho acceptable for user modeling, or should we stay with built-in file memory until self-hosting is worth it?
- Do we want Hermes to control Home Assistant/Homey/Homebridge eventually, or stay read-only for household status?
- Should Hermes have access to the homelab repo directly, or only a curated `/workspace` scratch/project context?
