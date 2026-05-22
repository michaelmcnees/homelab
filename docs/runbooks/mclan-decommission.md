# McLan Decommission Runbook

Use this runbook for the final removal of the legacy flat `10.0.0.0/22` network. It assumes the fresh audit in `docs/runbooks/networking.md` is current.

## Current State

The 2026-05-22 read-only audit found:

- 11 current McLan client entries.
- 6 UniFi infrastructure devices still managed on McLan.
- 5 expected host-static or infrastructure addresses still on McLan.
- Temporary PXE routes still deployed in `kubernetes/apps/external-services/temporary`.
- Only `pxe-pikachu` at `10.0.2.3` currently visible from the temporary PXE endpoint set.

## Pre-Window Checklist

- [ ] Confirm Central Command, TrueNAS, rayquaza, latios, and latias are intentionally staying on McLan for this window.
- [ ] Confirm UniFi infrastructure management migration is out of scope for this window, or prepare a separate controller/switch/AP management migration plan.
- [ ] Re-run the Prometheus UniFi query and confirm McLan clients match `docs/runbooks/networking.md`.
- [ ] Confirm temporary PXE hosts are no longer needed, or explicitly keep the relevant route manifests.
- [ ] Confirm `driveway` should be on IoT and fix its switch/VLAN path before McLan DHCP is touched.
- [ ] Remove McLan management from the Switch Lite-side latios and latias paths.
- [ ] Confirm backups and DNS are healthy before the window.

## Read-Only Audit Commands

Current McLan clients:

```sh
kubectl -n observability exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=unpoller_client_uptime_seconds%7Bnetwork%3D%22McLan%22%7D' \
  | jq -r '.data.result[] | .metric | [.ip, .name, .mac, .wired, (.sw_name // ""), (.sw_port // ""), (.essid // ""), (.ap_name // ""), (.vlan // "")] | @tsv' \
  | sort -u
```

UniFi infrastructure devices:

```sh
kubectl -n observability exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=unpoller_device_info' \
  | jq -r '.data.result[] | .metric | [.ip, .name, .mac, (.model // ""), (.type // ""), (.version // ""), (.site_name // "")] | @tsv' \
  | sort -u
```

Network counts:

```sh
kubectl -n observability exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=count%20by%20(network)%20(unpoller_client_uptime_seconds)' \
  | jq -r '.data.result[] | [.metric.network, .value[1]] | @tsv' \
  | sort
```

## Maintenance Sequence

1. Fix or retire the non-infrastructure McLan clients first:
   - Move `driveway` back to IoT if it should not be on McLan.
   - Classify `office` and `basement`.
   - Retire or move `pxe-pikachu`.
   - Remove McLan management from the alternate latios/latias paths.
2. Decide temporary PXE route fate:
   - If unused, remove the route manifests from `kubernetes/apps/external-services/temporary`.
   - If still needed, document the owner and expected retirement date.
3. Run `scripts/unifi-static-ip-state-audit.sh` and confirm no local IaC/state drift.
4. Run `tofu plan -parallelism=1` in `terraform/unifi` and review network changes.
5. During the window, shrink or disable McLan DHCP in UniFi.
6. Monitor client counts and DNS resolution.
7. Keep the McLan network itself as rollback until no active clients depend on it.
8. Remove McLan only after UniFi infrastructure and host-static management paths have final network assignments.

## Rollback

- Re-enable or expand McLan DHCP if clients lose connectivity.
- Revert any repo cleanup commit that removes temporary external routes, then let Flux reconcile.
- Restore switch port native VLANs to their pre-window values if wired clients disappear.
- Keep Central Command reachable before changing controller or switch management networks.
