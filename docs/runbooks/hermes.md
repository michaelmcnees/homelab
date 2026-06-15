# Hermes Agent

Hermes is deployed as an experimental in-cluster agent at `https://hermes.home.mcnees.me`.

## Shape

- Namespace: `apps`
- Image: `nousresearch/hermes-agent@sha256:5731e3f580a850e0810605b27c61198cc43288bd7fefccf1168f386487683c5f`
- Runtime: `/opt/hermes/.venv/bin/hermes gateway run` with `HERMES_DASHBOARD=1`
- Dashboard: Traefik `IngressRoute` behind the shared `oauth2-proxy` middleware
- Data PVC: `hermes-data` mounted at `/opt/data`
- Config: `hermes-config` mounted at `/opt/data/config.yaml`
- Workspace PVC: `hermes-workspace` mounted at `/workspace`
- Default provider: `openai-codex`
- Default model: `gpt-5.5`
- MCP servers:
  - ToolHive at `https://toolhive.home.mcnees.me/mcp`, aggregating Gmail,
    Honeydew, Linear, and future compatible personal MCP backends
  - Homey and Outline are cataloged in ToolHive but remain pending until their
    OAuth flows are reliable through ToolHive upstream auth.

The Hermes Docker docs warn against exposing the dashboard directly. Keep it on the internal Traefik entrypoint and oauth-protected unless we intentionally design a safer public gateway. The pod still runs the dashboard with Hermes' `--insecure` flag internally, so `NetworkPolicy/hermes-ingress` restricts dashboard ingress to Traefik.

## Runtime Path

Use the Hermes virtualenv entrypoint everywhere:

```sh
/opt/hermes/.venv/bin/hermes
```

The deployment also sets:

- `PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:...`
- `HOME=/opt/data/home`
- `HERMES_HOME=/opt/data`

An init container creates this stable compatibility symlink on the data PVC:

```text
/opt/data/home/.local/bin/hermes -> /opt/hermes/.venv/bin/hermes
```

Do not use the old `/opt/data/home/.hermes/hermes-agent/venv` path for troubleshooting, cron jobs, health checks, or subprocesses.

## Provider Keys

Provider keys are optional for initial boot, but Hermes will need at least one usable model provider before it can do useful agent work.

Hermes requires at least 64k context. Local Ollama is configured with `OLLAMA_CONTEXT_LENGTH=64000`, but Telegram proved too slow through the local CPU path: even a small message can send a multi-thousand-token agent prompt and hit the 120 second client timeout.

The default provider is `openai-codex` so Hermes can use the ChatGPT/Codex OAuth credential stored on the `hermes-data` PVC. Keep local Ollama available for private/offline experiments, not the default Telegram chat path. The ChatGPT Codex model allow list changes over time; if Hermes starts returning HTTP 400 for the default model, test the replacement with a one-shot command before updating this runbook.

When changing the default model in `kubernetes/apps/hermes/configmap.yaml`, also update `hermes.mcnees.me/config-revision` in `kubernetes/apps/hermes/deployment.yaml`. Hermes mounts `config.yaml` with `subPath`, so Flux updating the ConfigMap alone will not refresh the file inside an existing pod.

Edit the SOPS secret:

```sh
SOPS_AGE_KEY_FILE=homelab.age.key sops kubernetes/apps/hermes/secret.sops.yaml
```

Supported placeholders:

- `OPENROUTER_API_KEY`
- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `XAI_API_KEY`
- `OLLAMA_API_KEY`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_ALLOWED_USERS`
- `APPLE_APP_PASSWORD`
- `GMAIL_APP_PASSWORD`

Gmail MCP OAuth is now mediated by ToolHive. The legacy
`/opt/data/google_client_secret.json` file may still exist on the Hermes PVC,
but Hermes no longer reads it for MCP configuration.

## Mail Accounts

Hermes renders Himalaya mail accounts from Kubernetes secrets on every pod start:

- iCloud uses `APPLE_APP_PASSWORD`
- Gmail uses `GMAIL_APP_PASSWORD`
- Config path: `/opt/data/home/.config/himalaya/config.toml`
- File mode: `0600`

Do not hand-edit the persisted Himalaya config for password rotation. Update
`kubernetes/apps/hermes/secret.sops.yaml`, then reconcile or restart Hermes so
the init container rewrites the config from the current secret values.

Check mail access without printing secrets:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- sh -lc \
  'export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:$PATH; himalaya account doctor gmail; himalaya account doctor icloud'
```

