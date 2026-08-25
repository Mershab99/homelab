# Migrating Longhorn → ZFS + LocalPV-ZFS (one-time, 2026-08)

> **Status 2026-08-25: NOT YET RUN.** The hub still runs Longhorn (15 SSDs
> carrying `u-lh01`..`u-lh15` xfs partitions, `driver.longhorn.io` CSI, 3 bound
> PVs) on a Talos image whose extensions are intel-ucode + iscsi-tools +
> util-linux-tools — no `zfs`. Everything below is still the plan, not history.
> Note the delivery seam: the cluster's Flux GitRepository tracks
> `github.com/mershab99/homelab` `main`, which is still pre-pivot — "push the
> storage commit" in step 1 means pushing to **that** remote (or re-pointing
> the GitRepository), not just to the local/Gitea main.

In-place swap on the live single-node hub. **All Longhorn data is destroyed** —
everything is reproducible from git + `secrets/apply.sh`. Optional first:
export the vaultwarden vault and photoprism originals (both were `retain: true`).

The git side (schematic, machine config, ClusterProfiles, StorageClasses,
consumers) is already committed. This runbook is the hand-run part —
`talosctl` is never automated in this repo.

## 0. Prereqs

```bash
# RAM → pick the ARC cap (20-25% of total), then replace
# zfs.zfs_arc_max=TODO_20_PERCENT_OF_RAM_IN_BYTES in bootstrap/talos/controlplane.yaml
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 memory

# Disk inventory — confirm 15x "Samsung SSD 850" + the WDC boot disk; note dev names
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 get disks
```

Create the Backblaze B2 bucket + application key now (Velero needs it in step 6).

## 1. Tear down Longhorn (DATA LOSS POINT)

Push the storage commit (it removes the Longhorn chart from `04-storage.yaml`) —
Sveltos uninstalls Longhorn. Then clear the corpses:

```bash
# delete PVCs/PVs still referencing longhorn; then, if longhorn-system sticks
# in Terminating, use the finalizer recipe in the power-cycle-recovery skill
kubectl get pvc -A | grep longhorn
kubectl get ns longhorn-system
```

Arrakis tenant apps go down here; they come back in step 5.

## 2. Talos upgrade (zfs extension + config, one reboot)

The new schematic ID is already in `bootstrap/talos/r730-schematic.yaml` and
`controlplane.yaml` (`c86a996e…30eea:v1.13.5`). Make sure the ARC arg is filled
(step 0), then:

```bash
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  apply-config --mode staged --file bootstrap/talos/controlplane.yaml
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  upgrade --image factory.talos.dev/metal-installer/c86a996e871ad7d755f8f99109cbb0fda2b2903ba4c1b76668b257e9a2030eea:v1.13.5

# after reboot:
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 get extensions | grep zfs
```

## 3. Wipe the 15 data disks

UserVolumeConfigs are gone from the applied config, so Talos has released the
`u-lhNN` partitions; the disks still carry stale xfs labels until wiped:

```bash
# for each Samsung disk from `get disks` (sdX names — verify against model
# column each time; megaraid enumeration shuffles):
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  wipe disk sdb sdc sdd ...   # 15 Samsung disks, NOT the WDC boot disk
```

## 4. Create the pool

```bash
./bootstrap/zfs/create-pool.sh   # prompts before writing; 7 mirrors + 1 spare
```

Reboot once (`talosctl -e 192.168.2.70 -n 192.168.2.70 reboot`) and re-run the
script — it must print "already exists" (auto-import works). Do not proceed
until it does.

## 5. Let Sveltos converge

The same pushed commit carries zfs-localpv + snapshot-controller +
StorageClasses and the re-pointed consumers. Verify:

```bash
kubectl -n openebs get pods                     # zfs-localpv controller + node plugin Running
kubectl get sc                                  # fast-zfs (default), fast-block, db-zfs
kubectl -n tenants get pvc                      # kmc-arrakis-etcd on db-zfs, Bound
kubectl get cluster -n tenants                  # arrakis re-provisions
```

Smoke test: one PVC per class + a VolumeSnapshot round-trip.

## 6. Velero (BEFORE real data accumulates)

1. Fill `secrets/infrastructure/velero/velero-b2.secret.yaml`, uncomment it in
   `secrets/kustomization.yaml`, `./secrets/apply.sh`.
2. Replace the B2 bucket/region placeholders in
   `platform/sveltos/clusterprofiles/04b-backup.yaml`, uncomment it in the
   clusterprofiles `kustomization.yaml`, push.
3. `task backup:trigger SCHEDULE=velero-daily` (the chart's `daily` schedule),
   then restore into a scratch namespace (`task backup:restore FROM=<backup>`).
   Confirm the created name with `task backup:list`. An untested
   restore path is a hypothesis.

## Standing rules after migration

- **Before every Talos upgrade**: re-POST `r730-schematic.yaml` for the target
  version and confirm the zfs extension exists for it. A mismatch leaves the
  pool unimportable.
- Monthly: `zpool scrub tank` (via a privileged pod, same as create-pool.sh)
  and check `zpool status` — until observability is re-enabled, this is manual.
- Capacity: keep the pool under 80% (~11TB). COW fragments badly past that.
- Quarterly: restore a real PVC into a scratch namespace.
