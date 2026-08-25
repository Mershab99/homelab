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

## The path

There is **one** documented path, decided 2026-08-25:

> **Tear Longhorn down first (step 1), then upgrade straight to
> `c86a996e…2030eea:v1.13.5`.** One reboot. No transitional image.

The ordering is forced, not stylistic — see step 1. An escape hatch using a
transitional iscsi+zfs image exists and was deliberately **not** chosen; it is
recorded at the bottom of this file so nobody re-derives it, not as an option to
pick from here.

This cycle changes exactly two things: the extension set (`+zfs`,
`-iscsi-tools`) and the ZFS ARC cap. The IOMMU / `pcirebind` / vfio kernel args
were **stripped out of `controlplane.yaml` on purpose** so this reboot has one
subject. GPU passthrough is a separate later upgrade; the PCI BDF research for
it is preserved in the deferred-args comment block in
`bootstrap/talos/controlplane.yaml`.

## 0. Prereqs

> `bootstrap/talos/talosconfig` has an **empty `endpoints:` list**, so every
> `talosctl` call below must pass `-e 192.168.2.70` explicitly. Without `-e` you
> get `error constructing client: failed to determine endpoints`. This bites
> every single command in this runbook; the `$TC` shorthand in step 2 exists for
> exactly this reason.
>
> Exception: `talosctl validate` is a purely local subcommand and takes **no**
> `--talosconfig` / `-e` at all — passing them fails with `unknown flag`.

```bash
# RAM → ARC cap. DONE 2026-08-25: 96532 MB (~94.3 GiB) → 20 GiB ARC,
# zfs.zfs_arc_max=21474836480 is already set in bootstrap/talos/controlplane.yaml.
# Re-run only if DIMMs changed.
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 memory

# Disk inventory — confirm 15x "Samsung SSD 850" + the WDC boot disk; note dev names
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 get disks

# Config sanity (local only — no -e, no --talosconfig)
talosctl validate --config bootstrap/talos/controlplane.yaml --mode metal --strict
```

Baseline recorded 2026-08-25, re-verified against the live node the same day
(re-confirm before starting; drift is the enemy):

| Fact | Value |
|---|---|
| Talos | `v1.13.5` (latest 1.13 patch is `v1.13.9`) |
| Kubernetes | `v1.36.2`, node `r730` Ready, single control-plane |
| Kernel | `6.18.36-talos`, RAM 96532 MB |
| Running schematic | `36cd6536…b87c010` = intel-ucode 20260512 + **iscsi-tools v0.2.0** + util-linux-tools 2.41.4 — **no zfs** |
| `install.image` **on the node** | `…/29ffb20b…fc65fbbb:v1.13.5` (Longhorn-era, stale) |
| `install.image` **in this repo** | `…/c86a996e…2030eea:v1.13.5` (never applied) |
| Kernel cmdline | no `intel_iommu`, no `pcirebind`, no vfio args |

**Three different schematic IDs are in play** — that is the trap in this table,
not a typo. What is booted, what the node's own config says to install, and what
the repo says to install are three different images. The repo file has never
been applied: the live machine config is still the Longhorn-era one, carrying
the `/var/lib/longhorn` + `/var/mnt` rshared kubelet mounts, the
`node.longhorn.io/default-disks-config` annotation, and all 15
`UserVolumeConfig` documents.

Corollary on the cmdline row: `extraKernelArgs` take effect **only at
install/upgrade time**. The args that used to sit in `controlplane.yaml` had
never been installed, so any upgrade would have applied them for the first time
as a free rider on the storage change. They are now removed from the file, so
this cycle carries none.

Create the Backblaze B2 bucket + application key now (Velero needs it in step 6).

## 1. Tear down Longhorn (DATA LOSS POINT)

**Hard gate on step 2. Cannot be reordered.** The step-2 image (`c86a996e…`)
drops `iscsi-tools`, and Longhorn's v1 data engine needs `iscsiadm` from it. As
of 2026-08-25 Longhorn is still fully live on contraxia: `ext-iscsid` Running,
`longhorn` is the default StorageClass (alongside `longhorn-static`),
`longhorn-system` Active, and three volumes are attached + healthy:

