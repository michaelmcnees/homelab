# TrueNAS

TrueNAS storage configuration is managed with Ansible over SSH. OpenTofu remains responsible for infrastructure providers such as Proxmox and UniFi; TrueNAS datasets, local service users, permissions, and NFS shares are host configuration, so they live in Ansible.

The playbook uses the local TrueNAS `midclt` client on the appliance. This avoids relying on the deprecated REST API and keeps the managed operations close to the API methods documented by TrueNAS.

## Local Vars

Copy the example vars file:

```bash
cp ansible/inventory/group_vars/truenas.yml.example ansible/inventory/group_vars/truenas.yml
```

Then review the dataset and NFS share declarations in `ansible/inventory/group_vars/truenas.yml`. The file is gitignored because future TrueNAS automation may need local-only details.

## Access

The inventory expects TrueNAS at `10.0.1.1` and SSH access as `root`:

```bash
ssh root@10.0.1.1 midclt call system.info
```

If TrueNAS root SSH is disabled, enable SSH for an administrative account that can run `midclt`, then update `ansible/inventory/hosts.yml` or local inventory vars accordingly.

For a non-root admin account, set these in `ansible/inventory/group_vars/truenas.yml`:

```yaml
ansible_user: truenas_admin
ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

## Apply

```bash
task ansible:truenas
```

The playbook manages:

- Local NFS writer group/user, defaulting to `k8s-backup` with UID/GID `2000`.
- ZFS datasets declared in `truenas_datasets`.
- Dataset ownership and mode for Kubernetes writers.
- NFS shares declared in `truenas_nfs_shares`.
- NFS share allow lists and mapall user/group settings.

## Paperless Datasets

Paperless currently expects these TrueNAS exports:

```text
10.0.1.1:/mnt/data/apps/paperless/media
10.0.1.1:/mnt/data/apps/paperless/consume
10.0.1.1:/mnt/data/apps/paperless/export
```

Those desired datasets and shares are included in the example vars file. After `task ansible:truenas` succeeds, Paperless can be enabled in the root apps Kustomization.
