# TriliumNext

TriliumNext runs in the `apps` namespace at `https://notes.mcnees.me`.

## Components

- App: `triliumnext/trilium:v0.103.0`
- Storage: `trilium-data` local-path PVC mounted at `/home/node/trilium-data`
- Auth: Trilium's built-in login flow

The route is intentionally not behind oauth2-proxy so browser sessions, API access, and mobile clients can authenticate directly with Trilium.

## First Login

Open `https://notes.mcnees.me` and complete the initial Trilium setup. Save the generated credentials in your password manager.

## Mobile Evaluation

Use this instance while comparing Trilium mobile options. If a third-party mobile client needs the ETAPI token, create it inside Trilium after initial setup and store the token in the client only.

## Storage

The first deployment creates a 10Gi `local-path` PVC. Increase `kubernetes/apps/trilium/pvc.yaml` before heavy imports.
