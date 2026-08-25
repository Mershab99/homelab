#!/usr/bin/env bash
# Create the "tank" zpool on the R730 (contraxia) — 7x 2-way mirrors across 14
# of the 15 Samsung SSD 850 PRO 2TB disks; the 15th is registered separately as
# a hot spare (`--spare`).
#
# One-time, hand-run, below the GitOps line (like the Talos machine config).
# Everything consuming the pool (OpenEBS LocalPV-ZFS, StorageClasses) is
# git-driven via Sveltos (platform/sveltos/clusterprofiles/04-storage.yaml).
#
# ---------------------------------------------------------------------------
# WHERE THIS SITS IN THE RUNBOOK — READ BEFORE RUNNING
#
# This script is step 3 of the storage refit. Steps 1 and 2 are hand-run by the
# operator and this script CANNOT and MUST NOT do them:
#
#   1. TEAR DOWN LONGHORN FIRST. Longhorn is still the default StorageClass on
#      contraxia and still serves live volumes (monitoring/minio-data 50Gi,
#      tenants/etcd-data-kmc-arrakis-etcd-0 4Gi — the arrakis tenant control
#      plane etcd — and one ~5428Mi tenant PVC). Back them up / drain them,
#      delete the Longhorn chart and its StorageClasses, and only then proceed.
#   2. UPGRADE TALOS STRAIGHT TO THE ZFS SCHEMATIC. Target image:
#        factory.talos.dev/metal-installer/\
#        c86a996e871ad7d755f8f99109cbb0fda2b2903ba4c1b76668b257e9a2030eea:v1.13.5
#      = intel-ucode + util-linux-tools + zfs (bootstrap/talos/r730-schematic.yaml,
#      already wired into bootstrap/talos/controlplane.yaml). iscsi-tools is
#      deliberately gone — Longhorn is already dead by this point.
#      This cycle changes ONLY the extension set plus the ZFS ARC cap
#      (zfs.zfs_arc_max=21474836480, 20 GiB of the node's 96 GB). The
#      intel_iommu=on / pcirebind / vfio kernel args are STRIPPED for this
#      upgrade; GPU passthrough is a separate later change.
#      Applying controlplane.yaml also drops all 15 UserVolumeConfigs, which
#      releases every /var/mnt/lhNN mount at once — safe ONLY because step 1
#      already happened. Each disk then still carries its old GPT+xfs
#      signature, so `talosctl wipe disk sdX` each one before step 3.
#   3. (this script) create the pool, then register the spare.
#
# NOT CHOSEN — documented escape hatch only: schematic
# 20115cfe3340492b9e161ae6a6bf7ffaddf79b08b02519e1d155f856362b44ec, which
# carries iscsi-tools AND zfs simultaneously so a pool can be built while
# Longhorn is still live and volumes migrated in place. That transitional
# path was rejected for this refit. Do not reach for it without a decision.
#
# ---------------------------------------------------------------------------
# HOW THIS TALKS TO ZFS
#
# There is no shell on a Talos host. The zfs system extension installs the ZFS
# userland into the *host* rootfs at /usr/local/sbin/{zpool,zfs}. Verified
# against siderolabs/extensions storage/zfs/zfs-service/main.go, which execs
# exactly:
#     /usr/local/sbin/zpool import -fal      (boot)
#     /usr/local/sbin/zfs   unmount -au      (shutdown)
#     /usr/local/sbin/zpool export -a        (shutdown)
# Note what is NOT there: no ZED (ZFS Event Daemon). See --spare below.
#
# So the helper container only needs a shell + chroot, NOT ZFS binaries.
# Verified by inspecting openebs/zfs-driver:2.11.0 directly: Alpine 3.23.5 +
# busybox 1.37.0, whose only payload is /usr/local/bin/zfs-driver (76 MB Go
# binary). `find / -name zpool -o -name zfs` returns NOTHING — the image ships
# no zpool, no zfs, and no bash. It does ship /bin/sh, /usr/sbin/chroot,
# /sbin/blkid, grep, awk, readlink, sed, sort, uniq. This script therefore:
#   - drives the pod with `sh` (busybox ash), never bash;
#   - mounts the host rootfs at /host and runs `chroot /host <hostzpool> ...`.
# That is exactly how the zfs-localpv node plugin itself does it (its
# openebs-zfspv-bin ConfigMap is a `chroot /host ... zfs "$@"` shim), so if
# this works, the CSI driver will too.
#
# The image is reused purely because it is already pinned in 04-storage.yaml;
# any image with busybox would do.
#
# ---------------------------------------------------------------------------
# Usage:
#   ./create-pool.sh --list        # report every Samsung disk and why it is / is not a candidate
#   ./create-pool.sh --create      # auto-select 14 free disks -> 7x 2-way mirrors (prompts)
#   ./create-pool.sh --spare       # register the 15th disk as a hot spare (prompts)
#   ./create-pool.sh --add         # ESCAPE HATCH: bolt one more mirror onto an existing pool
#   ./create-pool.sh --self-test   # geometry assertion check, no cluster needed
#
# --create is idempotent: it exits 0 if "tank" already exists or imports.
#
# Overrides (all optional, all env vars):
#   DISKS="<by-id> <by-id> ..."   explicit disk list instead of auto-selection
#   WANT_MIRRORS=7                expected mirror count for --create (asserted, not advisory)
#   POOL / NODE / NS / POD / IMAGE / MODEL_PATTERN
# ---------------------------------------------------------------------------
set -euo pipefail

