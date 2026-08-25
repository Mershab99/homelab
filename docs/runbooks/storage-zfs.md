# Storage: ZFS on Talos, end to end (contraxia / r730)

Operator-facing runbook for the whole storage journey on the bare-metal hub:
tear Longhorn down → Talos zfs extension → wipe the Longhorn-era disks →
create the `tank` pool → let Sveltos deliver LocalPV-ZFS → prove it works.

Companion docs:

- `docs/runbooks/migrating-longhorn-to-zfs.md` — the one-time Longhorn teardown
  narrative (data-loss ordering, Velero follow-up). **Read it first if Longhorn
  is still installed.** This document is the mechanical detail underneath it.
- `bootstrap/zfs/create-pool.sh` — the pool creation script (step 4).
- `platform/sveltos/clusterprofiles/04-storage.yaml` — the GitOps layer.

**Destructive steps are §3 (disk wipe), §4 (pool create) and §8 (teardown).**
Everything else is read-only or reversible. Each destructive step carries a
DANGER callout.

### The order, and why it is not negotiable

| # | Step | Owner | Why here |
| --- | --- | --- | --- |
| 0 | **Tear Longhorn down** (chart, PVCs, PVs, `longhorn-system`) | `migrating-longhorn-to-zfs.md` §1 | The target schematic **drops `iscsi-tools`**. Longhorn's engine is iSCSI. The moment the node boots the new image, every Longhorn volume is unreachable — so Longhorn has to be gone *before* the upgrade, not cleaned up after it. |
| 1 | Talos upgrade to the zfs schematic | issue #5 / migration runbook §2 | Ships the zfs kernel module. Nothing downstream works without it (§1.2). |
| 2 | Wipe `sdb`–`sdp` (§3) | this runbook | Talos only releases the `u-lhNN` user volumes once the new config is applied **and** the node has rebooted — i.e. after step 1. `wipe disk` refuses a disk Talos still holds (§3.1). |
| 3 | Create `tank` (§4) | this runbook | Needs clean disks and a loaded module. |
| 4 | GitOps layer (§5) → acceptance (§6) | this runbook | Needs a pool to provision from. |

This is the operator's chosen path (option **(a)**, decided 2026-08-25). See
§2.1 for the alternative that was considered and rejected.

---

## 0. Conventions + observed starting state

Run everything from the repo root. These two helpers are used throughout:

```bash
cd /path/to/homelab
export TALOSCONFIG="$PWD/bootstrap/talos/talosconfig"

# Talos API against the single control-plane node
t() { talosctl -e 192.168.2.70 -n 192.168.2.70 "$@"; }

# Kubernetes API of the bare-metal cluster
k() { kubectl --context=admin@contraxia "$@"; }
```

**Talos has no host shell.** There is no `ssh`, no `talosctl shell`. Every
`zpool` / `zfs` command in this runbook is executed either from a privileged
pod (§4) or by exec-ing into the LocalPV-ZFS node plugin (§5 onward). That is
not a workaround — it is the only way to reach ZFS userland on this node.

### State observed 2026-08-25 (read-only inspection of the live node)

This is the *pre-migration* baseline. If your `t get extensions` already lists
`zfs`, steps 1–2 are done and you start at §3.

| Fact | Value |
| --- | --- |
| Node | `r730`, `192.168.2.70`, single control-plane |
| Talos | `v1.13.5` (server), Kubernetes `v1.36.2` |
| Running schematic | `36cd6536eaec8ba802be2d38974108359069cedba8857302f69792b26b87c010` |
| Extensions present | `intel-ucode 20260512`, `iscsi-tools v0.2.0`, `util-linux-tools 2.41.4` |
| Extensions **absent** | **`zfs` — not installed** |
| `zfs` kernel module | not loaded (`/proc/modules` has no `zfs`) |
| Kernel cmdline | no `zfs.zfs_arc_max`, no `intel_iommu` — `extraKernelArgs` not applied yet |
| RAM | 96532 MiB total |
| Boot disk | `sda` — `WDC WDS500G2B0A`, 500 GB, Talos GPT (`EFI`/`BIOS`/`BOOT`/`META`/`STATE`/`EPHEMERAL`) |
| Data disks | `sdb`–`sdp` — 15 × `Samsung SSD 850`, 2.0 TB each |
| Data disk contents | each has one GPT partition `sdX1`, filesystem `xfs`, partition label `u-lh01`…`u-lh15` |
| Talos volume state | `u-lh01`…`u-lh15` all `ready` — **still claimed by Talos as user volumes** |
| StorageClasses | `longhorn` (default), `longhorn-static` |
| CSI drivers | `driver.longhorn.io` only |
| `openebs` namespace | does not exist |
| Snapshot CRDs | not installed (`volumesnapshotclasses` is not a server resource) |
| PVCs on `longhorn` | `monitoring/minio-data` 50Gi, `tenants/etcd-data-kmc-arrakis-etcd-0` 4Gi, `tenants/pvc-9cc2fe90-…` 5428Mi |
| Sveltos hub cluster | `SveltosCluster mgmt/mgmt`, labels include `persona=infra` |
| Flux source | `GitRepository flux-system/homelab`, branch `main`, interval `5m`, Ready |

`sdq`/`sdr`/`sds` also appear in `t get disks` as 4.3 GB / 54 GB / 5.7 GB
`VIRTUAL-DISK` over transport `iscsi`. Those are **Longhorn engine devices**,
not physical disks. They disappear when Longhorn goes away. Never wipe them.

---

## 1. Pre-flight

All read-only. Nothing here changes the node.

### 1.1 Confirm you are talking to the right node

```bash
t version
```

Expected — the `Server` block must say `192.168.2.70` and a `Tag` matching the
Talos release you expect:

```
Server:
	NODE:        192.168.2.70
	Tag:         v1.13.5
	OS/Arch:     linux/amd64
	Enabled:     RBAC
```

```bash
k get nodes -o wide
```

Expected: exactly one node, `r730`, `Ready`, `control-plane`, `OS-IMAGE
Talos (v1.13.5)`.

### 1.2 Confirm the zfs system extension

```bash
t get extensions
```

Expected **after** the upgrade in §2:

```
NODE           NAMESPACE   TYPE              ID   VERSION   NAME               VERSION
192.168.2.70   runtime     ExtensionStatus   0    1         intel-ucode        <date>
192.168.2.70   runtime     ExtensionStatus   1    1         util-linux-tools   <ver>
192.168.2.70   runtime     ExtensionStatus   2    1         zfs                <ver>
192.168.2.70   runtime     ExtensionStatus   3    1         schematic          c86a996e…30eea
```

Observed **today** (pre-upgrade) — note `zfs` missing and `iscsi-tools` still
present from the Longhorn era:

```
192.168.2.70   runtime     ExtensionStatus   0    1         intel-ucode        20260512
192.168.2.70   runtime     ExtensionStatus   1    1         iscsi-tools        v0.2.0
192.168.2.70   runtime     ExtensionStatus   2    1         util-linux-tools   2.41.4
192.168.2.70   runtime     ExtensionStatus   3    1         schematic          36cd6536eaec8ba802be2d38974108359069cedba8857302f69792b26b87c010
```

> **ZFS cannot work without this extension. Full stop.**
> The `zfs` extension is what ships the ZFS *kernel module* and the ZFS
> userland into the Talos image. Talos is an immutable appliance — you cannot
> `modprobe`, `apt install`, or side-load it later. Without the extension:
> `zpool create` fails, `zpool import` fails, the LocalPV-ZFS node plugin
> CrashLoops, and **every PVC on `fast-zfs`/`fast-block`/`db-zfs` stays
> Pending forever**. There is no degraded mode and no fallback.

Second, independent check — the module itself:

```bash
t read /proc/modules | grep '^zfs '
```

