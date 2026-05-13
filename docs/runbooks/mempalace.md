# MemPalace

MemPalace is deployed as a pilot shared-memory workbench for Hermes, Codex, and Claude. It is local-first storage, not a normal web service, so the Kubernetes deployment keeps a long-running utility pod with the MemPalace CLI installed and the palace data mounted from TrueNAS.

## Shape

- Namespace: `apps`
- Deployment: `mempalace`
- Package: `mempalace==3.3.5`
- Data PV: `10.0.1.1:/mnt/data/k8s/apps/mempalace`
- Palace path in pod: `/data/palace`
- Workspace path in pod: `/workspace`
- No ingress or ClusterIP service

The official MemPalace project warns about impostor domains. Trust only:

- `https://github.com/MemPalace/mempalace`
- `https://pypi.org/project/mempalace/`
- `https://mempalaceofficial.com`

## TrueNAS

The palace directory is:

```text
/mnt/data/k8s/apps/mempalace/palace
```

It is exported through NFS for Kubernetes and mapped to the existing `apps:apps` media identity.

## Basic Commands

Open a shell:

```bash
kubectl --kubeconfig talos/kubeconfig -n apps exec -it deployment/mempalace -- sh
```

Check status:

```bash
python -m mempalace.cli --palace /data/palace status
```

Mine the mounted workspace:

```bash
python -m mempalace.cli --palace /data/palace init /workspace --yes
python -m mempalace.cli --palace /data/palace mine /workspace --wing homelab
```

`init --yes` writes `/workspace/mempalace.yaml`, but it may still skip the immediate mining prompt. Run `mine` explicitly after init.

Search:

```bash
python -m mempalace.cli --palace /data/palace search "why did we pick Talos" --wing homelab
```

Wake-up context:

```bash
python -m mempalace.cli --palace /data/palace wake-up --wing homelab
```

## Hermes Integration

Native Hermes support is still being discussed upstream in `NousResearch/hermes-agent#6323`. Until that lands, use this pilot in one of two ways:

1. Manual context injection: run `wake-up` or `search` in the MemPalace pod and paste the result into Hermes.
2. Future MCP bridge: install MemPalace in the Hermes image or mount compatible tooling, then run `mempalace --palace /data/palace mcp` once Hermes can consume the MCP server safely.

Do not expose the palace over a public route. The memory store may contain conversation history and sensitive project context.

## Codex and Claude

For local Codex and Claude usage, install MemPalace on the workstation and point it at a mounted copy of the same palace data if needed. The cleanest local path is a TrueNAS SMB/NFS mount of:

```text
/mnt/data/k8s/apps/mempalace/palace
```

Then use MemPalace's generated MCP instructions:

```bash
mempalace --palace /path/to/mounted/palace mcp
```

This keeps Kubernetes as the shared storage home, while desktop tools use their own local MCP process.

## Backup

The palace directory is on TrueNAS. It should be covered by TrueNAS snapshots for `data/k8s`. If the palace becomes important, add a restic job or explicit snapshot check for `/mnt/data/k8s/apps/mempalace`.

## Validation

The initial pilot was validated with a single seed document:

```bash
python -m mempalace.cli --palace /data/palace mine /workspace --wing homelab
python -m mempalace.cli --palace /data/palace search "self-hosted shared memory pilot" --wing homelab --results 3
python -m mempalace.cli --palace /data/palace status
```

Expected result: search returns `homelab-memory-seed.md`, and status shows at least one drawer under the `homelab` wing.