POOL="${POOL:-tank}"
NS="${NS:-kube-system}"               # PSA privileged-exempt — verified in
                                      # bootstrap/talos/_patches/03-apiserver-hardening.yaml:
                                      # enforce=baseline cluster-wide, exemptions.namespaces=[kube-system].
                                      # A privileged pod is rejected in any OTHER namespace.
POD="${POD:-zfs-pool-create}"
IMAGE="${IMAGE:-openebs/zfs-driver:2.11.0}"   # matches the zfs-localpv chart pin in 04-storage.yaml
NODE="${NODE:-r730}"                  # the machine that physically holds the disks
MODEL_PATTERN="${MODEL_PATTERN:-Samsung_SSD_850}"   # matches /dev/disk/by-id/ata-Samsung_SSD_850_PRO_2TB_<serial>
WANT_MIRRORS="${WANT_MIRRORS:-7}"     # 7x 2-way mirrors. NOT advisory — asserted twice, see below.
DISKS="${DISKS:-}"                    # explicit by-id paths; empty = auto-select for --create
WANT_DISKS=$((WANT_MIRRORS * 2))      # 14 data disks; the 15th is the spare

MODE=""
case "${1:-}" in
  --list)      MODE=list ;;
  --create)    MODE=create ;;
  --add)       MODE=add ;;
  --spare)     MODE=spare ;;
  --self-test) MODE=self-test ;;
  *)
    echo "usage: $0 --list | --create | --spare | --add | --self-test" >&2
    echo "       (DISKS='<by-id> ...' overrides auto-selection)" >&2
    exit 2 ;;
esac

