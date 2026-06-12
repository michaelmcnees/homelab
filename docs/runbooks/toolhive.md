# ToolHive

ToolHive is deployed as a Kubernetes operator in the `toolhive-system`
namespace. This initial install is a pilot for central MCP management and does
not expose any MCP gateway routes yet.

## Components

- Helm chart source: `kubernetes/repositories/toolhive.yaml`
- CRD release: `kubernetes/infrastructure/controllers/toolhive/helmrelease-crds.yaml`
- Operator release: `kubernetes/infrastructure/controllers/toolhive/helmrelease.yaml`
- Namespace: `toolhive-system`
- Version: `0.29.3`

The operator is configured with namespace-scoped RBAC for `toolhive-system`
only. Keep backend MCP resources and virtual MCP gateways in that namespace
unless the operator RBAC scope is intentionally expanded.

## Operations

Check Flux and Helm status:

```sh
flux --kubeconfig talos/kubeconfig get helmrelease -n toolhive-system
kubectl --kubeconfig talos/kubeconfig -n toolhive-system get pods
```

Check installed ToolHive API resources:

```sh
kubectl --kubeconfig talos/kubeconfig api-resources --api-group=toolhive.stacklok.dev
```

Check operator logs:

```sh
kubectl --kubeconfig talos/kubeconfig -n toolhive-system logs deploy/toolhive-operator
```

## Next Pilot Step

After the operator is healthy, create an `MCPGroup`, add Outline and Penpot as
remote backend entries, then front them with a `VirtualMCPServer`. Start with an
internal-only endpoint before exposing a home-network hostname.

## Hermes Direction

ToolHive is useful for centralizing MCP access for Hermes, Codex, Claude, and
other clients, but it is not the first fix for Hermes Gmail access. Hermes'
current mail setup has two separate paths:

- Himalaya uses Gmail IMAP with an app password.
- Hermes MCP can use Google's first-party Gmail Workspace MCP endpoint with
  OAuth.

Pilot Gmail directly in Hermes first. Once the Google MCP flow is proven and
tokens are stable, move Gmail and other backends behind a ToolHive
`VirtualMCPServer` if we want one governed endpoint, centralized incoming auth,
or tool filtering. That avoids debugging Google OAuth and ToolHive gateway
behavior at the same time.
