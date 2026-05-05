#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG_PATH:-talos/kubeconfig}"
NAMESPACE="${NAMESPACE:-apps}"
DEPLOYMENT="${DEPLOYMENT:-deployment/uptime-kuma}"
DB_PATH="${DB_PATH:-/app/data/kuma.db}"

kubectl --kubeconfig "$KUBECONFIG_PATH" exec -i -n "$NAMESPACE" "$DEPLOYMENT" -- sqlite3 "$DB_PATH" <<'SQL'
PRAGMA foreign_keys = ON;

INSERT INTO "group" (name, public, active, weight)
SELECT 'Core Platform', 0, 1, 1000
WHERE NOT EXISTS (SELECT 1 FROM "group" WHERE name = 'Core Platform');

INSERT INTO "group" (name, public, active, weight)
SELECT 'Infrastructure', 0, 1, 2000
WHERE NOT EXISTS (SELECT 1 FROM "group" WHERE name = 'Infrastructure');

WITH http_monitors(name, url, interval, weight) AS (
  SELECT 'Pocket ID' AS name, 'https://id.mcnees.me' AS url, 60 AS interval, 1000 AS weight
  UNION ALL SELECT 'LLDAP', 'https://lldap.home.mcnees.me', 60, 1010
  UNION ALL SELECT 'Homepage', 'https://dashboard.home.mcnees.me', 60, 1020
  UNION ALL SELECT 'Uptime Kuma', 'https://status.home.mcnees.me', 60, 1030
  UNION ALL SELECT 'AdGuard Home', 'https://adguard.home.mcnees.me', 60, 1040
  UNION ALL SELECT 'Grafana', 'https://grafana.home.mcnees.me', 60, 1060
  UNION ALL SELECT 'Beszel', 'https://beszel.home.mcnees.me', 60, 1070
  UNION ALL SELECT 'Proxmox Latios', 'https://latios.home.mcnees.me', 60, 2000
  UNION ALL SELECT 'Proxmox Latias', 'https://latias.home.mcnees.me', 60, 2010
  UNION ALL SELECT 'Proxmox Rayquaza', 'https://rayquaza.home.mcnees.me', 60, 2020
  UNION ALL SELECT 'TrueNAS', 'https://truenas.home.mcnees.me/ui/', 60, 2030
)
INSERT INTO monitor (
  name, active, user_id, interval, url, type, weight, maxretries,
  ignore_tls, maxredirects, accepted_statuscodes_json, retry_interval, method
)
SELECT name, 1, 1, interval, url, 'http', weight, 2, 1, 10, '["200-399"]', 20, 'GET'
FROM http_monitors
WHERE NOT EXISTS (
  SELECT 1 FROM monitor
  WHERE monitor.name = http_monitors.name
);

UPDATE monitor
SET url = 'https://truenas.home.mcnees.me/ui/'
WHERE name = 'TrueNAS';

INSERT INTO monitor (
  name, active, user_id, interval, type, weight, hostname, port, maxretries,
  retry_interval, accepted_statuscodes_json
)
SELECT 'Metagross Postgres', 1, 1, 60, 'port', 1050, 'metagross.internal.svc.cluster.local', 5432, 2, 20, '["200-299"]'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'Metagross Postgres');

INSERT INTO monitor_group (monitor_id, group_id, weight)
SELECT monitor.id, "group".id, monitor.weight
FROM monitor
JOIN "group" ON "group".name = 'Core Platform'
WHERE monitor.name IN (
  'Pocket ID',
  'LLDAP',
  'Homepage',
  'Uptime Kuma',
  'AdGuard Home',
  'Grafana',
  'Beszel',
  'Metagross Postgres'
)
AND NOT EXISTS (
  SELECT 1 FROM monitor_group
  WHERE monitor_group.monitor_id = monitor.id
    AND monitor_group.group_id = "group".id
);

INSERT INTO monitor_group (monitor_id, group_id, weight)
SELECT monitor.id, "group".id, monitor.weight
FROM monitor
JOIN "group" ON "group".name = 'Infrastructure'
WHERE monitor.name IN (
  'Proxmox Latios',
  'Proxmox Latias',
  'Proxmox Rayquaza',
  'TrueNAS'
)
AND NOT EXISTS (
  SELECT 1 FROM monitor_group
  WHERE monitor_group.monitor_id = monitor.id
    AND monitor_group.group_id = "group".id
);
SQL

kubectl --kubeconfig "$KUBECONFIG_PATH" rollout restart "$DEPLOYMENT" -n "$NAMESPACE"
kubectl --kubeconfig "$KUBECONFIG_PATH" rollout status "$DEPLOYMENT" -n "$NAMESPACE" --timeout=120s
