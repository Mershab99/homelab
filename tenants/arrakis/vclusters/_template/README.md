# vCluster template (Loft vcluster OSS — AI/MCP only)

vClusters are **reserved for the AI/MCP layer** (kagent + KMCP groups that want a
hard blast-radius boundary). Normal workloads live in **flat namespaces** on
arrakis (`tenants/arrakis/apps/<app>/` + a tenant-selector ClusterProfile) — NOT
vClusters. The `ai` vCluster is the running example. cert-manager is shared
from the host (certManager integration); kagent/kmcp install INSIDE each
vcluster via `16-ai-helpers` (generic CR sync toHost = vCluster PRO, so host
operators can't serve in-vcluster CRs).

To add a NEW AI/MCP vCluster (only when a group needs isolating from `ai`):

1. Copy `platform/sveltos/clusterprofiles/12-vcluster-ai.yaml` to
   `12-vcluster-<name>.yaml` (new release ns, Ingress host, and export secret
   `<name>-export-kubeconfig`), list it in `clusterprofiles/kustomization.yaml`.
2. Push — the vcluster self-registers via the exported kubeconfig + hub
   EventTrigger, see
   [docs/runbooks/registering-an-ai-vcluster.md](../../../../docs/runbooks/registering-an-ai-vcluster.md).

Full workflow: [docs/runbooks/adding-a-vcluster.md](../../../../docs/runbooks/adding-a-vcluster.md).

## Per-vCluster SveltosCluster label

Set by the auto-registration template — ONE label drives every
cross-cluster ClusterProfile selector:

| Label | Value |
|---|---|
| `persona` | `ai` — the AI/MCP vCluster persona (kagent/KMCP + OIDC-to-Dex). All vClusters use this. |
