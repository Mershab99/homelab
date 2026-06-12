# family vCluster

A vCluster hosting family-facing apps (Home Assistant today; more later —
Vaultwarden, photo gallery, etc.). One vCluster, many apps in separate
namespaces inside it.

## Layout

```
tenants/home/vclusters/family/
├── README.md
├── vcluster-values.yaml          # canonical vCluster Helm values (kept in sync
│                                 #   with the install ClusterProfile)
└── apps/                         # apps that run INSIDE the family vCluster
    └── home-assistant/
        └── lan-nad.yaml          # NAD copy in the home-assistant ns
                                  # (the Helm chart handles namespace + everything else)
```

## ClusterProfiles

- `platform/sveltos/clusterprofiles/12-vcluster-family.yaml` — installs the
  vCluster on the tenant.
- `platform/sveltos/clusterprofiles/13-app-home-assistant.yaml` — Home
  Assistant Helm release + NAD, delivered INTO the family vCluster.

Adding a new family app: write a `platform/sveltos/clusterprofiles/13-app-<name>.yaml`
that uses `clusterRefs` to target the family SveltosCluster + `helmCharts`
to install the app. Optionally drop a `tenants/home/vclusters/family/apps/<name>/`
subdir for any extra YAML the chart doesn't handle.
