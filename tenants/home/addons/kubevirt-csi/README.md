# kubevirt-csi — vendored manifest

KubeVirt CSI doesn't ship a Helm chart. The `tenant-baseline`
ClusterProfile reads from this directory via GitRepository policyRef and
applies the manifests to the tenant cluster.

## One-time vendoring (populate the placeholder)

`kubevirt-csi.yaml` ships as a placeholder. Replace with the upstream
tenant-side controller manifest at a pinned tag:

```bash
cd tenants/home/addons/kubevirt-csi

curl -fL https://raw.githubusercontent.com/kubevirt/csi-driver/v0.6.0/deploy/controller-tenant.yaml \
  -o kubevirt-csi.yaml
```

Then `git add` + commit. Sveltos's `tenant-baseline` ClusterProfile picks
it up on the next reconcile.

## Upgrade procedure

Same `curl` at a newer tag, re-commit.

## What it does

- Installs the kubevirt-csi-node DaemonSet on every tenant worker
- The CSI talks back to KubeVirt on the bare-metal (infra) cluster to
  attach/detach KubeVirt DataVolumes to the worker VMs
- Tenant PVCs that request the `kubevirt` storageClass route through this
  CSI to a backing Longhorn PVC on the bare-metal (infra) cluster

## StorageClass

`storageclass.yaml` (already committed) defines a `kubevirt` StorageClass
on the tenant pointing at the bare-metal `longhorn` StorageClass.
