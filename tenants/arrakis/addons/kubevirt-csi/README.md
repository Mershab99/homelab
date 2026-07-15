# kubevirt-csi — vendored manifest

KubeVirt CSI doesn't ship a Helm chart. The `tenant-baseline`
ClusterProfile reads from this directory via GitRepository policyRef and
applies the manifests to the tenant cluster.

## Files here

- `kubevirt-csi.yaml` — controller + node + RBAC + CSIDriver, vendored from
  `kubevirt/csi-driver` `deploy/{controller-tenant,tenant}/base` at a pinned
  commit (upstream has no release tags / helm chart). The header records the SHA.
- `driver-config.yaml` — the `kubevirt-csi-driver` Namespace + `driver-config`
  ConfigMap (all 3 keys; infraClusterNamespace=`tenants`).
- `storageclass.yaml` — the `kubevirt` StorageClass → bare-metal `longhorn`.

## Required out-of-band Secret

The controller needs a kubeconfig to the mgmt (infra) cluster, applied **to the
tenant**: `secrets/infrastructure/kubevirt-csi/infra-cluster-credentials.example.yaml`
→ `.secret.yaml`, applied with `KUBECONFIG` pointed at arrakis (not mgmt, so
`./secrets/apply.sh` does not cover it).

## Upgrade procedure

Re-vendor from a newer commit:
```bash
SHA=<new-commit>
yq eval-all 'select(.kind != "StorageClass" and .kind != "ConfigMap")' \
  <(curl -fsSL "https://raw.githubusercontent.com/kubevirt/csi-driver/$SHA/deploy/controller-tenant/base/deploy.yaml") \
  <(curl -fsSL "https://raw.githubusercontent.com/kubevirt/csi-driver/$SHA/deploy/tenant/base/deploy.yaml") \
  > /tmp/csi.yaml   # then re-add the header + commit
```

## What it does

- Installs the kubevirt-csi-node DaemonSet on every tenant worker
- The CSI talks back to KubeVirt on the bare-metal (infra) cluster to
  attach/detach KubeVirt DataVolumes to the worker VMs
- Tenant PVCs that request the `kubevirt` storageClass route through this
  CSI to a backing Longhorn PVC on the bare-metal (infra) cluster

## StorageClass

`storageclass.yaml` (already committed) defines a `kubevirt` StorageClass
on the tenant pointing at the bare-metal `longhorn` StorageClass.
