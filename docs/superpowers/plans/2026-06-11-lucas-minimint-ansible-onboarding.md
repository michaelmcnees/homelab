# Lucas MiniMint Ansible Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Onboard `lucas-minimint` into UniFi, Ansible, SSH-based maintenance, Cockpit, and household host monitoring.

**Architecture:** Add a Trusted VLAN DHCP reservation in UniFi, define `lucas-minimint` in Ansible as a personal desktop and household host, create a reusable bootstrap role for SSH/sudo setup, and create a focused Linux Mint desktop role that composes existing Cockpit and host-monitoring roles. Keep DOS game launchers out of this pass while leaving a typed variable shape for future desktop launcher management.

**Tech Stack:** OpenTofu/Terraform UniFi provider, Ansible YAML roles/playbooks, Linux Mint/Debian apt/systemd, Kubernetes Prometheus Operator `ScrapeConfig`.

---

## File Structure

- Modify: `terraform/unifi/static_ips.tf`
  - Add a UniFi DHCP reservation for `lucas-minimint`.
- Modify: `ansible/inventory/hosts.yml`
  - Add `household_hosts` and `personal_desktops` inventory groups.
- Create: `ansible/inventory/host_vars/lucas-minimint.yml`
  - Store host-specific role flags and monitoring defaults.
- Create: `ansible/roles/linux-desktop-bootstrap/defaults/main.yml`
  - Define bootstrap admin user and authorized key path.
- Create: `ansible/roles/linux-desktop-bootstrap/tasks/main.yml`
  - Install SSH, authorize the admin key, and configure passwordless sudo.
- Create: `ansible/roles/linux-desktop-bootstrap/README.md`
  - Document first-contact behavior.
- Create: `ansible/playbooks/bootstrap-linux-desktops.yml`
  - Run the bootstrap role against personal desktops.
- Create: `ansible/roles/linux-mint-desktop/defaults/main.yml`
  - Define management package list, Cockpit/monitoring toggles, and empty launcher list.
- Create: `ansible/roles/linux-mint-desktop/tasks/main.yml`
  - Validate Debian-family host and install baseline packages.
- Create: `ansible/roles/linux-mint-desktop/README.md`
  - Document scope and future launcher variable shape.
- Create: `ansible/playbooks/linux-mint-desktops.yml`
  - Run desktop baseline plus existing Cockpit and monitoring roles.
- Modify: `kubernetes/infrastructure/observability/kube-prometheus-stack/household-hosts-scrape.yaml`
  - Add `lucas-minimint` as a household Prometheus target.

## Task 1: UniFi DHCP Reservation

**Files:**
- Modify: `terraform/unifi/static_ips.tf`

- [ ] **Step 1: Add the static IP assignment**

Add this map entry in `local.static_ip_assignments`, near the existing `michaelcstudio2_0a6dab` Trusted VLAN workstation entry:

```hcl
    lucas_minimint_b6c466 = {
      name     = "lucas-minimint"
      mac      = "bc:a8:a6:b6:c4:66"
      fixed_ip = "10.0.20.98"
    }
```

- [ ] **Step 2: Format Terraform**

Run:

```bash
tofu fmt terraform/unifi/static_ips.tf
```

Expected: command exits `0`. It may print `terraform/unifi/static_ips.tf` if formatting changed.

- [ ] **Step 3: Validate UniFi config shape without applying**

Run:

```bash
cd terraform/unifi && tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit the DHCP reservation**

Run:

```bash
git add terraform/unifi/static_ips.tf
git commit -m "feat: reserve lucas minimint trusted ip"
```

Expected: commit succeeds with only `terraform/unifi/static_ips.tf` staged.

## Task 2: Ansible Inventory And Host Vars

**Files:**
- Modify: `ansible/inventory/hosts.yml`
- Create: `ansible/inventory/host_vars/lucas-minimint.yml`

- [ ] **Step 1: Update inventory groups**

Replace the current trailing signage section:

```yaml
    signage_clients:
      hosts:
        rotom: {}
```

with:

```yaml
    household_hosts:
      children:
        signage_clients:
          hosts:
            rotom: {}
        personal_desktops:
          hosts:
            lucas-minimint:
              ansible_host: 10.0.20.98
              ansible_user: mmcnees
              ansible_become: true
```

This preserves `rotom` as a signage client while also making it part of `household_hosts`.

- [ ] **Step 2: Create host vars for Lucas's desktop**

Create `ansible/inventory/host_vars/lucas-minimint.yml`:

```yaml
---
linux_desktop_bootstrap_admin_user: mmcnees
linux_desktop_bootstrap_authorized_key_file: "{{ lookup('env', 'HOME') }}/.ssh/id_ed25519.pub"

