# Alerting And HomePod VLAN Fix - 2026-06-18

## Summary

Two symptoms were investigated on 2026-06-18:

- Alertmanager email notifications are still arriving, but Pushover is quiet.
- HomePods are unreliable for AirPlay and smart-home control.

The symptoms share timing, but the evidence points to two separate configuration
issues:

- Pushover is configured and has no recorded delivery failures. Current firing
  alerts are `warning` alerts, and the active Alertmanager route sends warnings
  to email only.
- HomePod-like Apple room devices are split between Trusted VLAN 20 and IoT VLAN
  30 while phones are on Trusted VLAN 20. AirPlay and HomeKit are very sensitive
  to that split unless mDNS and follow-up unicast flows are deliberately allowed.

## Applied Changes

- Alertmanager routing was changed live on 2026-06-18 so `severity=warning` and
  `severity=critical` both route to the existing `pushover-email` receiver.
- The encrypted GitOps secret at
  `kubernetes/infrastructure/observability/kube-prometheus-stack/alertmanager-config.sops.yaml`
  was updated with the same route.
- After reload, active warning alerts routed to `pushover-email` and Pushover
  notification attempts increased from 20 to 25. One initial grouped notification
  hit Pushover HTTP 429 during the burst; the existing `repeat_interval` remains
  `12h`, so ongoing retries should be low volume.
- UniFi was inspected before making network changes. Legacy firewall rules,
  firewall groups, and traffic rules were empty, so there was no explicit
  controller-side VLAN block to remove. mDNS is already enabled on Trusted, IoT,
  K8s, Guest, and McLan networks.
- The remaining HomePod remediation is device-side: move the `Office` and
  `Living-Room` Apple clients from `McNet_IoT` to `McNet`.

## Evidence

Alertmanager:

- `Alertmanager/kube-prometheus-stack-alertmanager` is reconciled and available.
- Before the route change, the live `alertmanager-homelab-config` secret
  contained:
  - an `email` receiver,
  - a combined `pushover-email` receiver,
  - a route that sends `severity=critical` to `pushover-email`,
  - a route that sends `severity=warning` to `email`.
- Current active alerts are all `severity=warning`, including Grafana
  CrashLoop/TargetDown, Recyclarr failed jobs, and high Proxmox memory.
- Alertmanager metrics show Pushover has been attempted before and has zero
  recorded failures:
  - `alertmanager_notifications_total{integration="pushover"} 20`
  - `alertmanager_notifications_failed_total{integration="pushover",...} 0`

Smart home / VLAN:

- Current UniFi telemetry has phones and iPads on `McNet` / VLAN 20.
- Apple room-device names are split:
  - VLAN 20 / `McNet`: `Bedroom`, `Basement`, `Kitchen`
  - VLAN 30 / `McNet_IoT`: `Office`, `Living-Room`
- IoT endpoints such as `Lutron-02c0670a`, `HDHomeRun`, `Samsung`,
  `Basement-TV`, and `HOMEYBRIDGE` are on VLAN 30.
- In-cluster smart-home services are running on Kubernetes VLAN 10:
  - `homebridge` pod IP `10.0.10.14`
  - `homey` pod IP `10.0.10.15`

## Fix 1: Make Pushover Match The Desired Alert Policy

The current behavior matches the documented policy in
`docs/runbooks/observability.md`: warnings go to email; critical alerts go to
email plus Pushover.

The intended behavior is "every email-worthy alert should also push to
Pushover", so the warning route was changed to use the combined receiver too.

Recommended Alertmanager routing:

```yaml
route:
  receiver: email
  routes:
    - matchers:
        - alertname = Watchdog
      receiver: "null"
    - matchers:
        - severity = info
      receiver: "null"
    - matchers:
        - severity =~ warning|critical
      receiver: pushover-email
```

Keep the `pushover-email` receiver with both `email_configs` and
`pushover_configs`.

Execution notes for future credential or route changes:

1. Edit the source values in `.secrets/alertmanager.yml` only if credentials
   changed.
2. Regenerate
   `kubernetes/infrastructure/observability/kube-prometheus-stack/alertmanager-config.sops.yaml`
   from the local source template/process used for this repo.
3. Reconcile Flux:

```bash
flux --kubeconfig talos/kubeconfig reconcile kustomization observability --with-source
```

4. Verify Alertmanager loaded the config:

```bash
kubectl --kubeconfig talos/kubeconfig -n observability exec \
  alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  sh -c 'wget -qO- http://127.0.0.1:9093/metrics | grep alertmanager_config_last_reload_successful'
```

