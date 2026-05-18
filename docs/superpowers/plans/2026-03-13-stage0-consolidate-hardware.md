# Stage 0: Consolidate + Build New Nodes — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate existing LXCs onto Mew (swing node), convert snorlax to a Proxmox host named rayquaza with a TrueNAS VM (snorlax), and build two custom AMD 8700G nodes (latios, latias) — producing a 3-node Proxmox cluster ready for K3s VM provisioning. Dell Micros (charmander, squirtle, bulbasaur, pikachu) remain running legacy services (Docker, LazyLibrarian, Booklore) until Phase 3.

**Architecture:** Three independent tracks run in parallel or any order. Track A uses Proxmox live migration (Ceph LXCs) and backup/restore (local-storage LXCs) to move everything to Mew. Track B wipes snorlax's boot drive, installs Proxmox as rayquaza, passes through the HBA/iGPU/NVMe to a TrueNAS VM (snorlax), and imports existing ZFS pools. Track C builds two custom AMD nodes from scratch and provisions K3s VMs on them.

**Tech Stack:** Proxmox VE, Ceph, ZFS, IOMMU/VFIO passthrough, TrueNAS SCALE

**Spec:** `docs/superpowers/specs/2026-03-13-migration-plan-design.md` (Stage 0)

---

## Chunk 1: Track A — Consolidate onto Mew

### Task 1: Inventory current LXC/VM placement and storage backends

Before migrating, we need to know exactly what's where and whether each LXC is on Ceph or local storage.

- [ ] **Step 1: List all LXCs and VMs across the cluster**

From any Proxmox node or the web UI:

```bash
# Run on each Proxmox host (charmander, squirtle, bulbasaur, pikachu, mew)
pvesh get /nodes/<hostname>/lxc --output-format json-pretty
pvesh get /nodes/<hostname>/qemu --output-format json-pretty
```

Or from the Proxmox web UI: Datacenter → each node → list of CTs and VMs.

- [ ] **Step 2: Document storage backend per LXC**

For each LXC, check its disk configuration:

```bash
pct config <CTID>
```

Look for the `rootfs` line:
- `rootfs: ceph-pool:vm-XXX-disk-0` → **Ceph** (can live-migrate)
- `rootfs: local-lvm:vm-XXX-disk-0` → **Local** (needs backup/restore)

Record this in a checklist:

```
LXC: adguard (CTID: ???) — Ceph / Local — Node: ???
LXC: traefik (CTID: ???) — Ceph / Local — Node: ???
... (all 27 LXCs)
```

- [ ] **Step 3: Identify LXCs that must stay on pikachu**

Per the migration spec, these LXCs require host networking on pikachu and should either stay on pikachu or move to Mew temporarily:
- **homey-shs** — host networking required
- **homebridge** — host networking + USB access
- **pelican-wings** — stays on pikachu permanently

Decide: do these stay on pikachu during migration, or move to Mew temporarily? If Homebridge needs USB from pikachu, it must stay.

- [ ] **Step 4: Document the plan**

Create a migration checklist with columns: LXC name, CTID, current node, storage type, migration method (live-migrate / backup-restore / stays), target.

---

### Task 2: Live-migrate Ceph-backed LXCs to Mew

**Context:** Ceph-backed LXCs can be live-migrated with zero downtime. The LXC keeps running during migration — Proxmox handles the memory transfer and storage is already shared via Ceph.

- [ ] **Step 1: Verify Mew has sufficient resources**

```bash
# Check Mew's available resources
pvesh get /nodes/mew/status --output-format json-pretty
```

Mew has 256GB RAM and 1.44TB disk. Verify there's enough headroom for all LXCs combined. (There will be — the existing LXCs are small.)

- [ ] **Step 2: Live-migrate Ceph LXCs one at a time**

For each Ceph-backed LXC (except those staying on pikachu):

Via Proxmox web UI: Right-click LXC → Migrate → Target node: mew → Check "Online" → Start.

Or via CLI:

```bash
# From the source node
pct migrate <CTID> mew --online
```

**Order suggestion:** Start with non-critical LXCs (influxdb, mariadb, beszel, etc.) to build confidence, then migrate critical services (adguard, traefik) last.

Verify each LXC is running on Mew after migration:

```bash
pct status <CTID>  # Should show "running" on mew
```

- [ ] **Step 3: Verify critical services after migration**

