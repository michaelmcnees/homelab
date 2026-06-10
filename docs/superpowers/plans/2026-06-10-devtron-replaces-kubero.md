# Devtron Replaces Kubero Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Kubero with a full Devtron OSS installation at `https://cloud.dvflw.co`.

**Architecture:** Flux deploys a vendored, patched Devtron Helm chart from this repository. Devtron uses metagross PostgreSQL for state, RustFS for S3-compatible CI/CD object storage, Traefik/cert-manager/ExternalDNS for public access, and Flux prune removes Kubero after its manifests are removed.

**Tech Stack:** Flux CD, Kustomize, HelmRelease, SOPS, Ansible, PostgreSQL 16, RustFS, Traefik, cert-manager, ExternalDNS, Devtron OSS, Argo CD.

---

## File Structure

- `ansible/playbooks/postgresql-setup.yml` adds Devtron databases and ensures the `postgres` superuser has a password for Devtron external PostgreSQL.
- `ansible/inventory/group_vars/postgresql.yml` is ignored and receives the generated `pg_password_postgres` value during execution.
- `kubernetes/charts/devtron-operator/` vendors Devtron chart `0.23.2` and carries the `PG_DATABASE` duplicate-key patch.
- `kubernetes/apps/devtron/namespace.yaml` owns the Devtron namespace.
- `kubernetes/apps/devtron/secret.sops.yaml` stores the Helm values payload containing Devtron's external PostgreSQL and RustFS credentials.
- `kubernetes/apps/devtron/helmrelease.yaml` deploys the vendored Devtron chart with full OSS CI/CD and Argo CD enabled.
- `kubernetes/apps/devtron/ingress.yaml` exposes Devtron at `cloud.dvflw.co`.
- `kubernetes/apps/devtron/dnsendpoint.yaml` creates the Cloudflare DNS record for `cloud.dvflw.co`.
- `kubernetes/apps/devtron/kustomization.yaml` bundles Devtron app resources.
- `kubernetes/storage/rustfs/job-create-bucket-devtron.yaml` creates the RustFS `devtron` bucket.
- `kubernetes/storage/rustfs/kustomization.yaml` includes the new bucket job.
- `kubernetes/infrastructure/controllers/external-dns/helmrelease.yaml` adds `dvflw.co` to `domainFilters`.
- `kubernetes/apps/kustomization.yaml` swaps Kubero out and Devtron in.
- `kubernetes/infrastructure/controllers/kustomization.yaml` removes the Kubero operator.
- `kubernetes/apps/kubero/` is deleted.
- `kubernetes/infrastructure/controllers/kubero-operator/` is deleted.
- `docs/runbooks/devtron.md` records operational commands for login, verification, rollback, and known chart patch context.

---

### Task 1: Prepare Metagross PostgreSQL For Devtron

**Files:**
- Modify: `ansible/playbooks/postgresql-setup.yml`
- Modify locally only: `ansible/inventory/group_vars/postgresql.yml`

- [ ] **Step 1: Add Devtron databases to the PostgreSQL playbook**

In `ansible/playbooks/postgresql-setup.yml`, append these entries to `postgresql_databases` after the existing `penpot` entry:

```yaml
      - name: orchestrator
        owner: postgres
      - name: lens
        owner: postgres
      - name: git_sensor
        owner: postgres
      - name: casbin
        owner: postgres
```

- [ ] **Step 2: Add a task that manages the postgres user's password**

In `ansible/playbooks/postgresql-setup.yml`, add this task immediately after `Create PostgreSQL users`:

```yaml
    - name: Ensure postgres superuser password for Devtron
      become_user: postgres
      community.postgresql.postgresql_user:
        name: postgres
        password: "{{ pg_password_postgres }}"
        role_attr_flags: SUPERUSER,CREATEROLE,CREATEDB,REPLICATION,BYPASSRLS,LOGIN
        state: present
      no_log: true
```

