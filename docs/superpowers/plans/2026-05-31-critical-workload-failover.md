# Critical Workload Failover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make loss of the `lugia` VM survivable for external-service routing and notes workflows by removing single-node routing/state assumptions, proving failover to `ho-oh`, and adding guardrails so the original host OOM failure alerts before it becomes an outage.

**Architecture:** Keep Talos worker nodes on Proxmox, but treat `local-path` as non-critical-only storage. Put app-private RWO state for critical workloads on native Ceph RBD, keep canonical shared data on TrueNAS NFS where already intentional, and run Tailscale ingress/subnet routing with redundant operator-managed proxies spread across workers.

**Tech Stack:** Talos Kubernetes, Flux/Kustomize, Tailscale Kubernetes Operator, Proxmox VE, Ceph RBD/CephFS CSI, kube-prometheus-stack.

---

## Incident Findings

- `lugia` is Proxmox VM `143` on `latios` (`10.0.3.196`), configured from `terraform/proxmox/lugia.tf` with 8 cores and 40 GiB RAM.
- Kubernetes stopped hearing from `lugia` at 2026-05-29 23:43:52 America/Detroit, and the node lease stopped renewing at 23:44:45.
- `latios` killed the QEMU process for VM `143` at 2026-05-29 23:44:51:
  - `143.scope: A process of this unit has been killed by the OOM killer.`
  - `Out of memory: Killed process ... (kvm) ... task_memcg=/qemu.slice/143.scope`
- At the OOM event, `lugia` had roughly 27 GiB RSS, `articuno` roughly 5.8 GiB RSS, Ceph OSDs were present, and two `ceph ... --help` commands from an Ansible/Ceph provisioning session were each reported around 10.8 GiB RSS.
- `qm config 143` already has `onboot: 1`, so the VM was not intentionally disabled. It was killed by host memory pressure and stayed off until manually/externally started on 2026-05-31 15:50:47.
- The Kubernetes blast radius was high because:
  - Tailscale subnet router and shared-service ingress proxies were single-replica operator-managed pods, and all generated proxy pods landed on `lugia` after recovery.
  - `apps/trilium-data`, `apps/hermes-data`, and `apps/hermes-workspace` are `local-path` PVCs, so the notes path could not simply restart on `ho-oh`.

## References

- Tailscale Kubernetes Operator: https://tailscale.com/docs/features/kubernetes-operator/
- Tailscale cluster ingress: https://tailscale.com/docs/features/kubernetes-operator/guides/cluster-ingress
- Tailscale subnet router Connector: https://tailscale.com/docs/features/kubernetes-operator/guides/connector
- Existing storage migration inventory: `docs/runbooks/storage-inventory.md`
- Existing Tailscale runbook: `docs/runbooks/tailscale.md`

## Files To Change

- `kubernetes/infrastructure/controllers/tailscale-operator/homelab-subnet-router.yaml`
- `kubernetes/infrastructure/controllers/tailscale-operator/kustomization.yaml`
- `kubernetes/infrastructure/controllers/tailscale-operator/proxygroup.yaml`
- `kubernetes/auth/oauth2-proxy-kenway-arr/*.yaml`
- `kubernetes/apps/trilium/pvc.yaml`
- `kubernetes/apps/trilium/deployment.yaml`
- `kubernetes/apps/hermes/pvc.yaml`
- `kubernetes/apps/hermes/deployment.yaml`
- `kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-alerts.yaml`
- `docs/runbooks/tailscale.md`
- `docs/runbooks/storage-inventory.md`
- Optional follow-up: `terraform/proxmox/lugia.tf`

## Task 1: Capture the Incident and Add Host-Level Alerts

- [x] Add an incident note to `docs/runbooks/storage-inventory.md` or a new short runbook section documenting the exact OOM cause, timestamps, and commands used:
  - `journalctl --unit 143.scope --since "2026-05-29 00:00:00" --until "2026-05-31 16:00:00"`
  - `journalctl --since "2026-05-29 23:35:00" --until "2026-05-29 23:50:00" | grep -E "oom|Out of memory|143.scope|Killed process|ceph"`
  - `qm config 143`
