# UniFi Import Prep

Use this runbook before changing UniFi with OpenTofu. It is intentionally prep-only: the audit script reads local IaC and local OpenTofu state, but it does not contact UniFi or change infrastructure.

## Static Reservation Audit

Run:

```sh
scripts/unifi-static-ip-state-audit.sh
```

The script compares:

- Declared reservations in `terraform/unifi/static_ips.tf`
- Locally tracked resources in `terraform/unifi/terraform.tfstate`

It reports reservations that are declared but not tracked, and it prints import command templates for those missing entries.

The latest local prep audit reported 69 declared reservations, 69 tracked reservations, 0 missing entries, and 0 stale entries. Treat that as a local-state result, not proof that UniFi live state is ready for apply.

Local state IDs for existing `unifi_user.static_ips` resources are UniFi client/user object IDs, not MAC addresses. Before importing a missing reservation, collect the matching UniFi object ID from the controller UI or API and replace `<unifi-client-object-id>` in the generated command template.

## Safe Import Sequence

1. Run `scripts/unifi-static-ip-state-audit.sh`.
2. For each missing reservation, confirm the device still exists in UniFi and that its MAC/IP/name match the IaC declaration.
3. Skip retired services and temporary migration entries until they have a clear keep/remove decision.
4. Import one reservation at a time:

   ```sh
   cd terraform/unifi
   tofu import 'unifi_user.static_ips["example_key"]' '<unifi-client-object-id>'
   ```

5. After imports, run a plan only:

   ```sh
   cd terraform/unifi
   tofu plan -parallelism=1
   ```

6. Do not apply until the plan is reviewed and the maintenance window is appropriate.

## Entries To Reclassify Before Any Apply

These declarations or related network paths are migration-era candidates. Confirm whether each should stay, move, or be removed before applying UniFi changes:

| Area | Examples | Decision needed |
| --- | --- | --- |
| Legacy app LXCs | `adguard_home`, `lldap`, `pocketid`, `traefik`, `oauth2_proxy`, `outline`, `postgresql`, `mariadb`, `redis`, `influxdb`, `n8n`, `ollama`, `openwebui`, `overseerr`, `wizarr`, `booklore`, `lazylibrarian`, `pelican_panel` | Keep only if the LXC still exists or is needed as rollback. |
| Old K3s and PXE entries | `k3s_*`, `pxe_*`, `px_mew` | Remove after confirming no temporary external routes or PXE workflows still depend on them. |
| Host-static infrastructure | `truenas`, `rayquaza`, `latios`, `latias`, `central_command` | Keep as collision guards until their management networks are deliberately migrated. |
| Port forwards to legacy IPs | `https_cf`, `satisfactory`, `ldap`, `xbox_live` | Confirm destination ownership before any cleanup. |

## Guardrails

- Do not commit `terraform/unifi/terraform.tfstate`; it is local-only state and already ignored.
- Do not run `tofu apply` as part of import prep.
- Do not disable McLan DHCP until the blockers in `docs/runbooks/networking.md` are resolved.
- Do not remove `kubernetes/apps/external-services/temporary` until the PXE routes are confirmed unused or replaced.