linux_mint_desktop_enable_cockpit: true
linux_mint_desktop_enable_host_monitoring: true
linux_mint_desktop_launchers: []

host_monitoring_enable_beszel: false
host_monitoring_node_exporter_listen: "0.0.0.0:9100"
```

- [ ] **Step 3: Verify inventory parsing**

Run:

```bash
cd ansible && ansible-inventory --host lucas-minimint
```

Expected output includes:

```json
"ansible_host": "10.0.20.98",
"ansible_user": "mmcnees",
"linux_mint_desktop_enable_cockpit": true,
"host_monitoring_enable_beszel": false
```

- [ ] **Step 4: Commit inventory changes**

Run:

```bash
git add ansible/inventory/hosts.yml ansible/inventory/host_vars/lucas-minimint.yml
git commit -m "feat: add lucas minimint ansible inventory"
```

Expected: commit succeeds with only the two inventory files staged.

## Task 3: SSH And Sudo Bootstrap Role

**Files:**
- Create: `ansible/roles/linux-desktop-bootstrap/defaults/main.yml`
- Create: `ansible/roles/linux-desktop-bootstrap/tasks/main.yml`
- Create: `ansible/roles/linux-desktop-bootstrap/README.md`
- Create: `ansible/playbooks/bootstrap-linux-desktops.yml`

- [ ] **Step 1: Create bootstrap defaults**

Create `ansible/roles/linux-desktop-bootstrap/defaults/main.yml`:

```yaml
---
linux_desktop_bootstrap_admin_user: mmcnees
linux_desktop_bootstrap_authorized_key_file: "{{ lookup('env', 'HOME') }}/.ssh/id_ed25519.pub"
linux_desktop_bootstrap_sudoers_file: "/etc/sudoers.d/90-{{ linux_desktop_bootstrap_admin_user }}-ansible"
```

- [ ] **Step 2: Create bootstrap tasks**

Create `ansible/roles/linux-desktop-bootstrap/tasks/main.yml`:

```yaml
---
- name: Assert supported OS
  ansible.builtin.assert:
    that:
      - ansible_facts['os_family'] == 'Debian'
    fail_msg: "linux-desktop-bootstrap currently supports Debian-family hosts only."

- name: Assert local SSH public key exists
  ansible.builtin.stat:
    path: "{{ linux_desktop_bootstrap_authorized_key_file }}"
  delegate_to: localhost
  become: false
  register: _linux_desktop_bootstrap_key

- name: Fail when local SSH public key is missing
  ansible.builtin.assert:
    that:
      - _linux_desktop_bootstrap_key.stat.exists
      - _linux_desktop_bootstrap_key.stat.isreg
    fail_msg: "Expected SSH public key at {{ linux_desktop_bootstrap_authorized_key_file }}."

- name: Install OpenSSH server and sudo
  ansible.builtin.apt:
    name:
      - openssh-server
      - sudo
    state: present
    update_cache: true

- name: Enable and start SSH
  ansible.builtin.systemd:
    name: ssh.service
    enabled: true
    state: started

- name: Ensure admin user exists
  ansible.builtin.user:
    name: "{{ linux_desktop_bootstrap_admin_user }}"
    shell: /bin/bash
    create_home: true
    groups:
      - sudo
    append: true
    state: present

- name: Install admin authorized key
  ansible.posix.authorized_key:
    user: "{{ linux_desktop_bootstrap_admin_user }}"
    key: "{{ lookup('file', linux_desktop_bootstrap_authorized_key_file) }}"
    state: present

- name: Install passwordless sudo rule
  ansible.builtin.copy:
    dest: "{{ linux_desktop_bootstrap_sudoers_file }}"
    owner: root
    group: root
    mode: "0440"
    content: |
      {{ linux_desktop_bootstrap_admin_user }} ALL=(ALL) NOPASSWD:ALL
    validate: /usr/sbin/visudo -cf %s
```

- [ ] **Step 3: Create bootstrap playbook**

Create `ansible/playbooks/bootstrap-linux-desktops.yml`:

```yaml
---
- name: Bootstrap Linux desktop SSH and sudo access
  hosts: personal_desktops
  gather_facts: true
  become: true
  roles:
    - linux-desktop-bootstrap
```

- [ ] **Step 4: Create bootstrap README**

Create `ansible/roles/linux-desktop-bootstrap/README.md`:

````markdown
# `linux-desktop-bootstrap` role

Bootstraps Debian-family personal desktops for Ansible maintenance.

The role installs and enables OpenSSH server, installs the admin SSH public key,
and writes a passwordless sudoers drop-in for the configured admin user.

## First contact

Ansible requires SSH. If a fresh Linux Mint install does not already have SSH
enabled, run this once on the desktop before the first Ansible run:

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh.service
```