Expected after upgrade: one line starting `zfs `. Today it returns nothing
(the runbook's own check prints `zfs module NOT loaded`).

### 1.3 Confirm the ARC cap is in the applied kernel cmdline

```bash
t read /proc/cmdline
```

Expected after the upgrade: the line contains `zfs.zfs_arc_max=<bytes>`.

Observed today (no `extraKernelArgs` applied at all):

```
BOOT_IMAGE=/A/vmlinuz talos.platform=metal talos.config=none console=tty0
init_on_alloc=1 slab_nomerge pti=on consoleblank=0
nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1
module.sig_enforce=1 module.sig_enforce=1 proc_mem.force_override=never
```

> **The ARC cap is mandatory, not advisory.** The ZFS ARC is not
> kubelet-visible reclaimable memory. Uncapped, it grows into the page cache
> and the kubelet starts OOM-killing pods on a node that looks like it has
> free RAM.

`bootstrap/talos/controlplane.yaml` currently carries the placeholder
`zfs.zfs_arc_max=TODO_20_PERCENT_OF_RAM_IN_BYTES`. Size it from the node:

```bash
t memory
```

Observed: `TOTAL 96532` (MiB) ≈ 94.3 GiB. At the documented 20–25% target that
is **20 GiB = `21474836480`** (21.2%). Substitute the real number before
applying the config.

> `bootstrap/talos/controlplane.yaml` is owned by the Talos upgrade work, not
> by this runbook. Filling the placeholder is that step's job — §1.3 only
> tells you how to verify it landed.

#### The GPU args are stripped for this cycle

`controlplane.yaml` today also carries four GPU-passthrough kernel args:

```yaml
extraKernelArgs:
    - intel_iommu=on
    - pcirebind.rebind=0000:06:00.0_nvidia+vfio-pci   # TODO: real PCI BDF
    - pcirebind.rebind=0000:82:00.0_nvidia+vfio-pci   # TODO: real PCI BDF
    - pcirebind.rebind=0000:82:00.1_nvidia+vfio-pci   # TODO: real PCI BDF
    - zfs.zfs_arc_max=TODO_20_PERCENT_OF_RAM_IN_BYTES
```

**Operator decision (2026-08-25): all four GPU args come out for this
upgrade.** The only cmdline change in this cycle is the ARC cap. After the
upgrade `t read /proc/cmdline` must contain `zfs.zfs_arc_max=21474836480` and
**must not** contain `intel_iommu` or `pcirebind`.

Rationale: those three BDFs are placeholders — the comment above them in
`controlplane.yaml` says `⚠ Replace the PCI BDFs below with the real
addresses`. Handing `pcirebind` a wrong BDF on a single-control-plane node
turns a storage upgrade into a boot problem you can only fix through iDRAC.
This cycle changes exactly two things: the extension set and the ARC cap.
GPU passthrough returns as its own upgrade, with `t get pcidevices` output to
back the BDFs.

Verification after the upgrade:

```bash
t read /proc/cmdline | tr ' ' '\n' | grep -E 'zfs_arc_max|intel_iommu|pcirebind'
```

Expected: exactly one line, `zfs.zfs_arc_max=21474836480`.

### 1.4 Inventory the disks

```bash
t get disks
```

Expected: `sda` = `WDC WDS500G2B0A` 500 GB (boot), `sdb`–`sdp` = 15 ×
`Samsung SSD 850` 2.0 TB (the pool), plus `loopN` squashfs and possibly
`sdq`/`sdr`/`sds` iSCSI `VIRTUAL-DISK` (Longhorn, transient).

> **`/dev/sdX` names shuffle across boots on this box.** The megaraid_sas HBA
> does not enumerate deterministically. Re-run `t get disks` immediately before
> §3 and match on the `MODEL` column — never reuse a device list from a
> previous session. `bootstrap/zfs/create-pool.sh` sidesteps this entirely by
> addressing disks through `/dev/disk/by-id/*Samsung_SSD_850*`, and
> `controlplane.yaml` selects the boot disk with `diskSelector.model: WDC*`
> for the same reason.

### 1.5 Pre-flight checklist

- [ ] `t version` reaches `192.168.2.70`
- [ ] `k get nodes` shows one Ready control-plane
- [ ] `t get extensions` lists `zfs` (if not → §2)
- [ ] `t read /proc/modules | grep '^zfs '` returns a line
- [ ] `t read /proc/cmdline` contains a real `zfs.zfs_arc_max=<bytes>`
- [ ] `t get disks` shows 15 × `Samsung SSD 850`
- [ ] `t get extensions` schematic ID matches `bootstrap/talos/r730-schematic.yaml`
- [ ] Longhorn data you care about is exported (see the migration runbook)
- [ ] Longhorn is **torn down** — §1.6

### 1.6 Gate: Longhorn must already be gone

The upgrade in §2 drops the `iscsi-tools` extension. Longhorn's engine and
replica path is iSCSI (`sdq`/`sdr`/`sds` in §0 are its `VIRTUAL-DISK`
devices). After the reboot the node cannot attach a Longhorn volume at all —
so anything still running on `longhorn` loses its disk mid-flight, with no
clean unmount and no chance to export.

Tear it down first. That procedure is
[`migrating-longhorn-to-zfs.md`](migrating-longhorn-to-zfs.md) §1 — do not
duplicate it here. Three volumes were live on 2026-08-25:

```bash
k get pvc -A | grep -E 'longhorn|STORAGECLASS'
```

Observed today:

```
monitoring   minio-data                       Bound   ...   50Gi     longhorn
tenants      etcd-data-kmc-arrakis-etcd-0     Bound   ...   4Gi      longhorn
tenants      pvc-9cc2fe90-…                   Bound   ...   5428Mi   longhorn
```

`tenants/etcd-data-kmc-arrakis-etcd-0` is the **arrakis k0smotron control-plane
etcd**. Destroying it destroys the arrakis control plane; it re-provisions from
git afterwards (migration runbook §5). Know that before you start, not during.

Gate before continuing to §2:

```bash
k get pvc -A -o json | jq -r '
  [.items[] | select(.spec.storageClassName|test("longhorn"))
   | "\(.metadata.namespace)/\(.metadata.name)"] as $p
  | if ($p|length) == 0 then "OK: no longhorn PVCs" else "STOP: \($p)" end'
k get ns longhorn-system 2>&1 | tail -1   # want: NotFound
k get sc                                  # want: no longhorn / longhorn-static
```

Expected: `OK: no longhorn PVCs`, `Error from server (NotFound): namespaces
"longhorn-system" not found`, and no Longhorn StorageClass. If
`longhorn-system` hangs in `Terminating`, use the finalizer recipe in the
`power-cycle-recovery` skill — do not proceed with a half-deleted namespace.

---

## 2. Talos upgrade to the zfs schematic (reference only)

**The mechanics of the Talos upgrade are owned by the Talos upgrade issue.**
This section exists so a storage operator knows what must have happened, what
to run, and how to tell it worked. Do not treat it as the authoritative
upgrade procedure.

### 2.1 What must be true first

`bootstrap/talos/r730-schematic.yaml` requests three official extensions:
`siderolabs/intel-ucode`, `siderolabs/util-linux-tools`, `siderolabs/zfs`. Its
registered schematic ID (recorded in that file, 2026-08-24) is:

```
c86a996e871ad7d755f8f99109cbb0fda2b2903ba4c1b76668b257e9a2030eea
```

Re-POST it and confirm the ID still matches, then confirm Image Factory can
actually build that combination for the target Talos version:

```bash
curl -fsSL --data-binary @bootstrap/talos/r730-schematic.yaml \
  https://factory.talos.dev/schematics
# → {"id":"c86a996e871ad7d755f8f99109cbb0fda2b2903ba4c1b76668b257e9a2030eea"}
```

Read it back the other way if you only have an ID and want to know what is in
it:

```bash
curl -fsSL https://factory.talos.dev/schematics/c86a996e871ad7d755f8f99109cbb0fda2b2903ba4c1b76668b257e9a2030eea
```

Verified 2026-08-25 — returns exactly:

```yaml
customization:
    systemExtensions:
        officialExtensions:
            - siderolabs/intel-ucode
            - siderolabs/util-linux-tools
            - siderolabs/zfs
```

Note what is **not** there: `iscsi-tools`. That is deliberate, and it is the
whole reason Longhorn has to be gone before this step (§1.6).

#### Not chosen: the transitional schematic

There is a registered schematic that keeps both storage stacks alive at once:

```
20115cfe3340492b9e161ae6a6bf7ffaddf79b08b02519e1d155f856362b44ec
  = intel-ucode + iscsi-tools + util-linux-tools + zfs
```

(verified 2026-08-25 by `GET https://factory.talos.dev/schematics/20115cfe…`).

Booting that image would let Longhorn keep serving its three volumes while the
pool is built, so data could be copied volume-to-volume instead of exported and
restored.

> **The operator rejected this path on 2026-08-25. Do not run it.** It buys a
> live-migration window at the cost of two extra reboots on a
> single-control-plane node, a machine config that has to be edited three
> times, and a window where the CSI drivers of both stacks are registered
> against the same kubelet. It is recorded here only so that finding the ID in
> the history does not read as a missing step. The path this runbook documents
> is: tear Longhorn down (§1.6) → upgrade straight to `c86a996e…` → wipe →
> create the pool.

### 2.2 What to run

```bash
# 1. stage the machine config (ARC arg filled, UserVolumeConfigs removed)
t apply-config --mode staged --file bootstrap/talos/controlplane.yaml

# 2. upgrade to the zfs-extension installer image
t upgrade --preserve --image \
  factory.talos.dev/metal-installer/c86a996e871ad7d755f8f99109cbb0fda2b2903ba4c1b76668b257e9a2030eea:v1.13.5
```

> **`--preserve` is mandatory on this node.** contraxia is a single
> control-plane node; etcd lives on the `EPHEMERAL` partition. Without
> `--preserve` the upgrade wipes `EPHEMERAL` and takes etcd — and therefore
> every Cluster CR, every Sveltos binding — with it.

> **Do not use `task talos:hub:upgrade` for this.** Verified against
> `.taskfiles/talos.yml` (2026-08-25), that task is wrong here in three ways:
>
> - it pins `ghcr.io/siderolabs/installer:{{.TALOS_VERSION}}` — the *vanilla*
>   installer with **no extensions**, so it silently strips zfs and leaves
>   `tank` unimportable;
> - `TALOS_VERSION` defaults to **`v1.9.1`**, so a bare `task talos:hub:upgrade`
>   against a node running v1.13.5 is a *downgrade*, not an upgrade;
> - the sibling `talos:hub:schematic` task reads
>   `bootstrap/talos/hub/schematic.yaml`, a directory that does not exist in
>   this repo (the R730 schematic lives at
>   `bootstrap/talos/r730-schematic.yaml`).
>
> Run the two `talosctl` commands above by hand.

### 2.3 Expected downtime

Single control-plane node: **the Kubernetes API and every workload are down for
the whole reboot.** There is no second node to fail over to. Budget a
maintenance window; do not schedule this against a live tenant workload.

**Budget 10–15 minutes of full outage**, and do not start worrying before the
15-minute mark. The breakdown:

| Phase | Rough share |
| --- | --- |
| Pull the installer image, write the inactive boot partition | 1–3 min |
| Shut down, reboot | seconds |
| **R730 BIOS/POST** — memory training on 96 GB, the megaraid HBA enumerating 16 SATA devices, iDRAC init | **the single largest slice; several minutes on this box** |
| Talos boot, etcd recovery, kubelet ready, static pods back | 2–4 min |
| Workloads rescheduled and settled | a few more minutes |

> **A dark console for four minutes is normal on this machine.** It is POST,
> not a failed upgrade. Power-cycling an R730 mid-`talosctl upgrade` is how you
> turn a 12-minute maintenance window into a reinstall.

> ### iDRAC is the only recovery path
>
> If the node does not come back, `talosctl` cannot help you — the API is on
> the node that is not booting. Everything from that point is out-of-band:
> iDRAC virtual console on the R730 (`https://<idrac-ip>`), to read POST codes,
> see the Talos boot messages, choose the previous (rollback) boot entry from
> the GRUB menu, or attach virtual media to reinstall.
>
> **Confirm you can log into iDRAC *before* you start the upgrade, not after.**
> An R730 with no iDRAC access and no working boot is a trip to the rack.
>
> *UNVERIFIED: the iDRAC address and credentials for this chassis are not
> recorded in this repo — by design, no secrets here. Have them to hand.*

*UNVERIFIED: no upgrade has been run on this node from this branch, so the
10–15 minute figure is a budget from this hardware's known POST behaviour, not
a measured duration. Record the real number the first time you run it.*

### 2.4 How to watch it return

```bash
# stream the node's boot; reconnects as the API comes back
t dmesg -f

# or the live dashboard
t dashboard
```

Then, once the API answers:

```bash
t version                       # Server Tag == target version
t get extensions                # zfs present, iscsi-tools GONE, schematic c86a996e…
t read /proc/modules | grep '^zfs '
t read /proc/cmdline | tr ' ' '\n' | grep -E 'zfs_arc_max|intel_iommu|pcirebind'
                                # exactly one line: zfs.zfs_arc_max=21474836480
k get nodes                     # r730 Ready
k get pods -A | grep -v Running # settles to empty (Completed jobs aside)
```

Do not continue to §3 until all six pass.

---

## 3. Wipe the Longhorn-era data disks (`sdb`–`sdp`)

> ### ☠ DANGER — IRREVERSIBLE DATA DESTRUCTION ☠
>
> `talosctl wipe disk` destroys the partition table and filesystem metadata on
> the named devices. **There is no undo, no confirmation prompt, and no dry-run
> flag.** Every byte of Longhorn replica data on those 15 disks is gone the
> instant the command returns.
>
> - **Wiping `sda` bricks the node.** `sda` is the 500 GB `WDC WDS500G2B0A`
>   boot disk holding `EFI`/`BOOT`/`META`/`STATE`/`EPHEMERAL` — including etcd.
> - **Wiping `sdq`/`sdr`/`sds` corrupts live Longhorn volumes.** Those are
>   iSCSI `VIRTUAL-DISK` devices, not hardware.
> - **`/dev/sdX` letters shuffle across reboots on this HBA.** Re-run
>   `t get disks` in the same session and confirm the `MODEL` column reads
>   `Samsung SSD 850` for every device you are about to name.
>
> Do not paste the wipe command from this document without re-deriving the
> device list first.

### 3.1 Precondition: Talos must have released the disks

`talosctl wipe disk` refuses any block device Talos is currently using as a
volume:

> `Wipe a block device (disk or partition) which is not used as a volume.`

Right now Talos **is** using them. `t get volumestatus` shows `u-lh01` through
`u-lh15` in phase `ready`, each mapped to an `sdX1` partition:

```
192.168.2.70   runtime   VolumeStatus   u-lh01   2   partition   ready   /dev/sdn1   2.0 TB
192.168.2.70   runtime   VolumeStatus   u-lh05   2   partition   ready   /dev/sdb1   2.0 TB
...
```

Those claims come from the `UserVolumeConfig` entries that the ZFS pivot
removed from `bootstrap/talos/controlplane.yaml`. They are released only after
the new config is applied **and** the node reboots — i.e. after §2. **This is
why the wipe comes after the upgrade, not before.**

Gate on it:

```bash
t get volumestatus | grep u-lh || echo "OK: no u-lh user volumes remain"
```

Expected: `OK: no u-lh user volumes remain`. If any `u-lh*` row is still
present, stop — §2 is not finished, and the wipe will fail.

### 3.2 Re-derive the device list

```bash
t get disks
```

Copy the `ID` column of every row whose `MODEL` is `Samsung SSD 850`. On the
current enumeration that is `sdb sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm
sdn sdo sdp` — 15 devices. Count them. If you have 14 or 16, stop and find out
why before wiping anything.

### 3.3 Wipe

```bash
t wipe disk sdb sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp
```

Flags, from `talosctl wipe disk --help`:

- `--method FAST` (default) — zeroes the metadata regions. Correct here: ZFS
  writes its own labels, and these are SSDs with `autotrim` about to be enabled.
- `--method ZEROES` — full overwrite. Hours on 30 TB of SATA SSD. Only for
  decommissioning hardware that leaves the building.
- `--drop-partition` — removes the partition entry rather than only wiping it.
  Use it if you wipe a *partition* (`sdb1`) instead of a *disk* (`sdb`).
  Wiping the whole disk takes the GPT with it, so it is not needed here.

### 3.4 Verify every disk is clean

```bash
t get discoveredvolumes | grep -E ' sd[b-p]'
```

Expected — 15 rows, one per disk, each with an **empty** filesystem-type column
and **no `sdX1` partition rows at all**:

```
192.168.2.70   runtime   DiscoveredVolume   sdb   2   disk   2.0 TB
192.168.2.70   runtime   DiscoveredVolume   sdc   2   disk   2.0 TB
...
192.168.2.70   runtime   DiscoveredVolume   sdp   2   disk   2.0 TB
```

For contrast, this is the **pre-wipe** output (what you must NOT still see) —
note the `gpt` on the disk, the `sdX1` partition rows, `xfs`, and the `u-lhNN`
partition labels:

```
192.168.2.70   runtime   DiscoveredVolume   sdb    1   disk        2.0 TB   gpt
192.168.2.70   runtime   DiscoveredVolume   sdb1   1   partition   2.0 TB   xfs   u-lh05
192.168.2.70   runtime   DiscoveredVolume   sdc    1   disk        2.0 TB   gpt
192.168.2.70   runtime   DiscoveredVolume   sdc1   1   partition   2.0 TB   xfs   u-lh06
```

Machine-checkable gate:

```bash
t get discoveredvolumes | grep -E ' sd[b-p]1 ' && \
  echo "FAIL: partitions remain" || echo "OK: all 15 disks clean"
```

Also confirm you did not touch the boot disk — `sda1`…`sda6` must still be
there:

```bash
t get discoveredvolumes | grep -E ' sda[0-9]? '
```

Expected: `sda` gpt, `sda1` vfat EFI, `sda2` BIOS, `sda3` xfs BOOT, `sda4`
talosmeta META, `sda5` xfs STATE, `sda6` xfs EPHEMERAL.

---

## 4. Create the `tank` pool

> ### ☠ DANGER — WRITES VDEV LABELS TO 14 DISKS ☠
>
> `zpool create` is destructive and, past the point where data lands on the
> pool, effectively irreversible (see §8). The script prompts for a literal
> `YES` before it writes anything — that prompt is the last exit.
>
> **Never run a bare `zpool create` against disks that already carry a pool.**
> If `tank` exists, you want `zpool import`, not `create`. The script does the
> right thing automatically; a hand-typed `zpool create -f` does not.

### 4.1 Pre-req checklist

- [ ] §1 pre-flight fully green — `zfs` extension present, module loaded, ARC capped
- [ ] §3 complete — all 15 Samsung disks show no partitions in `discoveredvolumes`
- [ ] `kubectl` works and points at contraxia (the script reads `$KUBECONFIG`,
      falling back to `~/.kube/config` — a `--context` flag will not reach it)
- [ ] The `kube-system` namespace admits privileged pods. Verified today: it
      carries no `pod-security.kubernetes.io/enforce` label, so Pod Security
      Admission does not restrict it.
- [ ] Node can pull `openebs/zfs-driver:2.11.0` (pinned to match the chart
      version in `04-storage.yaml` — keep them in sync)

Because the script talks to the cluster, not to `talosctl`, point `KUBECONFIG`
at contraxia explicitly:

```bash
kubectl config use-context admin@contraxia
./bootstrap/zfs/create-pool.sh
```

### 4.2 What the script does and what it prompts

1. Launches a privileged pod `zfs-pool-create` in `kube-system` from
   `openebs/zfs-driver:2.11.0`, `hostNetwork: true`, with the host `/dev`
   bind-mounted. Waits up to 180s for Ready. Deletes it on exit via a trap.
2. Asserts `/sys/module/zfs` exists inside the pod. **If this fails you are not
   running the zfs-extension image** — go back to §2. Error text:
   `ERROR: zfs kernel module not loaded — is the node running the zfs-extension image?`
3. Checks for an existing pool: `zpool list tank || zpool import -N tank`. If
   either succeeds it prints `Pool 'tank' already exists:` plus `zpool status`
   and **exits 0 without touching anything**. This is what makes the script
   safe to re-run.
4. Enumerates `/dev/disk/by-id/*Samsung_SSD_850*`, skipping `*-part*` and
   de-duplicating `wwn-`/`ata-` aliases by resolved block device. Needs ≥14;
   fewer is a hard error listing what it found.
5. Takes the first 14 as pool members, pairs them into 7 mirrors, and leaves
   the 15th as an untouched in-chassis warm spare (not a ZFS hot spare — it is
   deliberately not in the pool).
6. Prints the layout and **prompts**:

   ```
   Pool layout (7 mirrors):
     mirror: /dev/disk/by-id/ata-Samsung_SSD_850_… /dev/disk/by-id/ata-Samsung_SSD_850_…
     ... (7 lines)
   Warm spare (left untouched):
     /dev/disk/by-id/ata-Samsung_SSD_850_…

   Create pool 'tank' — DESTROYS data on the 14 disks above. Type YES:
   ```

   Anything other than the exact string `YES` aborts with exit 1.
7. Creates the pool:

   ```
   zpool create -f -o ashift=12 -o autotrim=on -m legacy \
     -O compression=lz4 -O atime=off -O xattr=sa -O dnodesize=auto -O dedup=off \
     tank mirror <d1> <d2> mirror <d3> <d4> ... (7 mirrors)
   ```

   `-m legacy` matters: the pool is never auto-mounted at a host path; the CSI
   driver mounts datasets into pod namespaces itself.
8. Prints `zpool status` and the next-steps banner (reboot, re-run, then push
   the GitOps layer).

### 4.3 Post-verify — before the CSI driver exists

At this point the `zfs-localpv` node plugin is not installed yet, so there is
nothing to `exec` into. Use a one-shot privileged pod with the same shape the
script uses:

```bash
kubectl -n kube-system run zfs-shell --rm -it --restart=Never \
  --image=openebs/zfs-driver:2.11.0 \
  --overrides='{"spec":{"hostNetwork":true,"containers":[{"name":"zfs-shell","image":"openebs/zfs-driver:2.11.0","stdin":true,"tty":true,"command":["bash"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"dev","mountPath":"/dev"}]}],"volumes":[{"name":"dev","hostPath":{"path":"/dev"}}]}}' \
  -- bash
```

`--rm` deletes the pod on exit. Inside it:

```bash
zpool status tank
zpool list
zfs get all tank
```

*UNVERIFIED: this `kubectl run --overrides` invocation mirrors the pod spec in
`bootstrap/zfs/create-pool.sh` (privileged, hostNetwork, `/dev` hostPath) but
has not been executed — creating a pod is a cluster mutation and this branch is
read-only against the live cluster.*

**`zpool status tank`** — expected shape: `state: ONLINE`, `errors: No known
data errors`, and exactly 7 `mirror-N` vdevs each with two `ONLINE` members
named by their `by-id` path:

```
  pool: tank
 state: ONLINE
config:
	NAME                                       STATE     READ WRITE CKSUM
	tank                                       ONLINE       0     0     0
	  mirror-0                                 ONLINE       0     0     0
	    ata-Samsung_SSD_850_…                  ONLINE       0     0     0
	    ata-Samsung_SSD_850_…                  ONLINE       0     0     0
	  mirror-1 … mirror-6                      ONLINE       0     0     0
errors: No known data errors
```

Check: 7 mirrors, 14 leaf devices, no `DEGRADED`, no `UNAVAIL`, no `spares`
section (the 15th disk is intentionally outside the pool).

**`zpool list`** — expected roughly:

```
NAME   SIZE   ALLOC   FREE   CKPOINT  EXPANDSZ   FRAG  CAP  DEDUP  HEALTH  ALTROOT
tank   12.7T   ...    ...         -         -     0%   0%  1.00x  ONLINE  -
```

7 mirrors × ~1.8 TiB usable ≈ **12.7 TiB raw `SIZE`**. If `SIZE` is ~25 T you
built a stripe, not mirrors — destroy and recreate now, before data lands.
`HEALTH` must be `ONLINE`, `CAP` near 0%.

**`zfs get all tank`** — the properties the script sets must be present:

| Property | Expected |
| --- | --- |
| `compression` | `lz4` |
| `atime` | `off` |
| `xattr` | `sa` |
| `dnodesize` | `auto` |
| `dedup` | `off` |
| `mountpoint` | `legacy` |
| `ashift` (pool prop: `zpool get ashift tank`) | `12` |
| `autotrim` (pool prop: `zpool get autotrim tank`) | `on` |

Spot-check the two that are immutable-ish and most expensive to get wrong:

```bash
zpool get ashift,autotrim tank
zfs get -H -o property,value compression,atime,xattr,dedup,mountpoint tank
```

### 4.4 Prove the pool auto-imports across a reboot — do this NOW

> **Do not skip this and do not let data land on the pool first.** A pool that
> does not import on boot is a storage outage on every reboot, and it is far
> cheaper to fix on an empty pool.

```bash
t reboot
# wait for the node to come back (see §2.4), then:
./bootstrap/zfs/create-pool.sh
```

Expected: the script prints `Pool 'tank' already exists:` followed by
`zpool status`, and exits 0 **without prompting**. If it instead offers to
create the pool, the import failed — go to §7.2 and fix it before continuing.

---

## 5. The GitOps layer

### 5.1 How `04-storage.yaml` reaches the cluster

Nothing in the storage layer is applied by hand. The chain, each link verified
against the live cluster today:

1. **Push to `main`.** `bootstrap/flux/gitrepository.yaml` defines
   `GitRepository flux-system/homelab` → `https://github.com/mershab99/homelab`,
   branch `main`, `interval: 5m`, auth via the `flux-repo-pat` Secret.
   Flux source-controller stores an artifact per revision.
2. **The root ClusterProfile** (`clusters/baremetal/sveltos-root.yaml`, applied
   once by hand) targets `SveltosCluster mgmt/mgmt` with
   `syncMode: ContinuousWithDriftDetection` and two `kustomizationRefs` against
   that GitRepository — one of which is `./platform/sveltos/clusterprofiles`.
   Sveltos kustomize-builds that directory and applies every ClusterProfile in
   it, including `storage`. **Sveltos manages Sveltos from here.**
3. **The `storage` ClusterProfile** selects `matchLabels: persona: infra`. The
   live `SveltosCluster mgmt/mgmt` carries `persona=infra`, so it matches — the
   bare-metal hub is the storage node.
4. **Sveltos installs two Helm charts** onto the matched cluster:
   - `piraeus/snapshot-controller` `5.2.0` → release `snapshot-controller` in
     `kube-system`
   - `zfs-localpv/zfs-localpv` `2.11.0` → release `zfs-localpv` in `openebs`,
     with `crds.csi.volumeSnapshots.enabled: false` and `analytics.enabled: false`

   Both versions are pinned **exactly**: Sveltos v1.12 rejects `.x` wildcards.
5. **Sveltos applies the `policyRefs`** — the raw manifests under
   `./platform/sveltos/manifests/storage`: `storageclasses.yaml` (the three
   StorageClasses + the `zfs-snapclass` VolumeSnapshotClass), `minio.yaml`
   (Loki's S3 backend), `resource-quota.yaml`.

Note the ordering hazard baked into this design and why it is safe: the
StorageClasses reference `provisioner: zfs.csi.openebs.io`, which does not
exist until the chart installs. A StorageClass naming an absent provisioner is
inert, not an error — PVCs simply stay Pending until the driver registers.

### 5.2 Force a resync instead of waiting 5 minutes

```bash
k -n flux-system annotate gitrepository homelab \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

(or `flux reconcile source git homelab -n flux-system` if the `flux` CLI is
installed).

### 5.3 Confirm the source is current

```bash
k -n flux-system get gitrepository homelab
```

Expected — `READY True` and a `STATUS` naming the revision you just pushed:

```
NAMESPACE     NAME      URL                                    AGE   READY   STATUS
flux-system   homelab   https://github.com/mershab99/homelab   52d   True    stored artifact for revision 'main@sha1:<your-sha>'
```

If the SHA is not yours, Sveltos has not seen the change yet — nothing
downstream will be right.

### 5.4 Confirm Sveltos deployed the profile

```bash
k get clusterprofile storage
k get clustersummaries -A | grep -i storage
k -n mgmt get clustersummary -o wide
```

Expected: a ClusterSummary for `storage` bound to cluster `mgmt/mgmt` reporting
its Helm charts and policy refs as `Provisioned`. Any `Provisioning` that never
settles, or `Failed`, is where to read the message:

```bash
k get clustersummaries -A -o yaml | grep -A5 -i 'failuremessage\|status:'
```

### 5.5 Confirm the charts landed

```bash
k get pods -n openebs
```

Expected — the Deployment `zfs-localpv-controller` and the DaemonSet
`zfs-localpv-node`, both `Running`, node plugin count == node count (1):

```
NAME                                      READY   STATUS    RESTARTS   AGE
zfs-localpv-controller-<hash>-<hash>      5/5     Running   0          2m
zfs-localpv-node-<hash>                   2/2     Running   0          2m
```

The node pod's two containers are `csi-node-driver-registrar` and
`openebs-zfs-plugin`. **`openebs-zfs-plugin` CrashLooping is the signature of a
missing zfs extension or an unimported pool** — see §7.1/§7.2.

`5/5` on the controller is `csi-resizer`, `csi-snapshotter`,
`snapshot-controller`, `csi-provisioner`, `openebs-zfs-plugin`. That third one
is a **second** snapshot controller racing the piraeus Deployment below — a
known open defect, see §7.4b.

```bash
k get pods -n kube-system -l app.kubernetes.io/name=snapshot-controller
k -n kube-system get deploy snapshot-controller
```

Expected: `snapshot-controller` Deployment, 1/1 Ready.

### 5.6 Confirm the CSI driver registered

```bash
k get csidrivers
```

Expected: a `zfs.csi.openebs.io` row (alongside `driver.longhorn.io` if
Longhorn has not been removed yet).

```bash
k get zfsnodes -n openebs
```

Expected: one `ZFSNode` named after the node (`r730`), listing `tank` under its
pools. **This is the single best end-to-end check** — the ZFSNode object only
appears when the node plugin successfully enumerated real pools on the real
host. If it is missing or lists no pools, stop and go to §7.

```bash
k get crd | grep -E 'zfs\.openebs\.io|snapshot\.storage\.k8s\.io'
```

Expected CRDs: `zfsvolumes`, `zfssnapshots`, `zfsnodes`, `zfsbackups`,
`zfsrestores` (`.zfs.openebs.io`), plus `volumesnapshots`,
`volumesnapshotcontents`, `volumesnapshotclasses`, and the three
`volumegroupsnapshot*` (`.snapshot.storage.k8s.io`, owned by
snapshot-controller — see §7.4).

### 5.7 Confirm the StorageClasses

```bash
k get sc
```

Expected once Longhorn is gone:

```
NAME               PROVISIONER            RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
db-zfs             zfs.csi.openebs.io     Retain          WaitForFirstConsumer   true                   1m
fast-block         zfs.csi.openebs.io     Delete          WaitForFirstConsumer   true                   1m
fast-zfs (default) zfs.csi.openebs.io     Retain          WaitForFirstConsumer   true                   1m
```

Exactly one default (see §7.5):

```bash
k get sc -o json | \
  jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name] | "defaults: \(.)  count: \(length)"'
```

Expected: `defaults: ["fast-zfs"]  count: 1`.

```bash
k get volumesnapshotclass
```

Expected: `zfs-snapclass`, driver `zfs.csi.openebs.io`, marked default.

### 5.8 A shell into ZFS, for everything after this point

Once the node plugin is Running, use it instead of ad-hoc pods:

```bash
ZFSPOD=$(k -n openebs get pod -l app=openebs-zfs-node -o jsonpath='{.items[0].metadata.name}')
zx() { k -n openebs exec "$ZFSPOD" -c openebs-zfs-plugin -- "$@"; }

zx /sbin/zfs list -t all
zx chroot /host /sbin/zpool status tank
```

Two details that matter:

- **`/sbin/zfs` inside that container is a chroot wrapper**, not a binary. The
  chart mounts the `openebs-zfspv-bin` ConfigMap over it; the script runs
  `chroot /host /sbin/zfs "$@"` so ZFS *userland* always matches the host
  *kernel module*. Use `/sbin/zfs`, not a bare `zfs`.
- **`zpool` is not wrapped.** Only `zfs` gets a ConfigMap wrapper; there is no
  `zpool` equivalent. Reach the host binary explicitly:

  ```bash
  zx chroot /host /sbin/zpool status tank      # or /usr/sbin/zpool
  ```

  If neither path resolves, fall back to the image's own bundled `zpool`
  (`zx zpool status tank`) — it talks to `/dev/zfs`, which is host-mounted, but
  a userland/kernel-module version skew can make it report oddly. Prefer the
  chroot.

  *UNVERIFIED: the exact path of `zpool` inside the Talos host rootfs
  (`/sbin` vs `/usr/sbin`) was not confirmed — the zfs extension is not
  installed on the node today. The chart's own `zfs` wrapper probes
  `/host/sbin/zfs` then `/host/usr/sbin/zfs` then bare `zfs`; do the same for
  `zpool`.*

- The container mounts host `/` at `/host` **read-only**. Fine for
  `zpool status`/`list`/`get`; anything that writes (notably `zpool import`
  updating a cachefile) will fail. Use the one-shot privileged pod from §4.3
  for those.

---

## 6. Acceptance test

Copy-pasteable end to end. Uses namespace `storage-acceptance` so cleanup is
one `delete ns` — *except* for `fast-zfs`/`db-zfs` PVs, which are
`reclaimPolicy: Retain` and survive namespace deletion (see §6.5).

```bash
k create namespace storage-acceptance
export ZFSPOD=$(k -n openebs get pod -l app=openebs-zfs-node -o jsonpath='{.items[0].metadata.name}')
zx() { k -n openebs exec "$ZFSPOD" -c openebs-zfs-plugin -- "$@"; }
```

### 6.1 A `fast-zfs` PVC binds and a pod writes to it

```bash
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zfs-canary
  namespace: storage-acceptance
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: fast-zfs
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: zfs-writer
  namespace: storage-acceptance
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36
      command:
        - sh
        - -c
        - 'echo "canary-$(date -u +%s)" > /data/canary && sync && cat /data/canary && sleep 3600'
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: zfs-canary
EOF
```

`fast-zfs` is `WaitForFirstConsumer`, so the PVC stays `Pending` until
`zfs-writer` is scheduled. That is correct behaviour, not a fault.

```bash
k -n storage-acceptance wait --for=condition=Ready pod/zfs-writer --timeout=120s
k -n storage-acceptance get pvc zfs-canary
```

Expected: `STATUS Bound`, `CAPACITY 1Gi`, `STORAGECLASS fast-zfs`.

```bash
k -n storage-acceptance exec zfs-writer -- cat /data/canary
```

Expected: `canary-<epoch>`. Record this value — §6.3 must reproduce it exactly.

```bash
k -n storage-acceptance exec zfs-writer -- sh -c 'grep " /data " /proc/mounts'
```

Expected — source `tank/pvc-<uuid>`, filesystem type **`zfs`**:

```
tank/pvc-<uuid> /data zfs rw,xattr,posixacl,casesensitive 0 0
```

A native dataset, not ext4 on a zvol. If the type reads `ext4` you got a
`fast-block`-shaped volume from a `fast-zfs` claim — check the StorageClass
`parameters.fstype`.

(`/proc/mounts` rather than `df -T`: busybox's `df` may be built without the
`-T` option.)

**PASS:** PVC `Bound`, pod `Ready`, canary readable, `/proc/mounts` reports
type `zfs`.

### 6.2 A `VolumeSnapshot` of that PVC succeeds

```bash
cat <<'EOF' | k apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: zfs-canary-snap
  namespace: storage-acceptance
spec:
  volumeSnapshotClassName: zfs-snapclass
  source:
    persistentVolumeClaimName: zfs-canary
EOF

k -n storage-acceptance wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/zfs-canary-snap --timeout=120s
k -n storage-acceptance get volumesnapshot zfs-canary-snap
```

Expected: `READYTOUSE true`, a bound `SNAPSHOTCONTENT`, `SOURCEPVC
zfs-canary`, `RESTORESIZE 1Gi`.

The OpenEBS-side object should exist too:

```bash
k -n openebs get zfssnapshots
```

Expected: one `ZFSSnapshot` whose name matches the snapshot content.

**PASS:** `readyToUse: true` and a matching `ZFSSnapshot`.

### 6.3 …and can be restored

```bash
cat <<'EOF' | k apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zfs-canary-restore
  namespace: storage-acceptance
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: fast-zfs
  dataSource:
    name: zfs-canary-snap
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: zfs-reader
  namespace: storage-acceptance
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "cat /data/canary && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: zfs-canary-restore
EOF

k -n storage-acceptance wait --for=condition=Ready pod/zfs-reader --timeout=120s
k -n storage-acceptance exec zfs-reader -- cat /data/canary
```

Expected: **byte-identical** to the value from §6.1. A different value, an
empty file, or a missing file means the restore silently gave you a blank
volume — that is a failure even though every object says `Bound`.

**PASS:** restored PVC `Bound` and the canary string matches §6.1 exactly.

### 6.4 A `fast-block` PVC works for a KubeVirt DataVolume

CDI is present on the hub today (`datavolumes.cdi.kubevirt.io` and
`storageprofiles.cdi.kubevirt.io` CRDs exist; namespace
`kubevirt-hyperconverged` is Active).

`clusters/baremetal/addons/kubevirt-hco/storageprofile.yaml` pins the
`fast-block` StorageProfile to `volumeMode: Block`, so CDI hands the raw zvol
to the VM instead of stacking `disk.img` on ext4 on a zvol. Confirm it took:

```bash
k get storageprofile fast-block -o jsonpath='{.spec.claimPropertySets}{"\n"}'
```

Expected: `[{"accessModes":["ReadWriteOnce"],"volumeMode":"Block"}]`.

```bash
cat <<'EOF' | k apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: block-canary
  namespace: storage-acceptance
spec:
  source:
    blank: {}
  storage:
    storageClassName: fast-block
    accessModes: [ReadWriteOnce]
    volumeMode: Block
    resources:
      requests:
        storage: 1Gi
EOF

k -n storage-acceptance wait --for=jsonpath='{.status.phase}'=Succeeded \
  datavolume/block-canary --timeout=300s
k -n storage-acceptance get datavolume block-canary
k -n storage-acceptance get pvc block-canary \
  -o jsonpath='{.status.phase} {.spec.volumeMode} {.spec.storageClassName}{"\n"}'
```

Expected DataVolume `PHASE Succeeded`; PVC line: `Bound Block fast-block`.

A blank DataVolume is the smallest real exercise of this path — CDI's
import pod is the first consumer that unblocks `WaitForFirstConsumer`, and it
writes to the device, so a zvol that cannot be opened as a block device fails
here rather than silently later.

*UNVERIFIED: this DataVolume has not been applied — the acceptance test is
written against a cluster where `openebs`, `fast-block` and the pool do not yet
exist, and this branch is read-only against the live cluster. The
StorageProfile, the CRDs and the `fast-block` parameters are verified from the
repo and the live API; the DataVolume outcome is not.*

**PASS:** DataVolume `Succeeded` and the PVC is `Bound` with
`volumeMode: Block`.

### 6.5 `zfs list` shows the datasets and zvols

```bash
zx /sbin/zfs list -t all -o name,used,avail,refer,type,volblocksize,recordsize
```

Expected — one row per acceptance object, all under `tank/`:

| Object | Type | Notes |
| --- | --- | --- |
| `tank` | `filesystem` | the pool root |
| `tank/pvc-<uuid-of-zfs-canary>` | `filesystem` | §6.1, native dataset |
| `tank/pvc-<…>@snapshot-<uuid>` | `snapshot` | §6.2 |
| `tank/pvc-<uuid-of-zfs-canary-restore>` | `filesystem` | §6.3, clone of the snapshot |
| `tank/pvc-<uuid-of-block-canary>` | `volume` | §6.4, a **zvol** with `volblocksize 16K` |

Map PVC UUIDs to dataset names:

```bash
k -n storage-acceptance get pvc -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName
```

Then confirm the two class-specific properties actually took, since they are
the whole reason the classes are separate:

```bash
# fast-block → zvol, 16k volblocksize (StorageClass parameter volblocksize: "16k")
zx /sbin/zfs get -H -o value volblocksize tank/<pvc-of-block-canary>
# → 16K

# db-zfs → dataset, 16k recordsize (StorageClass parameter recordsize: "16k")
# fast-zfs → dataset, inherits the 128K default
zx /sbin/zfs get -H -o value recordsize tank/<pvc-of-zfs-canary>
# → 128K
```

Pool-level sanity while you are here:

```bash
zx chroot /host /sbin/zpool status tank
zx chroot /host /sbin/zpool list
```

Expected: `ONLINE`, `No known data errors`, `CAP` a percent or two.

**PASS:** every object above has a matching ZFS dataset/zvol/snapshot,
`volblocksize` on the `fast-block` zvol is `16K`, pool `ONLINE`.

### 6.6 Acceptance checklist

- [ ] §6.1 `fast-zfs` PVC `Bound`, pod Ready, `/proc/mounts` reports type `zfs`
- [ ] §6.2 `VolumeSnapshot` `readyToUse: true`, `ZFSSnapshot` exists
- [ ] §6.3 restored PVC `Bound` and canary string **identical** to §6.1
- [ ] §6.4 `fast-block` DataVolume `Succeeded`, PVC `Bound` + `volumeMode: Block`
- [ ] §6.5 datasets, zvol and snapshot all visible in `zfs list -t all`
- [ ] §6.5 `zpool status tank` → `ONLINE`, no errors

### 6.7 Cleanup — read this, `delete ns` is not enough

```bash
k delete ns storage-acceptance
```

That removes the pods, PVCs, snapshot and DataVolume. But:

- `fast-zfs` and `db-zfs` are **`reclaimPolicy: Retain`** — deliberately, so
  real data is released rather than reaped. Their PVs survive in phase
  `Released`, and **the ZFS datasets survive with them**.
- `fast-block` is `reclaimPolicy: Delete`, so its zvol does go away.

Finish the job:

```bash
# Released PVs left behind by the Retain classes
k get pv | grep Released

# Delete only the ones from this test (check the CLAIM column first!)
k delete pv <pv-name>

# Then confirm no orphan datasets remain
zx /sbin/zfs list -t all | grep -v '^tank *'
```

Expected end state: `zfs list` shows only `tank` and datasets belonging to real
workloads. Orphan `tank/pvc-*` datasets are leaked capacity — they will quietly
eat the pool.

---

## 7. Failure modes and recovery

### 7.1 zfs extension / Talos version mismatch — pool unimportable

**This is the repo's own standing warning** (`bootstrap/talos/r730-schematic.yaml`):
the ZFS extension version is coupled to the Talos release it was built against.

**Symptoms**

- `t get extensions` does not list `zfs` (or lists a different version than expected)
- `t read /proc/modules | grep '^zfs '` returns nothing
- `zpool import` reports no pools available, or the pool imports with a version error
- `openebs-zfs-plugin` container CrashLoopBackOff
- Every PVC on a `zfs.csi.openebs.io` class stuck `Pending`
- `k get zfsnodes -n openebs` empty or the node lists no pools

**Cause.** An upgrade ran against an image that lacks the extension, or against
a Talos version for which the zfs extension was never built. The most likely
concrete way to cause it in this repo is `task talos:hub:upgrade`, which uses
the vanilla `ghcr.io/siderolabs/installer` image (§2.2).

**Recovery**

1. Do not touch the disks. The pool is intact; the node just cannot read it.
2. Re-POST `bootstrap/talos/r730-schematic.yaml` for the *target* Talos version
   and confirm Image Factory returns an ID and can build that version:
   ```bash
   curl -fsSL --data-binary @bootstrap/talos/r730-schematic.yaml \
     https://factory.talos.dev/schematics
   ```
3. Re-upgrade to `factory.talos.dev/metal-installer/<id>:<version>` with
   `--preserve`.
4. Re-verify §1.2 and §1.3, then §4.4.

**Prevention.** Before *any* Talos upgrade: re-POST the schematic for the
target version and confirm the zfs extension exists for it. Never upgrade with
a bare installer image.

### 7.2 Pool not imported after a reboot

**Symptoms**

- `zpool list` → `no pools available`
- `create-pool.sh` offers to create the pool instead of printing "already exists"
- `openebs-zfs-plugin` running but `zfsnodes` shows no pools
- PVCs Pending with events about the pool not being found

**Diagnose** — from the one-shot privileged pod (§4.3), because import writes:

```bash
zpool import          # lists importable pools without importing
zpool status          # what is currently imported
```

If `zpool import` lists `tank` as importable, the pool is fine and only the
boot-time import failed.

**Recover**

```bash
zpool import -N tank   # -N = do not mount datasets; -m legacy means nothing to mount
zpool status tank
```

If it refuses because the pool looks in use by another system:

```bash
zpool import -f -N tank
```

> `-f` is safe on a single-node box where you know nothing else has the disks.
> It is **not** safe if the disks were ever presented to another host — a
> forced import of a pool another machine still has open corrupts it.

**Fix the boot path, do not just paper over it.** Root causes to check, in
order: the zfs extension is missing (§7.1); the pool was created but the node
rebooted before ZFS wrote a cachefile; a disk is genuinely absent, so the pool
imports `DEGRADED` or not at all — check `t get disks` for 15 Samsung rows.
Re-run §4.4 until a reboot reliably yields "already exists". A pool that needs
a manual import after every reboot is an outage on every reboot.

### 7.3 CSI driver not registered

**Symptoms**

- `k get csidrivers` has no `zfs.csi.openebs.io`
- PVC events: `storageclass.storage.k8s.io "fast-zfs" not found` or
  `waiting for a volume to be created ... no volume plugin matched`
- `k get zfsnodes -n openebs` empty

**Diagnose**

```bash
k get pods -n openebs
k -n openebs logs -l app=openebs-zfs-node -c openebs-zfs-plugin --tail=100
k -n openebs logs -l app=openebs-zfs-controller --tail=100
k -n openebs describe pod -l app=openebs-zfs-node | tail -40
k get clustersummaries -A | grep -i storage
```

**Common causes**

| Cause | Signature | Fix |
| --- | --- | --- |
| zfs extension missing | plugin CrashLoop, module errors in logs | §7.1 |
| Sveltos never deployed the chart | no `openebs` namespace at all | §5.3–§5.4: is the GitRepository at your SHA? does `mgmt` still carry `persona=infra`? |
| kubelet plugin dir mismatch | `csi-node-driver-registrar` errors on `/var/lib/kubelet/plugins_registry/` | confirm the kubelet root is `/var/lib/kubelet` on this node |
| Image pull failure | `ImagePullBackOff` on `openebs/zfs-driver:2.11.0` | check registry reachability |

The registrar and the plugin fail differently: registrar errors mean
Kubernetes cannot see the driver; plugin errors mean the driver cannot see ZFS.
Read the right container.

### 7.4 Snapshot CRDs — and the snapshot *controller* — owned by two charts

Both charts ship the external-snapshotter CRDs. Verified by rendering them:

- `piraeus/snapshot-controller` `5.2.0` → `volumesnapshotclasses`,
  `volumesnapshots`, `volumesnapshotcontents`, plus the three
  `volumegroupsnapshot*`
- `zfs-localpv` `2.11.0` → `volumesnapshotclasses`, `volumesnapshots`,
  `volumesnapshotcontents` (same three)

**The guard already in place**: `04-storage.yaml` sets

```yaml
crds:
  csi:
    volumeSnapshots:
      enabled: false   # CRDs owned by the snapshot-controller chart above
```

**Symptoms if that guard is removed or a chart is upgraded past it**

- Helm/Sveltos error: `rendered manifests contain a resource that already
  exists ... invalid ownership metadata; annotation validation error:
  key "meta.helm.sh/release-name" must equal "snapshot-controller": current
  value is "zfs-localpv"`
- The `storage` ClusterSummary stuck non-`Provisioned`
- Worse: an uninstall of *either* release deletes the shared CRDs, which
  cascades into deleting **every VolumeSnapshot object in the cluster**

**Diagnose ownership**

```bash
for c in volumesnapshots volumesnapshotcontents volumesnapshotclasses; do
  echo -n "$c → "
  k get crd $c.snapshot.storage.k8s.io \
    -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}'
