# Open WebUI

Open WebUI runs in Kubernetes at `https://ai.home.mcnees.me` and talks to the in-cluster Ollama service at `http://ollama.apps.svc.cluster.local:11434`.

## Auth

Open WebUI is not behind OAuth2-Proxy. It uses its own login flow, and the first account created during bootstrap becomes the admin account. After the admin account exists, disable open signups from the Open WebUI admin settings unless new local users need to self-register.

## Storage

Ollama model data currently uses a `50Gi` `local-path` PVC and prefers the `lugia` node. Open WebUI app data uses a `10Gi` `local-path` PVC. This keeps the initial deployment unblocked while shared bulk storage is still being sorted out.

Move Ollama models to shared or bulk storage later if the model library outgrows local-path or needs to survive node replacement without manual recovery.

## Models

Pull models from the Open WebUI admin interface, or directly with:

```bash
kubectl --kubeconfig talos/kubeconfig exec -n apps deployment/ollama -- ollama pull llama3.2
```
