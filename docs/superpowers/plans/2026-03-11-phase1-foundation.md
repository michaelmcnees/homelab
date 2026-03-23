# Phase 1: Foundation — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the foundational infrastructure — repo structure, OpenTofu-managed Proxmox VMs, Ansible-configured K3s cluster, Flux CD GitOps bootstrap, and SOPS secret encryption — all running alongside the existing homelab with zero disruption.

**Architecture:** OpenTofu creates VMs on the 3-node Proxmox cluster (latios, latias, rayquaza) using the bpg/proxmox provider. Ansible configures the VMs and bootstraps a 5-node K3s cluster (3 servers + 2 agents) across 3 hosts. Flux CD is bootstrapped to watch a GitHub repo for GitOps. SOPS with age handles secret encryption in the repo.

**Tech Stack:** OpenTofu 1.9+, Ansible 2.17+, K3s v1.31+, Flux CD v2, SOPS, age, Ubuntu 24.04 (cloud-init), Taskfile

**Spec:** `docs/superpowers/specs/2026-03-11-homelab-redesign-design.md`

---

## Chunk 1: Repo Scaffolding & OpenTofu Setup

### Task 1: Create repo scaffolding

**Files:**
- Create: `.gitignore`
- Create: `Taskfile.yml`
- Create: `terraform/proxmox/main.tf`
- Create: `terraform/proxmox/variables.tf`
- Create: `terraform/proxmox/outputs.tf`
- Create: `terraform/proxmox/versions.tf`
- Create: `terraform/unifi/.gitkeep`
- Create: `ansible/.gitkeep`
- Create: `kubernetes/.gitkeep`

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# Terraform
*.tfstate
*.tfstate.backup
.terraform/
.terraform.lock.hcl
*.tfvars
!*.tfvars.example

# Ansible
*.retry
ansible/kubeconfig.yaml
ansible/inventory/group_vars/k3s_cluster.yml

# SOPS
*.age.key

# OS
.DS_Store
*.swp

# IDE
.vscode/
.idea/
```

- [ ] **Step 2: Create `Taskfile.yml`**

```yaml
version: '3'

tasks:
  infra:init:
    desc: Initialize OpenTofu for Proxmox
    dir: terraform/proxmox
    cmd: tofu init

  infra:plan:
    desc: Preview Proxmox infrastructure changes
    dir: terraform/proxmox
    cmd: tofu plan

  infra:apply:
    desc: Apply Proxmox infrastructure changes
    dir: terraform/proxmox
    cmd: tofu apply

  network:init:
    desc: Initialize OpenTofu for Unifi
    dir: terraform/unifi
    cmd: tofu init

  network:plan:
    desc: Preview Unifi network changes
    dir: terraform/unifi
    cmd: tofu plan

  network:apply:
    desc: Apply Unifi network changes
    dir: terraform/unifi
    cmd: tofu apply

  ansible:collections:
    desc: Install Ansible collections (k3s-ansible, etc.)
    dir: ansible
    cmd: ansible-galaxy collection install -r collections/requirements.yml

  ansible:proxmox:
    desc: Configure Proxmox hosts
    dir: ansible
    cmd: ansible-playbook playbooks/proxmox-setup.yml

  ansible:k3s-prepare:
    desc: Prepare K3s node VMs (OS config + k3s prereqs)
    dir: ansible
    deps: [ansible:collections]
    cmd: ansible-playbook playbooks/k3s-prepare.yml

  ansible:k3s-install:
    desc: Install K3s cluster (uses k3s-ansible collection)
    dir: ansible
    cmd: ansible-playbook playbooks/k3s-install.yml

  ansible:k3s-upgrade:
    desc: Upgrade K3s cluster (update k3s_version in group_vars first)
    dir: ansible
    cmd: ansible-playbook playbooks/k3s-upgrade.yml

  flux:bootstrap:
    desc: Bootstrap Flux CD onto the cluster
    cmd: |
      flux bootstrap github \
        --owner=${GITHUB_USER} \
        --repository=homelab \
        --path=kubernetes \
        --personal \
        --private=false

  flux:check:
    desc: Check Flux sync status
    cmd: flux get all
```

- [ ] **Step 3: Create directory skeleton with .gitkeep files**

```bash
mkdir -p terraform/proxmox/nodes
mkdir -p terraform/unifi
mkdir -p ansible/{inventory/group_vars,playbooks,roles}
mkdir -p kubernetes/{flux-system,infrastructure/{controllers,configs,observability},apps,dev-lab,repositories}
mkdir -p docs/{superpowers/{specs,plans},runbooks,architecture}
touch terraform/unifi/.gitkeep
touch ansible/inventory/.gitkeep
touch kubernetes/.gitkeep
```

- [ ] **Step 4: Commit repo scaffolding**

```bash
git add .gitignore Taskfile.yml terraform/ ansible/ kubernetes/ docs/
git commit -m "scaffold: repo structure with Taskfile and directory skeleton"
```

---

### Task 2: Configure OpenTofu Proxmox provider

**Files:**
- Create: `terraform/proxmox/versions.tf`
- Create: `terraform/proxmox/main.tf`
- Create: `terraform/proxmox/variables.tf`
- Create: `terraform/proxmox/terraform.tfvars.example`

- [ ] **Step 1: Create `terraform/proxmox/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
  }
}
```

- [ ] **Step 2: Create `terraform/proxmox/main.tf`**

```hcl
provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = true # Self-signed certs on Proxmox

  ssh {
    agent = true
  }
}
```

- [ ] **Step 3: Create `terraform/proxmox/variables.tf`**

```hcl
# --- Provider Authentication ---

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL (e.g., https://10.0.0.x:8006)"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox API username (e.g., root@pam or terraform@pve!token)"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox API password or token secret"
  type        = string
  sensitive   = true
}

# --- VM Defaults ---

variable "vm_template_id" {
  description = "Proxmox VM template ID for cloud-init Ubuntu"
  type        = number
  default     = 9000
}