After migrating AdGuard:
```bash
# From any device on the network
nslookup google.com <adguard-ip>
```

After migrating Traefik:
```bash
# Test a service that goes through Traefik
curl -I https://<any-service>.home.mcnees.me
```

After migrating Homey (if moved):
- Check Homey app on phone — devices responding

- [ ] **Step 4: Verify all Ceph LXCs are on Mew**

```bash
pvesh get /nodes/mew/lxc --output-format json-pretty
```

Confirm all expected LXCs appear.

---

### Task 3: Backup and restore local-storage LXCs to Mew

**Context:** Local-storage LXCs can't live-migrate because their disk is on the local node. We backup, restore to Mew (which will place the disk on Ceph or Mew's local storage), then destroy the original. This causes brief downtime per LXC.

- [ ] **Step 1: Schedule during low-usage hours**

Local-storage LXC migrations cause downtime. Do these during off-hours (late night or early morning).

- [ ] **Step 2: For each local-storage LXC**

```bash
# 1. Stop the LXC
pct stop <CTID>

# 2. Create a backup
vzdump <CTID> --storage <backup-storage> --compress zstd --mode stop

# 3. Restore on Mew (specify ceph storage for the restored disk)
pct restore <NEW_CTID> /path/to/backup/vzdump-lxc-<CTID>-*.tar.zst \
  --storage ceph-pool --target mew

# 4. Start the restored LXC on Mew
pct start <NEW_CTID>

# 5. Verify the service works
# (service-specific verification)

# 6. Destroy the original on the old node
pct destroy <CTID>
```

Alternatively, use the Proxmox web UI: Backup → Restore → select mew as target.

- [ ] **Step 3: Verify all local-storage LXCs are on Mew**

Same verification as Task 2 Step 4.

---

### Task 4: Destroy old K3s VMs and unused LXCs

- [ ] **Step 1: Destroy old K3s VMs**

These VMs are empty (only Portainer agent running). Destroy them on their respective nodes:

```bash
# Stop and destroy each old K3s VM
qm stop <VMID> && qm destroy <VMID>
```

VMs to destroy: articuno, zapdos, moltres, lugia, ho-oh (old K3s cluster), hass.

Via Proxmox UI: Right-click VM → Stop → Remove (check "Destroy unreferenced disks").

- [ ] **Step 2: Destroy MariaDB LXC**

Confirmed unused. Destroy on whichever node it's running (should be on Mew after migration):

```bash
pct stop <CTID> && pct destroy <CTID>
```

- [ ] **Step 3: Verify Mew consolidation is complete**

```bash
# Verify Mew has all migrated LXCs
pvesh get /nodes/mew/lxc --output-format json-pretty

# Dells may still have legacy services running — that's expected
# pikachu may have homey-shs, homebridge, pelican-wings
```

Expected:
- charmander, squirtle, bulbasaur, pikachu: may still run legacy Docker services, LazyLibrarian, Booklore — this is fine until Phase 3
- pikachu: homey-shs, homebridge, pelican-wings (if they stayed)
- mew: all migrated LXCs running

- [ ] **Step 4: Commit any documentation updates**

If you created a migration checklist or notes, add them to the repo:

```bash
git add docs/
git commit -m "docs: track Stage 0 Track A consolidation onto Mew"
```

---

## Chunk 2: Track B — Rayquaza Conversion

### Task 5: Prepare for snorlax → rayquaza conversion

**Context:** Snorlax currently runs TrueNAS bare-metal. We need to convert it to a Proxmox host (renamed rayquaza) while preserving the ZFS pools on the HBA-connected drives. The boot SSD gets wiped; the HBA drives are untouched. The TrueNAS VM running on rayquaza will be named snorlax (inheriting the old hostname).

**Risk:** Plex and all TrueNAS apps will be offline during conversion. Schedule this when nobody is streaming.

- [ ] **Step 1: Document current TrueNAS configuration**

From TrueNAS web UI or CLI, export/document:

```bash
# Export TrueNAS config backup
# TrueNAS UI: System → General → Save Config

# Document pool layout
zpool status
zpool list

# Document datasets
zfs list -r <pool-name>

# Document shares (NFS/SMB)
# TrueNAS UI: Shares → document all share configs

# Document network configuration
# TrueNAS UI: Network → document interfaces, IPs, DNS

# Document running apps/services
# TrueNAS UI: Apps → document all installed apps and their configs
```

