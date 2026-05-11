# Cloudflare DNS Audit - 2026-05-11

This audit compares the current `mcnees.me` Cloudflare zone with public hosts declared in the homelab repo.

## Current Control Model

- ExternalDNS should own Kubernetes-routed public app records.
- Terraform/OpenTofu should own static Cloudflare records such as root/www, mail, DKIM, verification records, and non-homelab hosted apps.
- Internal `*.home.mcnees.me` records stay out of Cloudflare and are handled by AdGuard wildcard routing.
- `games.mcnees.me` must remain DNS-only because game allocations use raw TCP/UDP ports on that hostname.

## ExternalDNS-Owned Today

ExternalDNS currently has ownership TXT records for:

- `portal.mcnees.me`
- `support.mcnees.me`

This change adds ExternalDNS ownership intent for:

- `games.mcnees.me` as a DNS-only CNAME to `local.mcnees.me`
- `wings.games.mcnees.me` as a proxied CNAME to `local.mcnees.me`

## Public App Records To Migrate Into ExternalDNS

These Cloudflare records correspond to active or planned Kubernetes-routed services and should be moved into `DNSEndpoint` manifests, then allowed to converge under ExternalDNS ownership:

- `arcade.mcnees.me`
- `docs.mcnees.me`
- `family.mcnees.me`
- `games.mcnees.me`
- `homey.mcnees.me`
- `id.mcnees.me`
- `invitations.mcnees.me`
- `library.mcnees.me`
- `requests.mcnees.me`
- `wings.games.mcnees.me`

Already migrated:

- `portal.mcnees.me`
- `support.mcnees.me`

## Static Records To Manage With Terraform/OpenTofu

These should not be managed by ExternalDNS because they are root records, mail/authentication records, verification records, or non-cluster destinations:

- `mcnees.me`
- `www.mcnees.me`
- `local.mcnees.me`
- `62411269.mcnees.me`
- `em3407.mcnees.me`
- `url14.mcnees.me`
- `s1._domainkey.mcnees.me`
- `s2._domainkey.mcnees.me`
- `sig1._domainkey.mcnees.me`
- any MX, SPF, DMARC, DKIM, or provider verification TXT records

External hosted apps to verify before importing or deleting:

- `budget.mcnees.me`
- `freelancer.mcnees.me`
- `kanban.mcnees.me`
- `musonus.mcnees.me`
- `pokedex.mcnees.me`
- `polywork.mcnees.me`

## Likely Stale Cleanup Candidates

These address records exist in Cloudflare but are not current repo-declared public app targets. Verify manually before deletion:

- `*.cloud.mcnees.me`
- `*.hosting.mcnees.me`
- `cloud.mcnees.me`
- `gaming.mcnees.me`
- `git.mcnees.me`
- `gitlab.mcnees.me`
- `grafana.mcnees.me`
- `grocy.mcnees.me`
- `jake.mcnees.me`
- `minecraft.mcnees.me`
- `pelican.mcnees.me`
- `plex.mcnees.me`
- `postgres.mcnees.me`
- `pterodactyl.mcnees.me`
- `satisfactory.mcnees.me`
- `search.mcnees.me`
- `uptime.mcnees.me`
- `wings.mcnees.me`
- `wizarr.mcnees.me`

## Follow-Up Plan

1. Add a central `DNSEndpoint` manifest for all active public cluster services.
2. Add a `terraform/cloudflare` stack for static zone records.
3. Import or recreate static records in Terraform state.
4. Wait for ExternalDNS ownership TXT records to appear for migrated public app records.
5. Delete stale records only after service owners confirm they are unused.
