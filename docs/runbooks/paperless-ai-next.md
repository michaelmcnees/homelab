# Paperless-AI Next

Paperless-AI next runs in the `apps` namespace at `https://paperless-ai.home.mcnees.me`.

It is deployed with the Lite image first. Lite handles AI tagging, title generation, document type, and correspondent suggestions without the heavier RAG/vector search service. Switch to the Full image later if semantic document chat becomes useful.

## Storage

Paperless-AI next stores its own runtime settings, user database, processing history, and metrics on the `paperless-ai-next-data` local-path PVC mounted at `/app/data`.

The document archive itself stays in Paperless-ngx on TrueNAS-backed storage.

## First Setup

The deployment intentionally starts with:

```text
PAPERLESS_AI_INITIAL_SETUP=yes
ALLOW_REMOTE_SETUP=yes
DISABLE_AUTOMATIC_PROCESSING=yes
```

Open `https://paperless-ai.home.mcnees.me` and complete the first-run wizard.

Use these internal service URLs during setup:

```text
Paperless URL: http://paperless-ngx.apps.svc.cluster.local:8000
Paperless public URL: https://paperless.home.mcnees.me
Ollama URL: http://ollama.apps.svc.cluster.local:11434
```

Create a Paperless-ngx API token from the Paperless user settings and paste it into the wizard. Start with automatic processing disabled until a small test document has been processed manually.

After setup is complete and validated, remove `ALLOW_REMOTE_SETUP=yes` from the deployment and set `DISABLE_AUTOMATIC_PROCESSING=no` when you are ready for scheduled processing.

## Model Notes

Start with a small Ollama model that fits comfortably in the current cluster memory budget. The Lite image does not run the RAG service, so the model memory pressure comes from Ollama only.
