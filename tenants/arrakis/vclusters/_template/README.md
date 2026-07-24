# vCluster template (k3k shared mode — AI/MCP only)

vClusters are **reserved for the AI/MCP layer** (kagent + KMCP groups that want a
hard blast-radius boundary). Normal workloads live in **flat namespaces** on
arrakis (`tenants/arrakis/apps/<app>/` + a tenant-selector ClusterProfile) — NOT
vClusters. The `ai` vCluster is the running example.

To add a NEW AI/MCP vCluster (only when a group needs isolating from `ai`):

1. Add a k3k `Cluster` CR at
   `platform/sveltos/manifests/k3k-clusters/<name>.yaml` (model on `ai.yaml`).
   It is delivered to arrakis by the existing `12-k3k-clusters` ClusterProfile.
2. Add a helpers ClusterProfile `<NN>-<name>.yaml` (model on `16-ai-helpers.yaml`)
   and list it in `clusterprofiles/kustomization.yaml`.
3. Register the vCluster with the hub Sveltos — see
   [docs/runbooks/registering-a-k3k-vcluster.md](../../../../docs/runbooks/registering-a-k3k-vcluster.md).

Full workflow: [docs/runbooks/adding-a-vcluster.md](../../../../docs/runbooks/adding-a-vcluster.md).

## Per-vCluster SveltosCluster label

Set on the `SveltosCluster` created during registration — ONE label drives every
cross-cluster ClusterProfile selector:

| Label | Value |
|---|---|
| `persona` | `ai` — the AI/MCP vCluster persona (kagent/KMCP + OIDC-to-Dex). All vClusters use this. |