Save all documentation and the config backup to a safe location (NOT on snorlax — use another machine or cloud storage).

- [ ] **Step 2: Snapshot all datasets**

```bash
# Create a recursive snapshot of all pools before any changes
zfs snapshot -r <pool-name>@pre-migration-$(date +%Y%m%d)
```

This provides a rollback point if something goes wrong with pool import.

- [ ] **Step 3: Export ZFS pools**

```bash
# Export the ZFS pool cleanly — this is required before the drives
# are presented to a new OS/VM
zpool export <pool-name>
```

After export, verify the pool status shows as exported.

- [ ] **Step 4: Verify HBA drives are independent of boot**

Confirm the boot SSD is on the motherboard SATA/NVMe, not on the HBA card. The HBA card and all drives attached to it will be passed through to the snorlax VM. The boot SSD stays with Proxmox.

- [ ] **Step 5: Download Proxmox ISO**

Download the latest Proxmox VE ISO to a USB drive:
- https://www.proxmox.com/en/downloads

- [ ] **Step 6: Communicate downtime**

Let the household know: Plex, Tdarr, SABnzbd, and any TrueNAS-dependent services will be offline for a few hours.

---

### Task 6: Install Proxmox on rayquaza

- [ ] **Step 1: Install Proxmox VE**

Boot from USB, install Proxmox onto the boot SSD (formerly snorlax).

During installation:
- **Target disk**: Select the boot SSD only (NOT any HBA drives)
- **Hostname**: `rayquaza`
- **IP**: Keep the existing management IP (should be `10.0.0.74` based on the inventory, or assign a new one for rayquaza)
- **Gateway/DNS**: Match existing network config

- [ ] **Step 2: Post-install configuration**

After first boot, access Proxmox web UI at `https://<rayquaza-ip>:8006`.

```bash
# Remove enterprise repo, add no-subscription repo
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
apt update && apt full-upgrade -y
```

- [ ] **Step 3: Join rayquaza to the Proxmox cluster**

From an existing cluster node (e.g., mew):

```bash
# Get the join information
pvecm status
```

From rayquaza:

```bash
pvecm add <existing-node-ip> --use_ssh
```

Verify in Proxmox UI: Datacenter → Cluster → rayquaza appears as a member.

- [ ] **Step 4: Verify Ceph connectivity**

Rayquaza doesn't contribute an OSD (no spare SSD), but it should still be able to access Ceph storage as a client for VM boot disks:

```bash
ceph status  # Should show cluster health
ceph osd pool ls  # Should list pools
```

---

### Task 7: Configure IOMMU and device passthrough on rayquaza

**Context:** We need to pass through the HBA card (for ZFS drives), the iGPU (for QuickSync transcoding), and the NVMe metadata drives to the snorlax VM.

- [ ] **Step 1: Enable IOMMU in BIOS**

Reboot rayquaza, enter BIOS:
- Enable **VT-d** (Intel Virtualization Technology for Directed I/O)
- Enable **SR-IOV** if available
- Save and exit

- [ ] **Step 2: Enable IOMMU in Proxmox boot parameters**

```bash
# Edit the GRUB config
nano /etc/default/grub

# Change the GRUB_CMDLINE_LINUX_DEFAULT line to:
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"

# Update GRUB
update-grub
```

- [ ] **Step 3: Load VFIO modules**

```bash
# Add VFIO modules to load at boot
cat >> /etc/modules <<EOF
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF
```

- [ ] **Step 4: Blacklist GPU drivers (for iGPU passthrough)**

```bash
# Prevent the host from using the iGPU
cat > /etc/modprobe.d/blacklist-gpu.conf <<EOF
blacklist i915
blacklist snd_hda_intel
EOF
```

- [ ] **Step 5: Reboot and verify IOMMU**

```bash
reboot

# After reboot, verify IOMMU is enabled
dmesg | grep -e DMAR -e IOMMU

# List IOMMU groups to find HBA, iGPU, and NVMe devices
find /sys/kernel/iommu_groups/ -type l | sort -V
```

- [ ] **Step 6: Identify PCI device IDs**

```bash
# Find the HBA card
lspci -nn | grep -i "SAS\|HBA\|LSI\|Broadcom"

# Find the iGPU
lspci -nn | grep -i "VGA\|Display"

# Find the NVMe drives (the 2x 1TB metadata drives)
lspci -nn | grep -i "NVMe\|Non-Volatile"
```

