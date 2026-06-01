# Signage Client

This runbook covers Debian-based signage clients such as the Dell Optiplex
Micro attached to the ViewSonic TD2230 touch display.

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

Copy the example host vars and edit the address:

```sh
cp ansible/inventory/host_vars/signage-optiplex.yml.example \
  ansible/inventory/host_vars/signage-optiplex.yml
```

Edit `ansible/inventory/host_vars/signage-optiplex.yml`:

```yaml
---
ansible_host: 10.0.10.50
ansible_user: mcnees
ansible_become: true

signage_url: "https://signage.home.mcnees.me/display/kitchen"
signage_enable_host_monitoring: false
```

Then add the host to `ansible/inventory/hosts.yml`:

```yaml
signage_clients:
  hosts:
    signage-optiplex: {}
```

## Apply

Run:

```sh
task ansible:signage-client
```

The playbook installs Chromium, Xorg, Openbox, a dedicated `signage` user, and a
`signage-kiosk.service` systemd unit. The service owns `tty1`, disables display
blanking inside X, and restarts the browser if it exits.

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

To restart the kiosk after changing local display settings:

```sh
sudo systemctl restart signage-kiosk.service
```

## Monitoring

Once the client is visible in Beszel, set these host vars:

```yaml
signage_enable_host_monitoring: true
host_monitoring_beszel_hub_url: "http://beszel.home.mcnees.me:8090"
host_monitoring_beszel_agent_key: "<key-from-beszel>"
```

Then rerun `task ansible:signage-client`.

## Netboot Follow-Up

Netboot can be added later as a bare-metal rebuild path. Prefer a small
Proxmox LXC or VM for DHCP/TFTP/iPXE control, with any larger HTTP install
assets served from the cluster if useful. The Ansible role should remain the
configuration layer after the first boot, regardless of whether the OS was
installed manually or by PXE.
