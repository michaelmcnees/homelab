# Local Devtron Chart Patches

Vendored from `devtron/devtron-operator` chart `0.23.2`.

## External PostgreSQL PG_DATABASE duplicate-key patch

The upstream `gitsensor`, `lens`, and `casbin` templates render both `global.dbConfig` and component `.configs` into their component ConfigMaps. Both maps include `PG_DATABASE`, which creates duplicate YAML keys in external PostgreSQL mode.

This vendored copy renders `global.dbConfig | omit "PG_DATABASE"` in:

- `templates/gitsensor.yaml`
- `templates/lens.yaml`
- `templates/casbin.yaml`

Each component still renders its component-specific `PG_DATABASE`, so `git_sensor`, `lens`, and `casbin` remain separate databases.