- [ ] **Step 3: Generate the ignored local postgres password variable**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import base64
import os

path = Path("ansible/inventory/group_vars/postgresql.yml")
text = path.read_text()
if "pg_password_postgres:" not in text:
    password = base64.urlsafe_b64encode(os.urandom(24)).decode().rstrip("=")
    text = text.rstrip() + f'\npg_password_postgres: "{password}"\n'
    path.write_text(text)
PY
```

Expected: no terminal output. `git status --short ansible/inventory/group_vars/postgresql.yml` still prints nothing because the file is ignored.

- [ ] **Step 4: Run Ansible syntax check**

Run:

```bash
ansible-playbook --syntax-check ansible/playbooks/postgresql-setup.yml
```

Expected: output includes `playbook: ansible/playbooks/postgresql-setup.yml`.

- [ ] **Step 5: Apply PostgreSQL changes**

Run:

```bash
task ansible:postgresql
```

Expected: the play completes successfully and reports the Devtron databases as present or created.

- [ ] **Step 6: Verify databases exist on metagross**

Run:

```bash
ssh root@10.0.10.90 'sudo -u postgres psql -At -c "SELECT datname FROM pg_database WHERE datname IN ('\''orchestrator'\'','\''lens'\'','\''git_sensor'\'','\''casbin'\'') ORDER BY datname;"'
```

Expected:

```text
casbin
git_sensor
lens
orchestrator
```

- [ ] **Step 7: Commit PostgreSQL playbook changes**

Run:

```bash
git add ansible/playbooks/postgresql-setup.yml
git commit -m "feat: prepare postgres for devtron"
```

Expected: commit succeeds. The ignored `postgresql.yml` file is not included.

---

### Task 2: Vendor And Patch Devtron Chart

**Files:**
- Create: `kubernetes/charts/devtron-operator/`

- [ ] **Step 1: Pull Devtron chart 0.23.2**

Run:

```bash
mkdir -p /private/tmp/devtron-chart
helm repo add devtron https://helm.devtron.ai
helm repo update devtron
helm pull devtron/devtron-operator --version 0.23.2 --untar --untardir /private/tmp/devtron-chart
mkdir -p kubernetes/charts
rsync -a --delete /private/tmp/devtron-chart/devtron-operator/ kubernetes/charts/devtron-operator/
```

Expected: `kubernetes/charts/devtron-operator/Chart.yaml` exists and contains `version: 0.23.2`.

- [ ] **Step 2: Patch git-sensor ConfigMap**

In `kubernetes/charts/devtron-operator/templates/gitsensor.yaml`, replace:

```gotemplate
{{ toYaml $.Values.global.dbConfig | indent 2 }}
```

with:

```gotemplate
{{ toYaml (omit $.Values.global.dbConfig "PG_DATABASE") | indent 2 }}
```

- [ ] **Step 3: Patch lens ConfigMap**

In `kubernetes/charts/devtron-operator/templates/lens.yaml`, replace:

```gotemplate
{{ toYaml $.Values.global.dbConfig | indent 2 }}
```

with:

```gotemplate
{{ toYaml (omit $.Values.global.dbConfig "PG_DATABASE") | indent 2 }}
```

- [ ] **Step 4: Patch casbin ConfigMap**

In `kubernetes/charts/devtron-operator/templates/casbin.yaml`, replace:

```gotemplate
{{ toYaml $.Values.global.dbConfig | indent 2 }}
```

with:

```gotemplate
{{ toYaml (omit $.Values.global.dbConfig "PG_DATABASE") | indent 2 }}
```

- [ ] **Step 5: Add local patch note**

Create `kubernetes/charts/devtron-operator/PATCHES.md`:

```markdown
# Local Devtron Chart Patches

Vendored from `devtron/devtron-operator` chart `0.23.2`.

## External PostgreSQL PG_DATABASE duplicate-key patch

