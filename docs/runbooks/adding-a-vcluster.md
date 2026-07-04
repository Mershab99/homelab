# Adding a vCluster (new workload)

Use when you want a new logically-isolated API surface for a workload
(home-assistant, mershab.com website are existing examples). vClusters run on
the **arrakis** tenant via **k3k in shared mode** (workloads reflected onto
arrakis nodes; host Cilium CNI; NetworkPolicy isolation).

## Steps

1. **Add a k3k `Cluster` CR** at
   `platform/sveltos/manifests/k3k-clusters/<name>.yaml` (model on `mershab.yaml`
   — a `Namespace` + a `Cluster` with `mode: shared`, `nodeSelector`
   `node.mershab.com/pool: general`, OIDC `serverArgs`). It is delivered to
   arrakis by the existing `12-k3k-clusters` ClusterProfile (no new profile
   needed — it applies the whole `k3k-clusters/` dir).

2. **App manifests** go under `tenants/arrakis/vclusters/<name>/apps/<app>/`
   (deployments, services, NADs, etc.) — plain native YAML.

3. **App ClusterProfile** at
   `platform/sveltos/clusterprofiles/13-app-<name>.yaml` (model on
   `13-app-mershab-web.yaml`): `clusterRefs` the `<name>` SveltosCluster in ns
   `vclusters`, `dependsOn: vcluster-baseline`, deliver `apps/<app>/` via a
   GitRepository policyRef. Add it to `clusterprofiles/kustomization.yaml`.

4. **`OAuth2Client`** if the workload has a gated UI: add a CR under
   `clusters/baremetal/identity/oauth2clients/<name>.yaml`.

5. **Push.** Flux reconciles → `12-k3k-clusters` creates the k3k `Cluster` on
   arrakis.

6. **Register the vCluster** with the hub Sveltos (the one runtime step) — see
   [registering-a-k3k-vcluster.md](registering-a-k3k-vcluster.md). Once the
   `SveltosCluster` is Ready, `12-vcluster-baseline` + `11-oidc-rbac` + your
   `13-app-<name>` profile fan in.

## Verify

```bash
# k3k Cluster is Ready on arrakis
kubectl --context arrakis get clusters.k3k.io -n k3k-<name> <name>

# vCluster registered with the hub
kubectl --context mgmt get sveltoscluster -n vclusters <name> -o yaml | yq .status

# Workload running inside (pods reflected onto arrakis general pool)
kubectl --kubeconfig=<name>.kubeconfig get all -A
```