variable "vm_default_storage" {
  description = "Default storage pool for VM disks"
  type        = string
  default     = "ceph-pool"
}

variable "vm_ssh_public_key" {
  description = "SSH public key to inject via cloud-init"
  type        = string
}

variable "vm_default_gateway" {
  description = "Default gateway for VM network"
  type        = string
  default     = "10.0.0.1"
}

variable "vm_dns_servers" {
  description = "DNS servers for VMs"
  type        = string
  default     = "10.0.0.53"
}
```

- [ ] **Step 4: Create `terraform/proxmox/terraform.tfvars.example`**

```hcl
proxmox_endpoint   = "https://10.0.0.x:8006"
proxmox_username   = "root@pam"
proxmox_password   = "changeme"
vm_ssh_public_key  = "ssh-ed25519 AAAA... michael@workstation"
vm_default_gateway = "10.0.0.1"
vm_dns_servers     = "10.0.0.53"
```

- [ ] **Step 5: Create actual `terraform.tfvars` (not committed)**

Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in real values.

```bash
cd terraform/proxmox
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with actual Proxmox credentials
```

- [ ] **Step 6: Initialize OpenTofu and verify provider**

```bash
task infra:init
```

Expected: Provider downloaded, `.terraform/` directory created, lock file generated.

- [ ] **Step 7: Commit provider configuration**

```bash
git add terraform/proxmox/versions.tf terraform/proxmox/main.tf terraform/proxmox/variables.tf terraform/proxmox/terraform.tfvars.example
git commit -m "infra: configure OpenTofu with bpg/proxmox provider"
```

---

### Task 3: Create cloud-init VM template on Proxmox

**Context:** Before OpenTofu can create K3s VMs, a cloud-init enabled VM template must exist on at least one Proxmox node. This is a one-time manual step (or Ansible-automated) that creates a reusable template.

**Files:**
- Create: `ansible/playbooks/create-vm-template.yml`

- [ ] **Step 1: Create template creation playbook `ansible/playbooks/create-vm-template.yml`**

```yaml
---
# Creates a cloud-init Ubuntu 24.04 VM template on a Proxmox node.
# Run once per Proxmox node that will host K3s VMs.
#
# Usage: ansible-playbook playbooks/create-vm-template.yml -e "target_node=latios"
#
# Prerequisites: SSH access to the Proxmox node as root.

- name: Create cloud-init VM template
  hosts: "{{ target_node }}"
  become: true
  vars:
    template_vmid: 9000
    template_name: "ubuntu-2404-cloud-init"
    ubuntu_image_url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    ubuntu_image_file: "/tmp/noble-server-cloudimg-amd64.img"
    storage_pool: "local-lvm"

  tasks:
    - name: Check if template already exists
      command: qm status {{ template_vmid }}
      register: template_check
      failed_when: false
      changed_when: false

    - name: Download Ubuntu cloud image
      get_url:
        url: "{{ ubuntu_image_url }}"
        dest: "{{ ubuntu_image_file }}"
        mode: '0644'
      when: template_check.rc != 0

    - name: Create VM for template
      command: >
        qm create {{ template_vmid }}
        --name {{ template_name }}
        --memory 2048
        --cores 2
        --net0 virtio,bridge=vmbr0
        --ostype l26
        --scsihw virtio-scsi-single
        --agent enabled=1
      when: template_check.rc != 0

    - name: Import disk from cloud image
      command: >
        qm set {{ template_vmid }}
        --scsi0 {{ storage_pool }}:0,import-from={{ ubuntu_image_file }},discard=on,ssd=1
      when: template_check.rc != 0

    - name: Add cloud-init drive
      command: qm set {{ template_vmid }} --ide2 {{ storage_pool }}:cloudinit
      when: template_check.rc != 0

    - name: Set boot order to scsi0
      command: qm set {{ template_vmid }} --boot order=scsi0
      when: template_check.rc != 0

    - name: Enable serial console for cloud-init
      command: qm set {{ template_vmid }} --serial0 socket --vga serial0
      when: template_check.rc != 0

    - name: Convert to template
      command: qm template {{ template_vmid }}
      when: template_check.rc != 0

    - name: Clean up downloaded image
      file:
        path: "{{ ubuntu_image_file }}"
        state: absent
```

- [ ] **Step 2: Create minimal Ansible inventory for Proxmox hosts**

Create `ansible/inventory/hosts.yml`:

```yaml
---
all:
  children:
    proxmox_hosts:
      hosts:
        latios:
          ansible_host: 10.0.0.70  # pve1 — Update with actual Proxmox host IPs
          ansible_user: root
        latias:
          ansible_host: 10.0.0.71  # pve2
          ansible_user: root
        rayquaza:
          ansible_host: 10.0.0.72  # pve3
          ansible_user: root
```

**Note:** Update `ansible_host` values to match your actual Proxmox host IPs.

- [ ] **Step 3: Create `ansible/ansible.cfg`**

```ini
[defaults]
inventory = inventory/hosts.yml
host_key_checking = False
retry_files_enabled = False

