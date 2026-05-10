# Phase D Bring-up Checklist — 2026-05-09

Operational checklist for activating the Phase D observability work. The
manifests are all in place and `kubectl kustomize` is green, but the
placeholders need real credentials before anything starts collecting.

Companion docs:
- Roadmap: [`2026-05-09-observability-improvements-roadmap.md`](2026-05-09-observability-improvements-roadmap.md)
- Audit: [`../specs/observability-audit-2026-05-09.md`](../specs/observability-audit-2026-05-09.md)
- Restic design: [`../specs/2026-05-09-backup-strategy-restic-design.md`](../specs/2026-05-09-backup-strategy-restic-design.md)

**Order matters.** Each phase has prerequisites for the next.

---

## Phase 0 — Pre-flight (before `git push`)

- [x] **Create the restic NFS directory on TrueNAS**
      ```sh
      ssh truenas "sudo mkdir -p /mnt/data/backups/restic-homelab && sudo chown 1000:1000 /mnt/data/backups/restic-homelab"
      ```
      Add the share to `/etc/exports.d/` (or via the TrueNAS UI) with the same NFSv4.2 options the postgres backup share uses.

- [x] **Set the restic repository password** — *this is the only password in the system you cannot recover from. Save it somewhere outside git too (1Password, Bitwarden, paper).*
      ```sh
      # Generate something strong:
      openssl rand -base64 32
      ```
      Edit [`kubernetes/backups/restic-password-secret.sops.yaml`](../../kubernetes/backups/restic-password-secret.sops.yaml), set all namespace copies to the same password, then:
      ```sh
      sops --encrypt --in-place kubernetes/backups/restic-password-secret.sops.yaml
      ```

You can now merge the branch. Flux will reconcile.

---

## Phase 1 — Watch AdGuard migrate

The existing `adguard` Deployment will be deleted; `adguard-a` is created in its place. Brief outage (~30–60s) while the PVC re-attaches to the new Deployment. `adguard-b` comes up with empty PVCs.

- [ ] **Confirm both AdGuards are running**
      ```sh
      kubectl -n apps get deploy adguard-a adguard-b
      kubectl -n apps get svc adguard-a-dns adguard-b-dns
      # Verify .201 is on adguard-a-dns and .202 is on adguard-b-dns
      ```

- [ ] **Set the same admin user/password on both**
      Open https://adguard.home.mcnees.me — you should still hit the existing config (it's `adguard-a` with the existing PVC). Confirm admin creds work.

      Then port-forward to `adguard-b` and complete the first-run wizard with **the same admin email and password**:
      ```sh
      kubectl -n apps port-forward deploy/adguard-b 8080:80
      # Open http://localhost:8080 → first-run wizard, set same admin user
      ```

      *Reason:* adguardhome-sync uses the same credentials for both instances.

- [x] **Fill in the sync credentials**
      Edit [`kubernetes/apps/adguard/adguardhome-sync-secret.sops.yaml`](../../kubernetes/apps/adguard/adguardhome-sync-secret.sops.yaml) with the admin email + password (same value in `ORIGIN_*` and `REPLICA1_*`):
      ```sh
      sops --encrypt --in-place kubernetes/apps/adguard/adguardhome-sync-secret.sops.yaml
      git commit -am "fix: adguardhome-sync credentials"
      ```

- [x] **Fill in the exporter credentials**
      Same admin creds:
      ```sh
      # edit kubernetes/infrastructure/observability/adguard-exporter/secret.sops.yaml
      sops --encrypt --in-place kubernetes/infrastructure/observability/adguard-exporter/secret.sops.yaml
      ```

- [ ] **Verify sync is working** (after Flux reconciles, ~2–10 minutes)
      ```sh
      kubectl -n apps logs deploy/adguardhome-sync --tail=50
      # Should show "syncing" lines every 10 minutes; first run within seconds of pod start.
      ```

      Cross-check by changing a filter rule in `adguard-a`'s UI, wait 10 min, then check `adguard-b`'s UI — same rule should appear.

- [ ] **Update UniFi DHCP option 6 to advertise both IPs**
      UniFi controller → Settings → Networks → (your LAN) → DHCP Service Management → DNS Server → set primary `10.0.10.201` and secondary `10.0.10.202`. Save and run a DHCP renew on a test client to confirm it picks up both.

