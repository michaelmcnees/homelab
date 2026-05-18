# Talos Kubernetes Pivot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Ubuntu + K3s node build path with Talos Kubernetes while keeping Proxmox VM lifecycle declared in OpenTofu.

**Architecture:** OpenTofu creates five Proxmox VMs with VLAN 10 NICs and a Talos ISO attached. Talos machine configs are generated/applied with `talosctl` tasks, with generated secrets and rendered configs kept out of git.

**Tech Stack:** OpenTofu, bpg/proxmox provider, Talos Linux, talosctl, SOPS/age for secrets.

---

### Task 1: Replace Cloud-Init VM Module With Talos VM Module

**Files:**
- Delete: `terraform/proxmox/modules/k3s-node/main.tf`
- Delete: `terraform/proxmox/modules/k3s-node/variables.tf`
- Delete: `terraform/proxmox/modules/k3s-node/outputs.tf`
- Delete: `terraform/proxmox/modules/k3s-node/versions.tf`
- Create: `terraform/proxmox/modules/talos-node/main.tf`
- Create: `terraform/proxmox/modules/talos-node/variables.tf`
- Create: `terraform/proxmox/modules/talos-node/outputs.tf`

- [x] **Step 1: Create a Talos VM module**

The module should create a VM directly instead of cloning an Ubuntu cloud-init template. It should attach a Talos ISO, create a boot disk on `ceph-nvme`, use VLAN 10, enable serial console, and tag VMs as Talos/Kubernetes nodes.

- [x] **Step 2: Run format/validate**

Run: `tofu fmt -recursive terraform/proxmox && tofu validate`
Expected: formatting succeeds and validation reports the configuration is valid.

### Task 2: Seed Talos ISO Into Shared Proxmox Storage

**Files:**
- Modify: `terraform/proxmox/variables.tf`
- Modify: `Taskfile.yml`

- [x] **Step 1: Add Talos image variables**

Add `talos_version`, `talos_iso_url`, `talos_iso_datastore`, and `talos_iso_file_id` variables. Default to Talos `v1.12.6`, the official `metal-amd64.iso` release asset, and the shared `nfs-isos` datastore.

- [x] **Step 2: Add an ISO pre-seed task**

Use an Ansible-backed `task infra:talos-iso` command to download the ISO once into `/mnt/pve/nfs-isos/template/iso/`. OpenTofu should reference the resulting shared file ID instead of uploading ISO content through the Proxmox provider.

### Task 3: Update Node Definitions

**Files:**
- Modify: `terraform/proxmox/articuno.tf`
- Modify: `terraform/proxmox/zapdos.tf`
- Modify: `terraform/proxmox/moltres.tf`
- Modify: `terraform/proxmox/lugia.tf`
- Modify: `terraform/proxmox/ho-oh.tf`
- Modify: `terraform/proxmox/outputs.tf`

- [x] **Step 1: Point all five nodes at `./modules/talos-node`**

Pass each node the shared Talos ISO file ID and keep the existing VMIDs, IPs, host placement, disk sizes, and VLAN 10 tag.

Update: the original `110`-`114` VMIDs conflicted with existing Proxmox cluster guests, so the Talos VMs now use `140`-`144` while keeping the same static Kubernetes VLAN IPs.

- [x] **Step 2: Rename tags and outputs from K3s to Talos/Kubernetes**

Use `talos`, `kubernetes`, `control-plane`, and `worker` tags.

### Task 4: Add Talos Tasks and Ignore Generated Material

**Files:**
- Modify: `.gitignore`
- Modify: `Taskfile.yml`
- Create: `talos/patches/common.yaml`
- Create: `talos/patches/nodes/articuno.yaml`
- Create: `talos/patches/nodes/zapdos.yaml`
- Create: `talos/patches/nodes/moltres.yaml`
- Create: `talos/patches/nodes/lugia.yaml`
- Create: `talos/patches/nodes/ho-oh.yaml`
- Create: `talos/README.md`

- [x] **Step 1: Ignore generated Talos secrets/configs**

Ignore `talos/generated/`, `talos/talosconfig`, and `talos/secrets.yaml`.

- [x] **Step 2: Add task commands**

Add tasks for generating config, applying control-plane configs, applying worker configs, bootstrapping, fetching kubeconfig, and checking node health.

### Task 5: Retire K3s Ansible Path From Active Tasks

**Files:**
- Modify: `Taskfile.yml`
- Modify: `ansible/collections/requirements.yml`

- [x] **Step 1: Remove active K3s task entry points**

Keep Proxmox and PostgreSQL Ansible tasks, but remove K3s prepare/install/upgrade from the main task list.

- [x] **Step 2: Leave old K3s playbooks untouched for now**

Do not delete the old playbooks in the same change. Once Talos is bootstrapped, remove or archive the obsolete K3s Ansible files in a follow-up.

### Task 6: Verify Planning

**Files:**
- No file edits.

- [x] **Step 1: Run OpenTofu validation**

Run: `tofu fmt -recursive terraform/proxmox && tofu validate`
Expected: success.

- [x] **Step 2: Run Proxmox plan**

Run: `task infra:plan`
Expected: plan creates five Talos VMs referencing the pre-seeded shared ISO; no K3s/Ubuntu cloud-init template clone remains.

### Current Blocker: Proxmox API Token Permissions

The Talos VM plan is ready, and `nfs-isos:iso/talos-1.12.6-metal-amd64.iso` is pre-seeded on shared Proxmox storage. Applying the five VM resources is currently blocked by Proxmox returning HTTP 403 permission errors for the configured API token. Grant the token VM/storage creation permissions, or switch the ignored local tfvars to a sufficiently privileged Proxmox credential, then rerun `task infra:apply`.