[privilege_escalation]
become = True
become_method = sudo
```

- [ ] **Step 4: Run the template creation on each node that will host K3s VMs**

```bash
cd ansible
ansible-playbook playbooks/create-vm-template.yml -e "target_node=latios"
ansible-playbook playbooks/create-vm-template.yml -e "target_node=latias"
ansible-playbook playbooks/create-vm-template.yml -e "target_node=rayquaza"
```

Expected: Template VM ID 9000 exists on each Proxmox node.

- [ ] **Step 5: Verify template exists**

```bash
ssh root@latios "qm list | grep 9000"
```

Expected output: `9000  ubuntu-2404-cloud-init  ...  template`

- [ ] **Step 6: Commit**

```bash
git add ansible/ansible.cfg ansible/inventory/hosts.yml ansible/playbooks/create-vm-template.yml
git commit -m "ansible: add cloud-init VM template playbook and Proxmox inventory"
```

---

### Task 3b: Create Proxmox host setup playbook

**Files:**
- Create: `ansible/playbooks/proxmox-setup.yml`

**Context:** Configures the Proxmox hosts themselves — SSH hardening, fail2ban, security updates. Required by the spec (Section 7: Host Security). Ceph is already configured; this playbook ensures consistent security posture.

- [ ] **Step 1: Create `ansible/playbooks/proxmox-setup.yml`**

```yaml
---
- name: Configure Proxmox hosts
  hosts: proxmox_hosts
  become: true

  tasks:
    - name: Install security packages
      apt:
        name:
          - fail2ban
          - unattended-upgrades
          - apt-listchanges
        state: present
        update_cache: true

    - name: Configure SSH - disable password auth
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: "{{ item.regexp }}"
        line: "{{ item.line }}"
        state: present
      loop:
        - { regexp: '^#?PasswordAuthentication', line: 'PasswordAuthentication no' }
        - { regexp: '^#?PermitRootLogin', line: 'PermitRootLogin prohibit-password' }
        - { regexp: '^#?PubkeyAuthentication', line: 'PubkeyAuthentication yes' }
      notify: restart sshd

    - name: Configure fail2ban for SSH
      copy:
        content: |
          [sshd]
          enabled = true
          port = ssh
          filter = sshd
          logpath = /var/log/auth.log
          maxretry = 5
          bantime = 3600
          findtime = 600
        dest: /etc/fail2ban/jail.d/sshd.conf
        mode: '0644'
      notify: restart fail2ban

    - name: Configure fail2ban for Proxmox web UI
      copy:
        content: |
          [proxmox]
          enabled = true
          port = https,http,8006
          filter = proxmox
          logpath = /var/log/daemon.log
          maxretry = 3
          bantime = 3600
          findtime = 600
        dest: /etc/fail2ban/jail.d/proxmox.conf
        mode: '0644'
      notify: restart fail2ban

    - name: Create fail2ban filter for Proxmox
      copy:
        content: |
          [Definition]
          failregex = pvedaemon\[.*authentication failure; rhost=<HOST> user=.* msg=.*
          ignoreregex =
        dest: /etc/fail2ban/filter.d/proxmox.conf
        mode: '0644'
      notify: restart fail2ban

    - name: Enable unattended-upgrades for security updates
      copy:
        content: |
          APT::Periodic::Update-Package-Lists "1";
          APT::Periodic::Unattended-Upgrade "1";
          APT::Periodic::AutocleanInterval "7";
        dest: /etc/apt/apt.conf.d/20auto-upgrades
        mode: '0644'

    - name: Ensure services are enabled and started
      systemd:
        name: "{{ item }}"
        enabled: true
        state: started
      loop:
        - fail2ban
        - unattended-upgrades

  handlers:
    - name: restart sshd
      systemd:
        name: sshd
        state: restarted

    - name: restart fail2ban
      systemd:
        name: fail2ban
        state: restarted
```

- [ ] **Step 2: Run the playbook**

```bash
task ansible:proxmox
```

Expected: SSH hardened, fail2ban running, unattended-upgrades enabled on all 3 Proxmox hosts.

- [ ] **Step 3: Verify**

```bash
ssh root@latios "systemctl status fail2ban | head -5 && grep PasswordAuthentication /etc/ssh/sshd_config"
```

Expected: fail2ban active, `PasswordAuthentication no`.

- [ ] **Step 4: Commit**

```bash
git add ansible/playbooks/proxmox-setup.yml
git commit -m "ansible: add Proxmox host security hardening playbook"
```

---

## Chunk 2: K3s VM Definitions (OpenTofu)

### Task 4: Define K3s server VM module

**Files:**
- Create: `terraform/proxmox/modules/k3s-node/main.tf`
- Create: `terraform/proxmox/modules/k3s-node/variables.tf`
- Create: `terraform/proxmox/modules/k3s-node/outputs.tf`

**Context:** Create a reusable module for K3s nodes. All 5 K3s VMs share the same base config (Ubuntu cloud-init, SSH key, qemu-guest-agent), differing only in name, target node, IP, and resource allocation. VMs are distributed across 3 hosts: latios (pve1), latias (pve2), rayquaza (pve3).

**Note on networking:** The spec defines VLAN 10 (10.0.10.0/24) for K8s traffic, but the spec also states VLAN segmentation "can be migrated incrementally — not a day-one blocker." For Phase 1, K3s VMs are placed on the management VLAN (10.0.0.0/24) alongside Proxmox hosts for simplicity. Phase 4 migrates them to VLAN 10 when Unifi networking is configured via OpenTofu.

- [ ] **Step 1: Create `terraform/proxmox/modules/k3s-node/variables.tf`**

```hcl
variable "vm_name" {
  description = "VM hostname (e.g., articuno)"
  type        = string
}

variable "target_node" {
  description = "Proxmox node to place this VM on (e.g., latios)"
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID"
  type        = number
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 4
}

variable "memory" {
  description = "RAM in MB"
  type        = number
  default     = 8192
}

variable "disk_size" {
  description = "Boot disk size in GB"
  type        = number
  default     = 50
}

variable "storage_pool" {
  description = "Proxmox storage pool for VM disk"
  type        = string
  default     = "ceph-pool"
}

variable "ip_address" {
  description = "Static IP address (CIDR notation, e.g., 10.0.0.80/24)"
  type        = string
}

variable "gateway" {
  description = "Default gateway IP"
  type        = string
}

variable "dns_servers" {
  description = "DNS server IPs (space-separated)"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for cloud-init user"
  type        = string
}

variable "template_vm_id" {
  description = "VM template ID to clone from"
  type        = number
  default     = 9000
}

variable "ci_user" {
  description = "Cloud-init default user"
  type        = string
  default     = "mcnees"
}

variable "bridge" {
  description = "Network bridge for the VM"
  type        = string
  default     = "vmbr0"
}

variable "vlan_tag" {
  description = "VLAN tag for the VM network interface (-1 for no tag)"
  type        = number
  default     = -1
}

variable "tags" {
  description = "Tags to apply to the VM"
  type        = list(string)
  default     = ["k3s", "terraform"]
}

variable "onboot" {
  description = "Start VM on Proxmox boot"
  type        = bool
  default     = true
}
```

- [ ] **Step 2: Create `terraform/proxmox/modules/k3s-node/main.tf`**

```hcl
resource "proxmox_virtual_environment_vm" "k3s_node" {
  name      = var.vm_name
  node_name = var.target_node
  vm_id     = var.vm_id
  on_boot   = var.onboot
  tags      = var.tags

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_size
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge   = var.bridge
    vlan_id  = var.vlan_tag >= 0 ? var.vlan_tag : null
    firewall = false
  }

  agent {
    enabled = true
  }

  initialization {
    user_account {
      username = var.ci_user
      keys     = [var.ssh_public_key]
    }

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    dns {
      servers = split(" ", var.dns_servers)
    }
  }

  lifecycle {
    ignore_changes = [
      initialization[0].user_account[0].password,
    ]
  }
}
```

- [ ] **Step 3: Create `terraform/proxmox/modules/k3s-node/outputs.tf`**

```hcl
output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.k3s_node.vm_id
}