done
```

Expected: all three print `snapshot-controller`.

**Recover.** Restore `crds.csi.volumeSnapshots.enabled: false` in
`04-storage.yaml`, push, and let Sveltos reconcile. If a CRD is already
annotated to the wrong release, re-annotate it rather than deleting it —
deleting the CRD deletes every snapshot object it holds:

```bash
k annotate crd volumesnapshots.snapshot.storage.k8s.io \
  meta.helm.sh/release-name=snapshot-controller --overwrite
k annotate crd volumesnapshots.snapshot.storage.k8s.io \
  meta.helm.sh/release-namespace=kube-system --overwrite
```

#### 7.4b Two snapshot *controllers* — open defect in `04-storage.yaml`

`04-storage.yaml` disables the duplicated **CRDs** but not the duplicated
**controller**. Verified by rendering both charts at their pinned versions:

| | piraeus `snapshot-controller` 5.2.0 | `zfs-localpv` 2.11.0 |
| --- | --- | --- |
| Where | Deployment `snapshot-controller`, ns `kube-system` | sidecar container `snapshot-controller` inside Deployment `zfs-localpv-controller`, ns `openebs` |
| Image | `registry.k8s.io/sig-storage/snapshot-controller:v8.6.0` | `registry.k8s.io/sig-storage/snapshot-controller:v8.2.0` |
| Args | `--leader-election=true --leader-election-namespace=$(NAMESPACE)` | `--v=5` — **no leader election** |
| Value gate | — | `zfsController.snapshotController.enabled`, default `true`, **not set in `04-storage.yaml`** |

Both watch the same **cluster-scoped** `VolumeSnapshot` /
`VolumeSnapshotContent` objects. They cannot arbitrate: the piraeus instance
holds a lease in `kube-system` that the sidecar does not participate in at all,
and the sidecar has leader election disabled outright. So after §5 there are
**two active snapshot controllers of different versions** reconciling the same
objects.

**Symptoms:** duplicate or orphaned `VolumeSnapshotContent`; snapshots flapping
between `readyToUse` true/false; finalizers re-added as fast as they are
removed so a `VolumeSnapshot` will not delete; contradictory events on one
snapshot from two controllers.

**Diagnose**

```bash
# is the sidecar present?
k -n openebs get deploy zfs-localpv-controller \
  -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