# --- geometry assertion ---------------------------------------------------
# THE point of this script. `zpool create tank d1 d2 ... d14` is valid, silent,
# irreversible, and gives a 14-wide STRIPE with zero redundancy: one dead SSD
# out of fifteen takes the whole pool with it. zpool will not warn. So the vdev
# spec is asserted BEFORE anything is written, and the resulting pool is
# re-asserted against real `zpool status` AFTER.
#
# Also rejects raw /dev/sdX members. sdX is not stable here: the disks hang off
# megaraid_sas and the kernel enumerates them in controller order, which
# reshuffles across boots. Live proof on this node — Talos UserVolume -> device
# mapping is already scrambled relative to disk order: u-lh01=/dev/sdn,
# u-lh04=/dev/sde, u-lh05=/dev/sdb. A mirror built on sdX names can silently
# become a mirror of a disk with itself's neighbour after a reboot.
#
# Args: $1 = expected mirror count, rest = the vdev spec tokens.
assert_geometry() {
  local want_mirrors=$1; shift
  local mirrors=0 members=0 run=0 tok dups
  for tok in "$@"; do
    if [ "$tok" = "mirror" ]; then
      if [ "$mirrors" -gt 0 ] && [ "$run" -ne 2 ]; then
        echo "ERROR: mirror #$mirrors has $run members, want 2" >&2; return 1
      fi
      mirrors=$((mirrors + 1)); run=0
    else
      case "$tok" in
        /dev/disk/by-id/*) ;;
        *) echo "ERROR: vdev member '$tok' is not a stable /dev/disk/by-id path" >&2; return 1 ;;
      esac
      run=$((run + 1)); members=$((members + 1))
    fi
  done
  [ "$mirrors" -gt 0 ]                  || { echo "ERROR: vdev spec has no mirror groups — that is a STRIPE" >&2; return 1; }
  [ "$run" -eq 2 ]                      || { echo "ERROR: last mirror has $run members, want 2" >&2; return 1; }
  [ "$mirrors" -eq "$want_mirrors" ]    || { echo "ERROR: built $mirrors mirror groups, want exactly $want_mirrors" >&2; return 1; }
  [ "$members" -eq $((want_mirrors * 2)) ] || { echo "ERROR: built $members members, want $((want_mirrors * 2))" >&2; return 1; }
  # `|| true` on grep: it exits 1 on no-match, which pipefail would turn into a
  # spurious function failure for an all-"mirror" spec.
  dups=$(printf '%s\n' "$@" | grep -v '^mirror$' | sort | uniq -d || true)
  [ -z "$dups" ] || { echo "ERROR: duplicate device in vdev spec: $dups" >&2; return 1; }
}

# ponytail: one runnable check, no framework, no cluster. `--self-test` proves
# the assertion accepts N x 2-way and rejects every way it can silently go wrong.
if [ "$MODE" = "self-test" ]; then
  D=/dev/disk/by-id/ata-Samsung_SSD_850_PRO_2TB_S3D4NX0J80
  mkspec() {  # $1 = disk count -> "mirror d1 d2 mirror d3 d4 ..."
    local n out=""
    for n in $(seq 1 "$1"); do
      [ $(((n - 1) % 2)) -eq 0 ] && out="$out mirror"
      out="$out ${D}${n}"
    done
    printf '%s' "$out"
  }
  reject() {  # $1 = description, $2 = expected mirrors, $3 = spec that must be refused
    # shellcheck disable=SC2086 # deliberate word-splitting of the vdev spec
    if assert_geometry "$2" $3 >/dev/null 2>&1; then
      echo "SELF-TEST FAIL: accepted $1" >&2; exit 1
    fi
  }
  good14=$(mkspec 14)
  good8=$(mkspec 8)
  # shellcheck disable=SC2086
  assert_geometry 7 $good14 >/dev/null || { echo "SELF-TEST FAIL: valid 7x2 spec rejected" >&2; exit 1; }
  # shellcheck disable=SC2086
  assert_geometry 4 $good8  >/dev/null || { echo "SELF-TEST FAIL: valid 4x2 spec rejected" >&2; exit 1; }
  reject "a 14-wide stripe"        7 "${good14//mirror /}"
  reject "a single 14-way mirror"  7 "mirror ${good14//mirror /}"
  reject "6 mirrors when 7 asked"  7 "$(mkspec 12)"
  reject "8 mirrors when 7 asked"  7 "$(mkspec 16)"
  reject "an odd trailing disk"    7 "$good14 ${D}15"
  reject "a 3-member mirror"       4 "mirror ${D}1 ${D}2 ${D}3 mirror ${D}4 ${D}5 mirror ${D}6 ${D}7 mirror ${D}8 ${D}9"
  reject "a duplicated disk"       7 "${good14/${D}14/${D}13}"
  reject "an unstable sdX path"    7 "${good14/${D}14/\/dev\/sdp}"
  echo "self-test OK: 7x2 + 4x2 accepted; stripe / 14-way / short / long / odd / 3-way / dup / sdX all refused"
  exit 0
fi

if ! command -v kubectl >/dev/null; then
  echo "ERROR: kubectl not installed" >&2
  exit 1
fi
if [ -z "${KUBECONFIG:-}" ] && [ ! -f "$HOME/.kube/config" ]; then
  echo "ERROR: KUBECONFIG not set and ~/.kube/config absent" >&2
  exit 1
fi
# Wrong-cluster guard: the pod is pinned to this node, so if it does not exist
# here we are pointed at the wrong kubeconfig context and must not proceed.
if ! kubectl get node "$NODE" >/dev/null 2>&1; then
  echo "ERROR: node '$NODE' not found in the current context" >&2
  echo "       ($(kubectl config current-context 2>/dev/null || echo 'unknown context')) — wrong cluster?" >&2
  exit 1
fi

# --- Longhorn tripwire ----------------------------------------------------
# Read-only. Step 1 of the runbook is "tear down Longhorn". If it is still
# here, the operator skipped it, and every disk below is still load-bearing.
# --list is exempt: it writes nothing and is the tool for watching the teardown.
if [ "$MODE" != "list" ] &&
   { kubectl get sc longhorn >/dev/null 2>&1 || kubectl get ns longhorn-system >/dev/null 2>&1; }; then
  echo "ERROR: Longhorn is still installed on this cluster." >&2
  kubectl get sc 2>/dev/null | sed 's/^/       /' >&2
  echo "       Runbook step 1 (tear down Longhorn) has not completed. Its disks are" >&2
  echo "       live and one of them backs the arrakis tenant etcd. REFUSING." >&2
  echo "       Override only if you know why: LONGHORN_OK=1 $0 $1" >&2
  [ "${LONGHORN_OK:-}" = "1" ] || exit 1
  echo "       LONGHORN_OK=1 set — continuing anyway." >&2
fi

cleanup() { kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Launching privileged ZFS helper pod ($IMAGE) on node $NODE"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
spec:
  restartPolicy: Never
  nodeName: ${NODE}          # the disks are physical — never let the scheduler pick
  hostNetwork: true          # no CNI dependency during bootstrap
  hostPID: true              # REQUIRED: /proc/mounts is per-reader (it is /proc/self/mounts),
                             # so the only way to see the HOST mount table is to read PID 1's,
                             # and PID 1 is only visible with the host PID namespace.
                             # Without this the "is it mounted?" gate silently passes everything.
  tolerations:               # r730 is a control-plane node; tolerate the taint if it is ever re-added
    - operator: Exists
  containers:
    - name: zfs
      image: ${IMAGE}
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: dev
          mountPath: /dev    # carries /dev/zfs AND the udev-populated /dev/disk/by-id/ links
        - name: host-root
          mountPath: /host
          mountPropagation: HostToContainer   # so /host/{dev,proc,sys,var} follow the host
          readOnly: true                      # chroot only needs exec; ZFS ioctls go via /dev/zfs
  volumes:
    - name: dev
      hostPath:
        path: /dev
        type: Directory
    - name: host-root
      hostPath:
        path: /
        type: Directory
EOF
kubectl -n "$NS" wait --for=condition=Ready pod/"$POD" --timeout=180s

# sh (not bash — the image has none). Args after `--` land in $1.. inside the
# quoted heredoc, which keeps the in-pod scripts free of escaping.
zexec() { kubectl -n "$NS" exec -i "$POD" -- sh -s -- "$@"; }

echo "==> Pod preflight (fail closed on anything missing)"
if ! zexec "$MODEL_PATTERN" <<'INNER'
pattern=$1
for b in blkid readlink chroot grep awk; do
  command -v "$b" >/dev/null || { echo "  missing '$b' in the helper image — cannot vet disks safely" >&2; exit 1; }
done
test -c /dev/zfs || { echo "  /dev/zfs missing — zfs kernel module not loaded" >&2; exit 1; }
test -d /sys/module/zfs || { echo "  /sys/module/zfs missing — node is not on a zfs-extension image" >&2; exit 1; }
# The host mount table, via PID 1 (see hostPID above). Fail closed if unreadable,
# and sanity-check that it really is the host's and not the container's.
test -r /proc/1/mounts || { echo "  /proc/1/mounts unreadable — hostPID not in effect" >&2; exit 1; }
grep -q ' /var ' /proc/1/mounts || { echo "  /proc/1/mounts has no host /var — this is not the host mount table" >&2; exit 1; }
# The by-id links this whole script depends on must actually be present here.
n=0
for link in /dev/disk/by-id/*"$pattern"*; do
  [ -e "$link" ] || continue
  case "$link" in (*-part*) continue ;; esac
  n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "  no /dev/disk/by-id/*${pattern}* links inside the pod — /dev hostPath or udev is wrong" >&2; exit 1; }
echo "  ok: /dev/zfs, host mount table, ${n} '${pattern}' by-id link(s)"
INNER
then
  echo "ERROR: helper pod preflight failed. Nothing was touched." >&2
  echo "       If /dev/zfs is missing, the node is not yet on schematic" >&2
  echo "       c86a996e871ad7d755f8f99109cbb0fda2b2903ba4c1b76668b257e9a2030eea:v1.13.5." >&2
  echo "       Check: talosctl --talosconfig bootstrap/talos/talosconfig -e ${NODE} -n ${NODE} get extensions" >&2
  exit 1
fi

echo "==> Locating the host ZFS userland"
# Talos extensions install to /usr/local/sbin (verified against
# siderolabs/extensions storage/zfs). The others are fallbacks for a non-Talos
# host. Probed rather than hardcoded so a layout change fails here with a clear
# message instead of mid-create.
HOST_ZPOOL=$(zexec <<'INNER'
for p in /usr/local/sbin /usr/local/bin /sbin /usr/sbin /bin /usr/bin; do
  if [ -x "/host$p/zpool" ]; then printf '%s/zpool\n' "$p"; exit 0; fi
done
exit 1
INNER
) || {
  echo "ERROR: no zpool binary in the host rootfs — the zfs system extension is not installed." >&2
  exit 1
}
echo "    host zpool: $HOST_ZPOOL"

# Run the *host* zpool inside the host rootfs. Paths passed here (e.g.
# /dev/disk/by-id/...) resolve identically in and out of the chroot because
# /host/dev is the same host /dev we enumerate from.
zpool_host() { zexec "$HOST_ZPOOL" "$@" <<'INNER'
bin=$1; shift
exec chroot /host "$bin" "$@"
INNER
}

# --- disk enumeration -----------------------------------------------------
# One in-pod implementation, two output modes, so --list and auto-selection can
# never disagree about what "free" means.
#   report : human table on stdout
#   quiet  : one FREE by-id path per line, nothing else
#
# "Free" = the by-id link resolves to a block device that is (a) not mounted in
# the HOST mount table and (b) carries no blkid signature at all — no
# partition table, no filesystem, no leftover zfs_member label.
enumerate() { zexec "$MODEL_PATTERN" "$1" <<'INNER'
pattern=$1; mode=$2
free=0; busy=0; total=0
for link in /dev/disk/by-id/*"$pattern"*; do
  [ -e "$link" ] || continue                    # unmatched glob stays literal
  case "$link" in (*-part*) continue ;; esac    # leading ( keeps $( ) parsing balanced
  total=$((total + 1))
  dev=$(readlink -f "$link")
  why=""
  mnt=$(grep -E "^${dev}[0-9]* " /proc/1/mounts 2>/dev/null | awk '{print $2}' | tr '\n' ',')
  [ -n "$mnt" ] && why="MOUNTED at ${mnt%,}"
  sig=$(blkid "$dev" "$dev"[0-9]* 2>/dev/null | tr '\n' ';' || true)
  [ -z "$why" ] && [ -n "$sig" ] && why="HAS SIGNATURE"
  if [ -n "$why" ]; then
    busy=$((busy + 1))
    [ "$mode" = "quiet" ] && continue
    printf '  [in use ] %s -> %s\n            %s\n' "${link##*/}" "$dev" "$why"
    [ -n "$sig" ] && printf '            %s\n' "${sig%;}"
  else
    free=$((free + 1))
    if [ "$mode" = "quiet" ]; then printf '%s\n' "$link"; continue; fi
    printf '  [FREE   ] %s -> %s\n' "${link##*/}" "$dev"
  fi