output "vm_name" {
  description = "VM hostname"
  value       = proxmox_virtual_environment_vm.k3s_node.name
}

output "ip_address" {
  description = "VM IP address"
  value       = var.ip_address
}
```

- [ ] **Step 4: Commit module**

```bash
git add terraform/proxmox/modules/
git commit -m "infra: add reusable k3s-node OpenTofu module"
```

---

### Task 5: Define K3s server VMs (articuno, zapdos, moltres)

**Files:**
- Create: `terraform/proxmox/nodes/articuno.tf`
- Create: `terraform/proxmox/nodes/zapdos.tf`
- Create: `terraform/proxmox/nodes/moltres.tf`

- [ ] **Step 1: Create `terraform/proxmox/nodes/articuno.tf`**

```hcl
module "articuno" {
  source = "../modules/k3s-node"

  vm_name        = "articuno"
  target_node    = "latios"  # pve1
  vm_id          = 110
  cores          = 4
  memory         = 10240  # 10GB — server node on latios (64GB host)
  disk_size      = 50
  storage_pool   = var.vm_default_storage
  ip_address     = "10.0.0.80/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  tags           = ["k3s", "k3s-server", "terraform"]
}
```

- [ ] **Step 2: Create `terraform/proxmox/nodes/zapdos.tf`**

```hcl
module "zapdos" {
  source = "../modules/k3s-node"

  vm_name        = "zapdos"
  target_node    = "latias"  # pve2
  vm_id          = 111
  cores          = 4
  memory         = 10240  # 10GB — server node on latias (64GB host)
  disk_size      = 50
  storage_pool   = var.vm_default_storage
  ip_address     = "10.0.0.81/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  tags           = ["k3s", "k3s-server", "terraform"]
}
```

- [ ] **Step 3: Create `terraform/proxmox/nodes/moltres.tf`**

```hcl
module "moltres" {
  source = "../modules/k3s-node"

  vm_name        = "moltres"
  target_node    = "rayquaza"  # pve3
  vm_id          = 112
  cores          = 4
  memory         = 10240  # 10GB — server node on rayquaza (64GB host)
  disk_size      = 50
  storage_pool   = var.vm_default_storage
  ip_address     = "10.0.0.82/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  tags           = ["k3s", "k3s-server", "terraform"]
}
```

- [ ] **Step 4: Create `terraform/proxmox/outputs.tf`**

```hcl
output "k3s_server_ips" {
  description = "K3s control plane node IPs"
  value = {
    articuno = module.articuno.ip_address
    zapdos   = module.zapdos.ip_address
    moltres  = module.moltres.ip_address
  }
}

output "k3s_agent_ips" {
  description = "K3s worker node IPs"
  value = {
    lugia = module.lugia.ip_address
    ho_oh = module.ho_oh.ip_address
  }
}
```

- [ ] **Step 5: Commit**

```bash
git add terraform/proxmox/nodes/articuno.tf terraform/proxmox/nodes/zapdos.tf terraform/proxmox/nodes/moltres.tf terraform/proxmox/outputs.tf
git commit -m "infra: define K3s server VMs (articuno, zapdos, moltres)"
```

---

### Task 6: Define K3s agent VMs (lugia, ho-oh)

**Files:**
- Create: `terraform/proxmox/nodes/lugia.tf`
- Create: `terraform/proxmox/nodes/ho-oh.tf`

- [ ] **Step 1: Create `terraform/proxmox/nodes/lugia.tf`**

```hcl
module "lugia" {
  source = "../modules/k3s-node"

  vm_name        = "lugia"
  target_node    = "latios"  # pve1 — co-located with articuno (server)
  vm_id          = 113
  cores          = 4
  memory         = 40960  # 40GB — primary workload agent on latios (64GB host)
  disk_size      = 50
  storage_pool   = var.vm_default_storage
  ip_address     = "10.0.0.83/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  tags           = ["k3s", "k3s-agent", "terraform"]
}
```

- [ ] **Step 2: Create `terraform/proxmox/nodes/ho-oh.tf`**

```hcl
module "ho_oh" {
  source = "../modules/k3s-node"

