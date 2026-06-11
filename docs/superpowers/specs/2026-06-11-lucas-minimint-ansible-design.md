# Lucas MiniMint Ansible Onboarding Design

## Goal

Bring Lucas's Linux Mint desktop, `lucas-minimint`, under homelab Ansible management so it has stable LAN reachability, SSH access for the `mmcnees` admin account, passwordless sudo for routine automation, and baseline maintenance tooling. Future desktop configuration, including DOS game launchers, should build on this foundation but is out of scope for the first pass.

## Current Context

The homelab repository already has:

- `ansible/inventory/hosts.yml` for Ansible inventory.
- `ansible/roles/host-monitoring` for Beszel and node_exporter on household hosts.
- `ansible/roles/cockpit` for Cockpit on Debian-family hosts.
- `ansible/roles/signage-client` for kiosk clients, which is a different desktop use case and should not absorb normal user desktop management.
- `terraform/unifi/static_ips.tf` for UniFi DHCP reservations.
- `kubernetes/infrastructure/observability/kube-prometheus-stack/household-hosts-scrape.yaml` for static household node_exporter scrape targets.

`host-monitoring.yml` already targets a `household_hosts` group, but the current inventory does not define that group. `rotom` has host monitoring enabled from the signage playbook, and Prometheus already scrapes `10.0.30.183:9100`.

## Network Design

`lucas-minimint` is a personal Linux Mint desktop connected over WiFi. It belongs on the Trusted VLAN 20 network (`10.0.20.0/24`), which is where personal trusted clients live. The `McNet` SSID maps to VLAN 20.

Create a UniFi DHCP reservation:

- Device name: `lucas-minimint`
- MAC address: `bc:a8:a6:b6:c4:66`
- Reserved IP: `10.0.20.98`

The current temporary address is `10.0.20.239`. Ansible should target `10.0.20.98` after the reservation is applied and the client renews DHCP.

## Access Design

Use the existing admin account:

- SSH user: `mmcnees`
- Become: `true`
- Sudo policy: passwordless sudo for `mmcnees` on `lucas-minimint`
- SSH key: the normal public key from the admin workstation

First contact requires a bootstrap run while password-based SSH and sudo still work. After bootstrap, routine Ansible runs should not require interactive sudo.

The bootstrap automation should:

1. Install and enable `openssh-server`.
2. Ensure the `mmcnees` account has the normal admin public key in `~mmcnees/.ssh/authorized_keys`.
3. Install a sudoers drop-in granting `mmcnees` passwordless sudo.
4. Validate the sudoers file with `visudo`.

## Ansible Inventory Design

Add a normal desktop grouping rather than reusing the signage group:

- `personal_desktops`: normal family/admin desktops.
- `household_hosts`: common non-cluster household machines used by monitoring and future maintenance plays.

`lucas-minimint` should be a member of both through group hierarchy:

```yaml
household_hosts:
  children:
    personal_desktops:
      hosts:
        lucas-minimint:
          ansible_host: 10.0.20.98
          ansible_user: mmcnees
          ansible_become: true
```

Keep host-specific desktop and monitoring variables in `ansible/inventory/host_vars/lucas-minimint.yml` when they grow beyond basic inventory fields.

## Role And Playbook Design

Create a focused desktop role instead of expanding the kiosk role:

- Role: `ansible/roles/linux-mint-desktop`
- Playbook: `ansible/playbooks/linux-mint-desktops.yml`

The first implementation should handle baseline management only:

- Confirm the host is Debian-family Linux.
- Install baseline packages useful for remote management and future desktop automation.
- Include the existing `cockpit` role when enabled.
- Include the existing `host-monitoring` role when enabled.
- Define a future-facing launcher variable shape but do not create desktop shortcuts yet.

Suggested desktop variables:

```yaml
linux_mint_desktop_enable_cockpit: true
linux_mint_desktop_enable_host_monitoring: true
linux_mint_desktop_launchers: []
```

Future DOS game launcher management can extend `linux_mint_desktop_launchers` with fields such as `name`, `desktop_file`, `command`, `icon`, `working_directory`, and `categories`.

## Observability Design

After node_exporter is installed, add `10.0.20.98:9100` to `household-hosts-scrape.yaml` with labels:

```yaml
job: household_compute
household_role: personal_desktop
host: lucas-minimint
```

Beszel should remain optional per host. If enabled, `lucas-minimint` needs a per-host Beszel agent key from the Beszel UI. If no key is available during the first implementation, configure node_exporter and leave Beszel disabled for this host.

## Security And Safety

Passwordless sudo should be limited to `mmcnees` on this host through a dedicated file under `/etc/sudoers.d/`. The file must be installed with mode `0440` and validated with `visudo -cf`.

The playbooks should avoid changing Lucas's desktop session, browser configuration, games, or user files in the first pass. Remote desktop customization is a later feature built on the SSH and Ansible foundation.

## Validation

Validate the first pass with:

1. Apply or plan the UniFi DHCP reservation.
2. Renew DHCP or reboot `lucas-minimint` and confirm it receives `10.0.20.98`.
3. Run the bootstrap playbook using password-based SSH.
4. Confirm passwordless SSH and sudo work with `ansible -m ping` and `ansible -m command -a 'sudo -n true'`.
5. Run the Linux Mint desktop playbook.
6. Confirm Cockpit socket is active if enabled.
7. Confirm node_exporter is listening on port `9100`.
8. Confirm Prometheus marks the `lucas-minimint` target as up after the scrape config is applied.