The upstream `gitsensor`, `lens`, and `casbin` templates render both `global.dbConfig` and component `.configs` into their component ConfigMaps. Both maps include `PG_DATABASE`, which creates duplicate YAML keys in external PostgreSQL mode.

This vendored copy renders `global.dbConfig | omit "PG_DATABASE"` in:

- `templates/gitsensor.yaml`
- `templates/lens.yaml`
- `templates/casbin.yaml`

Each component still renders its component-specific `PG_DATABASE`, so `git_sensor`, `lens`, and `casbin` remain separate databases.
```

- [ ] **Step 6: Build chart dependencies**

Run:

```bash
helm dependency build kubernetes/charts/devtron-operator
```

Expected: `kubernetes/charts/devtron-operator/charts/argo-cd-7.7.15.tgz` exists.

- [ ] **Step 7: Commit vendored chart**

Run:

```bash
git add kubernetes/charts/devtron-operator
git commit -m "feat: vendor patched devtron chart"
```

Expected: commit succeeds.

---

### Task 3: Add RustFS Bucket For Devtron

**Files:**
- Create: `kubernetes/storage/rustfs/job-create-bucket-devtron.yaml`
- Modify: `kubernetes/storage/rustfs/kustomization.yaml`

- [ ] **Step 1: Create Devtron bucket job**

Create `kubernetes/storage/rustfs/job-create-bucket-devtron.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: rustfs-create-bucket-devtron
  namespace: object-storage
spec:
  backoffLimit: 12
  ttlSecondsAfterFinished: 604800
  template:
    spec:
      restartPolicy: OnFailure
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: mc
          image: minio/mc:RELEASE.2025-08-13T08-35-41Z
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          command:
            - /bin/sh
            - -c
            - |
              until mc alias set rustfs http://rustfs.object-storage.svc.cluster.local:9000 "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY"; do
                sleep 5
              done
              mc mb --ignore-existing rustfs/devtron
          env:
            - name: HOME
              value: /tmp
          envFrom:
            - secretRef:
                name: rustfs-secrets
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

- [ ] **Step 2: Include bucket job in RustFS kustomization**

In `kubernetes/storage/rustfs/kustomization.yaml`, add:

```yaml
  - job-create-bucket-devtron.yaml
```

after `job-create-bucket-penpot.yaml`.

- [ ] **Step 3: Verify storage kustomization builds**

Run:

```bash
kubectl kustomize kubernetes/storage/rustfs
```

Expected: output includes `name: rustfs-create-bucket-devtron`.

- [ ] **Step 4: Commit RustFS bucket job**

Run:

```bash
git add kubernetes/storage/rustfs/job-create-bucket-devtron.yaml kubernetes/storage/rustfs/kustomization.yaml
git commit -m "feat: add devtron rustfs bucket"
```

Expected: commit succeeds.

---

### Task 4: Add Devtron App Manifests

**Files:**
- Create: `kubernetes/apps/devtron/namespace.yaml`
- Create: `kubernetes/apps/devtron/secret.sops.yaml`
- Create: `kubernetes/apps/devtron/helmrelease.yaml`
- Create: `kubernetes/apps/devtron/ingress.yaml`
- Create: `kubernetes/apps/devtron/dnsendpoint.yaml`
- Create: `kubernetes/apps/devtron/kustomization.yaml`

- [ ] **Step 1: Create namespace manifest**

Create `kubernetes/apps/devtron/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: devtroncd
```

- [ ] **Step 2: Create Devtron encrypted values secret**

Run this command to generate and encrypt `kubernetes/apps/devtron/secret.sops.yaml` without printing secret values:

