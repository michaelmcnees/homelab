# Mantle Evaluation

Mantle was originally listed as the n8n replacement candidate, but the currently visible product does not expose a self-hosted deployment path for this lab.

## Current Finding

- Mantle is presented as a hosted automation/agent product at `mantle.work`.
- The public site describes connecting SaaS tools and building agents through the hosted product.
- No official container image, Helm chart, Kubernetes manifest, or self-hosted install guide has been identified yet.

## Lab Decision

Do not add a Kubernetes deployment until Mantle publishes a self-hosted runtime or we receive private deployment instructions.

Keep the n8n replacement decision open. If Mantle remains hosted-only, choose a self-hosted automation platform instead so automations can run inside the homelab and use the existing SOPS, GitOps, auth, backup, and observability patterns.

## Follow-Up

- Re-check Mantle for a self-hosted install path before spending implementation time.
- If no install path exists, evaluate self-hosted replacements such as Windmill, Activepieces, Node-RED, or keeping a minimal n8n deployment.