---

## Phase 2 — Backups

- [ ] **Confirm `restic-init` Job ran cleanly**
      ```sh
      kubectl -n internal logs job/restic-init
      # Should print "Initializing restic repository at /mnt/restic" once,
      # OR "Repository already initialized" on subsequent runs.
      ```

- [x] **Create a read-only MariaDB user for grimmory backups**
      Connect to grimmory MariaDB (however you do it today) and run:
      ```sql
      CREATE USER 'mariadb-backup'@'%' IDENTIFIED BY 'CHANGE_ME_STRONG_PASSWORD';
      GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, RELOAD, PROCESS, REPLICATION CLIENT ON *.* TO 'mariadb-backup'@'%';
      FLUSH PRIVILEGES;
      ```
      Then encrypt:
      ```sh
      # edit kubernetes/backups/mariadb-grimmory-credentials.sops.yaml
      sops --encrypt --in-place kubernetes/backups/mariadb-grimmory-credentials.sops.yaml
      ```

- [ ] **Verify backup-metrics-exporter sees the repo**
      After ~10 minutes:
      ```sh
      kubectl -n observability logs deploy/backup-metrics-exporter --tail=30
      kubectl -n observability port-forward svc/backup-metrics-exporter 9618:9618
      curl -s localhost:9618/metrics | grep homelab_backup
      ```

- [ ] **Configure TrueNAS ZFS Periodic Snapshot Tasks** for the bulk-data NFS shares
      TrueNAS UI → Data Protection → Periodic Snapshot Tasks → Add:
      - Dataset: `tank/k8s` — recursive, schedule hourly, retention `1 hour × 24, 1 day × 14, 1 week × 8, 1 month × 6`
      - Dataset: `tank/media` — same schedule

      Documented in [`docs/runbooks/truenas.md`](../../docs/runbooks/truenas.md) (you may want to update that runbook with the exact paths once configured).

- [ ] **Wait for first scheduled CronJob run** (mariadb at 03:15 UTC, adguard at 03:05 UTC) and confirm:
      ```sh
      kubectl -n apps get jobs --sort-by=.metadata.creationTimestamp
      # Look for: mariadb-grimmory-backup-<timestamp> Succeeded
      #           adguard-a-config-backup-<timestamp>  Succeeded
      ```

---

## Phase 3 — Media exporters

- [ ] **Collect 7 *arr API keys + Tautulli API key** from each app's web UI
      - sonarr / sonarr-anime / radarr / lidarr / lidarr-kids / prowlarr / bazarr → Settings → General → Security → API Key
      - tautulli → Settings → Web Interface → API → API Key

- [x] **Encrypt the media-exporter Secret**
      ```sh
      # edit kubernetes/media/exporters/secret.sops.yaml
      sops --encrypt --in-place kubernetes/media/exporters/secret.sops.yaml
      ```

- [ ] **Verify exportarr targets are scraped**
      ```sh
      kubectl -n media get pods -l app.kubernetes.io/component=exportarr
      # All 7 should be Running.
      # In Prometheus UI (https://prometheus.home.mcnees.me/targets):
      # search for exportarr — should see 7 targets all UP.
      ```

---

## Phase 4 — Tailscale exporter

- [x] **Create a Tailscale OAuth client**
      https://login.tailscale.com/admin/settings/oauth → Generate OAuth client → scope: `devices:read`. Copy the `client_id` and `client_secret` (you only see the secret once).

- [x] **Encrypt the Tailscale exporter Secret**
      ```sh
      # edit kubernetes/infrastructure/observability/tailscale-exporter/secret.sops.yaml
      sops --encrypt --in-place kubernetes/infrastructure/observability/tailscale-exporter/secret.sops.yaml
      ```

- [ ] **Verify the exporter is collecting**
      ```sh
      kubectl -n observability logs deploy/tailscale-exporter --tail=30
      # Should show "tailscale-exporter listening on :9619" with no recurring errors.
      kubectl -n observability port-forward deploy/tailscale-exporter 9619:9619
      curl -s localhost:9619/metrics | grep tailscale_device
      ```

      Open the **Homelab / Household Compute** dashboard in Grafana — the Tailnet Devices row should populate.