Then run the bootstrap playbook with password prompts:

```bash
cd ansible
ansible-playbook playbooks/bootstrap-linux-desktops.yml --limit lucas-minimint --ask-pass --ask-become-pass
```

After bootstrap, routine Ansible runs should use SSH key auth and passwordless
sudo.
````

- [ ] **Step 5: Syntax-check bootstrap playbook**

Run:

```bash
cd ansible && ansible-playbook playbooks/bootstrap-linux-desktops.yml --syntax-check
```

Expected output includes:

```text
playbook: playbooks/bootstrap-linux-desktops.yml
```

- [ ] **Step 6: Commit bootstrap role**

Run:

```bash
git add ansible/roles/linux-desktop-bootstrap ansible/playbooks/bootstrap-linux-desktops.yml
git commit -m "feat: add linux desktop bootstrap role"
```

Expected: commit succeeds with only bootstrap role/playbook files staged.

## Task 4: Linux Mint Desktop Role

**Files:**
- Create: `ansible/roles/linux-mint-desktop/defaults/main.yml`
- Create: `ansible/roles/linux-mint-desktop/tasks/main.yml`
- Create: `ansible/roles/linux-mint-desktop/README.md`
- Create: `ansible/playbooks/linux-mint-desktops.yml`

- [ ] **Step 1: Create Linux Mint desktop defaults**

Create `ansible/roles/linux-mint-desktop/defaults/main.yml`:

```yaml
---
linux_mint_desktop_enable_cockpit: true
linux_mint_desktop_enable_host_monitoring: true
linux_mint_desktop_launchers: []

linux_mint_desktop_packages:
  - curl
  - git
  - htop
  - openssh-client
  - rsync
  - vim
```

- [ ] **Step 2: Create Linux Mint desktop tasks**

Create `ansible/roles/linux-mint-desktop/tasks/main.yml`:

```yaml
---
- name: Assert supported OS
  ansible.builtin.assert:
    that:
      - ansible_facts['os_family'] == 'Debian'
    fail_msg: "linux-mint-desktop currently supports Debian-family hosts only."

- name: Install baseline desktop management packages
  ansible.builtin.apt:
    name: "{{ linux_mint_desktop_packages }}"
    state: present
    update_cache: true

- name: Validate launcher configuration is intentionally empty for first pass
  ansible.builtin.assert:
    that:
      - linux_mint_desktop_launchers | length == 0
    fail_msg: "Desktop launcher management is not implemented in this first pass."
```

- [ ] **Step 3: Create Linux Mint desktop playbook**

Create `ansible/playbooks/linux-mint-desktops.yml`:

```yaml
---
- name: Configure Linux Mint personal desktops
  hosts: personal_desktops
  gather_facts: true
  become: true
  roles:
    - linux-mint-desktop

  tasks:
    - name: Install Cockpit when configured
      ansible.builtin.include_role:
        name: cockpit
      when: linux_mint_desktop_enable_cockpit | bool

    - name: Install host monitoring when configured
      ansible.builtin.include_role:
        name: host-monitoring
      when: linux_mint_desktop_enable_host_monitoring | bool
```

- [ ] **Step 4: Create Linux Mint desktop README**

Create `ansible/roles/linux-mint-desktop/README.md`:

````markdown
# `linux-mint-desktop` role

Configures baseline maintenance tooling for Linux Mint personal desktops.

The role is intentionally separate from `signage-client`, which owns kiosk
behavior and display-session changes. This role does not modify the active
desktop session, browser settings, game files, or user launchers in its first
pass.

## Variables

| Variable | Default | What |
|---|---|---|
| `linux_mint_desktop_enable_cockpit` | `true` | Include the shared `cockpit` role from the desktop playbook. |
| `linux_mint_desktop_enable_host_monitoring` | `true` | Include the shared `host-monitoring` role from the desktop playbook. |
| `linux_mint_desktop_packages` | baseline admin packages | Packages installed for remote maintenance. |
| `linux_mint_desktop_launchers` | `[]` | Reserved for future managed desktop shortcuts. Must stay empty until launcher tasks exist. |

Future launcher entries should use a structured shape with fields such as
`name`, `desktop_file`, `command`, `icon`, `working_directory`, and
`categories`.
````

- [ ] **Step 5: Syntax-check desktop playbook**

Run:

```bash
cd ansible && ansible-playbook playbooks/linux-mint-desktops.yml --syntax-check
```

Expected output includes:

```text
playbook: playbooks/linux-mint-desktops.yml
```

- [ ] **Step 6: Commit desktop role**

Run:

```bash
git add ansible/roles/linux-mint-desktop ansible/playbooks/linux-mint-desktops.yml
git commit -m "feat: add linux mint desktop role"
```

Expected: commit succeeds with only Linux Mint desktop role/playbook files staged.

## Task 5: Prometheus Household Scrape Target

**Files:**
- Modify: `kubernetes/infrastructure/observability/kube-prometheus-stack/household-hosts-scrape.yaml`

- [ ] **Step 1: Add Lucas MiniMint target**

In `spec.staticConfigs`, add a second item after the existing `rotom` item:

```yaml
    - targets:
        - "10.0.20.98:9100"
      labels:
        job: household_compute
        household_role: personal_desktop
        host: lucas-minimint
```

The resulting `staticConfigs` should contain both `rotom` and `lucas-minimint` as separate entries so each host keeps its own `host` label.

- [ ] **Step 2: Validate YAML renders through kustomize**

Run:

```bash
kubectl kustomize kubernetes/infrastructure/observability/kube-prometheus-stack
```

Expected: command exits `0` and rendered output contains:

```yaml
host: lucas-minimint
```

- [ ] **Step 3: Commit scrape target**

Run:

```bash
git add kubernetes/infrastructure/observability/kube-prometheus-stack/household-hosts-scrape.yaml
git commit -m "feat: scrape lucas minimint node exporter"
```

Expected: commit succeeds with only the scrape config staged.

## Task 6: End-To-End Bootstrap And Maintenance Run

**Files:**
- No repository file changes expected.

- [ ] **Step 1: Apply UniFi reservation**

Run from the UniFi Terraform directory:

```bash
cd terraform/unifi && tofu plan
```

Expected: the plan includes one new `unifi_user.static_ips["lucas_minimint_b6c466"]` reservation with fixed IP `10.0.20.98`.

Then apply when the plan only contains the intended reservation:

```bash
cd terraform/unifi && tofu apply
```

Expected: apply exits `0`.

- [ ] **Step 2: Ensure first-contact SSH is available**

From an admin terminal, test:

```bash
ssh mmcnees@10.0.20.239 true
```

Expected: command exits `0` if SSH is already active.

If SSH is not active, run this once on `lucas-minimint` locally:

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh.service
```

Then re-run:

```bash
ssh mmcnees@10.0.20.239 true
```

Expected: command exits `0`.

- [ ] **Step 3: Renew DHCP and verify target IP**

Renew DHCP from NetworkManager on `lucas-minimint` or reboot the machine.

From the admin terminal, verify:

```bash
ping -c 3 10.0.20.98
```

Expected: three replies from `10.0.20.98`.

- [ ] **Step 4: Run bootstrap playbook with password prompts**

Run:

```bash
cd ansible && ansible-playbook playbooks/bootstrap-linux-desktops.yml --limit lucas-minimint --ask-pass --ask-become-pass
```

Expected: play recap shows `failed=0`.

- [ ] **Step 5: Verify SSH key auth and passwordless sudo**

Run:

```bash
cd ansible && ansible lucas-minimint -m ping
```

Expected output includes:

```json
"ping": "pong"
```

Run:

```bash
cd ansible && ansible lucas-minimint -m command -a "sudo -n true"
```

Expected: task exits successfully with `rc=0`.

- [ ] **Step 6: Run Linux Mint desktop playbook**

Run:

```bash
cd ansible && ansible-playbook playbooks/linux-mint-desktops.yml --limit lucas-minimint
```

Expected: play recap shows `failed=0`.

- [ ] **Step 7: Verify services**

Run:

```bash
cd ansible && ansible lucas-minimint -m command -a "systemctl is-active cockpit.socket"
```

Expected output includes:

```text
active
```

Run:

```bash
cd ansible && ansible lucas-minimint -m command -a "systemctl is-active prometheus-node-exporter"
```

Expected output includes:

```text
active
```

Run:

```bash
curl -fsSL http://10.0.20.98:9100/metrics
```

Expected: output starts with Prometheus metric comments such as `# HELP`.

- [ ] **Step 8: Reconcile observability config**

Run:

```bash
flux --kubeconfig talos/kubeconfig reconcile kustomization observability --with-source
```

Expected: reconcile exits `0`.

After Prometheus reloads, confirm the `lucas-minimint` target is up in the Prometheus UI or with an API query.

## Self-Review Notes

- Spec coverage: network reservation, inventory, SSH key, passwordless sudo, Cockpit, host monitoring, and Prometheus scrape are covered.
- Desktop shortcuts: intentionally not implemented; the launcher list is defined but asserted empty to avoid silent partial behavior.
- First-contact SSH: handled explicitly because Ansible cannot connect before SSH is available.