- [x] Extend `kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-alerts.yaml` with a critical alert for expected Proxmox guests down that explicitly includes VM `143` and pages fast.
- [x] Add a warning/critical memory-pressure alert for Proxmox nodes using available exporter metrics. Prefer exporter metrics already present in Prometheus; validate metric names before committing.
- [x] Verify alerts with `kubectl --kubeconfig talos/kubeconfig apply --dry-run=server -f kubernetes/infrastructure/observability/kube-prometheus-stack/homelab-alerts.yaml`.

## Task 2: Make Tailscale Routing Highly Available

- [x] Add `kubernetes/infrastructure/controllers/tailscale-operator/proxygroup.yaml`:

  ```yaml
  apiVersion: tailscale.com/v1alpha1
  kind: ProxyGroup
  metadata:
    name: homelab-shared-ingress
  spec:
    type: ingress
    replicas: 2
  ```

- [x] Add `proxygroup.yaml` to `kubernetes/infrastructure/controllers/tailscale-operator/kustomization.yaml`.
- [x] Update each `kubernetes/auth/oauth2-proxy-kenway-arr/*.yaml` Tailscale `Ingress` annotation block to include:

  ```yaml
  tailscale.com/proxy-group: homelab-shared-ingress
  ```

- [x] Change `kubernetes/infrastructure/controllers/tailscale-operator/homelab-subnet-router.yaml` from `replicas: 1` to `replicas: 2`.
- [ ] Reconcile and validate:
  - `kubectl --kubeconfig talos/kubeconfig apply --dry-run=server -k kubernetes/infrastructure/controllers/tailscale-operator`
  - `flux --kubeconfig talos/kubeconfig reconcile kustomization infrastructure --with-source`
  - `kubectl --kubeconfig talos/kubeconfig get proxygroup,connector -A`
  - `kubectl --kubeconfig talos/kubeconfig get pods -n tailscale -o wide`
- [ ] Confirm the two subnet router devices advertise the same routes and are approved in Tailscale. Auto-approval should cover this via `tag:homelab-admin-router`, but verify in the admin console after reconciliation.
- [ ] Perform a routing failover drill:
  - `kubectl --kubeconfig talos/kubeconfig cordon lugia`
  - delete one generated Tailscale subnet router pod and one shared ingress proxy pod
  - verify replacements run on `ho-oh` or another healthy non-`lugia` node
  - verify admin subnet access and all Kenway shared URLs still work
  - `kubectl --kubeconfig talos/kubeconfig uncordon lugia`

## Task 3: Move Notes Workloads Off Local-Path

- [x] Add new Ceph RBD PVCs without mutating existing bound PVCs:
  - `apps/trilium-data-ceph`, 10 Gi, `ceph-rbd`, RWO
  - `apps/hermes-data-ceph`, 10 Gi, `ceph-rbd`, RWO
  - `apps/hermes-workspace-ceph`, 20 Gi, `ceph-rbd`, RWO
- [x] Confirm fresh PVCs bind:
  - `kubectl --kubeconfig talos/kubeconfig -n apps get pvc trilium-data-ceph hermes-data-ceph hermes-workspace-ceph -o wide`
- [x] Schedule a short write freeze:
  - `kubectl --kubeconfig talos/kubeconfig -n apps scale deploy/trilium deploy/hermes --replicas=0`
  - wait until both pods are gone.
- [x] Run one-off copy jobs that mount old and new PVCs in the same pod and preserve ownership/permissions with tar or rsync:
  - `trilium-data` to `trilium-data-ceph`
  - `hermes-data` to `hermes-data-ceph`
  - `hermes-workspace` to `hermes-workspace-ceph`
- [x] Compare source and destination sizes/file counts from inside the copy jobs before switching deployments.
- [x] Update deployment claim names:
  - `trilium-data` mount uses `trilium-data-ceph`
  - `hermes-data` mount uses `hermes-data-ceph`
  - `hermes-workspace` mount uses `hermes-workspace-ceph`