```

Expected **if the defect is present**: a `snapshot-controller` line alongside
`csi-resizer`, `csi-snapshotter`, `csi-provisioner` and `openebs-zfs-plugin`
(5 containers → `5/5 Running`). With the fix applied there are 4.

```bash
# who holds the lease — and note that only one of the two is even trying
k -n kube-system get lease | grep -i snapshot
```

**Fix** — add the toggle next to the existing CRD toggle in the `zfs-localpv`
chart values in `platform/sveltos/clusterprofiles/04-storage.yaml`:

```yaml
values: |
  zfsController:
    snapshotController:
      enabled: false   # piraeus snapshot-controller in kube-system owns this
  crds:
    zfsLocalPv:
      enabled: true
    csi:
      volumeSnapshots:
        enabled: false
  analytics:
    enabled: false
```

> **Not applied.** `04-storage.yaml` is out of scope for this runbook (docs
> only). This section documents the defect and the fix; the edit belongs to
> whoever owns that manifest. Until then, §6.2/§6.3 may pass or flake
> depending on which controller wins the race — treat an intermittent snapshot
> failure as this, not as a ZFS fault.

### 7.5 A second default StorageClass

`fast-zfs` carries `storageclass.kubernetes.io/is-default-class: "true"`. So
did `longhorn` — and today, **on the live cluster, `longhorn` is still the
default**. During the migration window both can exist.

**Symptoms**

- PVCs with no `storageClassName` land on the wrong class, or stay Pending
- API validation: `Invalid value: "true": there is already a default
  StorageClass`
- Charts that omit a storage class (vcluster, operator-vended Postgres)
  provision onto Longhorn after you thought Longhorn was gone

**Diagnose**

```bash
k get sc -o json | \
  jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name] | "defaults: \(.)  count: \(length)"'
