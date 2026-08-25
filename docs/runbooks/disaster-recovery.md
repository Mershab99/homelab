# Disaster recovery

The bare-metal cluster is **not** disposable — losing its etcd loses every
tenant Cluster CR, every Sveltos profile binding, and every Flux source.
Cluster secrets are plaintext + gitignored (`*.secret.yaml`) — keep your filled
copies off-box; they are re-applied by hand on restore (see `secrets/README.md`).

## Backups (running)

- **etcd snapshot CronJob** on the bare-metal cluster runs
  `talosctl etcd snapshot` daily, writes to a `fast-zfs` PVC, then
  `rclone copy` to an off-box destination (configured in
  `clusters/baremetal/infrastructure/etcd-backup/`).
- **Filled secrets** (`secrets/**/*.secret.yaml`) are gitignored, so they are
  NOT in Git — keep a copy off-box alongside the etcd snapshot. Without them the
  charts that consume cloudflare/dex/oidc/minio Secrets won't come up.
- **Tenant etcd snapshots** (each tenant has its own etcd, run by the hosted
  control plane as a StatefulSet on `db-zfs` — 16k recordsize, see
  `tenants/arrakis/infra/cluster.yaml`). Snapshots land on a `fast-zfs` PVC and
  are shipped off-box.
- **PVC data**: Velero → Backblaze B2 with the CSI plugin (ZFS snapshots via
  `zfs-snapclass`). `platform/sveltos/clusterprofiles/04b-backup.yaml` is still
  commented out in the clusterprofiles `kustomization.yaml` — until it is
  enabled, PVC contents have **no off-box copy**.

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
   because Talos installs to the boot disk selected by MODEL (`WDC*`, the 500GB
   WD Blue) — never by `/dev/sdX`, which megaraid_sas reshuffles across boots —
   so the 15 `Samsung SSD 850` pool disks are untouched. The zfs extension
   auto-imports `tank` on boot; re-run `./bootstrap/zfs/create-pool.sh` to
   check: it imports and prints `already exists` + `zpool status` when the pool
   is there, and only prompts to create when it genuinely is not. Never run a
   bare `zpool create` against populated disks.
7. **Tenant CP comes back.** Kamaji recreates the StatefulSet from the
   `KamajiControlPlane` CR; etcd PVCs reattach with prior state.
8. **Tenant cluster reconciles.** CAPI sees existing KubeVirt VMs (`fast-block`
   PVCs — zvol+ext4 — intact); they boot, joined nodes show up.
9. **vClusters come back** when Sveltos re-installs each `12-vcluster-*`
   helm release on the tenant. Registration is hands-free: the exported
   kubeconfig Secret re-appears and the hub EventTrigger re-creates the
   SveltosCluster (`docs/runbooks/registering-a-vcluster.md`); profiles
   re-fire.

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