- [x] Reconcile, start workloads, and validate:
  - `kubectl --kubeconfig talos/kubeconfig -n apps rollout status deploy/trilium`
  - `kubectl --kubeconfig talos/kubeconfig -n apps rollout status deploy/hermes`
  - notes endpoint loads and recent notes are present
  - Hermes can read/write the Obsidian vault and workspace.
- [x] Keep the old local-path PVCs retained until at least one successful backup and one failover drill have completed.

## Task 4: Make New Critical State Avoid Local-Path by Default

- [x] Inventory remaining `local-path` PVCs and rank them by outage impact:
  - routing/auth/DNS: AdGuard config/work, OAuth2 state if any, external DNS dependencies
  - personal core apps: Trilium, Hermes, Obsidian support state, Uptime Kuma
  - app databases and media support state: Immich Postgres, Paperless, Open WebUI, RustFS, RomM support volumes
  - observability state: Prometheus and Loki
- [ ] Move only high-impact app-private RWO data to `ceph-rbd` in small batches using the same freeze-copy-switch pattern.
- [ ] After the critical PVCs are migrated, remove the default annotation from `local-path` and decide whether `ceph-rbd` should become the default class.
- [ ] Update `docs/runbooks/storage-inventory.md` after each migration with source PVC, target storage class, validation result, and rollback note.

## Task 5: Reduce Latios OOM Risk

- [ ] Review Proxmox memory headroom on `latios` after the routing and notes migrations.
- [ ] Consider reducing `lugia` memory in `terraform/proxmox/lugia.tf` from 40960 MiB to 32768 MiB, but only after confirming workloads no longer need the full 40 GiB.
- [ ] Avoid running exploratory `ceph ... --help` commands during memory pressure until the cause of the 2026-05-29 Ceph command RSS spike is understood.
- [ ] Add a short Proxmox/Ceph operations note: when provisioning Ceph from Ansible, watch `free -h`, `ps aux --sort=-rss`, and Proxmox node memory alerts.

## Task 6: Prove Lugia-Loss Recovery

- [ ] Before the drill, confirm backups for notes/Hermes are current or manually snapshot/export the important data.
- [ ] Cordon `lugia`:
  - `kubectl --kubeconfig talos/kubeconfig cordon lugia`
- [ ] Restart critical workloads or delete their pods one at a time:
  - Tailscale subnet router generated pod
  - Tailscale shared ingress generated pods
  - `apps/trilium`
  - `apps/hermes`
- [ ] Validate each workload remains reachable or recovers on `ho-oh`:
  - admin Tailscale subnet access
  - Kenway shared Arr URLs
  - notes UI
  - Hermes notes workflow
- [ ] Uncordon `lugia`:
  - `kubectl --kubeconfig talos/kubeconfig uncordon lugia`
- [ ] Record the drill result in `docs/runbooks/tailscale.md` and `docs/runbooks/storage-inventory.md`.

## Rollback

- Tailscale HA rollback: remove the proxy group annotation from Kenway ingress resources, reduce the subnet router `replicas` back to `1`, remove `proxygroup.yaml` from the kustomization, and reconcile.
- Notes rollback: scale the deployment down, switch the deployment claim names back to the old local-path PVCs, reconcile, then scale back up.
- Alert rollback: remove newly added Prometheus rules and reconcile observability.
- Do not delete old local-path PVCs until the new Ceph-backed workloads have survived at least one backup and one failover drill.

## Success Criteria

- Losing or cordoning `lugia` no longer removes Tailscale subnet routing.
- Kenway shared Tailscale ingress remains available while a generated proxy pod is deleted or rescheduled away from `lugia`.
- Trilium and Hermes can start on `ho-oh` with their persistent state intact.
- Proxmox VM `143` down and Proxmox host memory pressure generate actionable alerts.
- `local-path` is no longer the default target for new critical app state.