```bash
python3 - <<'PY'
from pathlib import Path
import subprocess
import yaml

postgres_vars = yaml.safe_load(Path("ansible/inventory/group_vars/postgresql.yml").read_text())
rustfs = yaml.safe_load(subprocess.check_output(["sops", "--decrypt", "kubernetes/storage/rustfs/secret.sops.yaml"], text=True))

values = {
    "global": {
        "externalPostgres": {
            "PG_PASSWORD": postgres_vars["pg_password_postgres"],
        },
    },
    "secrets": {
        "BLOB_STORAGE_S3_ACCESS_KEY": rustfs["stringData"]["RUSTFS_ACCESS_KEY"],
        "BLOB_STORAGE_S3_SECRET_KEY": rustfs["stringData"]["RUSTFS_SECRET_KEY"],
    },
}

secret = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": "devtron-values",
        "namespace": "devtroncd",
    },
    "stringData": {
        "values.yaml": yaml.safe_dump(values, sort_keys=False),
    },
}

tmp = Path("/private/tmp/devtron-values-secret.yaml")
tmp.write_text(yaml.safe_dump(secret, sort_keys=False))
subprocess.check_call(["sops", "--encrypt", "--encrypted-regex", "^(data|stringData)$", "--output", "kubernetes/apps/devtron/secret.sops.yaml", str(tmp)])
tmp.unlink()
PY
```

Expected: `kubernetes/apps/devtron/secret.sops.yaml` exists and contains encrypted `stringData`.

- [ ] **Step 3: Create HelmRelease**

Create `kubernetes/apps/devtron/helmrelease.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: devtron
  namespace: devtroncd
spec:
  interval: 30m
  chart:
    spec:
      chart: ./kubernetes/charts/devtron-operator
      sourceRef:
        kind: GitRepository
        name: flux-system
        namespace: flux-system
      interval: 12h
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  valuesFrom:
    - kind: Secret
      name: devtron-values
      valuesKey: values.yaml
  values:
    global:
      storageClass: ceph-rbd
      externalPostgres:
        enabled: true
        PG_ADDR: metagross.internal.svc.cluster.local
      dbConfig:
        PG_ADDR: metagross.internal.svc.cluster.local
        PG_PORT: "5432"
        PG_USER: postgres
        PG_DATABASE: orchestrator
    installer:
      modules:
        - cicd
    configs:
      BLOB_STORAGE_PROVIDER: S3
      BLOB_STORAGE_S3_ENDPOINT: http://rustfs.object-storage.svc.cluster.local:9000
      BLOB_STORAGE_S3_ENDPOINT_INSECURE: "true"
      DEFAULT_BUILD_LOGS_BUCKET: devtron
      DEFAULT_CACHE_BUCKET: devtron
      DEFAULT_CACHE_BUCKET_REGION: us-east-1
      DEFAULT_CD_LOGS_BUCKET_REGION: us-east-1
      BASE_URL_SCHEME: HTTPS
      BASE_URL: cloud.dvflw.co
      PROMETHEUS_URL: http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090
    components:
      devtron:
        service:
          type: ClusterIP
        ingress:
          enabled: false
    argo-cd:
      enabled: true
```

- [ ] **Step 4: Create public ingress and certificate**

Create `kubernetes/apps/devtron/ingress.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: devtron
  namespace: devtroncd
spec:
  entryPoints:
    - websecure-external
  routes:
    - match: Host(`cloud.dvflw.co`)
      kind: Rule
      middlewares:
        - name: public-chain
          namespace: infrastructure
      services:
        - name: devtron-service
          port: 80
  tls:
    secretName: devtron-tls
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: devtron
  namespace: devtroncd
spec:
  secretName: devtron-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - cloud.dvflw.co
```

- [ ] **Step 5: Create DNS endpoint**

Create `kubernetes/apps/devtron/dnsendpoint.yaml`:

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: devtron-public
  namespace: devtroncd
spec:
  endpoints:
    - dnsName: cloud.dvflw.co
      recordType: A
      targets:
        - 104.14.105.18
```

- [ ] **Step 6: Create Devtron kustomization**

Create `kubernetes/apps/devtron/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secret.sops.yaml
  - helmrelease.yaml
  - ingress.yaml
  - dnsendpoint.yaml
