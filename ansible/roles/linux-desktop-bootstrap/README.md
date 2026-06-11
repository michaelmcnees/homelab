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
