# Disaster recovery

The bare-metal cluster is **not** disposable — losing its etcd loses every
tenant Cluster CR, every Sveltos profile binding, and every Flux source.
Cluster secrets are plaintext + gitignored (`*.secret.yaml`) — keep your filled
copies off-box; they are re-applied by hand on restore (see `secrets/README.md`).

## Backups (running)

- **etcd snapshot CronJob** on the bare-metal cluster runs
  `talosctl etcd snapshot` daily, writes to a `zfs` PVC, then
  `rclone copy` to an off-box destination (configured in
  `clusters/baremetal/infrastructure/etcd-backup/`).
- **Filled secrets** (`secrets/**/*.secret.yaml`) are gitignored, so they are
  NOT in Git — keep a copy off-box alongside the etcd snapshot. Without them the
  charts that consume cloudflare/dex/oidc/minio Secrets won't come up.
- **Kamaji tenant etcd snapshots** (each tenant has its own etcd, run by
  Kamaji as a StatefulSet on `zfs`). Snapshots taken by Kamaji's
  built-in snapshot job onto a `zfs` PVC, and shipped off-box.

## Restore order

1. **Rebuild the bare-metal Talos node from ISO.** Apply the same
   machineconfig from Git (`bootstrap/talos/r730.yaml`).
2. **Recover etcd** from the latest snapshot:
   ```bash
   talosctl --nodes <node-ip> bootstrap --recover-from=<snapshot.db>
   ```
3. **Wait for kube-apiserver up.** Re-run the helm bootstrap to restore the
   delivery layer (both idempotent): `bootstrap/helm/01-cilium.sh`, then
   `bootstrap/helm/02-flux.sh` (reinstalls Flux source + helm controllers,
   re-applies `bootstrap/flux/`, and helm-controller reinstalls Sveltos).
4. **Re-apply cluster secrets** from your off-box copies (drop the filled
   `*.secret.yaml` back into `secrets/`, then):
   ```bash
   ./secrets/apply.sh
   ```
5. **Re-apply the root ClusterProfile** —
   `kubectl apply -f clusters/baremetal/sveltos-root.yaml` (after re-labeling
   `mgmt`, see `docs/bootstrap.md` step 5). source-controller re-pulls Git,
   Sveltos re-applies every ClusterProfile, every Helm release re-installs,
   every CR re-creates.
6. **Verify the `tank` ZFS pool imported.** The pool survives the host rebuild
   because the data disks (sdc–sdq) are untouched — `install.wipe` only clears
   the boot disk `/dev/sdb`. The zfs extension auto-imports `tank` on boot;
   `task zfs:status` should show ONLINE. (If it didn't import, re-run the
   zpool-create Job — it's a no-op import when the pool already exists. Never
   re-run a bare `zpool create` against populated disks.)
7. **Tenant CP comes back.** Kamaji recreates the StatefulSet from the
   `KamajiControlPlane` CR; etcd PVCs reattach with prior state.
8. **Tenant cluster reconciles.** CAPI sees existing KubeVirt VMs (`zfs` PVCs
   intact); they boot, `kubeadm join`-ed nodes show up.
9. **vClusters come back** when the k3k operator reconciles their `Cluster`
   CRs on the tenant. Re-register each with the bare-metal Sveltos controller
   (kubeconfig Secret + SveltosCluster) per
   `docs/runbooks/registering-a-k3k-vcluster.md`; profiles re-fire.

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