5. Verify Pushover is being attempted for current warning alerts:

```bash
kubectl --kubeconfig talos/kubeconfig -n observability exec \
  alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  sh -c 'wget -qO- http://127.0.0.1:9093/metrics | grep "alertmanager_notifications_total.*pushover"'
```

Optional hardening: add an explicit low-noise synthetic alert that routes to
Pushover after Alertmanager restarts or config changes. `Watchdog` is currently
dropped, so it does not prove Pushover delivery.

## Fix 2: Put All HomePods On The Same Client VLAN As Phones

For this household layout, put HomePods on Trusted VLAN 20 with phones, iPads,
and laptops. That restores the simplest AirPlay path and avoids depending on
cross-VLAN AirPlay behavior for daily use.

Immediate UniFi changes:

1. Move the `Office` HomePod-like client currently at `10.0.30.253` from
   `McNet_IoT` to `McNet`.
2. Move the `Living-Room` HomePod-like client currently at `10.0.30.221` from
   `McNet_IoT` to `McNet`.
3. Confirm `Bedroom`, `Basement`, and `Kitchen` remain on `McNet`.
4. Reboot or power-cycle the moved HomePods after changing WiFi.

Verification:

```bash
kubectl --kubeconfig talos/kubeconfig -n observability exec \
  prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  sh -c 'wget -qO- "http://127.0.0.1:9090/api/v1/query?query=unpoller_client_uptime_seconds"' \
  | jq -r '.data.result[] | .metric
    | select(.name == "Office" or .name == "Living-Room" or .name == "Bedroom" or .name == "Basement" or .name == "Kitchen")
    | [.ip, .name, .essid, .vlan, .ap_name] | @tsv'
```

Expected result: all HomePods report `McNet` and VLAN `20`.

## Fix 3: Allow HomePods And Trusted Clients To Reach Smart-Home Backends

After all HomePods are on VLAN 20, keep IoT devices isolated but allow the flows
that make HomeKit and smart-home bridges work.

Recommended firewall policy:

- Allow Established/Related between VLANs.
- Allow Trusted VLAN 20 to IoT VLAN 30 for device control.
- Allow Trusted VLAN 20 to Kubernetes VLAN 10 for Homey/Homebridge ingress and
  services.
- Allow IoT VLAN 30 to Kubernetes VLAN 10 only for the specific smart-home
  services it must initiate to.
- Keep broad IoT-to-Trusted blocked.
- Keep Guest isolated.
- Keep mDNS enabled on Trusted and IoT networks.

Minimum practical allowlist:

| Source | Destination | Purpose |
| --- | --- | --- |
| Trusted VLAN 20 | IoT VLAN 30 | Phone/HomePod initiated device control |
| Trusted VLAN 20 | `10.0.10.14`, `10.0.10.15`, Traefik VIPs | Homebridge/Homey/local web access |
| IoT VLAN 30 | `10.0.10.14`, `10.0.10.15` | IoT devices that must report to Homebridge/Homey |
| IoT VLAN 30 | `10.0.10.201`, `10.0.10.202` UDP/TCP 53 | AdGuard DNS |
| Trusted VLAN 20, IoT VLAN 30 | UDP 5353 via UniFi mDNS service | Bonjour/HomeKit/AirPlay discovery |

AirPlay uses mDNS for discovery and then opens unicast sessions. If discovery
works but playback/control fails, inspect blocked inter-VLAN traffic between the
phone IP and HomePod IP immediately after an AirPlay attempt.

## Terraform Follow-up

`terraform/unifi` currently manages networks, WLANs, port forwards, and DHCP
reservations, but there is no firewall policy-as-code checked in. During this
investigation, `tofu providers schema -json` failed with a provider plugin
handshake error for `filipowm/unifi` v1.0.0, so firewall resource syntax was not
validated locally.

Do the immediate restore in UniFi first. Then codify firewall rules after the
provider can produce a schema and a clean `tofu plan`.

Follow-up acceptance criteria:

- `tofu -chdir=terraform/unifi providers schema -json` succeeds.
- Firewall rules for Trusted, IoT, K8s, and Guest are represented in code.
- `tofu -chdir=terraform/unifi plan` shows only the intended firewall changes.
- The HomePod verification query shows all HomePods on VLAN 20.
- A warning alert increments Pushover notification attempts, or a synthetic
  Pushover test alert is received.
