# Hermes Agent

Hermes is deployed as an experimental in-cluster agent at `https://hermes.home.mcnees.me`.

## Shape

- Namespace: `apps`
- Image: `nousresearch/hermes-agent:latest`
- Runtime: `hermes gateway run` with `HERMES_DASHBOARD=1`
- Dashboard: Traefik `IngressRoute` behind the shared `oauth2-proxy` middleware
- Data PVC: `hermes-data` mounted at `/opt/data`
- Workspace PVC: `hermes-workspace` mounted at `/workspace`
- Ollama endpoint: `http://ollama.apps.svc.cluster.local:11434`

The Hermes Docker docs warn against exposing the dashboard directly. Keep it local-only and oauth-protected unless we intentionally design a safer public gateway.

## Provider Keys

Provider keys are optional for initial boot, but Hermes will need at least one usable model provider before it can do useful agent work.

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

## Gateways Later

Hermes supports chat gateways such as Telegram and Discord. Add those as a follow-up once we decide which account should own the bot tokens and approved user list.