  vm_name        = "ho-oh"
  target_node    = "latias"  # pve2 — co-located with zapdos (server) and pelipper (Pelican)
  vm_id          = 114
  cores          = 4
  memory         = 20480  # 20GB — latias (64GB) also hosts zapdos (10GB) + pelipper (20GB)
  disk_size      = 50
  storage_pool   = var.vm_default_storage
  ip_address     = "10.0.0.84/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  tags           = ["k3s", "k3s-agent", "terraform"]
}
```

- [ ] **Step 3: Run `tofu plan` to validate all 5 VMs**

```bash
task infra:plan
```

Expected: Plan shows 5 VMs to create (articuno, zapdos, moltres, lugia, ho-oh). No errors.

- [ ] **Step 4: Commit**

```bash
git add terraform/proxmox/nodes/lugia.tf terraform/proxmox/nodes/ho-oh.tf
git commit -m "infra: define K3s agent VMs (lugia, ho-oh)"
```

---

### Task 7: Apply OpenTofu — Create all K3s VMs

- [ ] **Step 1: Apply the infrastructure**

```bash
task infra:apply
```

Expected: 5 VMs created in Proxmox. Each VM boots, gets its cloud-init IP, and is accessible via SSH.

- [ ] **Step 2: Verify each VM is accessible**

```bash
ssh mcnees@10.0.0.80 "hostname"  # articuno (server, latios)
ssh mcnees@10.0.0.81 "hostname"  # zapdos (server, latias)
ssh mcnees@10.0.0.82 "hostname"  # moltres (server, rayquaza)
ssh mcnees@10.0.0.83 "hostname"  # lugia (agent, latios)
ssh mcnees@10.0.0.84 "hostname"  # ho-oh (agent, latias)
```

Expected: Each returns its hostname.

- [ ] **Step 3: Verify in Proxmox UI**

Open Proxmox web UI. Confirm all 5 VMs are running on their respective nodes (latios, latias, rayquaza) with correct resource allocations.

- [ ] **Step 4: Commit state (if using local state)**

The `.tfstate` file is gitignored. No commit needed, but verify it exists:

```bash
ls -la terraform/proxmox/terraform.tfstate
```

---

## Chunk 3: Ansible K3s Cluster Setup (using k3s-ansible collection)

> **Note:** This chunk uses the official [k3s-io/k3s-ansible](https://github.com/k3s-io/k3s-ansible) collection (`k3s.orchestration`) instead of hand-rolled playbooks. The collection handles K3s installation, HA detection, config file management, kubeconfig merging, and provides upgrade/reset playbooks out of the box.

### Task 8: Install k3s-ansible collection and create inventory

**Files:**
- Create: `ansible/collections/requirements.yml`
- Modify: `ansible/ansible.cfg`
- Modify: `ansible/inventory/hosts.yml`
- Create: `ansible/inventory/group_vars/k3s_cluster.yml`

- [ ] **Step 1: Create `ansible/collections/requirements.yml`**

```yaml
---
collections:
  - name: k3s.orchestration
    version: ">=1.2.0"
  - name: community.general
    version: ">=7.0.0"
  - name: ansible.posix
    version: ">=1.5.0"
```

- [ ] **Step 2: Update `ansible/ansible.cfg` to include collections path**

```ini
[defaults]
inventory = inventory/hosts.yml
host_key_checking = False
retry_files_enabled = False
collections_path = ~/.ansible/collections:/usr/share/ansible/collections

[privilege_escalation]
become = True
become_method = sudo
```

- [ ] **Step 3: Install the collection**

```bash
task ansible:collections
```

Expected: Collection `k3s.orchestration` installed to `~/.ansible/collections`.

- [ ] **Step 4: Update `ansible/inventory/hosts.yml` with k3s-ansible group names**

The collection expects groups named `server` and `agent` (not `k3s_servers`/`k3s_agents`):

```yaml
---
all:
  children:
    proxmox_hosts:
      hosts:
        latios:
          ansible_host: 10.0.0.70  # pve1 — Update with actual Proxmox host IPs
          ansible_user: root
        latias:
          ansible_host: 10.0.0.71  # pve2
          ansible_user: root
        rayquaza:
          ansible_host: 10.0.0.72  # pve3
          ansible_user: root

    # k3s-ansible collection expects 'server' and 'agent' group names
    k3s_cluster:
      children:
        server:
          hosts:
            articuno:
              ansible_host: 10.0.0.80  # on latios/pve1
            zapdos:
              ansible_host: 10.0.0.81  # on latias/pve2
            moltres:
              ansible_host: 10.0.0.82  # on rayquaza/pve3
        agent:
          hosts:
            lugia:
              ansible_host: 10.0.0.83  # on latios/pve1
            ho-oh:
              ansible_host: 10.0.0.84  # on latias/pve2
      vars:
        ansible_user: mcnees
        ansible_become: true
```

- [ ] **Step 5: Create `ansible/inventory/group_vars/k3s_cluster.yml.example`** (committed to repo as reference)

```yaml
---
# K3s cluster configuration (k3s-ansible collection variables)
# Copy to k3s_cluster.yml and fill in real values. k3s_cluster.yml is gitignored.

# K3s version — check https://github.com/k3s-io/k3s/releases for latest stable
k3s_version: "v1.31.6+k3s1"

# Cluster token — generate with: openssl rand -base64 64
token: "CHANGE_ME_GENERATE_WITH_openssl_rand_-base64_64"

# API endpoint — first server node IP (or VIP if using kube-vip later)
api_endpoint: "10.0.0.80"
api_port: 6443

# K3s server config — written to /etc/rancher/k3s/config.yaml on server nodes
# We disable built-in traefik, servicelb, and local-storage because
# Phase 2 deploys MetalLB, Traefik, and democratic-csi via Flux CD.
server_config_yaml: |
  disable:
    - traefik
    - servicelb
    - local-storage
  flannel-backend: vxlan
  tls-san:
    - "10.0.0.80"

