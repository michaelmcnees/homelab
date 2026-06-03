# Signage Client

This runbook covers Debian-based signage clients such as `rotom`, the Dell
Optiplex Micro attached to the ViewSonic TD2230 touch display.

## Goal

The client boots into a full-screen Chromium kiosk and opens a managed URL. That
URL can be Questboard, Home Assistant, Grafana, Anthias, or a future
cluster-hosted signage router.

## Debian Install Notes

During installation:

1. Install Debian with SSH server enabled.
2. Create the normal administrative user used for Ansible.
3. Add that user to sudo.
4. Use wired Ethernet if possible.
5. Leave desktop environment selection unchecked; the Ansible role installs the
   minimal Xorg/Openbox kiosk stack.

After the first boot, confirm SSH works from the workstation:

```sh
ssh mcnees@<optiplex-ip-or-dns>
```

## Inventory

Rotom is tracked in Ansible as a real host:

```yaml
signage_clients:
  hosts:
    rotom: {}
```

Its host vars live in `ansible/inventory/host_vars/rotom.yml`:

```yaml
---
ansible_host: 10.0.30.183
ansible_user: mmcnees
ansible_become: true

signage_url: "https://questboard.home.mcnees.me"
signage_enable_host_monitoring: false
```

## Apply

Run:

```sh
task ansible:signage-client
```

The playbook installs Chromium, Xorg, Openbox, a dedicated `signage` user, and a
`signage-kiosk.service` systemd unit. The service owns `tty1`, disables display
blanking inside X, and restarts the browser if it exits.

The session waits for HTTP(S) `signage_url` to become reachable before launching
Chromium, which avoids stranding the display on Chrome's offline page when Wi-Fi
or DNS comes up after X starts.

Rotom's hidden-SSID Wi-Fi is configured locally on the host with
`wpa_supplicant@wlp1s0.service` and `systemd-networkd`; the Wi-Fi secret is not
stored in this repository.

Rotom opts into `signage_manage_network_stack`, so Ansible disables
ifupdown/`networking.service`, NetworkManager, and
`systemd-networkd-wait-online.service`. The kiosk does its own URL readiness
check instead of delaying boot on `network-online.target`.

## Change Displayed Content

Change `signage_url` in the host vars file, then rerun:

```sh
task ansible:signage-client
```

## Useful Checks

On the client:

```sh
systemctl status signage-kiosk.service
journalctl -u signage-kiosk.service -b
cat /etc/signage-client/signage.env
```

If the display shows Chrome's offline page after moving or rebooting the client,
first verify the host still has a usable address:

```sh
ip -br addr show wlp1s0
ip route
curl -I https://questboard.home.mcnees.me
```

To restart the kiosk after changing local display settings:

```sh
sudo systemctl restart signage-kiosk.service
```

## Monitoring

For Prometheus-only monitoring, enable the monitoring role and disable Beszel:

```yaml
signage_enable_host_monitoring: true
host_monitoring_enable_beszel: false
host_monitoring_node_exporter_listen: "0.0.0.0:9100"
```

Once the client is visible in Beszel, keep monitoring enabled and add the Beszel vars:

```yaml
signage_enable_host_monitoring: true
host_monitoring_enable_beszel: true
host_monitoring_beszel_hub_url: "http://beszel.home.mcnees.me:8090"
host_monitoring_beszel_agent_key: "<key-from-beszel>"
```

Then rerun `task ansible:signage-client`.

Set `signage_enable_cockpit: true` when the client should expose Cockpit on
port `9090` for browser-based administration.

## Netboot Follow-Up

Netboot can be added later as a bare-metal rebuild path. Prefer a small
Proxmox LXC or VM for DHCP/TFTP/iPXE control, with any larger HTTP install
assets served from the cluster if useful. The Ansible role should remain the
configuration layer after the first boot, regardless of whether the OS was
installed manually or by PXE.
