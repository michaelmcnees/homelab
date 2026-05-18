# Talos Kubernetes

Talos replaces the old Ubuntu + K3s node build path. OpenTofu owns the Proxmox VMs, while `talosctl` owns Talos machine config and Kubernetes bootstrap.

Generated Talos files are intentionally ignored:

- `talos/generated/`
- `talos/talosconfig`
- `talos/secrets.yaml`
- `talos/kubeconfig`

`talos/secrets.yaml` is the cluster identity source. Keep a private backup of it.
Regenerating it creates a different Talos CA and client identity, which will not
authenticate to an existing cluster.

## Flow

1. Create the Proxmox VMs with `task infra:plan` and `task infra:apply`.
2. Generate a fresh secrets bundle once with `task talos:gen-secrets`.
3. Generate local Talos configs with `task talos:gen-config`.
4. Apply configs to each node.
5. Bootstrap from `articuno`.
6. Fetch kubeconfig.

The first apply may need the temporary DHCP address shown by Talos maintenance mode or UniFi. Pass that address as `NODE`. Repeat applies can omit `NODE` and use the final static IP.

```sh
task talos:apply-control-plane HOST=articuno NODE=10.0.10.x
task talos:apply-control-plane HOST=zapdos NODE=10.0.10.x
task talos:apply-control-plane HOST=moltres NODE=10.0.10.x
task talos:apply-worker HOST=lugia NODE=10.0.10.x
task talos:apply-worker HOST=ho-oh NODE=10.0.10.x
task talos:bootstrap
task talos:kubeconfig
task talos:health
```