Codex OAuth is not stored in SOPS. It is created inside the running Hermes pod and persisted on the `hermes-data` PVC:

```sh
kubectl --kubeconfig talos/kubeconfig exec -n apps deployment/hermes -- sh -c \
  'su hermes -s /bin/sh -c "/opt/hermes/.venv/bin/hermes auth add openai-codex --type oauth --no-browser --timeout 300"'
```

Run Hermes auth commands as the `hermes` user. `kubectl exec` enters this image as root, and root-owned `/opt/data/auth.json` files are unreadable by the long-running Hermes process. If Codex jobs report `No Codex credentials stored` while logs also show `Permission denied: '/opt/data/auth.json'`, repair ownership without printing token contents:

```sh
kubectl --kubeconfig talos/kubeconfig exec -n apps deployment/hermes -- sh -c \
  'chown 10000:10000 /opt/data/auth.json && chmod 600 /opt/data/auth.json'
```

## MCP Servers

Hermes is configured with a single remote HTTP MCP server named `toolhive`.

- Endpoint: `https://toolhive.home.mcnees.me/mcp`
- Auth: OAuth
- Active backends: Gmail personal, Gmail Develop for Good, Gmail HOA, Gmail
  Craft Export, Honeydew, Linear, and future personal MCP backends
  aggregated by ToolHive
- Pending backends: Homey and Outline are cataloged in ToolHive, but remain
  direct-client fallbacks. Homey needs ToolHive support for its OAuth
  `form_post` and `client_secret_basic` requirements. Outline is pending until
  its Dynamic Client Registration rate limit clears or a stable OAuth client
  registration is configured.

After the ConfigMap is reconciled, authorize ToolHive from Hermes on first use.
Hermes persists MCP OAuth tokens on the `hermes-data` PVC and reuses them
across restarts.

Reload MCP servers from inside Hermes after config changes:

```text
/reload-mcp
```

First-time ToolHive authorization:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec -it deployment/hermes -- sh -lc 'su hermes -s /bin/sh -c "export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:\$PATH; hermes mcp login toolhive"'
```

Open the printed OAuth URL and complete the flow, then verify:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- sh -lc 'su hermes -s /bin/sh -c "export HOME=/opt/data/home PATH=/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:\$PATH; hermes mcp test toolhive"'
```

Tokens are stored under `/opt/data/mcp-tokens`. Treat those files like
credentials; do not paste or hand-edit their contents.

The Gmail upstream Google OAuth hop is mediated by ToolHive:

- ToolHive endpoint: `https://toolhive.home.mcnees.me/mcp`
- Gmail backend: `https://gmailmcp.googleapis.com/mcp/v1`
- ToolHive backend names: `gmail`, `gmail-develop-for-good`, `gmail-hoa`,
  `gmail-craft-export`
- Scopes: `https://www.googleapis.com/auth/gmail.readonly`,
  `https://www.googleapis.com/auth/gmail.compose`,
  `https://www.googleapis.com/auth/gmail.modify`, and
  `https://www.googleapis.com/auth/gmail.labels`
- Google upstream callback: `https://toolhive.home.mcnees.me/oauth/callback`

If Google returns `redirect_uri_mismatch`, update the OAuth client in the
Google Cloud project to allow the ToolHive callback
`https://toolhive.home.mcnees.me/oauth/callback`, then rerun
`hermes mcp login toolhive`.

Hermes' MCP OAuth client currently registers its own callback as
`http://127.0.0.1:<port>/callback` and binds that listener inside the Hermes
pod. That loopback callback is separate from ToolHive's upstream provider
callback. Until Hermes supports a public callback URL or device-code MCP auth,
first-time Hermes-to-ToolHive login can still require a `kubectl port-forward`.

