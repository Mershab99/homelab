# Disaster recovery

The bare-metal cluster is **not** disposable — losing its etcd loses every
tenant Cluster CR, every Sveltos profile binding, every Flux source, every
sealed-secret encryption key (unless backed up separately).

## Backups (running)

- **etcd snapshot CronJob** on the bare-metal cluster runs
  `talosctl etcd snapshot` daily, writes to a Ceph RBD PVC, then
  `rclone copy` to an off-box destination (configured in
  `clusters/baremetal/infrastructure/etcd-backup/`).
- **Sealed-secrets controller key** is exported nightly and stored alongside
  the etcd snapshot. Without it, restoring Git is useless — the cluster
  cannot decrypt any sealed secret.
- **Kamaji tenant etcd snapshots** (each tenant has its own etcd, run by
  Kamaji as a StatefulSet on `ceph-block-rbd`). Snapshots taken by Kamaji's
  built-in snapshot job into the same Ceph pool, and shipped off-box.

## Restore order

1. **Rebuild the bare-metal Talos node from ISO.** Apply the same
   machineconfig from Git (`bootstrap/talos/r730.yaml`).
2. **Recover etcd** from the latest snapshot:
   ```bash
   talosctl --nodes <node-ip> bootstrap --recover-from=<snapshot.db>
   ```
3. **Wait for kube-apiserver up.** Flux Operator (if previously installed by
   Helm) auto-restarts and reconciles its `FluxInstance`. If the Helm release
   itself is lost, re-run `bootstrap/helm/02-flux-operator.sh`.
4. **Restore sealed-secrets controller key** from off-box:
   ```bash
   kubectl -n sealed-secrets apply -f sealed-secrets-key-backup.yaml
   kubectl -n sealed-secrets rollout restart deployment sealed-secrets-controller
   ```
5. **Reconcile Flux** — Flux re-pulls Git, re-applies everything, every Helm
   release re-installs, every CR re-creates.
6. **Verify Rook/Ceph health.** Ceph survives the host rebuild because OSDs
   were on data disks Talos doesn't touch. `ceph status` should be HEALTH_OK
   once the mons rejoin.
7. **Tenant CP comes back.** Kamaji recreates the StatefulSet from the
   `KamajiControlPlane` CR; etcd PVCs reattach with prior state.
8. **Tenant cluster reconciles.** CAPI sees existing KubeVirt VMs (Ceph PVCs
   intact); they boot, `kubeadm join`-ed nodes show up.
9. **vClusters come back** when the tenant cluster's HelmReleases reconcile.
   Bundled `sveltos-applier` reconnects to the bare-metal Sveltos controller;
   profiles re-fire.

## Dry-run

Do this once per quarter:

1. Snapshot the bare-metal etcd via the CronJob trigger.
2. Spin a parallel VM, install Talos with the same machineconfig.
3. Restore the snapshot. Confirm `clusterctl describe cluster home -n tenants`
   reports the tenant cluster.
4. Tear down the parallel VM.

## Known caveat: K80 driver

The K80 needs `nvidia-driver-470` (CUDA 11.4 ceiling). If Ubuntu LTS in the
KubeadmConfigTemplate is bumped past Jammy, the apt package may disappear and
the GPU pool won't come up. If this hits, pin the Ubuntu image AMI/version in
the KubeVirt DataVolume template until a driver upgrade path exists.
