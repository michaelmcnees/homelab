# Homelab Redesign — Implementation Roadmap

> **Spec:** `docs/superpowers/specs/2026-03-11-homelab-redesign-design.md`

## Phase Overview

Each phase has its own plan document, builds on the previous phase, and produces working infrastructure at every stage. The existing homelab continues running throughout — nothing gets torn down until its replacement is verified.

| Phase | Plan | What it delivers | Depends on |
|-------|------|-----------------|------------|
| **1: Foundation** | `2026-03-11-phase1-foundation.md` | Repo structure, OpenTofu VMs, Ansible K3s cluster, Flux bootstrap, SOPS secrets | Nothing (greenfield) |
| **2: Core Platform** | `2026-03-11-phase2-core-platform.md` | Traefik, cert-manager, MetalLB, ExternalDNS, democratic-csi, databases, auth chain | Phase 1 |
| **3: Service Migrations** | `2026-03-11-phase3-service-migrations.md` | Migrate all services from LXCs to K8s, virtualize TrueNAS on snorlax, set up pikachu LXCs + Pelican VM | Phase 2 |
| **4: Polish** | `2026-03-11-phase4-polish.md` | Observability stack, Unifi as Code, dev lab, VLAN segmentation, documentation/runbooks | Phase 3 |

## Execution Order

```
Phase 1: Foundation (can start immediately, no disruption to existing setup)
    │
    ▼
Phase 2: Core Platform (cluster is running, deploy platform services)
    │
    ▼
Phase 3: Service Migrations (move services one-by-one, decommission old LXCs)
    │
    ▼
Phase 4: Polish (observability, networking refinements, documentation)
```

## Key Principle

At every phase boundary, the homelab is fully functional. No phase leaves things in a broken state. Services are migrated individually — if a migration fails, the old LXC is still running.