## Telegram

Telegram uses the long-running Hermes gateway already started by the deployment.

1. Create a bot with BotFather and save the bot token in `TELEGRAM_BOT_TOKEN`.
2. Get your numeric Telegram user ID from `@userinfobot` and save it in `TELEGRAM_ALLOWED_USERS`.
3. Reconcile `apps` or restart the `hermes` deployment.

`TELEGRAM_ALLOWED_USERS` is comma-separated, so multiple user IDs can be added later.

The cluster currently resolves `api.telegram.org` to IPv6 first, but Hermes pods do not have working IPv6 egress. IPv4 works. The deployment sets `TELEGRAM_FALLBACK_IPS` so Hermes uses known Telegram IPv4 endpoints when the primary DNS path fails. This fallback is expected until cluster IPv6 egress is fixed or DNS stops returning an unreachable IPv6 path.

Check Telegram connectivity:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps exec deployment/hermes -- sh -lc \
  'getent hosts api.telegram.org; curl -4 -sS -I --connect-timeout 10 https://api.telegram.org | sed -n "1,5p"; curl -6 -sS -I --connect-timeout 10 https://api.telegram.org | sed -n "1,5p"'
```

Check fallback status in logs:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps logs deployment/hermes --tail=300 | \
  grep -Ei 'telegram.*(fallback|api.telegram.org|network|connected)'
```

## Dashboard Exposure

Hermes dashboard exposure should remain:

- Kubernetes Service: `ClusterIP`
- Traefik entrypoint: `websecure`, not `websecure-external`
- Middleware: `oauth2-proxy`
- Pod ingress: allowed only from Traefik by `NetworkPolicy/hermes-ingress`

Verification:

```sh
kubectl --kubeconfig talos/kubeconfig -n apps get svc hermes -o wide
kubectl --kubeconfig talos/kubeconfig -n apps get ingressroute hermes -o yaml
kubectl --kubeconfig talos/kubeconfig -n apps get networkpolicy hermes-ingress -o yaml
curl -Ik https://hermes.home.mcnees.me
curl -Ik https://hermes.mcnees.me
```

Expected: `hermes.home.mcnees.me` redirects/challenges through auth; no public `hermes.mcnees.me` route exists.

## Scheduled Jobs

Cron jobs must use:

```yaml
provider: openai-codex
model: gpt-5.5
```

Audit persisted jobs after changing model defaults:

```sh
kubectl --kubeconfig talos/kubeconfig exec -n apps deployment/hermes -- sh -lc \
  '/opt/hermes/.venv/bin/python - <<'"'"'PY'"'"'
import json
from pathlib import Path
jobs = json.loads(Path("/opt/data/cron/jobs.json").read_text()).get("jobs", [])
bad = [
    (j.get("id"), j.get("name"), j.get("provider"), j.get("model"))
    for j in jobs
    if j.get("enabled", True)
    and (j.get("provider") != "openai-codex" or j.get("model") != "gpt-5.5")
]
for row in bad:
    print(row)
raise SystemExit(1 if bad else 0)
PY'
```

If a job is pinned to an unsupported model, update it through Hermes tooling rather than editing JSON by hand:

```text
cronjob(action="update", job_id="<id>", model="gpt-5.5", provider="openai-codex")
```

Active durable-note jobs should write canonical notes/rules to Outline. Obsidian is legacy only; paused jobs may retain old Obsidian references for migration history, but active jobs must either use Outline MCP or report that no durable note was written.

## Optional Tool Warnings

This deployment does not currently enable RL tooling or web search.

- `tinker-atropos found but not installed` is acceptable unless RL work is intentionally enabled. Do not install it in this deployment image without also adding `TINKER_API_KEY`/`WANDB_API_KEY` handling and a concrete RL job.
- `web` tool unavailable is acceptable. Do not create cron jobs that depend on the `web` tool until a search provider key is added through SOPS and explicitly enabled.

## Gateways Later

Hermes supports additional chat gateways such as Discord and Slack. Add those as a follow-up once we decide which account should own the bot tokens and approved user lists.
