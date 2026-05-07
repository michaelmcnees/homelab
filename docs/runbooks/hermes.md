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
- Ollama endpoint: `http://ollama.apps.svc.cluster.local:11434/v1`
- Default model: `qwen3.5:9b`
- Context length: `64000`

The Hermes Docker docs warn against exposing the dashboard directly. Keep it local-only and oauth-protected unless we intentionally design a safer public gateway.

## Provider Keys

Provider keys are optional for initial boot, but Hermes will need at least one usable model provider before it can do useful agent work.

Hermes requires at least 64k context. Local Ollama is configured with `OLLAMA_CONTEXT_LENGTH=64000`, and Hermes declares the same value in `hermes-config`.

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

## Telegram

Telegram uses the long-running Hermes gateway already started by the deployment.

1. Create a bot with BotFather and save the bot token in `TELEGRAM_BOT_TOKEN`.
2. Get your numeric Telegram user ID from `@userinfobot` and save it in `TELEGRAM_ALLOWED_USERS`.
3. Reconcile `apps` or restart the `hermes` deployment.

`TELEGRAM_ALLOWED_USERS` is comma-separated, so multiple user IDs can be added later.

## Gateways Later

Hermes supports additional chat gateways such as Discord and Slack. Add those as a follow-up once we decide which account should own the bot tokens and approved user lists.
