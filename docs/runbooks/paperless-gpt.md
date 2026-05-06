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
- Main LLM: `ollama` with `granite4.1:3b`
- Vision OCR LLM: `ollama` with `minicpm-v`
- OCR mode: `image`
- PDF upload/replacement: disabled by default
- New tag creation: disabled by default

Before enabling automatic processing, upload or pick one test document in Paperless and add the `paperless-gpt` tag for manual review.

## Monitoring

Grafana dashboard: `https://grafana.home.mcnees.me/d/homelab-paperless/homelab-paperless`

This dashboard combines Kubernetes metrics and Loki logs for Paperless-ngx, Paperless-GPT, and Ollama. Use it to check:

- Deployment availability for `paperless-ngx`, `paperless-gpt`, and `ollama`.
- Paperless PVC usage.
- Container restarts.
- Paperless ingest events such as `Consuming`, `consumption finished`, and `New document id`.
- Paperless-GPT/Ollama warnings, timeouts, prompt truncation, and `/api/chat` requests.

## Slow Processing

If a document appears stuck in Paperless-GPT, first confirm whether Paperless-ngx already completed ingestion:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps logs deployment/paperless-ngx --tail=200
```

Then check whether Ollama is still processing a long model request:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps logs deployment/ollama --since=2h | rg 'POST     "/api/chat"|truncating|error|WARN'
```

On 2026-05-06, a 52-page dishwasher manual was ingested by Paperless-ngx in about 27 seconds, but Paperless-GPT sent a 12,120-token prompt to `qwen3:8b`; Ollama truncated it to 8,192 tokens and the `/api/chat` call took about 49 minutes. The deployment now uses `granite4.1:3b`, `OLLAMA_CONTEXT_LENGTH=4096`, `TOKEN_LIMIT=500`, and `LLM_REQUESTS_PER_MINUTE=5` to keep local model enrichment from monopolizing the workflow.