```

Expected: `count: 1`.

**Recover.** Un-default the loser. Both `longhorn` and `longhorn-static` are
Longhorn-chart objects, so the durable fix is finishing the Longhorn teardown
(the migration runbook). To break a tie immediately:

```bash
k patch sc longhorn -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

> That is a hand-patch of a chart-managed object — it will be reverted the next
> time the chart reconciles. It buys time; it is not the fix.

Note the same trap exists one level down: the tenant class `kubevirt`
(`tenants/arrakis/addons/kubevirt-csi/storageclass.yaml`) is default **on
arrakis**, not on the hub. Two clusters, two defaults, and they are not in
conflict — do not "fix" one by looking at the other.

### 7.6 ARC starving the node

**Symptoms:** pods OOMKilled on a node whose `free` looks healthy; kubelet
evictions under memory pressure; a large ARC.

**Diagnose**

```bash
t read /proc/cmdline | tr ' ' '\n' | grep zfs_arc_max   # must be present
t read /proc/spl/kstat/zfs/arcstats | grep -E '^(size|c_max) '
t memory
```

`size` must stay under `c_max`, and `c_max` must equal the value on the
cmdline.

**Recover.** Fix `zfs.zfs_arc_max` in `bootstrap/talos/controlplane.yaml`,
apply, reboot. There is no live knob path on Talos.

