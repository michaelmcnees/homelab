# Homelab Agent Notes

## Repository Shape

This repository is the source of truth for the homelab. Most live Kubernetes
state is reconciled by Flux from manifests under `kubernetes/`.

- Cluster access uses `talos/kubeconfig`.
- Flux Kustomizations live under `kubernetes/flux-system/`.
- Application and media workloads live under `kubernetes/apps/` and
  `kubernetes/media/`.
- Infrastructure controllers and observability live under
  `kubernetes/infrastructure/`.
- Authentication and shared access live under `kubernetes/auth/`.
- Operational notes belong in `docs/runbooks/`.
- Secrets are SOPS-managed. Do not decrypt, print, or rewrite encrypted payloads
  unless the task explicitly requires it.

## GitOps Rule

If a task changes anything that Flux manages, do not consider the task complete
until the matching repository change is committed, integrated with current
`origin/main`, pushed to `origin/main`, and verified there.

Live `kubectl apply`, `patch`, or manual cluster edits are only temporary
stabilization steps. They must be followed by a Git commit and push, otherwise
Flux may revert them.

Before final response for Flux-managed work:

1. Run the relevant local render or validation, such as
   `kubectl --kubeconfig talos/kubeconfig kustomize <path>`.
2. Commit only the files that belong to the task.
3. Fetch/integrate current `origin/main` before pushing.
4. Push to `origin/main`.
5. Verify the pushed remote head or Flux reconciliation status.

If the local worktree contains unrelated user changes, do not include them in
the task commit. Use a temporary clean worktree when needed to cherry-pick the
task commit onto current `origin/main`.

## Operational Practices

- Prefer declarative changes in Git over imperative cluster fixes.
- When debugging alerts, query Prometheus directly and verify both the raw metric
  and the alert expression.
- For Arr/Prowlarr issues, treat Prowlarr as the source of truth for current
  indexer reachability; downstream Arr `IndexerStatusCheck` entries can be stale.
- Household host monitoring may include personal devices that sleep or move.
  Alert only on household hosts explicitly marked as lab infrastructure.
- Keep public or shared access paths behind explicit auth. Do not expose Arr app
  services directly if the app trusts local cluster traffic.

## Useful Commands

```bash
kubectl --kubeconfig talos/kubeconfig get kustomizations -n flux-system
kubectl --kubeconfig talos/kubeconfig kustomize kubernetes/<path>
flux --kubeconfig talos/kubeconfig reconcile kustomization <name> --with-source
git status --short
git ls-remote origin refs/heads/main
```
