# Local Devtron Chart Patches

Vendored from `devtron/devtron-operator` chart `0.23.2`.

## External PostgreSQL PG_DATABASE duplicate-key patch

The upstream `gitsensor`, `lens`, and `casbin` templates render both `global.dbConfig` and component `.configs` into their component ConfigMaps. Both maps include `PG_DATABASE`, which creates duplicate YAML keys in external PostgreSQL mode.

This vendored copy renders `global.dbConfig | omit "PG_DATABASE"` in:

- `templates/gitsensor.yaml`
- `templates/lens.yaml`
- `templates/casbin.yaml`

Each component still renders its component-specific `PG_DATABASE`, so `git_sensor`, `lens`, and `casbin` remain separate databases.

## Kubernetes batch/v1 compatibility patch

The upstream chart conditionally falls back to `batch/v1beta1` for several Jobs and CronJobs. Modern Kubernetes versions reject `batch/v1beta1`, and local Helm rendering does not reliably advertise capabilities as `batch/v1/Job` or `batch/v1/CronJob`.

This vendored copy renders `batch/v1` directly in:

- `templates/app-sync-job.yaml`
- `templates/cost-sync-job.yaml`
- `templates/grafana.yaml`
- `templates/migrator.yaml`