```

- [ ] **Step 7: Commit Devtron app manifests**

Run:

```bash
git add kubernetes/apps/devtron
git commit -m "feat: add devtron app manifests"
```

Expected: commit succeeds.

---

### Task 5: Wire DNS Zone And Swap Apps

**Files:**
- Modify: `kubernetes/infrastructure/controllers/external-dns/helmrelease.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`
- Modify: `kubernetes/infrastructure/controllers/kustomization.yaml`

- [ ] **Step 1: Add dvflw.co to ExternalDNS domain filters**

In `kubernetes/infrastructure/controllers/external-dns/helmrelease.yaml`, change:

```yaml
    domainFilters:
      - mcnees.me
```

to:

```yaml
    domainFilters:
      - mcnees.me
      - dvflw.co
```

- [ ] **Step 2: Replace Kubero app with Devtron app**

In `kubernetes/apps/kustomization.yaml`, replace:

```yaml
  - ./kubero
```

with:

```yaml
  - ./devtron
```

- [ ] **Step 3: Remove Kubero operator from infrastructure controllers**

In `kubernetes/infrastructure/controllers/kustomization.yaml`, remove:

```yaml
  - kubero-operator
```

- [ ] **Step 4: Build affected kustomizations**

Run:

```bash
kubectl kustomize kubernetes/infrastructure/controllers >/private/tmp/infrastructure-controllers.yaml
kubectl kustomize kubernetes/apps >/private/tmp/apps.yaml
```

Expected: both commands exit successfully.

- [ ] **Step 5: Commit wiring changes**

Run:

```bash
git add kubernetes/infrastructure/controllers/external-dns/helmrelease.yaml kubernetes/apps/kustomization.yaml kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "feat: wire devtron into flux"
```

Expected: commit succeeds.

---

### Task 6: Verify Rendered Devtron Chart

**Files:**
- Read: `kubernetes/apps/devtron/secret.sops.yaml`
- Read: `kubernetes/apps/devtron/helmrelease.yaml`
- Read: `kubernetes/charts/devtron-operator/templates/gitsensor.yaml`
- Read: `kubernetes/charts/devtron-operator/templates/lens.yaml`
- Read: `kubernetes/charts/devtron-operator/templates/casbin.yaml`

- [ ] **Step 1: Render Devtron chart with decrypted values**

Run:

```bash
sops --decrypt kubernetes/apps/devtron/secret.sops.yaml | yq -r '.stringData["values.yaml"]' >/private/tmp/devtron-secret-values.yaml
yq '.spec.values' kubernetes/apps/devtron/helmrelease.yaml >/private/tmp/devtron-public-values.yaml
helm template devtron kubernetes/charts/devtron-operator \
  --namespace devtroncd \
  -f /private/tmp/devtron-public-values.yaml \
  -f /private/tmp/devtron-secret-values.yaml \
  >/private/tmp/devtron-rendered.yaml
rm /private/tmp/devtron-secret-values.yaml /private/tmp/devtron-public-values.yaml
```

Expected: `helm template` exits successfully.

- [ ] **Step 2: Verify component database keys are not duplicated**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import yaml

docs = [doc for doc in yaml.safe_load_all(Path("/private/tmp/devtron-rendered.yaml").read_text()) if doc]
expected = {
    "git-sensor-cm": "git_sensor",
    "lens-cm": "lens",
    "casbin-cm": "casbin",
}
for name, database in expected.items():
    matches = [doc for doc in docs if doc.get("kind") == "ConfigMap" and doc.get("metadata", {}).get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"{name}: expected one ConfigMap, found {len(matches)}")
    data = matches[0].get("data", {})
    if data.get("PG_DATABASE") != database:
        raise SystemExit(f"{name}: PG_DATABASE={data.get('PG_DATABASE')!r}, expected {database!r}")
print("Devtron component PG_DATABASE values are unique and correct.")
PY
```

Expected:

```text
Devtron component PG_DATABASE values are unique and correct.
```

- [ ] **Step 3: Verify Devtron service is ClusterIP**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import yaml

