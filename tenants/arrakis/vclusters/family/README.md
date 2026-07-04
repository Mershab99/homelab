# family vCluster

A vCluster hosting family-facing apps (Home Assistant today; more later —
Vaultwarden, photo gallery, etc.). One vCluster, many apps in separate
namespaces inside it.

## Layout

```
tenants/arrakis/vclusters/family/
├── README.md
└── apps/                         # apps that run INSIDE the family vCluster
    └── home-assistant/
        └── lan-nad.yaml          # NAD copy in the home-assistant ns
                                  # (the Helm chart handles namespace + everything else)
```

The k3k `Cluster` CR for family lives at
`platform/sveltos/manifests/k3k-clusters/family.yaml` (shared mode).

## ClusterProfiles

- `platform/sveltos/clusterprofiles/12-k3k-clusters.yaml` — delivers the family
  (and mershab) k3k `Cluster` CRs onto the tenant.
- `platform/sveltos/clusterprofiles/13-app-home-assistant.yaml` — Home
  Assistant Helm release + NAD, delivered INTO the family vCluster (after it is
  registered — see docs/runbooks/registering-a-k3k-vcluster.md).

Adding a new family app: write a `platform/sveltos/clusterprofiles/13-app-<name>.yaml`
that uses `clusterRefs` to target the family SveltosCluster + `helmCharts`
to install the app. Optionally drop a `tenants/arrakis/vclusters/family/apps/<name>/`
subdir for any extra YAML the chart doesn't handle.
