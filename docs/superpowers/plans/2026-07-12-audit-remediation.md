# Audit Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 2026-07-12 audit gaps: secret-scan history, harden HelmReleases, pin `:latest` images, add in-cluster CI (ARC), add Renovate, and migrate Flux bootstrap to Flux Operator.

**Architecture:** All Kubernetes changes are GitOps — edit manifests, commit, push to `main`, `flux reconcile`, verify Ready. The cluster is reached via `KUBECONFIG=talos/kubeconfig` from the repo root. ARC and flux-operator follow the existing repo pattern: OCI `HelmRepository` in `kubernetes/repositories/`, `HelmRelease` next to workloads. Live-cluster steps (operator install, FluxInstance) run last.

**Tech Stack:** Flux v2.8.x, SOPS/age, ARC gha-runner-scale-set 0.14.2, flux-operator 0.52.0, gitleaks, kubeconform, Renovate (hosted Mend app).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-12-audit-remediation-design.md`
- Repo may be public or private at any point — assume nothing about visibility.
- NEVER commit these working-tree WIP files (user's in-flight work): `ansible/*` (except as noted in Task 3), `kubernetes/apps/kustomization.yaml`, `kubernetes/apps/penpot/`, `kubernetes/infrastructure/observability/kube-prometheus-stack/*`, `kubernetes/storage/rustfs/job-create-buckets.yaml`, `kubernetes/storage/rustfs/kustomization.yaml`, `kubernetes/storage/rustfs/penpot-rustfs-credentials.sops.yaml`, `docs/runbooks/penpot.md`, `ansible/roles/host-monitoring/files/`, `paseo.json`. Always `git add` specific files, never `-A` or `.`.
- All Secret manifests MUST be SOPS-encrypted before commit (`sops -e -i <file>`); `.sops.yaml` covers `kubernetes/**`. Verify encryption with `grep -q 'ENC\[' <file>` before `git add`.
- Every kubectl/flux command: `export KUBECONFIG=talos/kubeconfig` from repo root first.
- Verification loop after each push: `flux reconcile source git flux-system && flux reconcile kustomization <name> --with-source` then check Ready.
- Commit messages: short imperative, no scope prefixes (match repo style, e.g. "Add Linear API key to hermes secret and deployment").

---

### Task 1: One-time gitleaks full-history scan

**Files:** none created in repo (report goes to /tmp)

**Interfaces:**
- Consumes: nothing
- Produces: gate decision — findings must be reported to the user before any other task runs

- [ ] **Step 1: Install gitleaks**

```bash
brew install gitleaks
gitleaks version
```
Expected: version 8.x prints.

- [ ] **Step 2: Scan full history**

```bash
cd /Users/michael/Developer/homelab
gitleaks git --report-path /tmp/gitleaks-homelab.json --report-format json . ; echo "exit: $?"
```
Expected: exit 0 (clean) or exit 1 (leaks found).

- [ ] **Step 3: Triage results**

```bash
python3 -c "
import json
try: d=json.load(open('/tmp/gitleaks-homelab.json'))
except Exception: d=[]
print(len(d),'findings')
for f in d[:50]: print(f['RuleID'], f['File'], f.get('StartLine'), f['Commit'][:8])
"
```

Known-acceptable findings (do NOT count as leaks): matches inside `*.sops.yaml` files (values are `ENC[AES256_GCM,...]` ciphertext), the age public key in `.sops.yaml`, and `*.example` files with obvious dummy values. Anything else — STOP, report each finding to the user with file/commit, and wait for rotation decisions before continuing to Task 2. Do not attempt history rewrite (out of scope per spec).

- [ ] **Step 4: Report summary to user** (clean or findings list). No commit.

---

### Task 2: driftDetection on all HelmReleases + pin tailscale-operator

**Files:**
- Modify (12 HelmRelease manifests):
  - `kubernetes/databases/redis/helmrelease.yaml`
  - `kubernetes/infrastructure/observability/loki/helmrelease.yaml`
  - `kubernetes/infrastructure/observability/kube-prometheus-stack/helmrelease.yaml` — **WIP-adjacent dir**: this file itself is NOT in the user's modified list, but `kustomization.yaml` in the same dir is. Only stage the helmrelease file.
  - `kubernetes/infrastructure/observability/alloy/helmrelease.yaml`
  - `kubernetes/infrastructure/observability/version-checker/helmrelease.yaml`
  - `kubernetes/infrastructure/controllers/local-path-provisioner/helmrelease.yaml`
  - `kubernetes/infrastructure/controllers/metrics-server/helmrelease.yaml`
  - `kubernetes/infrastructure/controllers/external-dns/helmrelease.yaml`
  - `kubernetes/infrastructure/controllers/cert-manager/helmrelease.yaml`
  - `kubernetes/infrastructure/controllers/tailscale-operator/helmrelease.yaml` (also version pin)
  - `kubernetes/infrastructure/controllers/metallb/helmrelease.yaml`
  - `kubernetes/infrastructure/controllers/traefik/helmrelease.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: all 12 HelmReleases carry `spec.driftDetection.mode: enabled`; tailscale-operator chart pinned `"1.98.4"`

- [ ] **Step 1: Add driftDetection block to each of the 12 files**

In each file, insert directly under the `spec:` line (before `interval:`), at 2-space indent:

```yaml
  driftDetection:
    mode: enabled
```

- [ ] **Step 2: Pin tailscale-operator**

In `kubernetes/infrastructure/controllers/tailscale-operator/helmrelease.yaml` change:

```yaml
      version: ">=1.84.0"
```
to:
```yaml
      version: "1.98.4"
```
(1.98.4 = chart version currently deployed, verified via `kubectl get helmrelease -A`.)

- [ ] **Step 3: Validate builds**

```bash
cd /Users/michael/Developer/homelab
for f in $(grep -rl 'kustomize.config.k8s.io' kubernetes --include=kustomization.yaml); do kubectl kustomize "$(dirname $f)" >/dev/null || echo "FAIL: $f"; done; echo DONE
```
Expected: only `DONE`.

- [ ] **Step 4: Commit and push**

```bash
git add kubernetes/databases/redis/helmrelease.yaml kubernetes/infrastructure/observability/loki/helmrelease.yaml kubernetes/infrastructure/observability/kube-prometheus-stack/helmrelease.yaml kubernetes/infrastructure/observability/alloy/helmrelease.yaml kubernetes/infrastructure/observability/version-checker/helmrelease.yaml kubernetes/infrastructure/controllers/local-path-provisioner/helmrelease.yaml kubernetes/infrastructure/controllers/metrics-server/helmrelease.yaml kubernetes/infrastructure/controllers/external-dns/helmrelease.yaml kubernetes/infrastructure/controllers/cert-manager/helmrelease.yaml kubernetes/infrastructure/controllers/tailscale-operator/helmrelease.yaml kubernetes/infrastructure/controllers/metallb/helmrelease.yaml kubernetes/infrastructure/controllers/traefik/helmrelease.yaml
git commit -m "Enable drift detection on all HelmReleases and pin tailscale-operator"
git push
```

- [ ] **Step 5: Reconcile and verify**

```bash
export KUBECONFIG=talos/kubeconfig
flux reconcile source git flux-system
flux reconcile kustomization infrastructure --with-source
flux reconcile kustomization observability --with-source
flux reconcile kustomization databases --with-source
kubectl get helmrelease -A
```
Expected: all 12 show `READY True`. Watch for 2 minutes (`kubectl get helmrelease -A -w`) for drift-correction flapping — kube-prometheus-stack is the usual suspect (webhook caBundle fields). If a release upgrades repeatedly, STOP and report; the fix is an `ignore` rule under `driftDetection.ignore` (paths list), decided with the user.

---

### Task 3: Fix duplicate ansible_host under lugia

**Files:**
- Modify: `ansible/inventory/hosts.yml` (WIP file — edit, do NOT commit)

**Interfaces:**
- Consumes: nothing
- Produces: valid inventory; user commits it with their own WIP later

- [ ] **Step 1: Inspect the duplicate**

```bash
grep -n -A3 'lugia' ansible/inventory/hosts.yml
```
Current state (bug — duplicate key, second silently wins in YAML):

```yaml
            lugia:
              ansible_host: 10.0.10.14
              ansible_host: 10.0.10.15
```

- [ ] **Step 2: Fix**

The cluster has a node `ho-oh` (visible in `kubectl get nodes`) not present in inventory. Replace the duplicate line so lugia keeps `.14` and ho-oh gets `.15`:

```yaml
            lugia:
              ansible_host: 10.0.10.14
            ho-oh:
              ansible_host: 10.0.10.15
```

**Confirm with the user before finalizing** — they may know the intended mapping (this is their in-flight edit). Do not commit; leave in working tree.

---

### Task 4: Pin all :latest images

**Files:**
- Modify:
  - `kubernetes/storage/rustfs/deployment.yaml` (line ~28)
  - `kubernetes/apps/syncthing/deployment.yaml` (line ~50)
  - `kubernetes/smart-home/homebridge/deployment.yaml` (line ~27)
  - `kubernetes/smart-home/homey/deployment.yaml` (line ~27)
  - `kubernetes/apps/pelican-panel/deployment.yaml` (line ~40)
  - `kubernetes/apps/mantle/deployment.yaml` (lines ~33 and ~60 — two containers)
  - `kubernetes/apps/hermes/deployment.yaml` (line ~178)
  - `kubernetes/infrastructure/observability/adguard-exporter/deployment.yaml` (lines ~31 and ~103 — two Deployments in one file)
  - `kubernetes/media/exporters/tautulli-exporter.yaml` (line ~31)

**Interfaces:**
- Consumes: nothing
- Produces: zero `:latest`-only image references under `kubernetes/`

- [ ] **Step 1: Apply the pin table** (old → new; all values pre-resolved against the running cluster and registries on 2026-07-12):

| File | Old | New | Basis |
|---|---|---|---|
| storage/rustfs/deployment.yaml | `rustfs/rustfs:latest` | `rustfs/rustfs:1.0.0-beta.2` | running digest ↔ tag |
| apps/syncthing/deployment.yaml | `syncthing/syncthing:latest` | `syncthing/syncthing:2.1.0` | running digest ↔ tag |
| smart-home/homebridge/deployment.yaml | `homebridge/homebridge:latest` | `homebridge/homebridge:2026-05-06` | running digest ↔ tag |
| smart-home/homey/deployment.yaml | `ghcr.io/athombv/homey-shs:latest` | `ghcr.io/athombv/homey-shs:latest@sha256:721f4252c673dd4bdab4e69c8783cbb554fa3ebcf8b56b147f4d3b2f2708b433` | no versioned tags upstream — digest pin |
| apps/pelican-panel/deployment.yaml | `ghcr.io/pelican-dev/panel:latest` | `ghcr.io/pelican-dev/panel:v1.0.0-beta34` | tag currently running |
| apps/mantle/deployment.yaml (×2) | `ghcr.io/dvflw/mantle:latest` | `ghcr.io/dvflw/mantle:latest@sha256:dee440be68d324d6745c193408eefda265f13152d18107e849c1b1f700c41cff` | running build is newer than newest release tag v0.5.1 — digest pin |
| apps/hermes/deployment.yaml | `nousresearch/hermes-agent:latest` | `nousresearch/hermes-agent:latest@sha256:5731e3f580a850e0810605b27c61198cc43288bd7fefccf1168f386487683c5f` | no versioned tags — digest pin |
| observability/adguard-exporter/deployment.yaml (×2) | `ebrianne/adguard-exporter:latest` | `ebrianne/adguard-exporter:v1.14` | newest upstream release (exporter policy) |
| media/exporters/tautulli-exporter.yaml | `mm404/tautulli-exporter:latest` | `mm404/tautulli-exporter:0.2.3` | newest upstream = running |

- [ ] **Step 2: Verify no :latest remain**

```bash
grep -rn 'image:.*:latest$' kubernetes --include='*.yaml'
```
Expected: no output (digest-pinned `latest@sha256:` lines don't match the `$` anchor).

- [ ] **Step 3: Validate builds** (same loop as Task 2 Step 3). Expected: only `DONE`.

- [ ] **Step 4: Commit and push**

```bash
git add kubernetes/storage/rustfs/deployment.yaml kubernetes/apps/syncthing/deployment.yaml kubernetes/smart-home/homebridge/deployment.yaml kubernetes/smart-home/homey/deployment.yaml kubernetes/apps/pelican-panel/deployment.yaml kubernetes/apps/mantle/deployment.yaml kubernetes/apps/hermes/deployment.yaml kubernetes/infrastructure/observability/adguard-exporter/deployment.yaml kubernetes/media/exporters/tautulli-exporter.yaml
git commit -m "Pin all :latest images to running versions or digests"
git push
```

- [ ] **Step 5: Reconcile and verify pods**

```bash
export KUBECONFIG=talos/kubeconfig
flux reconcile source git flux-system
for k in storage apps smart-home observability media; do flux reconcile kustomization $k; done
kubectl get pods -A | grep -E 'rustfs|syncthing|homebridge|homey|pelican|mantle|hermes|adguard-exporter|tautulli-exporter' | grep -v Running || echo "all Running"
```
Expected: `all Running` (pods that restarted pull identical bytes — digests match what already runs; adguard-exporter may restart onto v1.14). If any CrashLoop: `kubectl describe pod` for image pull errors, report to user before reverting.

---

### Task 5: ARC GitHub App + SOPS secret

**Files:**
- Create: `kubernetes/infrastructure/controllers/arc/namespace.yaml`
- Create: `kubernetes/infrastructure/controllers/arc/secret.sops.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: namespaces `arc-system`, `arc-runners`; SOPS Secret `arc-github-app` in `arc-runners` with keys `github_app_id`, `github_app_installation_id`, `github_app_private_key` (the exact key names the gha-runner-scale-set chart expects)

- [ ] **Step 1: User creates the GitHub App** — give the user these instructions and WAIT for the three values:

> 1. https://github.com/settings/apps → New GitHub App
> 2. Name: `homelab-arc` (any unique name). Homepage URL: repo URL. Uncheck Webhook → Active.
> 3. Repository permissions: **Actions: Read-only**, **Administration: Read and write**, **Metadata: Read-only**. (Administration R/W is required for runner registration on repo-level scale sets.)
> 4. "Only on this account" → Create.
> 5. Note the **App ID**. Generate a **private key** (.pem downloads).
> 6. Install App → your account → select repositories: `homelab` (add the Arbor Lane repo too for later).
> 7. From the installation URL `.../installations/<number>`, note the **Installation ID**.
> Provide: App ID, Installation ID, path to the .pem file.

- [ ] **Step 2: Write namespace manifest**

`kubernetes/infrastructure/controllers/arc/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: arc-system
---
apiVersion: v1
kind: Namespace
metadata:
  name: arc-runners
```

- [ ] **Step 3: Create and encrypt the secret** (substitute real values; PEM path from user):

```bash
cd /Users/michael/Developer/homelab
kubectl create secret generic arc-github-app \
  --namespace arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALLATION_ID> \
  --from-file=github_app_private_key=<PATH_TO_PEM> \
  --dry-run=client -o yaml > kubernetes/infrastructure/controllers/arc/secret.sops.yaml
sops -e -i kubernetes/infrastructure/controllers/arc/secret.sops.yaml
grep -q 'ENC\[' kubernetes/infrastructure/controllers/arc/secret.sops.yaml && echo ENCRYPTED
shred -u <PATH_TO_PEM> 2>/dev/null || rm -P <PATH_TO_PEM>
```
Expected: `ENCRYPTED` prints. NEVER stage this file unencrypted. No commit yet — Task 6 commits the whole `arc/` dir.

---

### Task 6: ARC controller + runner scale set manifests

**Files:**
- Create: `kubernetes/repositories/actions-runner-controller.yaml`
- Create: `kubernetes/infrastructure/controllers/arc/helmrelease-controller.yaml`
- Create: `kubernetes/infrastructure/controllers/arc/helmrelease-runners.yaml`
- Create: `kubernetes/infrastructure/controllers/arc/kustomization.yaml`
- Modify: `kubernetes/repositories/kustomization.yaml` (add entry)
- Modify: `kubernetes/infrastructure/controllers/kustomization.yaml` (add `arc` entry)

**Interfaces:**
- Consumes: Secret `arc-github-app` (Task 5)
- Produces: runner scale set named `homelab-runner` — CI workflows use `runs-on: homelab-runner` (Task 7 depends on this exact name)

- [ ] **Step 1: HelmRepository**

`kubernetes/repositories/actions-runner-controller.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: actions-runner-controller
  namespace: flux-system
spec:
  interval: 24h
  type: oci
  url: oci://ghcr.io/actions/actions-runner-controller-charts
```

Add `- actions-runner-controller.yaml` to the `resources:` list in `kubernetes/repositories/kustomization.yaml` (alphabetical position: first).

- [ ] **Step 2: Controller HelmRelease**

`kubernetes/infrastructure/controllers/arc/helmrelease-controller.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: arc-controller
  namespace: arc-system
spec:
  driftDetection:
    mode: enabled
  interval: 30m
  chart:
    spec:
      chart: gha-runner-scale-set-controller
      version: "0.14.2"
      sourceRef:
        kind: HelmRepository
        name: actions-runner-controller
        namespace: flux-system
      interval: 12h
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
```

- [ ] **Step 3: Runner scale set HelmRelease**

`kubernetes/infrastructure/controllers/arc/helmrelease-runners.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: homelab-runner
  namespace: arc-runners
spec:
  driftDetection:
    mode: enabled
  interval: 30m
  dependsOn:
    - name: arc-controller
      namespace: arc-system
  chart:
    spec:
      chart: gha-runner-scale-set
      version: "0.14.2"
      sourceRef:
        kind: HelmRepository
        name: actions-runner-controller
        namespace: flux-system
      interval: 12h
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    githubConfigUrl: https://github.com/michaelmcnees/homelab
    githubConfigSecret: arc-github-app
    minRunners: 0
    maxRunners: 3
    containerMode:
      type: ""  # plain mode, no dind
```

(Release name `homelab-runner` == the `runs-on` label.)

- [ ] **Step 4: Kustomization glue**

`kubernetes/infrastructure/controllers/arc/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secret.sops.yaml
  - helmrelease-controller.yaml
  - helmrelease-runners.yaml
```

Add `- arc` to `kubernetes/infrastructure/controllers/kustomization.yaml` resources (alphabetical: first, before `cert-manager`).

- [ ] **Step 5: Validate builds** (Task 2 Step 3 loop). Expected: only `DONE`.

- [ ] **Step 6: Commit and push**

```bash
git add kubernetes/repositories/actions-runner-controller.yaml kubernetes/repositories/kustomization.yaml kubernetes/infrastructure/controllers/arc/ kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "Add ARC controller and homelab runner scale set"
git push
```

- [ ] **Step 7: Reconcile and verify runner registration**

```bash
export KUBECONFIG=talos/kubeconfig
flux reconcile source git flux-system
flux reconcile kustomization infrastructure --with-source
kubectl -n arc-system get pods
kubectl -n arc-runners get pods
kubectl get helmrelease -n arc-system -n arc-runners 2>/dev/null; kubectl get helmrelease -A | grep -E 'arc|runner'
gh api /repos/michaelmcnees/homelab/actions/runners --jq '.runners[].name' 2>/dev/null; gh api /repos/michaelmcnees/homelab/actions/runners/registration-token >/dev/null 2>&1 || true
```
Expected: controller pod Running in `arc-system`; a listener pod `homelab-runner-*-listener` Running in `arc-runners` (zero runner pods while idle — minRunners 0). GitHub side: repo → Settings → Actions → Runners shows scale set `homelab-runner` (or check `gh api /repos/michaelmcnees/homelab/actions/runners`). If listener CrashLoops: `kubectl -n arc-runners logs deploy/homelab-runner-*-listener` — most common cause is wrong App permissions (needs Administration R/W) or wrong installation ID.

---

### Task 7: CI workflow

**Files:**
- Create: `.github/workflows/validate.yaml`

**Interfaces:**
- Consumes: runner scale set `homelab-runner` (Task 6)
- Produces: required validation on PRs and main pushes

- [ ] **Step 1: Write workflow**

`.github/workflows/validate.yaml`:

```yaml
name: validate
on:
  pull_request:
  push:
    branches: [main]

jobs:
  manifests:
    runs-on: homelab-runner
    steps:
      - uses: actions/checkout@v4

      - name: Install tools
        run: |
          set -euo pipefail
          mkdir -p "$HOME/bin"
          curl -sSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.7.1/kustomize_v5.7.1_linux_amd64.tar.gz" | tar -xz -C "$HOME/bin" kustomize
          curl -sSL "https://github.com/yannh/kubeconform/releases/download/v0.7.0/kubeconform-linux-amd64.tar.gz" | tar -xz -C "$HOME/bin" kubeconform
          echo "$HOME/bin" >> "$GITHUB_PATH"

      - name: Kustomize build all
        run: |
          set -euo pipefail
          fail=0
          for f in $(grep -rl 'kustomize.config.k8s.io' kubernetes --include=kustomization.yaml); do
            d=$(dirname "$f")
            kustomize build "$d" > /dev/null || { echo "BUILD FAIL: $d"; fail=1; }
          done
          exit $fail

      - name: Kubeconform
        run: |
          set -euo pipefail
          fail=0
          for f in $(grep -rl 'kustomize.config.k8s.io' kubernetes --include=kustomization.yaml); do
            d=$(dirname "$f")
            kustomize build "$d" | kubeconform \
              -strict -ignore-missing-schemas -skip Secret \
              -schema-location default \
              -schema-location 'https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/{{ .ResourceKind }}{{ .KindSuffix }}.json' \
              || { echo "SCHEMA FAIL: $d"; fail=1; }
          done
          exit $fail

  gitleaks:
    runs-on: homelab-runner
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Install gitleaks
        run: |
          set -euo pipefail
          mkdir -p "$HOME/bin"
          curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v8.24.3/gitleaks_8.24.3_linux_x64.tar.gz" | tar -xz -C "$HOME/bin" gitleaks
          echo "$HOME/bin" >> "$GITHUB_PATH"
      - name: Scan
        run: gitleaks git --no-banner .
```

Note: gitleaks scans full history each run (cheap at this repo size, catches everything); SOPS ciphertext can false-positive — if the first run flags `*.sops.yaml` lines, add `.gitleaks.toml` with a path allowlist for `\.sops\.yaml$` and commit it with the fix.

- [ ] **Step 2: Commit and push**

```bash
git add .github/workflows/validate.yaml
git commit -m "Add manifest validation and secret scanning CI"
git push
```

- [ ] **Step 3: Verify run executes on cluster runner**

```bash
gh run watch --repo michaelmcnees/homelab $(gh run list --repo michaelmcnees/homelab --limit 1 --json databaseId --jq '.[0].databaseId')
export KUBECONFIG=talos/kubeconfig
kubectl -n arc-runners get pods
```
Expected: a `homelab-runner-*` runner pod appears during the run, both jobs green, pod scales back to zero after. If jobs queue forever: listener logs (Task 6 Step 7 debugging).

---

### Task 8: Renovate

**Files:**
- Create: `renovate.json5`

**Interfaces:**
- Consumes: nothing (hosted app, no cluster resources)
- Produces: automated dependency PRs, validated by Task 7 CI

- [ ] **Step 1: Write config**

`renovate.json5`:

```json5
{
  $schema: "https://docs.renovatebot.com/renovate-schema.json",
  extends: ["config:recommended"],
  labels: ["dependencies"],
  prHourlyLimit: 2,
  "flux": {
    managerFilePatterns: ["/kubernetes/.+\\.yaml$/"],
  },
  "kubernetes": {
    managerFilePatterns: ["/kubernetes/.+\\.yaml$/"],
  },
  packageRules: [
    {
      matchUpdateTypes: ["patch", "minor"],
      groupName: "{{depName}} non-major",
    },
    {
      matchUpdateTypes: ["major"],
      dependencyDashboardApproval: false,
      groupName: null,
    },
  ],
}
```

- [ ] **Step 2: Commit and push**

```bash
git add renovate.json5
git commit -m "Add Renovate configuration"
git push
```

- [ ] **Step 3: User installs the Mend Renovate app** — instruct and wait:

> https://github.com/apps/renovate → Install → select `homelab` repo.

- [ ] **Step 4: Verify** — within ~1h Renovate opens an onboarding/first PR; CI (Task 7) runs on it. Check `gh pr list --repo michaelmcnees/homelab`. Confirm detected deps in the PR body include HelmRelease chart versions and container tags.

---

### Task 9: Flux Operator migration — live cutover

**Files:** none committed in this task (live cluster only; Task 10 commits manifests)

**Interfaces:**
- Consumes: healthy cluster (all prior tasks green)
- Produces: flux-operator managing Flux via FluxInstance `flux` in `flux-system`; Task 10 relies on names `flux-operator` (HelmRelease) and `flux` (FluxInstance)

- [ ] **Step 1: Pre-flight snapshot**

```bash
export KUBECONFIG=talos/kubeconfig
flux check
flux get kustomizations -A > /tmp/pre-migration-ks.txt
flux get helmreleases -A > /tmp/pre-migration-hr.txt
grep -c True /tmp/pre-migration-ks.txt /tmp/pre-migration-hr.txt
```
Expected: `flux check` all green; counts noted (13 Kustomizations + flux-system, 14 HelmReleases incl. ARC). Any not-Ready → STOP, fix first.

- [ ] **Step 2: Install flux-operator via Helm**

```bash
command -v helm >/dev/null || brew install helm
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system --version 0.52.0
kubectl -n flux-system get pods -l app.kubernetes.io/name=flux-operator
```
Expected: operator pod Running.

- [ ] **Step 3: Apply FluxInstance** (mirrors gotk-sync + carries the SOPS patch from `kubernetes/flux-system/patches/sops-decryption.yaml`):

Write `/tmp/flux-instance.yaml`:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.x"
    registry: ghcr.io/fluxcd
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
    - image-reflector-controller
    - image-automation-controller
  cluster:
    type: kubernetes
    networkPolicy: true
  sync:
    kind: GitRepository
    url: ssh://git@github.com/michaelmcnees/homelab
    ref: refs/heads/main
    path: kubernetes
    pullSecret: flux-system
    interval: 1m
  kustomize:
    patches:
      - target:
          kind: Kustomization
          name: flux-system
        patch: |
          - op: add
            path: /spec/decryption
            value:
              provider: sops
              secretRef:
                name: sops-age
```

**Before applying**, read the current patch to confirm the op/paths match:
```bash
cat kubernetes/flux-system/patches/sops-decryption.yaml
```
Adjust the `patch:` block to be semantically identical (same decryption provider/secretRef). Then:

```bash
kubectl apply -f /tmp/flux-instance.yaml
kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=5m
```
Expected: Ready. The operator adopts the existing controllers (`migrateResources` defaults to true).

- [ ] **Step 4: Verify parity**

```bash
flux check
flux get kustomizations -A > /tmp/post-migration-ks.txt
flux get helmreleases -A > /tmp/post-migration-hr.txt
diff <(awk '{print $1,$2}' /tmp/pre-migration-ks.txt) <(awk '{print $1,$2}' /tmp/post-migration-ks.txt) && echo KS-MATCH
diff <(awk '{print $1,$2}' /tmp/pre-migration-hr.txt) <(awk '{print $1,$2}' /tmp/post-migration-hr.txt) && echo HR-MATCH
kubectl -n flux-system get fluxreport flux -o yaml | grep -A5 'entitlement\|distribution' | head -12
```
Expected: `KS-MATCH`, `HR-MATCH`, FluxReport present, all Ready.

**Rollback** (if anything is unrecoverable): `kubectl delete fluxinstance flux -n flux-system && helm uninstall flux-operator -n flux-system && flux bootstrap github --owner=michaelmcnees --repository=homelab --branch=main --path=kubernetes` — restores the exact prior setup. Workloads are untouched either way.

---

### Task 10: Flux Operator migration — repo cleanup

**Files:**
- Create: `kubernetes/flux-system/flux-operator.yaml`
- Create: `kubernetes/flux-system/flux-instance.yaml`
- Create: `kubernetes/repositories/flux-operator.yaml`
- Modify: `kubernetes/flux-system/kustomization.yaml`
- Delete: `kubernetes/flux-system/gotk-components.yaml`, `kubernetes/flux-system/gotk-sync.yaml`, `kubernetes/flux-system/patches/sops-decryption.yaml`

**Interfaces:**
- Consumes: running FluxInstance `flux` (Task 9)
- Produces: operator + instance fully GitOps-managed; bootstrap artifacts gone

- [ ] **Step 1: HelmRepository for operator chart**

`kubernetes/repositories/flux-operator.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  interval: 24h
  type: oci
  url: oci://ghcr.io/controlplaneio-fluxcd/charts
```

Add `- flux-operator.yaml` to `kubernetes/repositories/kustomization.yaml`.

- [ ] **Step 2: Operator HelmRelease** (adopts the Task 9 helm install — same release name + namespace):

`kubernetes/flux-system/flux-operator.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  driftDetection:
    mode: enabled
  interval: 30m
  chart:
    spec:
      chart: flux-operator
      version: "0.52.0"
      sourceRef:
        kind: HelmRepository
        name: flux-operator
        namespace: flux-system
      interval: 12h
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
```

- [ ] **Step 3: FluxInstance manifest** — `kubernetes/flux-system/flux-instance.yaml`: exact content applied in Task 9 Step 3 (copy from `/tmp/flux-instance.yaml`, including any adjustments made).

- [ ] **Step 4: Rewrite flux-system kustomization**

`kubernetes/flux-system/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- apps.yaml
- auth.yaml
- backups.yaml
- databases.yaml
- flux-instance.yaml
- flux-operator.yaml
- hdf.yaml
- infrastructure-configs.yaml
- infrastructure.yaml
- media.yaml
- observability.yaml
- smart-home.yaml
- storage.yaml
```

Delete files:

```bash
git rm kubernetes/flux-system/gotk-components.yaml kubernetes/flux-system/gotk-sync.yaml kubernetes/flux-system/patches/sops-decryption.yaml
rmdir kubernetes/flux-system/patches 2>/dev/null || true
```

(The SOPS patch now lives inside the FluxInstance `spec.kustomize.patches`; GitRepository + root Kustomization are operator-generated. The old `flux-system` Kustomization object is adopted by the operator, so removing gotk-sync from git does not delete it.)

- [ ] **Step 5: Validate build**

```bash
kubectl kustomize kubernetes/flux-system > /dev/null && kubectl kustomize kubernetes > /dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 6: Commit and push**

```bash
git add kubernetes/flux-system/flux-operator.yaml kubernetes/flux-system/flux-instance.yaml kubernetes/flux-system/kustomization.yaml kubernetes/repositories/flux-operator.yaml kubernetes/repositories/kustomization.yaml
git commit -m "Migrate Flux bootstrap to Flux Operator with FluxInstance"
git push
```

- [ ] **Step 7: Final verification**

```bash
export KUBECONFIG=talos/kubeconfig
flux reconcile source git flux-system
flux reconcile kustomization flux-system --with-source
kubectl -n flux-system get helmrelease flux-operator
kubectl -n flux-system get fluxinstance flux
flux check
flux get kustomizations -A | grep -vc True || true
```
Expected: HelmRelease `flux-operator` Ready (adopted existing helm release), FluxInstance Ready, `flux check` green, zero not-Ready Kustomizations. Then update issue #1 with a comment: ARC controller now available; Arbor Lane needs its own scale set (possibly dind).

- [ ] **Step 8: Update runbook index** — if `docs/runbooks/` has a CI/flux runbook pattern the user wants, note in final summary; not created here (YAGNI).