done
if [ "$mode" != "quiet" ]; then
  echo
  echo "  $total disk(s) matching '$pattern': $free free, $busy in use."
  echo "  Free disks pair into $((free / 2)) 2-way mirror(s)."
fi
INNER
}

# by-id -> "<by-id> <kernel-name> <wwn-link>", so the confirmation banner can be
# cross-checked against `talosctl get disks` (whose wwid field is the same value
# in naa.<hex> form, e.g. naa.5002538c4075d725 == wwn-0x5002538c4075d725).
resolve_ids() { # shellcheck disable=SC2086
  zexec $1 <<'INNER'
for link in "$@"; do
  dev=$(readlink -f "$link")
  wwn=""
  for w in /dev/disk/by-id/wwn-*; do
    [ -e "$w" ] || continue
    [ "$(readlink -f "$w")" = "$dev" ] && { wwn=${w##*/}; break; }
  done
  printf '%s %s %s\n' "$link" "${dev##*/}" "${wwn:-<no-wwn-link>}"
done
INNER
}

if [ "$MODE" = "list" ]; then
  echo "==> ${MODEL_PATTERN} disks — candidate status"
  enumerate report
  echo
  echo "  A disk becomes FREE only after Longhorn is gone, its UserVolumeConfig is"
  echo "  out of the APPLIED Talos machine config, and 'talosctl wipe disk sdX' has run."
  echo "  That includes a leftover 'zfs_member' label from an aborted attempt —"
  echo "  'talosctl wipe disk sdX' clears it too."
  exit 0
fi

# --- disk selection -------------------------------------------------------
if [ "$MODE" = "spare" ]; then
  NEED=1
else
  NEED=$WANT_DISKS
fi

if [ -z "$DISKS" ] && [ "$MODE" = "add" ]; then
  # --add is the escape hatch, not the happy path. Guessing which of the
  # remaining disks to permanently staple onto a live pool is not a decision
  # this script gets to make.
  echo "ERROR: --add requires an explicit DISKS list (an even number of by-id paths)." >&2
  echo "       Run '$0 --list' first." >&2
  exit 1
fi

if [ -z "$DISKS" ]; then
  echo "==> Auto-selecting free ${MODEL_PATTERN} disks"
  DISKS=$(enumerate quiet)
  [ -n "$DISKS" ] || { echo "ERROR: no free ${MODEL_PATTERN} disks. Run '$0 --list' to see why." >&2; exit 1; }
  FOUND=$(printf '%s\n' "$DISKS" | grep -c . || true)
  if [ "$MODE" = "create" ] && [ "$FOUND" -lt "$NEED" ]; then
    echo "ERROR: need $NEED free disks for ${WANT_MIRRORS}x 2-way mirrors, found $FOUND." >&2
    echo "       Run '$0 --list' to see what is holding the rest." >&2
    exit 1
  fi
  # Take exactly what this mode needs and leave the rest alone — on --create
  # that deliberately leaves the 15th disk untouched for --spare.
  # sed, not head: head closes the pipe early, printf takes SIGPIPE, and
  # `set -o pipefail` would turn that into a spurious abort.
  DISKS=$(printf '%s\n' "$DISKS" | sed -n "1,${NEED}p")
  [ "$FOUND" -le "$NEED" ] || echo "    $FOUND free, using the first $NEED (lowest serial first)."
else
  echo "==> Using the explicit DISKS list"
fi

# shellcheck disable=SC2086 # DISKS is a deliberate whitespace-separated list
NDISKS=$(printf '%s\n' $DISKS | grep -c . || true)

# --- safety gate ----------------------------------------------------------
# Re-vets every disk immediately before writing, including an explicit DISKS
# list that never went through enumerate(). Refuses anything mounted or
# carrying any signature — so this script cannot destroy a live disk even if
# it is handed one by mistake. There is no -f anywhere in this file.
echo "==> Safety gate on the ${NDISKS} selected disk(s)"
# shellcheck disable=SC2086
if ! zexec $DISKS <<'INNER'
rc=0
[ -r /proc/1/mounts ] || { echo "  cannot read the host mount table — failing closed" >&2; exit 1; }
for link in "$@"; do
  case "$link" in
    /dev/disk/by-id/*) ;;
    *) echo "  $link: not a /dev/disk/by-id path — refusing (sdX names reorder across boots)" >&2; rc=1; continue ;;
  esac
  if [ ! -e "$link" ]; then echo "  $link: does not exist" >&2; rc=1; continue; fi
  dev=$(readlink -f "$link")
  if [ ! -b "$dev" ]; then echo "  $link -> $dev: not a block device" >&2; rc=1; continue; fi
  mnt=$(grep -E "^${dev}[0-9]* " /proc/1/mounts | awk '{print $2}' | tr '\n' ',')
  if [ -n "$mnt" ]; then
    echo "  $link -> $dev: MOUNTED on the host at ${mnt%,}. REFUSING." >&2
    rc=1; continue
  fi
  sig=$(blkid "$dev" "$dev"[0-9]* 2>/dev/null | tr '\n' ';' || true)
  if [ -n "$sig" ]; then
    echo "  $link -> $dev: still has a filesystem/partition signature. REFUSING." >&2
    echo "      ${sig%;}" >&2
    echo "      Wipe it first: talosctl wipe disk ${dev##*/}" >&2
    rc=1; continue
  fi
  echo "  $link -> $dev: clean"
done
exit $rc
INNER
then
  echo "ERROR: one or more selected disks are not safe to use. Nothing was written." >&2
  exit 1
fi

POOL_EXISTS=no
if zpool_host list "$POOL" >/dev/null 2>&1 || zpool_host import -N "$POOL" >/dev/null 2>&1; then
  POOL_EXISTS=yes
fi

# --- --spare --------------------------------------------------------------
if [ "$MODE" = "spare" ]; then
  if [ "$POOL_EXISTS" != "yes" ]; then
    echo "ERROR: pool '$POOL' does not exist — run '$0 --create' first." >&2
    exit 1
  fi
  [ "$NDISKS" -eq 1 ] || { echo "ERROR: --spare takes exactly 1 disk, got $NDISKS." >&2; exit 1; }
  echo
  echo "Register as a HOT SPARE for '$POOL':"
  # shellcheck disable=SC2086
  resolve_ids "$DISKS" | awk '{printf "  %s\n      (%s, %s)\n", $1, $2, $3}'
  echo
  echo "  ⚠ Talos ships NO ZED. Verified: siderolabs/extensions storage/zfs runs only"
  echo "    'zpool import -fal' at boot and 'zfs unmount -au' + 'zpool export -a' at"
  echo "    shutdown — there is no zfs-zed service. This spare will therefore NOT"
  echo "    auto-activate on a disk fault. It is a WARM spare: 'zpool status' shows"
  echo "    it, but recovery is one manual command:"
  echo "        chroot /host ${HOST_ZPOOL} replace ${POOL} <failed-by-id> <spare-by-id>"
  read -r -p "Type YES: " ANSWER
  [ "$ANSWER" = "YES" ] || { echo "Aborted."; exit 1; }
  # ashift is per-vdev and is applied when the spare is activated into a mirror;
  # passing it here keeps the whole pool on one explicit value.
  # shellcheck disable=SC2086
  zpool_host add -o ashift=12 "$POOL" spare $DISKS
  zpool_host status "$POOL"
  exit 0
fi

# --- build + assert the vdev spec -----------------------------------------
if [ $((NDISKS % 2)) -ne 0 ] || [ "$NDISKS" -lt 2 ]; then
  echo "ERROR: got $NDISKS disk(s); need an even number >= 2 for 2-way mirrors." >&2
  exit 1
fi
NEW_MIRRORS=$((NDISKS / 2))

# Pairing is lexical by serial. Deliberate: all 15 disks sit on the same PERC
# controller and the same backplane, so there is no failure domain to spread a
# mirror across. Pass DISKS explicitly if you want a specific pairing.
VDEV_ARGS=""
i=0
for d in $DISKS; do
  if [ $((i % 2)) -eq 0 ]; then VDEV_ARGS="$VDEV_ARGS mirror"; fi
  VDEV_ARGS="$VDEV_ARGS $d"
  i=$((i + 1))
done

# Assertion #1 of 2 — on the spec, before anything is written. For --create
# this is the hard 7x2 requirement; --add asserts whatever it was handed.
if [ "$MODE" = "create" ]; then
  ASSERT_MIRRORS=$WANT_MIRRORS
  if [ "$NEW_MIRRORS" -ne "$WANT_MIRRORS" ]; then
    echo "ERROR: --create builds exactly ${WANT_MIRRORS}x 2-way mirrors (${WANT_DISKS} disks); got $NDISKS disk(s)." >&2
    echo "       Set WANT_MIRRORS=<n> to deliberately build a different geometry." >&2
    exit 1
  fi
else
  ASSERT_MIRRORS=$NEW_MIRRORS
fi
# shellcheck disable=SC2086
assert_geometry "$ASSERT_MIRRORS" $VDEV_ARGS || { echo "Refusing to touch '$POOL' with a bad vdev spec." >&2; exit 1; }

# --- confirmation banner --------------------------------------------------
echo
echo "Intended layout: ${NEW_MIRRORS}x 2-way mirror (usable ~= ${NEW_MIRRORS} x 2TB, half the raw)"
echo "Cross-check each wwn- against 'talosctl get disks' (wwid naa.<hex> == wwn-0x<hex>):"
# shellcheck disable=SC2086
resolve_ids "$DISKS" | awk '
  NR % 2 == 1 { a1 = $1; a2 = $2; a3 = $3 }
  NR % 2 == 0 { printf "  mirror-%d:\n", (NR/2)-1
                printf "      %s\n        (%s, %s)\n", a1, a2, a3
                printf "      %s\n        (%s, %s)\n", $1, $2, $3 }'
echo

# --- create ---------------------------------------------------------------
if [ "$MODE" = "create" ]; then
  if [ "$POOL_EXISTS" = "yes" ]; then
    echo "Pool '$POOL' already exists — nothing to do."
    zpool_host status "$POOL"
    exit 0
  fi
  echo "⚠ DESTRUCTIVE: this writes ZFS vdev labels to all ${NDISKS} disks above."
  read -r -p "Create pool '$POOL' as ${WANT_MIRRORS}x 2-way mirrors. Type YES: " ANSWER
  [ "$ANSWER" = "YES" ] || { echo "Aborted."; exit 1; }

  echo "==> Creating pool"
  # Pool properties (-o) — permanent or near-permanent, so each is explicit:
  #
  #   ashift=12   MANDATORY and IMMUTABLE. Measured on this node:
  #               /sys/block/sdb/queue/physical_block_size = 512 and
  #               logical_block_size = 512, so ZFS's auto-detect picks ashift=9.
  #               These are 512e NAND SSDs with 8K pages; ashift=9 permanently
  #               bakes in read-modify-write amplification and can only be undone
  #               by destroying and rebuilding the pool. Get it right once, here.
  #   autotrim=on Measured: /sys/block/sdb/queue/discard_max_bytes = 0 — the PERC
  #               megaraid_sas path does NOT pass UNMAP through today, so this is
  #               a no-op right now. Set anyway: harmless when unsupported, and it
  #               starts working for free if the controller is ever flipped to
  #               true HBA/IT mode. Verify with `zpool status -t tank`.
  #   cachefile=none
  #               Talos imports at boot with `zpool import -fal` (scan-based, no
  #               cachefile — verified in siderolabs/extensions zfs-service), and
  #               a zpool.cache written from inside this container would land on
  #               ephemeral storage anyway. Explicit so a stale cache is never
  #               consulted.
  #   -m legacy   The pool root must never auto-mount: on Talos only /var is
  #               writable, and zfs-localpv creates every dataset with
  #               `-o mountpoint=legacy` and mounts it at the kubelet target
  #               itself. Children inherit legacy — exactly what the driver wants.
  #
  # Root-dataset properties (-O), inherited by every zfs-localpv volume:
  #
  #   compression=lz4   Not zstd. The pool backs Postgres (db-zfs) and KubeVirt
  #                     block devices (fast-block), where write latency matters
  #                     more than ratio; lz4 costs ~nothing and early-aborts on
  #                     already-compressed VM images, while zstd-3 is several
  #                     times the CPU for a ratio we do not need on 28TB raw.
  #                     Per-volume override stays available via the StorageClass
  #                     `compression` parameter, so a cold archive dataset can opt
  #                     into zstd later without rebuilding the pool.
  #   atime=off         Nothing here reads atime; leaving it on turns every read
  #                     into a metadata write.
  #   xattr=sa          Store xattrs in the dnode instead of a hidden directory —
  #                     the standard container-workload setting.
  #   acltype=posixacl  Pairs with xattr=sa; some workloads set POSIX ACLs and
  #                     silently fail without it.
  #   dnodesize=auto    Required to actually benefit from xattr=sa.
  #   dedup=off         Explicit. Dedup is the classic ZFS footgun (RAM-hungry,
  #                     effectively irreversible); never let it be turned on by
  #                     accident or inheritance.
  #
  # No `-f`. The safety gate above already proved every disk is clean, so a force
  # flag could only ever mask a mistake.
  # shellcheck disable=SC2086
  zpool_host create \
    -o ashift=12 \
    -o autotrim=on \
    -o cachefile=none \
    -m legacy \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    -O acltype=posixacl \
    -O dnodesize=auto \
    -O dedup=off \
    "$POOL" $VDEV_ARGS
  EXPECT_MIRRORS=$NEW_MIRRORS
fi

# --- add (escape hatch) ---------------------------------------------------
if [ "$MODE" = "add" ]; then
  if [ "$POOL_EXISTS" != "yes" ]; then
    echo "ERROR: pool '$POOL' does not exist — use --create first." >&2
    exit 1
  fi
  HAVE_MIRRORS=$(zpool_host status "$POOL" | grep -c '^[[:space:]]*mirror-[0-9]' || true)
  echo "Pool '$POOL' currently has $HAVE_MIRRORS mirror vdev(s)."
  echo "⚠ A vdev added to a pool cannot be removed. Adding a bare disk here would"
  echo "  permanently staple a non-redundant stripe member onto the pool — hence"
  echo "  the geometry assertion above."
  read -r -p "Add ${NEW_MIRRORS} mirror(s) to '$POOL'. Type YES: " ANSWER
  [ "$ANSWER" = "YES" ] || { echo "Aborted."; exit 1; }

  echo "==> Adding mirror(s)"
  # ashift is a per-vdev property: it is NOT inherited from the pool, so it must
  # be repeated on every add or the new vdev silently gets ashift=9.
  # shellcheck disable=SC2086
  zpool_host add -o ashift=12 "$POOL" $VDEV_ARGS
  EXPECT_MIRRORS=$((HAVE_MIRRORS + NEW_MIRRORS))
fi

# --- assertion #2 of 2 ----------------------------------------------------
echo "==> Verifying resulting geometry"
# Belt-and-braces: assert against what ZFS actually built, not what we asked
# for. A stripe would show zero "mirror-N" lines.
ACTUAL_MIRRORS=$(zpool_host status "$POOL" | grep -c '^[[:space:]]*mirror-[0-9]' || true)
if [ "$ACTUAL_MIRRORS" -ne "$EXPECT_MIRRORS" ]; then
  echo "ERROR: pool '$POOL' has $ACTUAL_MIRRORS mirror vdevs, expected $EXPECT_MIRRORS." >&2
  echo "       DO NOT put data on it — inspect before proceeding." >&2
  zpool_host status "$POOL" >&2
  exit 1
fi
echo "    OK: $ACTUAL_MIRRORS mirror vdev(s)"
zpool_host status "$POOL"
zpool_host get ashift,autotrim,cachefile,compression,atime "$POOL" || true

# ashift is the one mistake that cannot be undone without destroying the pool,
# and `zpool get ashift` only reports the create-time pool default — it does not
# prove what each vdev actually got. zdb reads the on-disk labels, which does.
# Soft check: `zdb -C` needs a cachefile (we set cachefile=none) so `-e` is the
# fallback; if neither works, say so rather than pretend it was verified.
echo "==> Verifying per-vdev ashift on disk (zdb labels)"
ASHIFTS=$(zexec "${HOST_ZPOOL%zpool}zdb" "$POOL" <<'INNER' || true
bin=$1; pool=$2
chroot /host "$bin" -C "$pool" 2>/dev/null || chroot /host "$bin" -e -C "$pool" 2>/dev/null
INNER
) || true
# xargs (not `tr '\n' ' '`) so the result has no trailing space to defeat the case match.
ASHIFTS=$(printf '%s\n' "$ASHIFTS" | grep -o 'ashift: [0-9]*' | awk '{print $2}' | sort -u | xargs || true)
case "$ASHIFTS" in
  "12") echo "    OK: every vdev is ashift=12" ;;
  "")   echo "    UNVERIFIED: zdb produced no ashift lines. Check by hand before storing data:" >&2
        echo "                chroot /host ${HOST_ZPOOL%zpool}zdb -e -C ${POOL} | grep ashift" >&2 ;;
  *)    echo "ERROR: mixed or wrong ashift across vdevs: [$ASHIFTS] — want exactly 12." >&2
        echo "       This is PERMANENT. Do not put data on this pool." >&2
        exit 1 ;;
esac

cat <<EOF

============================================================
 Next:
   1. ${0##*/} --spare      — register the 15th disk as a warm
      spare (manual activation only; Talos ships no ZED).
   2. Reboot the node once and re-run --create — it must print
      "already exists" (auto-import via the zfs extension's
      \`zpool import -fal\`). If the pool does NOT import on
      boot, fix that BEFORE any data lands on it.
   3. Let Sveltos install zfs-localpv + the StorageClasses
      (platform/sveltos/clusterprofiles/04-storage.yaml) and
      make fast-zfs the default class.
   4. Confirm the ARC cap took: it is set via the Talos kernel
      arg zfs.zfs_arc_max=21474836480 (20 GiB of 96 GB), not
      by this script.
============================================================
EOF
