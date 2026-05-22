# Project Completion Hit List

This is the remaining work to call the homelab migration complete. Items are grouped by what can be prepared in-repo versus what requires live infrastructure changes.

## Repo-Ready Prep

- [x] Add a read-only UniFi static reservation audit helper: `scripts/unifi-static-ip-state-audit.sh`.
- [x] Document the safe UniFi import workflow: `docs/runbooks/unifi-import-prep.md`.
- [x] Turn the McLan decommission checklist into a final maintenance-window runbook once the active-client list is fresh.
- [x] Decide which temporary PXE routes in `kubernetes/apps/external-services/temporary` should be removed versus retained.
- [x] Prepare cleanup patches for retired external services, but hold them until live route usage is verified.
- [x] Remove stale, unreferenced Homebridge external-service manifest that pointed at old `10.0.2.5`.
- [ ] Add final "break glass" documentation for DNS, Flux, SOPS, Talos, UniFi, and storage access.
- [ ] Add an "in case of death" operator guide with account locations, recovery order, and service ownership.

## Needs Live Operator Work

- [x] Run a fresh UniFi client audit and classify remaining McLan clients from `docs/runbooks/networking.md`.
- [x] Remove retired Dell mini nodes from Proxmox cluster membership with `pvecm delnode`.
- [ ] Disconnect the latios/latias secondary management links from Switch Lite ports 11 and 9.
- [ ] Remove retired `pxe-pikachu` UniFi reservation/state now that Pikachu is shut down.
- [ ] Restore TrueNAS/snorlax NFS reachability for Proxmox `nfs-isos` and `nfs-backups`; `10.0.1.1` was unreachable from Proxmox on 2026-05-22 even though VM `500` was running on rayquaza.
- [ ] Finish McLan decommissioning: shrink or disable DHCP, monitor, then remove the legacy flat `/22` only after rollback is no longer needed.
- [ ] Confirm whether `https_cf`, `satisfactory`, `ldap`, and `xbox_live` port forwards still point to intended live destinations.
- [x] Confirm temporary PXE endpoints are no longer needed, then delete the live routes and remove the repo manifests.
- [x] Detach Talos installer ISOs from installed Proxmox VMs so control-plane restarts do not depend on the TrueNAS-backed `nfs-isos` datastore.
- [ ] Create and configure the PBS LXC (`deoxys`) and backup jobs.
- [ ] Create or migrate the Pelican Wings VM on pikachu/rayquaza if that is still the intended final topology.

## Observability And Backup Follow-Up

- [ ] Confirm AdGuard sync by changing a harmless rule on `adguard-a` and checking replication to `adguard-b`.
- [ ] Confirm UniFi DHCP advertises both AdGuard VIPs: `10.0.10.201` and `10.0.10.202`.
- [ ] Confirm restic scheduled backups after a full daily cycle.
- [ ] Configure or verify TrueNAS periodic snapshots for `tank/k8s` and `tank/media`.
- [ ] Watch the Tailscale exporter logs for recurring API/network errors even though Prometheus currently scrapes it successfully.
- [ ] Finish household host onboarding in Beszel and Prometheus if those hosts should appear in the household dashboard.

## Completion Gate

Call the project complete when all of these are true:

- McLan DHCP is disabled or removed and no unexpected clients remain on `10.0.0.0/22`.
- UniFi IaC state is reconciled and `tofu plan` is reviewed with no surprising network changes.
- Temporary PXE and legacy external-service routes are either removed or explicitly documented as permanent.
- PBS/restic/ZFS snapshot coverage is documented and producing metrics.
- Core runbooks cover DNS, ingress, storage, backups, identity, Kubernetes recovery, and UniFi recovery.
- A non-author can follow the break-glass docs to recover DNS, reach the cluster, and identify backup restore paths.
