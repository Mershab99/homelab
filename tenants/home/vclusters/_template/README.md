# vCluster template

Copy this directory for each new vCluster:

```bash
cp -r tenants/home/vclusters/_template tenants/home/vclusters/<name>
# Then in tenants/home/vclusters/<name>/:
#   - rename or hand-edit vcluster-values.yaml (releaseName, sveltosCluster.name)
#   - replace placeholder workload label
#   - add app manifests under apps/
```

After that, add a new ClusterProfile at
`platform/sveltos/clusterprofiles/12-vcluster-<name>.yaml` (model on
`12-vcluster-home-assistant.yaml`) that:

1. Installs the vCluster on the tenant cluster via Sveltos `helmCharts`
   (using the values file in this directory)
2. Reads `apps/` via GitRepository policyRef and delivers it INSIDE the
   resulting vCluster once it registers (after the bundled
   sveltos-applier connects to mgmt)

And add it to `platform/sveltos/clusterprofiles/kustomization.yaml`.

## Per-vCluster labels

`vcluster-values.yaml` sets labels on the vCluster's SveltosCluster
registration. These drive cross-cluster ClusterProfile selectors:

| Label | Set when |
|---|---|
| `sveltos.projectsveltos.io/type: vcluster` | always |
| `workload: <name>` | always — used by per-workload ClusterProfiles |
| `needs.lan: "true"` | the workload attaches to br-multus |
| `needs.gpu: "k80" \| "p2000"` | the workload wants a specific GPU |
| `oidc.enabled: "true"` | the workload's apiserver federates to Dex (default yes) |