Record the PCI addresses (e.g., `0000:03:00.0`) and device IDs (e.g., `[8086:xxxx]`) for each device. You'll need these when creating the snorlax VM.

---

### Task 8: Create snorlax VM and install TrueNAS

- [ ] **Step 1: Create the snorlax VM**

Via Proxmox web UI or CLI:

```bash
qm create 200 \
  --name snorlax \
  --memory 32768 \
  --cores 4 \
  --sockets 2 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --efidisk0 ceph-pool:1,format=raw,efitype=4m,pre-enrolled-keys=1 \
  --scsihw virtio-scsi-single \
  --scsi0 ceph-pool:32,format=raw \
  --net0 virtio,bridge=vmbr0 \
  --ostype l26 \
  --boot order=scsi0
```

Adjust VMID (200) as needed. Key settings:
- **Memory**: 32GB
- **CPU**: Host passthrough for best performance
- **Machine**: q35 (required for PCIe passthrough)
- **BIOS**: OVMF/UEFI (required for PCIe passthrough)
- **Boot disk**: Ceph-backed (live-migratable in theory, though passthrough pins it to rayquaza)

- [ ] **Step 2: Attach PCI devices for passthrough**

Using the PCI addresses identified in Task 7 Step 6:

```bash
# Pass through HBA card
qm set 200 --hostpci0 <HBA_PCI_ADDRESS>,pcie=1

# Pass through iGPU
qm set 200 --hostpci1 <IGPU_PCI_ADDRESS>,pcie=1

# Pass through NVMe drives (each one separately)
qm set 200 --hostpci2 <NVME1_PCI_ADDRESS>,pcie=1
qm set 200 --hostpci3 <NVME2_PCI_ADDRESS>,pcie=1
```

- [ ] **Step 3: Upload TrueNAS ISO and attach to VM**

```bash
# Download TrueNAS SCALE ISO to Proxmox
wget -P /var/lib/vz/template/iso/ <truenas-scale-iso-url>

# Attach ISO to snorlax
qm set 200 --cdrom local:iso/<truenas-iso-filename>
```

- [ ] **Step 4: Install TrueNAS SCALE**

Start the VM and open the console:

```bash
qm start 200
```

In the TrueNAS installer:
- **Install destination**: The 32GB Ceph-backed virtual disk (NOT any passed-through drives)
- **Set admin password**
- Complete installation, remove ISO, reboot

- [ ] **Step 5: Import ZFS pools**

In TrueNAS web UI or CLI:

```bash
# The pools from the passed-through HBA drives should be visible
zpool import  # List available pools

# Import the pool
zpool import <pool-name>

# Verify datasets are intact
zfs list -r <pool-name>

# Verify snapshots exist (including the pre-migration snapshot)
zfs list -t snapshot -r <pool-name>
```

- [ ] **Step 6: Restore TrueNAS configuration**

From TrueNAS web UI:
- System → General → Upload Config → select the config backup from Task 5

Or manually recreate:
- Network configuration (IP, DNS, gateway)
- NFS/SMB shares
- Users and permissions
- App configurations (Plex, Tdarr, SABnzbd, Stash, Romm)

- [ ] **Step 7: Verify iGPU passthrough for QuickSync**

In TrueNAS / inside the Plex container:

```bash
# Check that the iGPU is visible
ls /dev/dri/
# Should show renderD128 and card0

# Verify with vainfo (if available)
vainfo
```

Plex should show hardware transcoding available in settings.

- [ ] **Step 8: Verify all TrueNAS services**

| Service | How to verify |
|---------|--------------|
| Plex | Open Plex web UI, play a video, confirm hardware transcoding works |
| Tdarr | Open Tdarr web UI, confirm it sees the library and GPU |
| SABnzbd | Open SABnzbd web UI, confirm connection to indexers |
| Stash | Open Stash web UI, confirm library accessible |
| Romm | Open Romm web UI |
| NFS shares | From another machine: `showmount -e <snorlax-ip>` |
| SMB shares | Access from a client machine |

- [ ] **Step 9: Configure snorlax for automatic start**

In Proxmox:

```bash
qm set 200 --onboot 1 --startup order=1
```

This ensures snorlax starts automatically if rayquaza reboots.

---

### Task 9: Create moltres VM placeholder on rayquaza