# K3s agent config — written to /etc/rancher/k3s/config.yaml on agent nodes
# agent_config_yaml: |
```

Then create the actual `ansible/inventory/group_vars/k3s_cluster.yml` (gitignored, NOT committed):
copy the example and fill in a real token.

- [ ] **Step 6: Commit**

```bash
git add ansible/collections/requirements.yml ansible/ansible.cfg ansible/inventory/hosts.yml ansible/inventory/group_vars/k3s_cluster.yml.example
git commit -m "ansible: adopt k3s-ansible collection with inventory and config"
```

---

### Task 9: Create K3s preparation playbook

**Files:**
- Create: `ansible/playbooks/k3s-prepare.yml`

**Context:** Installs homelab-specific packages (open-iscsi, nfs-common, qemu-guest-agent) and then runs the k3s-ansible collection's `prereq` role for K3s-specific setup (sysctl, kernel modules, swap, etc.).

- [ ] **Step 1: Create `ansible/playbooks/k3s-prepare.yml`**

```yaml
---
# Prepares K3s nodes with homelab-specific packages, then runs
# the k3s.orchestration prereq role for K3s-specific setup
# (sysctl, kernel modules, etc.)
#
# Usage: task ansible:k3s-prepare
#   or:  ansible-playbook playbooks/k3s-prepare.yml

- name: Prepare nodes for K3s
  hosts: k3s_cluster
  become: true

  tasks:
    - name: Update apt cache
      apt:
        update_cache: true
        cache_valid_time: 3600

    - name: Install homelab-specific packages
      apt:
        name:
          - apt-transport-https
          - ca-certificates
          - curl
          - gnupg
          - open-iscsi       # Required for democratic-csi iSCSI (future)
          - nfs-common       # Required for democratic-csi NFS mounts
          - qemu-guest-agent # Proxmox VM integration
          - unattended-upgrades
        state: present

    - name: Enable and start qemu-guest-agent
      systemd:
        name: qemu-guest-agent
        enabled: true
        state: started

    - name: Enable unattended-upgrades for security updates
      copy:
        content: |
          APT::Periodic::Update-Package-Lists "1";
          APT::Periodic::Unattended-Upgrade "1";
          APT::Periodic::AutocleanInterval "7";
        dest: /etc/apt/apt.conf.d/20auto-upgrades
        mode: '0644'

  roles:
    - role: k3s.orchestration.prereq
```

- [ ] **Step 2: Run the preparation playbook**

```bash
task ansible:k3s-prepare
```

Expected: All 5 K3s nodes prepared. The `prereq` role handles swap, kernel modules, sysctl, and br_netfilter automatically.

- [ ] **Step 3: Verify a node**

```bash
ssh mcnees@10.0.0.80 "swapon --show && sysctl net.ipv4.ip_forward && lsmod | grep br_netfilter && dpkg -l | grep open-iscsi"
```

Expected: No swap, `ip_forward = 1`, `br_netfilter` loaded, `open-iscsi` installed.

- [ ] **Step 4: Commit**

```bash
git add ansible/playbooks/k3s-prepare.yml
git commit -m "ansible: add K3s node preparation playbook (k3s-ansible prereq + homelab extras)"
```

---

### Task 10: Create K3s installation and lifecycle playbooks

**Files:**
- Create: `ansible/playbooks/k3s-install.yml`
- Create: `ansible/playbooks/k3s-upgrade.yml`
- Create: `ansible/playbooks/k3s-reset.yml`

**Context:** Uses the k3s-ansible collection roles (`k3s_server`, `k3s_agent`) for installation. The collection handles HA detection (auto `--cluster-init`), config file creation (`/etc/rancher/k3s/config.yaml` from `server_config_yaml`), token management, and kubeconfig setup. We add a final play to fetch and fix the kubeconfig locally.

- [ ] **Step 1: Create `ansible/playbooks/k3s-install.yml`**

```yaml
---
# Installs K3s cluster using the official k3s-ansible collection.
# Handles bootstrap server, additional servers, and agent nodes.
#
# Prerequisites:
#   - Run 'task ansible:k3s-prepare' first
#   - ansible/inventory/group_vars/k3s_cluster.yml must exist with real values
#
# Usage: task ansible:k3s-install
#   or:  ansible-playbook playbooks/k3s-install.yml

- name: Install K3s server nodes
  hosts: server
  roles:
    - role: k3s.orchestration.k3s_server

- name: Install K3s agent nodes
  hosts: agent
  roles:
    - role: k3s.orchestration.k3s_agent

- name: Fetch kubeconfig to local machine
  hosts: server[0]
  become: true
  tasks:
    - name: Fetch kubeconfig
      fetch:
        src: /etc/rancher/k3s/k3s.yaml
        dest: "{{ playbook_dir }}/../kubeconfig.yaml"
        flat: true

    - name: Fix kubeconfig server address
      delegate_to: localhost
      become: false
      replace:
        path: "{{ playbook_dir }}/../kubeconfig.yaml"
        regexp: 'https://127.0.0.1:6443'
        replace: "https://{{ api_endpoint }}:{{ api_port | default(6443) }}"
```

- [ ] **Step 2: Create `ansible/playbooks/k3s-upgrade.yml`**

```yaml
---
# Upgrades K3s cluster using the official k3s-ansible collection.
# Updates k3s_version in group_vars/k3s_cluster.yml before running.
#
# Usage: task ansible:k3s-upgrade
#   or:  ansible-playbook playbooks/k3s-upgrade.yml

- name: Upgrade K3s server nodes
  hosts: server
  roles:
    - role: k3s.orchestration.k3s_server

- name: Upgrade K3s agent nodes
  hosts: agent
  roles:
    - role: k3s.orchestration.k3s_agent
```

- [ ] **Step 3: Create `ansible/playbooks/k3s-reset.yml`**

```yaml
---
# Completely removes K3s from all nodes. DESTRUCTIVE — use with caution.
# This will delete all K3s data, pods, and cluster state.
#
# Usage: ansible-playbook playbooks/k3s-reset.yml
#   (intentionally NOT in Taskfile to prevent accidental use)

- name: Reset K3s agent nodes
  hosts: agent
  become: true
  tasks:
    - name: Run K3s agent uninstall script
      command: /usr/local/bin/k3s-agent-uninstall.sh
      args:
        removes: /usr/local/bin/k3s-agent-uninstall.sh

