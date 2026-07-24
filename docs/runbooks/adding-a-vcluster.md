# Adding a vCluster (AI/MCP isolation only)

**First: do you actually need a vCluster?** The default home for a workload is a
**flat namespace on arrakis**, not a vCluster. vClusters are reserved for the
**AI/MCP layer** — throwaway, RBAC-isolated groups of kagent Agents / KMCP MCP
servers that want a hard blast-radius boundary. The `ai` vCluster is the first
and (today) only one.

- **Normal app** (public or private) → flat namespace. Add
  `tenants/arrakis/apps/<app>/` manifests + a tenant-selector ClusterProfile
  (model on `13-app-web.yaml` for public, `13-app-home-assistant.yaml` for a
  private/NetBird app). No vCluster involved.
- **A new AI/MCP group** that must be isolated from the `ai` vCluster → a new
  vCluster, per the steps below. (Start by just adding CRs to `ai`; split only
  when a real trust boundary appears.)

vClusters run on **arrakis** via **k3k in shared mode** (workloads reflected onto
arrakis nodes; host Cilium CNI; NetworkPolicy isolation).

## Steps

1. **Add a k3k `Cluster` CR** at
   `platform/sveltos/manifests/k3k-clusters/<name>.yaml` (model on `ai.yaml` — a
   `Namespace` + a `Cluster` with `mode: shared`, `nodeSelector`
   `node.mershab.com/pool: general`, OIDC `serverArgs`). Delivered to arrakis by
   the existing `12-k3k-clusters` ClusterProfile (it applies the whole
   `k3k-clusters/` dir — no new profile needed for the CR itself).

2. **Helpers ClusterProfile** at
   `platform/sveltos/clusterprofiles/<NN>-<name>.yaml` (model on
   `16-ai-helpers.yaml`): `clusterRefs` the `<name>` SveltosCluster in ns
   `vclusters`, install the controllers/charts, deliver any samples via a
   GitRepository policyRef. Add it to `clusterprofiles/kustomization.yaml`.

3. **Push.** Flux reconciles → `12-k3k-clusters` creates the k3k `Cluster` on
   arrakis.

4. **Register the vCluster** with the hub Sveltos (the one runtime step — k3k
   can't self-register) — see
   [registering-a-k3k-vcluster.md](registering-a-k3k-vcluster.md). Once the
   `SveltosCluster` is Ready, `12-vcluster-baseline` + `11-oidc-rbac` + your
   helpers profile fan in.

5. **Expose privately** if the vCluster's Services need reaching from outside:
   a NetBird `NetworkResource` (see `platform/sveltos/manifests/netbird/README.md`).
   No public Gateway route for AI/MCP internals.

## Verify

```bash
# k3k Cluster is Ready on arrakis
kubectl --context admin@arrakis get clusters.k3k.io -n k3k-<name> <name>

# vCluster registered with the hub
kubectl --context admin@contraxia get sveltoscluster -n vclusters <name> -o yaml | yq .status

# Controllers running inside (pods reflected onto arrakis general pool)
kubectl --kubeconfig=<name>.kubeconfig get all -A
```