**Context:** moltres (K3s server) will run on rayquaza alongside snorlax. We don't install K3s yet (that's Stage 2), but we can reserve resources and create the VM definition in OpenTofu.

- [ ] **Step 1: Verify resource budget on rayquaza**

rayquaza specs: i3-13100 (4C/8T), 64GB RAM (check actual).

Resource allocation:
- snorlax (TrueNAS VM): ~32GB RAM
- moltres (K3s server): ~10GB RAM
- Proxmox host overhead: ~2-4GB
- Remaining: ~18-20GB buffer

```bash
# Verify on rayquaza
free -h
nproc
```

- [ ] **Step 2: Note for Stage 2**

Do NOT create the moltres VM yet — it needs to be on VLAN 10 which doesn't exist until Stage 1. OpenTofu will create it in Stage 2 after networking is in place.

Record that rayquaza is ready for moltres with ~10GB RAM allocated.

---

## Chunk 3: Track C — Build Custom Nodes (latios + latias)

### Task 10: Physical assembly

**Context:** Two custom AMD 8700G mini-PCs are being built from parts. These become the primary K3s compute nodes.

- [ ] **Step 1: Assemble latios**

Parts: AMD 8700G CPU, motherboard, RAM, PSU, cooler, NVMe boot drive, case.

Assemble, verify POST, enter BIOS to confirm all hardware detected.

- [ ] **Step 2: Assemble latias**

Same as latios. Assemble, verify POST, enter BIOS.

- [ ] **Step 3: Enable virtualization in BIOS (both nodes)**

On each node, enter BIOS and enable:
- **SVM** (AMD Secure Virtual Machine / AMD-V)
- **IOMMU** (if available, for future PCIe passthrough)
- Set boot order to USB first (for Proxmox install)

---

### Task 11: Install Proxmox on latios and latias

- [ ] **Step 1: Install Proxmox VE on latios**

Boot from USB, install Proxmox onto the NVMe boot drive.

During installation:
- **Target disk**: NVMe boot drive
- **Hostname**: `latios`
- **IP**: Assign a management IP on the existing management network
- **Gateway/DNS**: Match existing network config

- [ ] **Step 2: Install Proxmox VE on latias**

Same process:
- **Hostname**: `latias`
- **IP**: Assign a management IP on the existing management network

- [ ] **Step 3: Post-install configuration (both nodes)**

```bash
# Remove enterprise repo, add no-subscription repo
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
apt update && apt full-upgrade -y
```

- [ ] **Step 4: Join latios to the Proxmox cluster**

From latios:

```bash
pvecm add <existing-node-ip> --use_ssh
```

Verify in Proxmox UI: Datacenter → Cluster → latios appears.

- [ ] **Step 5: Join latias to the Proxmox cluster**

From latias:

```bash
pvecm add <existing-node-ip> --use_ssh
```

Verify in Proxmox UI: Datacenter → Cluster → latias appears.

---

### Task 12: Configure networking and Ceph on new nodes

- [ ] **Step 1: Configure VLAN-aware bridges on latios**

