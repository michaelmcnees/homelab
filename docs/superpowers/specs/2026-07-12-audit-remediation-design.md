# Audit Remediation Design — 2026-07-12

Remediation of gaps found in the 2026-07-12 GitOps repo audit: CI, dependency
automation, image pinning, HelmRelease hardening, and Flux Operator migration.

## Context

- Flux monorepo, single Talos cluster, Flux v2.8.6 (bootstrap-managed).
- Repo is currently public on GitHub; owner will flip it private. Nothing in
  this design assumes public visibility. Private repos consume GitHub Actions
  minutes, so CI runs on a self-hosted runner in the cluster.
- Issue #1 requests an ARC runner for Arbor Lane e2e — the ARC controller
  installed here serves that too (Arbor Lane gets its own scale set later).
- Cluster is reachable from this machine via `talos/kubeconfig`. SSH access to
  ansible hosts is set up (root key auth to latios, latias, rayquaza,
  metagross, registeel, truenas).
- In-flight working-tree changes (penpot, host-monitoring) are untouched;
  every step commits only its own files.

## Work Order

Each step is independently commit-able and verifiable:

1. One-time gitleaks full-history scan (local)
2. Quick fixes: driftDetection, tailscale-operator pin, inventory fix
3. Image pinning (remove `:latest`)
4. ARC: controller + homelab runner scale set
5. CI workflow on the self-hosted runner
6. Renovate (hosted Mend app + config)
7. Flux Operator migration (live, last — biggest blast radius)

## 1. Secret Scan (one-time, local)

Run `gitleaks git` against full history. The repo's history was public, so
anything ever committed must be treated as exposed.

- Findings → rotate the credential; record findings in the PR/commit notes.
- History rewrite (if warranted) is deferred until after the repo goes
  private; it is out of scope here.

## 2. Quick Fixes

- Add `spec.driftDetection.mode: enabled` to all 12 HelmReleases
  (schema-verified field on `helm.toolkit.fluxcd.io/v2`).
- Pin `tailscale-operator` chart from `>=1.84.0` to the exact currently
  deployed version (consistent with the other 11 releases).
- Fix duplicate `ansible_host` under `lugia` in `ansible/inventory/hosts.yml`
  (10.0.10.14 and 10.0.10.15 both listed; second entry likely ho-oh).

## 3. Image Pinning

Mixed strategy for the 11 `:latest` references:

- **Stateful/risky** (rustfs, syncthing, homebridge, homey-shs, pelican-panel,
  mantle, hermes-agent): pin to the tag currently running in the cluster
  (queried via kubectl at implementation time). Zero behavior change.
- **Trivial exporters** (adguard-exporter ×2, tautulli-exporter): pin to
  latest upstream release tag.
- Images with no usable tags (e.g. `ghcr.io/dvflw/mantle` if only `latest`
  exists): pin by digest.

The implementation PR includes a table: file/line, old ref, new ref, source
of the pin (cluster vs upstream vs digest). Renovate owns bumps afterward.

## 4. ARC (Actions Runner Controller)

New directory `kubernetes/infrastructure/controllers/arc/`, reconciled by the
existing `infrastructure` Flux Kustomization.

- Two HelmReleases from OCI charts at
  `ghcr.io/actions/actions-runner-controller-charts`:
  - `gha-runner-scale-set-controller` → namespace `arc-system`
  - `gha-runner-scale-set` named `homelab-runner` → namespace `arc-runners`,
    `githubConfigUrl: https://github.com/michaelmcnees/homelab`
- Auth via **GitHub App** (scoped, no token expiry churn). Owner creates the
  app and installs it on `homelab` + the Arbor Lane repo. App ID,
  installation ID, and private key stored as SOPS secret in `arc-runners`.
- `minRunners: 0`, `maxRunners: 3` — scale-to-zero when idle.
- Plain runner mode (no Docker-in-Docker). Arbor Lane e2e may need a dind
  scale set later; that is deferred to issue #1.

Personal GitHub accounts cannot use org-level runner registration, so scale
sets are per-repo: `homelab-runner` now, an Arbor Lane set later under the
same controller.

## 5. CI Workflow

`.github/workflows/validate.yaml`, `runs-on: homelab-runner`, triggered on
pull requests and pushes to `main`:

1. **kustomize build** — build every directory containing a Kustomize config;
   fail on any build error.
2. **kubeconform** — schema-validate rendered output using Flux CRD schemas;
   skip kinds without schemas (third-party CRDs) and SOPS-encrypted Secrets.
3. **gitleaks** — diff scan of the pushed range/PR (full history covered by
   step 1).

Tools are downloaded in-job at pinned versions (simple to start; a prebaked
runner image is a later optimization).

**Known limitation:** CI runs on the cluster it validates. A commit that
breaks Flux badly enough to kill the runner can't be gated by CI. Accepted
for a homelab — validation can always run locally.

## 6. Renovate

Hosted Mend Renovate GitHub App (free, works on private repos, zero Actions
minutes). Config `renovate.json5` at repo root:

- Managers: `flux` (HelmRelease chart versions), `kubernetes` (image tags in
  `kubernetes/**`), `github-actions` (action pins in workflows).
- Patch + minor updates grouped per app; majors get solo PRs with changelogs.
- No digest pinning (readable tags preferred).
- No schedule restriction initially; throttle later if PR volume is noisy.

Owner installs the Mend app on the repo; config drives everything else.

## 7. Flux Operator Migration

Migrate from `flux bootstrap` (gotk-sync.yaml) to Flux Operator +
FluxInstance, per https://fluxoperator.dev/docs/guides/migration/

1. Pre-flight: `flux check`; confirm all 13 Kustomizations and 12
   HelmReleases Ready; snapshot state for comparison.
2. Install flux-operator via Helm into `flux-system`.
3. Create `FluxInstance`: distribution 2.x, sync = existing git URL, branch
   `main`, path `kubernetes`, reusing the existing `flux-system` git-auth
   secret. **Carry `kubernetes/flux-system/patches/` into
   `spec.kustomize.patches`** — easy to miss, required for parity.
4. Operator adopts the existing controllers; verify via `FluxReport` and all
   resources returning to Ready.
5. Repo cleanup: delete `gotk-components.yaml` and `gotk-sync.yaml`; commit
   the operator HelmRelease and FluxInstance manifests so the operator itself
   is GitOps-managed.
6. Rollback: re-running `flux bootstrap github` restores the previous setup
   exactly. Workloads keep running throughout — only Flux controllers
   restart.

## Verification

- Every step ends with `flux reconcile` and Ready checks on affected
  resources.
- CI proves itself by validating its own PR.
- Image pins verified by pod restart + Ready in affected namespaces.
- Migration verified by `flux check`, `FluxReport`, and full-fleet Ready
  status matching the pre-flight snapshot.

## Out of Scope

- Flipping the repo private (owner handles).
- Git history rewrite for any leaked secrets (decided after scan + privacy
  flip).
- Arbor Lane runner scale set / dind mode (issue #1, later).
- NetworkPolicies, SOPS for ansible group_vars, Flux notification Providers —
  audit findings deferred to future work.
