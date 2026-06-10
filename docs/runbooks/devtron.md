# Devtron

Devtron is deployed at `https://cloud.dvflw.co` as the replacement for Kubero.

## Shape

- Namespace: `devtroncd`
- Flux app: `kubernetes/apps/devtron`
- Chart: vendored `kubernetes/charts/devtron-operator`
- HelmRelease: `devtron/devtron`, sourced from the Flux GitRepository
- URL: Traefik `IngressRoute/devtron` on `websecure-external`
- Certificate: `Certificate/devtron` with secret `devtron-tls`
- DNS: `DNSEndpoint/devtron-public` publishes `cloud.dvflw.co`
- Database: metagross PostgreSQL at `metagross.internal.svc.cluster.local`
- Databases: `orchestrator`, `lens`, `git_sensor`, `casbin`
- Object storage: RustFS bucket `devtron`
- StorageClass: `ceph-rbd`

The Flux `apps` Kustomization waits for `infrastructure-configs`, `databases`, and `storage`. Keep that ordering: Devtron's Helm hooks need the metagross service and RustFS bucket path ready before the chart settles.

## Secrets

Devtron private Helm values are stored in:

```sh
SOPS_AGE_KEY_FILE=homelab.age.key sops kubernetes/apps/devtron/secret.sops.yaml
```

The encrypted payload is `stringData.values.yaml` for the `devtron-values` Secret. It currently carries:

- `global.externalPostgres.PG_PASSWORD`
- `secrets.BLOB_STORAGE_S3_ACCESS_KEY`
- `secrets.BLOB_STORAGE_S3_SECRET_KEY`

The PostgreSQL password must match `pg_password_postgres` in the ignored Ansible inventory file:

```sh
ansible/inventory/group_vars/postgresql.yml
```

Do not commit the ignored inventory file.

## Chart Patches

The Devtron operator chart is vendored at version `0.23.2`. Local patch context lives in:

```text
kubernetes/charts/devtron-operator/PATCHES.md
```

Current local patches:

- `gitsensor`, `lens`, and `casbin` omit `global.dbConfig.PG_DATABASE` before merging component configs. This prevents duplicate `PG_DATABASE` keys when external PostgreSQL is enabled.
- chart templates that previously selected `batch/v1beta1` now render `batch/v1` for Kubernetes compatibility.
- the external PostgreSQL database creator renders as a normal Job, not a `pre-install` hook, so it can reference chart-created service accounts and config maps.

Before upgrading the chart, reapply or retire those patches deliberately and run the render checks below.

## Render Checks

Render the chart with the public HelmRelease values and encrypted private values:

```sh
SOPS_AGE_KEY_FILE=homelab.age.key sops --decrypt kubernetes/apps/devtron/secret.sops.yaml | \
  yq -r '.stringData["values.yaml"]' >/private/tmp/devtron-secret-values.yaml

yq '.spec.values' kubernetes/apps/devtron/helmrelease.yaml >/private/tmp/devtron-public-values.yaml

helm template devtron kubernetes/charts/devtron-operator \
  --namespace devtroncd \
  -f /private/tmp/devtron-public-values.yaml \
  -f /private/tmp/devtron-secret-values.yaml \
  >/private/tmp/devtron-rendered.yaml
```

Expected checks:

```sh
rg -n "name: git-sensor-cm|name: lens-cm|PG_DATABASE: git_sensor|PG_DATABASE: lens" /private/tmp/devtron-rendered.yaml
rg -n "apiVersion: (batch|extensions)/v1beta1" /private/tmp/devtron-rendered.yaml
rg -n "name: devtron-service|type: ClusterIP" /private/tmp/devtron-rendered.yaml
```

Expected: `git-sensor-cm` uses `git_sensor`, `lens-cm` uses `lens`, no deprecated beta API versions are rendered, and `devtron-service` is `ClusterIP`.

`casbin` is enterprise-gated in the chart. To check the patched template without enabling enterprise in production:

```sh
helm template devtron kubernetes/charts/devtron-operator \
  --namespace devtroncd \
  -f /private/tmp/devtron-public-values.yaml \
  -f /private/tmp/devtron-secret-values.yaml \
  --set devtronEnterprise.enabled=true \
  >/private/tmp/devtron-enterprise-rendered.yaml

rg -n "name: casbin-cm|PG_DATABASE: casbin" /private/tmp/devtron-enterprise-rendered.yaml
```