| PVC | Size | Shows in `get disks` as |
|---|---|---|
| `monitoring/minio-data` | 50Gi | `sdr` — iscsi VIRTUAL-DISK 54 GB |
| `tenants/etcd-data-kmc-arrakis-etcd-0` | 4Gi | `sdq` — iscsi VIRTUAL-DISK 4.3 GB |
| `tenants/pvc-9cc2fe90-5f21-485e-95df-7af5bfcea181` | 5428Mi | `sds` — iscsi VIRTUAL-DISK 5.7 GB |

`tenants/etcd-data-kmc-arrakis-etcd-0` is the **arrakis tenant cluster's etcd**.
Booting an image without `iscsi-tools` while these exist breaks their
attachment; this is not a cosmetic failure. Export anything worth keeping from
minio / vaultwarden / photoprism **before** this step — after it, it is gone.

Push the storage commit (it removes the Longhorn chart from `04-storage.yaml`) —
Sveltos uninstalls Longhorn. Then clear the corpses:

```bash
# delete PVCs/PVs still referencing longhorn; then, if longhorn-system sticks
# in Terminating, use the finalizer recipe in the power-cycle-recovery skill
kubectl --context admin@contraxia get pvc -A | grep longhorn
kubectl --context admin@contraxia get ns longhorn-system
```

Do not proceed to step 2 until the three iscsi `VIRTUAL-DISK` entries have
disappeared from `talosctl … get disks`. That is the observable signal that
Longhorn has actually let go, and it is more trustworthy than the namespace
being gone.

Arrakis tenant apps go down here; they come back in step 5.

## 2. Talos upgrade (zfs extension + config, one reboot)

`r730` is the **only** control-plane node. This reboots it: the Talos API, the
Kubernetes API and every workload go away for the duration. Budget 10-15 min —
an R730 POST alone is several minutes, and `powercycle` pays that in full. Have
iDRAC reachable before you start; it is the only recovery path if the node does
not come back.

Verify the target image exists before touching the node — a 404 here means a bad
boot, and there is no second control-plane node to fall back to:

```bash
ID=c86a996e871ad7d755f8f99109cbb0fda2b2903ba4c1b76668b257e9a2030eea
curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  "https://factory.talos.dev/v2/metal-installer/$ID/manifests/v1.13.5"   # expect 200
```

Confirmed `200` on 2026-08-25. Re-POSTing `bootstrap/talos/r730-schematic.yaml`
to `https://factory.talos.dev/schematics` the same day returned that same ID, so
the file and the image agree — the factory POST is idempotent, so this is a
cheap way to prove the schematic has not drifted.

The schematic ID is already in `r730-schematic.yaml` and `controlplane.yaml`;
the ARC arg is filled (step 0). Then:

```bash
TC="--talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70"

talosctl $TC apply-config --mode staged --file bootstrap/talos/controlplane.yaml
talosctl $TC upgrade \
  --image "factory.talos.dev/metal-installer/$ID:v1.13.5" \
  --reboot-mode powercycle \
  --drain=false
```

Flag notes — the details that bite:

- **There is no `--preserve` flag.** It was removed; `talosctl upgrade` in v1.13
  has no such flag and **always** preserves `STATE` and `EPHEMERAL`.
  Preservation is not optional and not something you can request. Only
  `talosctl reset` destroys them. If you find a `--preserve` in an older note,
  the note is stale — the flags that actually matter are `--reboot-mode`,
  `--drain` and `--stage`.
- `--reboot-mode powercycle` bypasses kexec and forces a full BIOS POST. kexec
  on a PERC-equipped R730 is the flakier path, and this reboot is immediately
  followed by wiping and repartitioning 15 disks behind that controller — a real
  firmware re-init makes the megaraid re-enumeration in step 3 trustworthy.
  Slower; worth it on the box with no fallback.
- `--drain=false` because draining a single-node cluster evicts pods with
  nowhere to reschedule, and a PDB can stall the default `--drain-timeout 5m`
  for nothing. The node is rebooting regardless. Drop this flag if you would
  rather have the clean shutdown and can absorb the wait.
- `install.wipe: true` and `diskSelector.model: WDC*` only ever scope the 500GB
  WD boot disk (`sda`, `WDC WDS500G2B0A`). The 15 Samsung SSDs are outside the
  selector and are not touched by the installer.
- `--mode staged` writes the config to disk and applies it on the next boot —
  which is the reboot the upgrade triggers. One reboot, not two.

