# Paperless-GPT

Paperless-GPT is the AI companion for Paperless-ngx. It connects to Paperless through an API token and uses Ollama for local title, tag, correspondent, document type, and OCR suggestions.

The app is staged in `kubernetes/apps/paperless-gpt`, but it is intentionally not enabled in the root apps Kustomization until a real Paperless API token exists. This avoids a noisy crash loop during bootstrap.

## URLs

- Paperless-ngx: `https://paperless.home.mcnees.me`
- Paperless-GPT: `https://paperless-gpt.home.mcnees.me`
- Internal Paperless URL: `http://paperless-ngx.apps.svc.cluster.local:8000`
- Internal Ollama URL: `http://ollama.apps.svc.cluster.local:11434`

## Enable

1. Sign in to Paperless-ngx and create an API token for the Paperless-GPT service user.
2. Replace `PAPERLESS_API_TOKEN` in `kubernetes/apps/paperless-gpt/secret.sops.yaml`.
3. Encrypt the secret:

```bash
sops --encrypt --in-place kubernetes/apps/paperless-gpt/secret.sops.yaml
```

4. Add `./paperless-gpt` to `kubernetes/apps/kustomization.yaml`.
5. Add a Homepage tile after the app is reachable.
6. Commit, push, and reconcile Flux.

## Defaults

- Image: `icereed/paperless-gpt:v0.25.1`
- Prompt storage: `paperless-gpt-prompts` local-path PVC mounted at `/app/prompts`
- Main LLM: `ollama` with `qwen3:8b`
- Vision OCR LLM: `ollama` with `minicpm-v`
- OCR mode: `image`
- PDF upload/replacement: disabled by default
- New tag creation: disabled by default

Before enabling automatic processing, upload or pick one test document in Paperless and add the `paperless-gpt` tag for manual review.