docs = [doc for doc in yaml.safe_load_all(Path("/private/tmp/devtron-rendered.yaml").read_text()) if doc]
services = [doc for doc in docs if doc.get("kind") == "Service" and doc.get("metadata", {}).get("name") == "devtron-service"]
if len(services) != 1:
    raise SystemExit(f"expected one devtron-service, found {len(services)}")
service_type = services[0].get("spec", {}).get("type")
if service_type != "ClusterIP":
    raise SystemExit(f"devtron-service type is {service_type!r}, expected 'ClusterIP'")
print("devtron-service is ClusterIP.")
PY
```

Expected:

```text
devtron-service is ClusterIP.
```

- [ ] **Step 4: Commit any render-fix changes**

If Steps 1-3 forced manifest fixes, run:

```bash
git add kubernetes/charts/devtron-operator kubernetes/apps/devtron
git commit -m "fix: render devtron chart cleanly"
```

Expected: commit succeeds if there were changes. If there were no changes, skip this step.

---

### Task 7: Remove Kubero Manifests

**Files:**
- Delete: `kubernetes/apps/kubero/`
- Delete: `kubernetes/infrastructure/controllers/kubero-operator/`

- [ ] **Step 1: Check for live Kubero-managed workloads**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig get kubero -A
kubectl --kubeconfig talos/kubeconfig get pods -A -l application.kubero.dev/name
```

Expected: either only the `kubero/kubero` control-plane custom resource appears, or no desired user workloads appear. Stop and document any user workloads before continuing.

- [ ] **Step 2: Delete Kubero manifest directories**

Use `apply_patch` delete hunks for these files:

```text
kubernetes/apps/kubero/kubero.yaml
kubernetes/apps/kubero/namespace.yaml
kubernetes/apps/kubero/secret.sops.yaml
kubernetes/apps/kubero/kustomization.yaml
kubernetes/apps/kubero/ingress.yaml
kubernetes/infrastructure/controllers/kubero-operator/kustomization.yaml
```

Expected: `git status --short kubernetes/apps/kubero kubernetes/infrastructure/controllers/kubero-operator` shows only deleted files under those paths.

- [ ] **Step 3: Confirm kustomizations no longer reference Kubero**

Run:

```bash
rg -n "kubero|kubero-operator" kubernetes/apps/kustomization.yaml kubernetes/infrastructure/controllers/kustomization.yaml kubernetes/apps kubernetes/infrastructure/controllers
```

Expected: no output.

- [ ] **Step 4: Commit Kubero removal**

Run:

```bash
git add -A kubernetes/apps/kubero kubernetes/infrastructure/controllers/kubero-operator kubernetes/apps/kustomization.yaml kubernetes/infrastructure/controllers/kustomization.yaml
git commit -m "chore: remove kubero"
```

Expected: commit succeeds.

---

### Task 8: Add Devtron Runbook

**Files:**
- Create: `docs/runbooks/devtron.md`

- [ ] **Step 1: Create runbook**

Create `docs/runbooks/devtron.md`:

```markdown
# Devtron

Devtron replaces Kubero as the homelab Kubernetes application delivery dashboard.

## URL

- Public URL: `https://cloud.dvflw.co`
- Namespace: `devtroncd`
- Flux HelmRelease: `devtroncd/devtron`

## Architecture

Devtron is deployed from the vendored chart at `kubernetes/charts/devtron-operator`.

The vendored chart carries a local patch for external PostgreSQL mode: `gitsensor`, `lens`, and `casbin` render `global.dbConfig | omit "PG_DATABASE"` so their component-specific `PG_DATABASE` values are not duplicated.

Devtron uses:

- PostgreSQL on `metagross.internal.svc.cluster.local`
- Databases: `orchestrator`, `lens`, `git_sensor`, `casbin`
- RustFS endpoint: `http://rustfs.object-storage.svc.cluster.local:9000`
- RustFS bucket: `devtron`
- Traefik entryPoint: `websecure-external`
- Certificate: `devtroncd/devtron-tls`