- name: Reset K3s server nodes
  hosts: server
  become: true
  tasks:
    - name: Run K3s server uninstall script
      command: /usr/local/bin/k3s-uninstall.sh
      args:
        removes: /usr/local/bin/k3s-uninstall.sh
```

- [ ] **Step 4: Generate a K3s token**

```bash
openssl rand -base64 64
```

Copy the output and update `ansible/inventory/group_vars/k3s_cluster.yml` — replace `CHANGE_ME_GENERATE_WITH_openssl_rand_-base64_64` with the generated token.

- [ ] **Step 5: Run the K3s install playbook**

```bash
task ansible:k3s-install
```

Expected: K3s cluster bootstrapped via collection roles. All 5 K3s nodes joined (3 servers + 2 agents across 3 hosts). Kubeconfig saved to `ansible/kubeconfig.yaml`.

- [ ] **Step 6: Set up local kubeconfig**

```bash
# Merge into existing kubeconfig (safe — won't overwrite other clusters)
KUBECONFIG=~/.kube/config:ansible/kubeconfig.yaml kubectl config view --flatten > ~/.kube/config.merged
mv ~/.kube/config.merged ~/.kube/config
chmod 600 ~/.kube/config

# Set the new cluster as the active context
kubectl config use-context default
```

If you have no existing kubeconfig, a simple copy works instead:
```bash
mkdir -p ~/.kube
cp ansible/kubeconfig.yaml ~/.kube/config
chmod 600 ~/.kube/config
```

- [ ] **Step 7: Verify the cluster**

```bash
kubectl get nodes -o wide
```

Expected output:
```
NAME        STATUS   ROLES                       AGE   VERSION
articuno    Ready    control-plane,etcd,master   Xm    v1.31.6+k3s1
zapdos      Ready    control-plane,etcd,master   Xm    v1.31.6+k3s1
moltres     Ready    control-plane,etcd,master   Xm    v1.31.6+k3s1
lugia       Ready    <none>                      Xm    v1.31.6+k3s1
ho-oh       Ready    <none>                      Xm    v1.31.6+k3s1
```

- [ ] **Step 8: Verify disabled defaults**

```bash
kubectl get pods -A
```

Expected: No Traefik, no ServiceLB, no local-path-provisioner pods. Only core K3s components (coredns, metrics-server, etc.).

- [ ] **Step 9: Commit**

```bash
git add ansible/playbooks/k3s-install.yml ansible/playbooks/k3s-upgrade.yml ansible/playbooks/k3s-reset.yml
git commit -m "ansible: K3s install/upgrade/reset playbooks using k3s-ansible collection"
```

**Note:** Both `ansible/kubeconfig.yaml` and `ansible/inventory/group_vars/k3s_cluster.yml` are already in `.gitignore` (added in Task 1). Only the `.example` file is committed. The real token and kubeconfig never enter the repo.

---

## Chunk 4: SOPS, Flux, and GitOps Bootstrap

### Task 11: Set up SOPS + age encryption

**Files:**
- Create: `.sops.yaml`

- [ ] **Step 1: Install age and SOPS (on your workstation)**

```bash
# macOS
brew install age sops

# Verify
age --version
sops --version
```

- [ ] **Step 2: Generate an age keypair**

```bash
age-keygen -o ~/.config/sops/age/keys.txt
```

Expected output includes the public key: `age1...`. Save this — you'll need it for `.sops.yaml` and the Flux secret.

**CRITICAL:** Back up `~/.config/sops/age/keys.txt` to your password manager immediately. This is the only key that can decrypt your secrets.

- [ ] **Step 3: Create `.sops.yaml` in repo root**

```yaml
creation_rules:
  - path_regex: kubernetes/.*\.ya?ml$
    encrypted_regex: "^(data|stringData)$"
    age: >-
      age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Replace `age1xxx...` with your actual public key from step 2.

- [ ] **Step 4: Create the SOPS age secret in K8s (for Flux decryption)**

```bash
kubectl create namespace flux-system

kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

- [ ] **Step 5: Test SOPS encryption round-trip**

```bash
# Create a test secret
cat > /tmp/test-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
  namespace: default
type: Opaque
stringData:
  password: "super-secret-value"
EOF

# Encrypt it
sops --encrypt /tmp/test-secret.yaml > /tmp/test-secret.enc.yaml

# Verify data is encrypted
cat /tmp/test-secret.enc.yaml | grep "password"
# Should show encrypted value, not "super-secret-value"

# Decrypt it
sops --decrypt /tmp/test-secret.enc.yaml | grep "password"
# Should show "password: super-secret-value"

# Clean up
rm /tmp/test-secret.yaml /tmp/test-secret.enc.yaml
```

- [ ] **Step 6: Commit**

```bash
git add .sops.yaml
git commit -m "secrets: configure SOPS with age encryption"
```

---

### Task 12: Bootstrap Flux CD

**Files:**
- Creates: `kubernetes/flux-system/` (auto-generated by Flux bootstrap)

**Prerequisites:** GitHub personal access token with `repo` scope. Export as `GITHUB_TOKEN`.

- [ ] **Step 1: Install Flux CLI (on your workstation)**

```bash
# macOS
brew install fluxcd/tap/flux

# Verify
flux --version
```

- [ ] **Step 2: Run Flux pre-flight checks**

```bash
flux check --pre
```

Expected: All checks pass (Kubernetes version compatible, cluster accessible).

- [ ] **Step 3: Bootstrap Flux**

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx  # Your GitHub PAT
export GITHUB_USER=your-github-username

flux bootstrap github \
  --owner=${GITHUB_USER} \
  --repository=homelab \
  --path=kubernetes \
  --personal \
  --private=false
```

Expected: Flux creates/pushes to the GitHub repo, installs its controllers into the cluster, and commits the `kubernetes/flux-system/` directory.

**Note:** If the repo already exists locally, Flux will add to it. If it doesn't exist on GitHub yet, Flux creates it. You may need to set the remote URL after bootstrap:

```bash
git remote set-url origin git@github.com:${GITHUB_USER}/homelab.git
git pull origin main --rebase
```