---

## 8. Rollback and teardown

> ### ☠ DANGER — THIS SECTION DESTROYS ALL POOL DATA ☠
>
> Only run this on a pool you intend to abandon. Take a Velero backup first if
> anything real is on it.

### 8.1 What is reversible and what is not

| Action | Reversible? |
| --- | --- |
| Uninstall the `zfs-localpv` chart (comment out `04-storage.yaml`) | **Yes.** The pool and every dataset survive. LocalPV-ZFS only issues commands against the host; it stores nothing itself. Reinstalling re-adopts existing datasets via the `ZFSVolume` CRs, provided those CRs still exist. |
| Delete a PVC on `fast-zfs`/`db-zfs` (`Retain`) | **Yes** — PV goes `Released`, dataset survives. Also means it leaks if you forget (§6.7). |
| Delete a PVC on `fast-block` (`Delete`) | **No** — the zvol is destroyed. |
| `zpool destroy tank` | **Sometimes** — `zpool import -D` can recover a destroyed pool *if the disks have not been written since*. Do not rely on it. |
| `zpool labelclear` / `talosctl wipe disk` after a destroy | **No.** Once vdev labels are gone, the pool is unrecoverable by any means. |
| Losing both members of one mirror | **No.** A 7×2 mirror survives one failure per vdev, not two in the same vdev. |