---

## Phase 5 — Beszel re-targeting

- [x] **Confirm oauth2-proxy is gone from Beszel UI**
      Visit `https://beszel.home.mcnees.me` — should show Beszel's login screen directly (no oauth2-proxy redirect).

- [ ] **Set up a Beszel admin user** (if not already) via Beszel's first-run wizard.

- [x] **Remove Beszel Tailnet sharing**
      Beszel is intentionally not shared over Tailscale. The `beszel-tailnet`
      ingress was removed from the repo and deleted from the live cluster.

---

## Phase 6 — Onboard a household host (repeat per device)

For each laptop / Mac Studio / kids' future PC:

- [ ] **Install Tailscale and join the tailnet** (out-of-band — `brew install tailscale` on Mac, distro package on Linux). Note the host's tailnet hostname.

- [ ] **Add the host to the Beszel hub UI**
      In Beszel UI: Add System → fill in the hostname, port `45876`. Beszel generates a public key — copy it.

- [ ] **Add the host to Ansible inventory**
      Edit [`ansible/inventory/hosts.yml`](../../ansible/inventory/hosts.yml) and add (creating the group if needed):
      ```yaml
      household_hosts:
        hosts:
          michael-mbp:
            ansible_host: michael-mbp.tail-XXXX.ts.net
            ansible_user: michael
            host_monitoring_beszel_agent_key: "ed25519:<the-key-from-beszel>"
        vars:
          host_monitoring_beszel_hub_url: "http://beszel.tail-XXXX.ts.net:8090"
      ```

- [ ] **Run the ansible playbook**
      ```sh
      cd ansible
      ansible-playbook -i inventory/hosts.yml playbooks/host-monitoring.yml --limit michael-mbp
      ```

- [ ] **Add the host to Prometheus's static scrape config**
      Edit [`kubernetes/infrastructure/observability/kube-prometheus-stack/household-hosts-scrape.yaml`](../../kubernetes/infrastructure/observability/kube-prometheus-stack/household-hosts-scrape.yaml), uncomment and add:
      ```yaml
      - targets:
          - "michael-mbp.tail-XXXX.ts.net:9100"
        labels:
          job: household_compute
          household_role: workstation
      ```
      Add `household-hosts-scrape.yaml` back to the kube-prometheus-stack
      kustomization once at least one real target exists, then commit and let
      Flux reconcile.

- [ ] **Verify both targets**
      - Beszel hub UI: host shows green / connected
      - Prometheus targets: `household-hosts` job shows the new target as `up=1`
      - Grafana → Homelab / Household Compute: the host appears in the Workstation Health table

---

## Sanity-check after everything

Run this once everything's bedded in (give it 24h for the first backup cycle):

```sh
# Inventory of new alerting groups firing zero alerts:
kubectl -n observability get prometheusrule -o name | xargs -I{} kubectl -n observability get {} -o yaml | grep -E "alert:|severity:" | head -50

# Confirm all new ServiceMonitors picked up by Prometheus operator:
kubectl get servicemonitor,podmonitor -A | grep -E "adguard|backup|exportarr|tautulli|tailscale|flux"

# Backup repo first sample (after ~24h):
# In Grafana: dashboard "Homelab / Backups" should show non-zero
#   homelab_backup_latest_timestamp_seconds{tag="adguard-a-config"}
#   homelab_backup_latest_timestamp_seconds{tag="mariadb-grimmory"}
```

---

## Realistic time estimate

| Phase | Hands-on time | Wait time |
|---|---|---|
| 0 (TrueNAS path + restic password) | 5 min | — |
| 1 (AdGuard) | 15 min | ~10 min for first sync |
| 2 (Backups) | 20 min (mostly TrueNAS UI) | ~24h to confirm full daily cycle |
| 3 (Media) | 15 min (collecting 8 API keys) | ~5 min |
| 4 (Tailscale) | 10 min | ~5 min |
| 5 (Beszel) | 5 min | — |
| 6 (per household host) | 10 min | ~5 min |

Total active time before everything is wired: **~70 min**, plus one overnight wait for the first backup cycle to complete.