## Rollout

Flux tracks the `main` branch. After the Devtron changes are on `main`, reconcile in dependency order:

```sh
flux --kubeconfig talos/kubeconfig reconcile source git flux-system -n flux-system
flux --kubeconfig talos/kubeconfig reconcile kustomization storage -n flux-system --with-source
flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure -n flux-system --with-source
flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure-configs -n flux-system --with-source
flux --kubeconfig talos/kubeconfig reconcile kustomization databases -n flux-system --with-source
flux --kubeconfig talos/kubeconfig reconcile kustomization apps -n flux-system --with-source
```

Watch the RustFS bucket job:

```sh
kubectl --kubeconfig talos/kubeconfig -n object-storage get job rustfs-create-bucket-devtron
kubectl --kubeconfig talos/kubeconfig -n object-storage logs job/rustfs-create-bucket-devtron
```

Watch Devtron:

```sh
flux --kubeconfig talos/kubeconfig -n devtroncd get helmrelease devtron
kubectl --kubeconfig talos/kubeconfig -n devtroncd get pods
kubectl --kubeconfig talos/kubeconfig -n devtroncd get jobs
kubectl --kubeconfig talos/kubeconfig -n devtroncd get certificate devtron
kubectl --kubeconfig talos/kubeconfig -n devtroncd get ingressroute devtron -o yaml
```

The HelmRelease sets `install.disableWaitForJobs` and `upgrade.disableWaitForJobs` because `app-sync-job-*` imports chart data and can run longer than the install timeout. Treat `HelmRelease/devtron` plus the workload deployments/statefulsets as the install health signal; `app-sync-job-*` may continue after Helm is Ready.

## DNS and TLS

The `cloud.dvflw.co` route depends on the shared Cloudflare API token in:

```text
infrastructure/cloudflare-api-token
```

That token must be able to read and edit the `dvflw.co` zone. If the certificate stays pending, inspect the ACME challenge:

```sh
kubectl --kubeconfig talos/kubeconfig -n devtroncd describe challenge
```

This error means the token cannot see the `dvflw.co` zone:

```text
Found no Zones for domain _acme-challenge.cloud.dvflw.co.
```

Update the Cloudflare token scope/account, then re-run:

```sh
flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure -n flux-system --with-source
flux --kubeconfig talos/kubeconfig reconcile kustomization apps -n flux-system --with-source
```

## Login

The chart notes point to `devtron-secret` key `ADMIN_PASSWORD` for the default admin password. Give the installer a minute to finish before reading it:

```sh
kubectl --kubeconfig talos/kubeconfig -n devtroncd get secret devtron-secret \
  -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d; echo
```

If the key is not present yet, wait for Devtron pods and jobs to finish and check recent logs:

```sh
kubectl --kubeconfig talos/kubeconfig -n devtroncd get pods,jobs
kubectl --kubeconfig talos/kubeconfig -n devtroncd logs deployment/devtron --tail=200
```

Then sign in at:

```text
https://cloud.dvflw.co/dashboard
```

## Kubero Teardown

Before removing Kubero from Git, verify no Kubero-managed workloads are still running:

```sh
kubectl --kubeconfig talos/kubeconfig get kubero -A
kubectl --kubeconfig talos/kubeconfig get pods -A -l application.kubero.dev/name
```

After the Kubero manifests and operator are removed from `main`, Flux prune should remove the Kubero custom resource, namespace, and operator resources:

```sh
kubectl --kubeconfig talos/kubeconfig get kubero -A
kubectl --kubeconfig talos/kubeconfig get namespace kubero kubero-operator-system
```

## Rollback

To roll back before Devtron is trusted:

1. Revert the commits that remove Kubero manifests and add Devtron.
2. Push `main`.
3. Reconcile the Flux source and affected Kustomizations.

```sh
flux --kubeconfig talos/kubeconfig reconcile source git flux-system -n flux-system
flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure -n flux-system --with-source
flux --kubeconfig talos/kubeconfig reconcile kustomization apps -n flux-system --with-source
```

Devtron's chart uses some hook resources with `helm.sh/resource-policy: keep`. If uninstalling Devtron fully, inspect the `devtroncd`, `devtron-ci`, `devtron-cd`, `devtron-demo`, and `argo` namespaces for retained resources before deleting namespaces.