**The point of no return is overwriting the vdev labels**, not `zpool destroy`.
Between destroy and labelclear there is a narrow recovery window; after
labelclear or a disk wipe there is none.

### 8.2 Safe teardown order

1. **Stop the consumers first.** Comment `04-storage.yaml` out of
   `platform/sveltos/clusterprofiles/kustomization.yaml` and push. Sveltos
   uninstalls `zfs-localpv` and `snapshot-controller` and removes the
   StorageClasses. Wait for `openebs` pods to be gone:
   ```bash
   k get pods -n openebs
   k get sc
   ```
   Tearing down the pool while the CSI driver still holds mounts leaves stale
   mounts in the kubelet that outlive the pool.

2. **Delete the PVs.** `Retain` PVs hold nothing once the driver is gone, but
   they will confuse a re-install:
   ```bash
   k get pv | grep zfs.csi.openebs.io
   k delete pv <name>...
   ```

3. **Destroy the pool** from a one-shot privileged pod (§4.3):
   ```bash
   zpool status tank      # last look — confirm you are on the right box
   zpool destroy tank
   zpool import           # tank should now appear only under "destroyed"
   ```
   *Stop here if you might want it back.* `zpool import -D tank` recovers it
   while the labels are intact.

4. **Clear the labels** — the irreversible step:
   ```bash
   for d in /dev/disk/by-id/*Samsung_SSD_850*; do
     case "$d" in (*-part*) continue ;; esac
     zpool labelclear -f "$d"
   done
   ```
   Or, from outside the cluster, the §3 wipe: re-derive the device list from
   `t get disks` and run `t wipe disk sdb … sdp`.