## Initial Admin Login

Retrieve the initial admin password:

```bash
kubectl --kubeconfig talos/kubeconfig -n devtroncd get secret devtron-secret \
  -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d
```

Username: `admin`

## Verification

Check HelmRelease:

```bash
flux --kubeconfig talos/kubeconfig get helmrelease devtron -n devtroncd
```

Check Devtron installer:

```bash
kubectl --kubeconfig talos/kubeconfig -n devtroncd get installers installer-devtron \
  -o jsonpath='{.status.sync.status}'
```

Expected status: `Applied`

Check certificate:

```bash
kubectl --kubeconfig talos/kubeconfig -n devtroncd get certificate devtron
```

Check DNS:

```bash
dig +short cloud.dvflw.co
```

Expected answer includes `104.14.105.18`.

## Rollback

Revert the commits that removed Kubero and added Devtron, then reconcile Flux:

```bash
flux --kubeconfig talos/kubeconfig reconcile source git flux-system -n flux-system
flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure -n flux-system
flux --kubeconfig talos/kubeconfig reconcile kustomization apps -n flux-system
```

Leave Devtron PostgreSQL databases and the RustFS `devtron` bucket in place until the failed installation has been inspected.
```

- [ ] **Step 2: Commit runbook**

Run:

```bash
git add docs/runbooks/devtron.md
git commit -m "docs: add devtron runbook"
```

Expected: commit succeeds.

---

### Task 9: Roll Out With Flux

**Files:**
- No new file edits.

- [ ] **Step 1: Push commits**

Run:

```bash
git push
```

Expected: push succeeds.

- [ ] **Step 2: Reconcile sources and storage**

Run:

```bash
flux --kubeconfig talos/kubeconfig reconcile source git flux-system -n flux-system
flux --kubeconfig talos/kubeconfig reconcile kustomization storage -n flux-system --with-source
```

Expected: both commands report successful reconciliation.

- [ ] **Step 3: Confirm RustFS bucket job succeeds**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig -n object-storage get jobs rustfs-create-bucket-devtron
kubectl --kubeconfig talos/kubeconfig -n object-storage logs job/rustfs-create-bucket-devtron
```

Expected: job completions show `1/1`; logs show `Bucket created successfully` or bucket already exists.

- [ ] **Step 4: Reconcile infrastructure and apps**

Run:

```bash
flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure -n flux-system --with-source
flux --kubeconfig talos/kubeconfig reconcile kustomization apps -n flux-system --with-source
```

Expected: both commands report successful reconciliation.

- [ ] **Step 5: Verify Devtron HelmRelease**

Run:

```bash
flux --kubeconfig talos/kubeconfig get helmrelease devtron -n devtroncd
```

Expected: `READY` is `True`.

- [ ] **Step 6: Verify Devtron installer**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig -n devtroncd get installers installer-devtron -o jsonpath='{.status.sync.status}'
```

Expected:

```text
Applied
```

- [ ] **Step 7: Verify DNS and TLS**

Run:

```bash
dig +short cloud.dvflw.co
kubectl --kubeconfig talos/kubeconfig -n devtroncd get certificate devtron
curl -I https://cloud.dvflw.co
```

Expected: DNS includes `104.14.105.18`, the certificate is ready, and `curl` returns an HTTPS response.

- [ ] **Step 8: Verify Kubero is pruned**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig get ns kubero kubero-operator-system
kubectl --kubeconfig talos/kubeconfig get crd | rg -i kubero
```

Expected: Kubero namespaces are not found and no Kubero CRDs remain after Flux prune completes.

- [ ] **Step 9: Retrieve Devtron admin password**

Run:

```bash
kubectl --kubeconfig talos/kubeconfig -n devtroncd get secret devtron-secret -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d
```

Expected: command prints a password. Do not commit or paste this value into logs or docs.
