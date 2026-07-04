# vCluster template (k3k shared mode)

vClusters run on arrakis via **k3k** (shared mode). To add one:

1. Add a k3k `Cluster` CR at
   `platform/sveltos/manifests/k3k-clusters/<name>.yaml` (model on `mershab.yaml`).
   It is delivered to arrakis by the existing `12-k3k-clusters` ClusterProfile.
2. Put app manifests here: `tenants/arrakis/vclusters/<name>/apps/<app>/`.
3. Add an app ClusterProfile `13-app-<name>.yaml` (model on
   `13-app-mershab-web.yaml`) and list it in `clusterprofiles/kustomization.yaml`.
4. Register the vCluster with the hub Sveltos — see
   [docs/runbooks/registering-a-k3k-vcluster.md](../../../../docs/runbooks/registering-a-k3k-vcluster.md).

Full workflow: [docs/runbooks/adding-a-vcluster.md](../../../../docs/runbooks/adding-a-vcluster.md).

## Per-vCluster SveltosCluster labels

Set on the `SveltosCluster` created during registration — they drive
cross-cluster ClusterProfile selectors:

| Label | Set when |
|---|---|
| `sveltos.projectsveltos.io/type: vcluster` | always |
| `workload: <name>` | always — used by per-workload ClusterProfiles |
| `needs.lan: "true"` | the workload attaches to br-multus |
| `oidc.enabled: "true"` | the workload's apiserver federates to Dex (default yes) |