```bash
# Edit /etc/network/interfaces to create a VLAN-aware bridge
# Example:
auto vmbr0
iface vmbr0 inet static
    address <latios-mgmt-ip>/24
    gateway <gateway-ip>
    bridge-ports <physical-interface>
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

- [ ] **Step 2: Configure VLAN-aware bridges on latias**

Same as latios, with latias's IP.

- [ ] **Step 3: Add Ceph OSDs on latios**

Install 1-2x 1TB SATA SSDs in latios and add as Ceph OSDs:

```bash
# Install the SSD(s) physically, then:
ceph-volume lvm create --data /dev/<ssd-device>
```

Or via Proxmox UI: Datacenter → latios → Ceph → OSD → Create OSD.

- [ ] **Step 4: Add Ceph OSDs on latias**

Same process for latias.

- [ ] **Step 5: Verify Ceph health**

```bash
ceph status
ceph osd tree  # Should show new OSDs on latios and latias
```

---

### Task 13: Create K3s VMs on new nodes

**Context:** K3s VMs are created now as placeholders but K3s installation happens in Stage 2. VMs need to be on VLAN 10 (created in Stage 1), so these may be created in Stage 2 via OpenTofu instead. This task documents the planned allocation.

- [ ] **Step 1: Plan VM allocation on latios**

| VM | Role | RAM | Notes |
|----|------|-----|-------|
| articuno | K3s server | 10GB | Control plane |
| lugia | K3s agent | 40GB | Primary workload runner |

- [ ] **Step 2: Plan VM allocation on latias**

| VM | Role | RAM | Notes |
|----|------|-----|-------|
| zapdos | K3s server | 10GB | Control plane |
| ho-oh | K3s agent | 20GB | Workload runner |
| pelipper | Pelican | 20GB | Pelican panel |

- [ ] **Step 3: Note for Stage 2**

Do NOT create the K3s VMs yet — they need VLAN 10 networking from Stage 1. OpenTofu will create them in Stage 2.

Record planned allocations so Stage 2 can reference them.

---

### Task 14: Migrate smart-home services

- [x] **Step 1: Migrate Homey to Kubernetes**

Homey was migrated into the `smart-home` namespace and verified stable
overnight. The public route remains `homey.mcnees.me`; local access remains
`homey.home.mcnees.me`.

- [x] **Step 2: Migrate Homebridge to Kubernetes**

Homebridge was migrated into the `smart-home` namespace and verified stable
overnight at `homebridge.home.mcnees.me`.

---

## Chunk 4: Storage Tiering (0B+)

**Context:** After the snorlax TrueNAS VM is running on rayquaza with passed-through NVMe drives, configure storage tiering for optimal performance.

This includes:
- Optane drives for ZFS metadata (special vdev) and ZIL/SLOG
- NVMe drives for L2ARC read cache
- SSD pool for flash-tier datasets

Refer to `docs/superpowers/specs/2026-03-14-storage-tiering-design.md` for the full design.

---

## Chunk 5: Final Verification

### Task 15: Final verification and commit

- [ ] **Step 1: Verify end state**

**Track A (Mew consolidation):**
- [ ] All services accessible and functioning on Mew
- [ ] Old K3s VMs destroyed
- [ ] MariaDB LXC destroyed
- [ ] Dells (charmander, squirtle, bulbasaur, pikachu) still running legacy services — this is expected

**Track B (Rayquaza conversion):**
- [ ] Proxmox installed on rayquaza (formerly snorlax), joined to cluster
- [ ] snorlax VM running with HBA, iGPU, NVMe passthrough
- [ ] ZFS pools imported, all datasets intact
- [ ] Plex working with hardware transcoding
- [ ] All TrueNAS apps functional
- [ ] NFS/SMB shares accessible

**Track C (Custom nodes):**
- [ ] latios assembled, Proxmox installed, joined to cluster
- [ ] latias assembled, Proxmox installed, joined to cluster
- [ ] VLAN-aware bridges configured on both nodes
- [ ] Ceph OSDs added on both nodes
- [x] Homey running in Kubernetes and verified stable
- [x] Homebridge running in Kubernetes and verified stable
- [ ] K3s VM allocations documented for Stage 2

- [ ] **Step 2: Commit any changes**

```bash
git add -A
git commit -m "docs: complete Stage 0 — Mew consolidation, rayquaza conversion, custom node builds"
git push origin main
```

---

## Stage 0 Completion Checklist

At the end of Stage 0, you should have:

- [ ] All existing LXCs running on Mew (except those migrated to latios/latias)
- [ ] Dells (charmander, squirtle, bulbasaur, pikachu) still running legacy Docker services, LazyLibrarian, Booklore — decommissioned in Phase 3
- [ ] Old K3s VMs (articuno-ho-oh) and hass VM destroyed
- [ ] MariaDB LXC destroyed
- [ ] Rayquaza (formerly snorlax) running Proxmox, joined to cluster
- [ ] Snorlax VM running TrueNAS on rayquaza with all pools imported and services working
- [ ] Plex/Tdarr hardware transcoding verified
- [ ] Latios running Proxmox, joined to cluster, Ceph OSDs added, Homey LXC migrated
- [ ] Latias running Proxmox, joined to cluster, Ceph OSDs added, Homebridge LXC migrated
- [ ] 3-node cluster (latios, latias, rayquaza) ready for K3s VM provisioning
- [ ] K3s VM allocations planned: articuno + lugia on latios, zapdos + ho-oh + pelipper on latias, moltres on rayquaza
- [ ] All critical services (AdGuard, Traefik, Homey/Homebridge, Plex) working

**Next:** Proceed to Stage 1 (Networking) to set up VLAN infrastructure via OpenTofu.