### 8.3 Recreate

The whole point of `create-pool.sh` being idempotent and the layout being in
git: recreate is just the forward path again.

```bash
# 1. disks clean?
t get discoveredvolumes | grep -E ' sd[b-p]1 ' && echo "NOT CLEAN" || echo "clean"

# 2. rebuild the pool
./bootstrap/zfs/create-pool.sh          # prompts for YES

# 3. prove auto-import
t reboot && ./bootstrap/zfs/create-pool.sh   # must print "already exists"

# 4. re-enable the GitOps layer
#    uncomment 04-storage.yaml in platform/sveltos/clusterprofiles/kustomization.yaml
#    push, then §5.3–§5.7

# 5. re-run §6 in full
```

Data does **not** come back with the pool. Recreating `tank` gives you an empty
pool; restoring the contents is Velero's job (`04b-backup.yaml`,
`docs/runbooks/disaster-recovery.md`).

---

## 9. Standing rules once the pool is live

- **Before every Talos upgrade**: re-POST `r730-schematic.yaml` for the target
  version and confirm the zfs extension exists for it. A mismatch leaves the
  pool unimportable (§7.1).
- **Never** `talosctl upgrade` with a bare `ghcr.io/siderolabs/installer` image.
- **Monthly**: `zx chroot /host /sbin/zpool scrub tank`, then check
  `zx chroot /host /sbin/zpool status tank` a day later. Manual until observability
  is re-enabled.
- **Capacity**: keep the pool under 80% (~10 TiB of the ~12.7 TiB). COW
  fragments badly past that, and the damage is not undone by freeing space.
- **Quarterly**: restore a real PVC into a scratch namespace. An untested
  restore path is a hypothesis.
- **After every reboot**: confirm `tank` imported before assuming workloads are
  healthy.
- **Velero must be live before real data accumulates** — `04b-backup.yaml` is
  still commented out of the clusterprofiles kustomization.

---

## Appendix: what in this document is UNVERIFIED

Verified today (2026-08-25) by read-only inspection of the live node and
cluster, and by rendering the pinned charts locally:

- every fact in the §0 state table
- `t version`, `t get extensions`, `t get disks`, `t get discoveredvolumes`,
  `t get volumestatus`, `t memory`, `t read /proc/cmdline`,
  `t read /proc/modules` — commands and their real output
- `talosctl wipe disk` syntax and flags (`--help` on the installed client)
- `k get sc`, `k get csidrivers`, `k get pvc -A`, `k get crd`,
  `k get sveltosclusters`, `k get clusterprofiles`,
  `k -n flux-system get gitrepository` — commands and their real output
- chart resource names, container names, labels and mounts, from
  `helm template` of `zfs-localpv 2.11.0` and `piraeus/snapshot-controller 5.2.0`
  at the exact versions pinned in `04-storage.yaml`
- the §7.4b dual-snapshot-controller defect: both charts' rendered container
  specs, images (`v8.2.0` vs `v8.6.0`), leader-election args, and the
  `zfsController.snapshotController.enabled: true` default from
  `helm show values openebs-zfs/zfs-localpv --version 2.11.0`
- the `/sbin/zfs` chroot wrapper and the read-only `/host` mount, from the
  rendered `openebs-zfspv-bin` ConfigMap and DaemonSet spec
- **both schematic IDs, read back from Image Factory** with
  `GET https://factory.talos.dev/schematics/<id>`:
  `c86a996e…30eea` = intel-ucode + util-linux-tools + zfs (no `iscsi-tools`);
  `20115cfe…44ec` = the same plus `iscsi-tools` (§2.1, not chosen)
- the `.taskfiles/talos.yml` findings in §2.2 — the vanilla
  `ghcr.io/siderolabs/installer` image, `TALOS_VERSION` defaulting to `v1.9.1`,
  and `HUB_DIR = bootstrap/talos/hub` not existing
- the `extraKernelArgs` block quoted in §1.3 — verbatim from
  `bootstrap/talos/controlplane.yaml`, including the three `TODO: real PCI BDF`
  placeholders
- the §1.6 Longhorn gate `jq` command — **run against the live cluster**; it
  currently prints
  `STOP: ["monitoring/minio-data","tenants/etcd-data-kmc-arrakis-etcd-0","tenants/pvc-9cc2fe90-5f21-485e-95df-7af5bfcea181"]`
- the `u-lhNN` partition labels: re-confirmed 2026-08-25 as `u-lh01`…`u-lh15`
  (`sdb1`=`u-lh05`, `sdn1`=`u-lh01`, `sdo1`=`u-lh02`, `sdp1`=`u-lh03`), and
  all 15 still `ready` in `t get volumestatus`

**UNVERIFIED** — written from the repo and chart definitions, not executed,
because doing so would mutate the cluster or the node:

- §2.3 the 10–15 minute downtime budget — an estimate from this hardware's POST
  behaviour, not a measured run; and the iDRAC address/credentials, which are
  deliberately not in this repo
- §2 upgrade duration and return behaviour (no upgrade run from this branch)
- §3 wipe output (destructive)
- §4 `create-pool.sh` runtime output, `zpool status`/`list`/`get all` shapes,
  and the pool `SIZE` estimate (~12.7 TiB) — arithmetic from 7 × 2 TB mirrors,
  not measured
- §4.3 the `kubectl run --overrides` helper pod invocation (creating a pod is a
  mutation); its spec mirrors the known-good one in `create-pool.sh`
- §5.5–§5.7 expected output shapes for `openebs` pods, `zfsnodes` and the
  StorageClass listing (the `openebs` namespace does not exist yet)
- **all of §6** — no PVC, snapshot or DataVolume was created
- §7 symptom strings: the Helm ownership error in §7.4 and the default-class
  validation error in §7.5 are the standard upstream messages, not messages
  captured from this cluster
- §8 teardown commands (destructive)