⚠ **`apply-config` above also removes all 15 `UserVolumeConfig` documents**, so
Talos releases `u-lh01`…`u-lh15` (currently all ready, 2.0 TB each). That is
intended here — step 3 wipes them anyway — but it means step 2 is destructive to
the data disks' partitioning, so run it only when you mean to go all the way. If
you want the zfs extension **without** releasing the disks, patch just the
install block instead:

```bash
talosctl $TC patch machineconfig --mode staged -p '[
  {"op":"replace","path":"/machine/install/image",
   "value":"factory.talos.dev/metal-installer/'"$ID"':v1.13.5"}
]'
```

That narrower patch is the right tool if you are only proving the zfs extension
boots, or if step 1 is done but you are not yet ready to lose the partitioning.

Watch it come back:

```bash
talosctl $TC dmesg --follow          # reconnects as the API returns
talosctl $TC health --wait-timeout 15m
talosctl $TC get extensions          # expect zfs 2.4.3 + intel-ucode + util-linux-tools,
                                     # and NO iscsi-tools
talosctl $TC read /proc/cmdline      # expect zfs.zfs_arc_max=21474836480
                                     # and NO intel_iommu / pcirebind (stripped on purpose)
kubectl --context admin@contraxia get nodes -o wide   # r730 Ready, Talos v1.13.5
```

If `get extensions` still shows `iscsi-tools`, the node booted the old image —
stop and check `install.image` on the node before going near step 3.

## 3. Wipe the 15 data disks

UserVolumeConfigs are gone from the applied config, so Talos has released the
`u-lhNN` partitions; the disks still carry stale xfs labels until wiped.

⚠ **Re-run `get disks` and read the MODEL column immediately before wiping.**
Two independent reasons, both measured on 2026-08-25:

1. megaraid_sas enumeration shuffles across boots, and the label→device mapping
   is already scrambled today — `sdn1` is `u-lh01`, `sde1` is `u-lh04`, `sdb1`
   is `u-lh05`. There is no `sdX` ↔ `u-lhNN` correspondence to reason from.
2. Longhorn's iscsi `VIRTUAL-DISK`s occupied `sdq`/`sdr`/`sds` in the pre-step-1
   listing. A stale device list is how the wrong disk gets wiped.

Wipe only devices whose MODEL is `Samsung SSD 850`. Never `sda`
(`WDC WDS500G2B0A`, the boot disk).

```bash
# Verify first, then wipe. Do not paste an sdX list from an earlier run.
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  get disks

talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  wipe disk sdb sdc sdd ...   # the 15 Samsung disks from THIS run's output
```

## 4. Create the pool

```bash
./bootstrap/zfs/create-pool.sh   # prompts before writing; 7 mirrors + 1 spare
```

The script uses `/dev/disk/by-id` paths for exactly the stability reason in step
3. Reboot once (`talosctl -e 192.168.2.70 -n 192.168.2.70 reboot`) and re-run the
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

Note: namespace `openebs` does not exist yet as of 2026-08-25 — it arrives with
this convergence, so an empty `get pods` before step 5 is expected, not a fault.

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
  pool unimportable. Verified 2026-08-25: zfs 2.4.3 exists for both v1.13.5 and
  v1.13.9, same userland, so no on-disk format difference between those two.
- Staying on v1.13.5 through this migration is deliberate. Bump to v1.13.9 as
  its own boring upgrade once ZFS is proven — not bundled with a storage swap.
- Monthly: `zpool scrub tank` (via a privileged pod, same as create-pool.sh)
  and check `zpool status` — until observability is re-enabled, this is manual.
- Capacity: keep the pool under 80% (~11TB). COW fragments badly past that.
- Quarterly: restore a real PVC into a scratch namespace.

## Appendix — escape hatch, documented but NOT chosen

A transitional schematic carrying `iscsi-tools` **and** `zfs` together was
registered and verified on 2026-08-25:

```
20115cfe3340492b9e161ae6a6bf7ffaddf79b08b02519e1d155f856362b44ec
  = intel-ucode + iscsi-tools + util-linux-tools + zfs
  (manifests confirmed 200 for both :v1.13.5 and :v1.13.9)
```

It would let Longhorn keep running while the tank pool is built, migrating
volume-by-volume and dropping back to `c86a996e…` on a later reboot — trading
one extra reboot for removing the big-bang data-loss step.

**It was rejected for this migration.** The chosen path is the runbook order
above: destroy Longhorn first, then upgrade once. This ID is recorded only so a
future migration that genuinely needs both storage stacks live at the same time
does not have to re-derive it. Do not substitute it into step 2.
