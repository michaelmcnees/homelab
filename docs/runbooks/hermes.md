# Hermes Agent

Hermes is deployed as an experimental in-cluster agent at `https://hermes.home.mcnees.me`.

## Shape

- Namespace: `apps`
- Image: `nousresearch/hermes-agent:latest`
- Runtime: `hermes gateway run` with `HERMES_DASHBOARD=1`
- Dashboard: Traefik `IngressRoute` behind the shared `oauth2-proxy` middleware
- Data PVC: `hermes-data` mounted at `/opt/data`
- Config: `hermes-config` mounted at `/opt/data/config.yaml`
- Workspace PVC: `hermes-workspace` mounted at `/workspace`
- Default provider: `openai-codex`
- Default model: `gpt-5.3-codex`

The Hermes Docker docs warn against exposing the dashboard directly. Keep it local-only and oauth-protected unless we intentionally design a safer public gateway.

## Provider Keys

Provider keys are optional for initial boot, but Hermes will need at least one usable model provider before it can do useful agent work.

Hermes requires at least 64k context. Local Ollama is configured with `OLLAMA_CONTEXT_LENGTH=64000`, but Telegram proved too slow through the local CPU path: even a small message can send a multi-thousand-token agent prompt and hit the 120 second client timeout.

The default provider is `openai-codex` so Hermes can use the ChatGPT/Codex OAuth credential stored on the `hermes-data` PVC. Keep local Ollama available for private/offline experiments, not the default Telegram chat path.

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

Codex OAuth is not stored in SOPS. It is created inside the running Hermes pod and persisted on the `hermes-data` PVC:

```sh
kubectl --kubeconfig talos/kubeconfig exec -n apps deployment/hermes -- \
  /opt/hermes/.venv/bin/hermes auth add openai-codex --type oauth --no-browser --timeout 300
```

## Telegram

Telegram uses the long-running Hermes gateway already started by the deployment.

1. Create a bot with BotFather and save the bot token in `TELEGRAM_BOT_TOKEN`.
2. Get your numeric Telegram user ID from `@userinfobot` and save it in `TELEGRAM_ALLOWED_USERS`.
3. Reconcile `apps` or restart the `hermes` deployment.

`TELEGRAM_ALLOWED_USERS` is comma-separated, so multiple user IDs can be added later.

## Gateways Later

Hermes supports additional chat gateways such as Discord and Slack. Add those as a follow-up once we decide which account should own the bot tokens and approved user lists.