- [ ] **Step 4: Configure Flux to use SOPS for decryption**

Create `kubernetes/flux-system/patches/sops-decryption.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

Then patch the Flux kustomization:

Add to `kubernetes/flux-system/kustomization.yaml` (append to existing patches):

```yaml
patches:
  - path: patches/sops-decryption.yaml
    target:
      kind: Kustomization
```

- [ ] **Step 5: Commit and push SOPS patch**

```bash
mkdir -p kubernetes/flux-system/patches
# (create the files from step 4)
git add kubernetes/flux-system/patches/
git add kubernetes/flux-system/kustomization.yaml
git commit -m "flux: enable SOPS decryption with age"
git push
```

- [ ] **Step 6: Verify Flux is running and syncing**

```bash
flux check
```

Expected: All Flux components healthy.

```bash
flux get kustomizations
```

Expected:
```
NAME          REVISION        SUSPENDED  READY  MESSAGE
flux-system   main@sha1:xxx   False      True   Applied revision: main@sha1:xxx
```

- [ ] **Step 7: Verify SOPS integration**

```bash
kubectl -n flux-system get secret sops-age
```

Expected: Secret exists.

---

### Task 13: Create initial Flux infrastructure structure

**Files:**
- Create: `kubernetes/infrastructure/controllers/kustomization.yaml`
- Create: `kubernetes/infrastructure/configs/kustomization.yaml`
- Create: `kubernetes/infrastructure/observability/kustomization.yaml`
- Create: `kubernetes/infrastructure/kustomization.yaml`
- Create: `kubernetes/apps/kustomization.yaml`

**Context:** Set up the Flux Kustomization resources that tell Flux what to watch and in what order. Infrastructure deploys before apps.

- [ ] **Step 1: Create `kubernetes/infrastructure/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - controllers
  - configs
  - observability
```

- [ ] **Step 2: Create `kubernetes/infrastructure/controllers/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
  # Will be populated as controllers are added in Phase 2:
  # - metallb.yaml
  # - traefik.yaml
  # - cert-manager.yaml
  # - external-dns.yaml
```

- [ ] **Step 3: Create `kubernetes/infrastructure/configs/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
  # Will be populated in Phase 2:
  # - cluster-issuers.yaml
  # - metallb-config.yaml
```

- [ ] **Step 4: Create `kubernetes/infrastructure/observability/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
  # Will be populated in Phase 4:
  # - kube-prometheus-stack.yaml
  # - loki.yaml
```

- [ ] **Step 5: Create `kubernetes/apps/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
  # Will be populated as apps are migrated in Phase 3
```

- [ ] **Step 6: Create `kubernetes/repositories/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
  # Will be populated with HelmRepository sources in Phase 2:
  # - metallb.yaml
  # - traefik.yaml
  # - cert-manager.yaml
  # - prometheus-community.yaml
```

- [ ] **Step 7: Create Flux Kustomization resources for infrastructure and apps**

These go inside `kubernetes/flux-system/` so the bootstrap Kustomization picks them up automatically.

Create `kubernetes/flux-system/infrastructure.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/infrastructure
  prune: true
  wait: true
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

Create `kubernetes/flux-system/apps.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/apps
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

- [ ] **Step 8: Add new resources to `kubernetes/flux-system/kustomization.yaml`**

Add the infrastructure and apps Kustomizations to the flux-system kustomization's `resources` list so Flux applies them:

```yaml
# Append to the resources list in kubernetes/flux-system/kustomization.yaml
resources:
  # ... existing flux-system resources (gotk-components.yaml, gotk-sync.yaml) ...
  - infrastructure.yaml
  - apps.yaml
```

- [ ] **Step 9: Commit and push**

```bash
git add kubernetes/
git commit -m "flux: add infrastructure and apps Kustomization structure with repositories scaffold"
git push
```

- [ ] **Step 10: Verify Flux picks up the new structure**

```bash
flux reconcile kustomization flux-system --with-source
sleep 30
flux get kustomizations
```

Expected: `flux-system`, `infrastructure`, and `apps` Kustomizations all show `Ready: True`.

---

### Task 14: Push everything to GitHub and verify end-to-end

- [ ] **Step 1: Check git status**

```bash
git status
```

Expected: Clean working tree, all changes committed.

- [ ] **Step 2: Push to GitHub**

```bash
git push origin main
```

- [ ] **Step 3: Verify Flux sync from GitHub**

```bash
flux reconcile source git flux-system
flux get kustomizations
```

Expected: All kustomizations synced from GitHub.

- [ ] **Step 4: Final cluster health check**

```bash
kubectl get nodes -o wide
kubectl get pods -A
flux get all
```

Expected:
- 5 K3s nodes Ready (articuno, zapdos, moltres, lugia, ho-oh)
- Flux system pods running
- All Flux resources synced

---

## Phase 1 Completion Checklist

At the end of Phase 1, you should have:

- [ ] Git repo on GitHub with full directory structure
- [ ] Taskfile with documented commands
- [ ] OpenTofu managing 5 K3s VMs (articuno, zapdos, moltres, lugia, ho-oh) via bpg/proxmox provider
- [ ] Cloud-init Ubuntu template on all 3 Proxmox nodes (latios, latias, rayquaza)
- [ ] Ansible inventory covering Proxmox hosts and K3s nodes
- [ ] K3s cluster: 3 servers (HA etcd) + 2 agents across 3 hosts, all nodes Ready
- [ ] Traefik, ServiceLB, and local-storage disabled (replaced in Phase 2)
- [ ] SOPS + age configured for secret encryption
- [ ] Flux CD bootstrapped, watching GitHub, syncing `kubernetes/` directory
- [ ] Infrastructure and Apps Kustomization structure ready for Phase 2

**Next:** Proceed to Phase 2 (Core Platform) to deploy Traefik, cert-manager, MetalLB, ExternalDNS, democratic-csi, databases, and the auth chain.
