#!/usr/bin/env bash
# Create the "tank" zpool on the R730 — 7x 2-way mirrors from the 15 Samsung
# 850 SSDs (14 used, the 15th left untouched as an in-chassis warm spare).
#
# One-time, hand-run, below the GitOps line (like the Talos machine config).
# Everything consuming the pool (OpenEBS LocalPV-ZFS, StorageClasses) is
# git-driven via Sveltos (platform/sveltos/clusterprofiles/04-storage.yaml).
#
# Idempotent: exits 0 if "tank" already exists/imports. Destructive on first
# run (writes vdev labels to 14 disks) — prompts before creating.
#
# Pre-reqs:
#   - KUBECONFIG pointed at the bare-metal cluster (contraxia)
#   - Talos running the zfs-extension image (r730-schematic.yaml) — the disks
#     must already be wiped (talosctl wipe disk, see docs/runbooks)
set -euo pipefail

POOL="tank"
NS="kube-system"                      # privileged PSA exempt; openebs ns may not exist yet
POD="zfs-pool-create"
IMAGE="openebs/zfs-driver:2.11.0"     # matches the zfs-localpv chart pin in 04-storage.yaml
MODEL_PATTERN="Samsung_SSD_850"
DATA_DISKS=14                         # 7 mirrors; disk 15 stays as warm spare

if ! command -v kubectl >/dev/null; then
  echo "ERROR: kubectl not installed" >&2
  exit 1
fi
if [ -z "${KUBECONFIG:-}" ] && [ ! -f "$HOME/.kube/config" ]; then
  echo "ERROR: KUBECONFIG not set and ~/.kube/config absent" >&2
  exit 1
fi

cleanup() { kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Launching privileged ZFS helper pod ($IMAGE)"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
spec:
  restartPolicy: Never
  hostNetwork: true
  containers:
    - name: zfs
      image: ${IMAGE}
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: dev
          mountPath: /dev
  volumes:
    - name: dev
      hostPath:
        path: /dev
EOF
kubectl -n "$NS" wait --for=condition=Ready pod/"$POD" --timeout=180s

zexec() { kubectl -n "$NS" exec -i "$POD" -- bash -s; }

echo "==> Checking zfs kernel module on the host"
if ! zexec <<'INNER'
test -d /sys/module/zfs
INNER
then
  echo "ERROR: zfs kernel module not loaded — is the node running the zfs-extension image?" >&2
  echo "       (r730-schematic.yaml, install.image in controlplane.yaml)" >&2
  exit 1
fi

echo "==> Checking for existing pool '$POOL'"
if zexec <<INNER
zpool list ${POOL} >/dev/null 2>&1 || zpool import -N ${POOL} >/dev/null 2>&1
INNER
then
  echo "Pool '$POOL' already exists:"
  zexec <<INNER
zpool status ${POOL}
INNER
  exit 0
fi

echo "==> Discovering ${MODEL_PATTERN} disks by-id"
# one by-id link per physical disk: skip partitions, dedupe wwn-/ata- aliases
# by resolved block device, stable sort. NOTE: pattern hardcoded in the quoted
# heredoc — keep in sync with MODEL_PATTERN above.
DISKS=$(zexec <<'INNER'
set -e
for link in /dev/disk/by-id/*Samsung_SSD_850*; do
  case "$link" in (*-part*) continue ;; esac   # leading ( keeps $( ) parsing balanced
  echo "$(readlink -f "$link") $link"
done | sort | awk '!seen[$1]++ {print $2}'
INNER
)
COUNT=$(echo "$DISKS" | grep -c . || true)
if [ "$COUNT" -lt "$DATA_DISKS" ]; then
  echo "ERROR: found $COUNT ${MODEL_PATTERN} disks, need at least ${DATA_DISKS}:" >&2
  echo "$DISKS" >&2
  exit 1
fi

POOL_DISKS=$(echo "$DISKS" | head -n "$DATA_DISKS")
SPARES=$(echo "$DISKS" | tail -n +$((DATA_DISKS + 1)))

VDEV_ARGS=""
i=0
for d in $POOL_DISKS; do
  if [ $((i % 2)) -eq 0 ]; then VDEV_ARGS="$VDEV_ARGS mirror"; fi
  VDEV_ARGS="$VDEV_ARGS $d"
  i=$((i + 1))
done

echo
echo "Pool layout ($((DATA_DISKS / 2)) mirrors):"
echo "$POOL_DISKS" | paste - - | sed 's/^/  mirror: /'
echo "Warm spare (left untouched):"
echo "${SPARES:-  (none)}" | sed 's/^/  /'
echo
read -r -p "Create pool '$POOL' — DESTROYS data on the ${DATA_DISKS} disks above. Type YES: " ANSWER
if [ "$ANSWER" != "YES" ]; then
  echo "Aborted."
  exit 1
fi

echo "==> Creating pool"
zexec <<INNER
set -e
zpool create -f \
  -o ashift=12 \
  -o autotrim=on \
  -m legacy \
  -O compression=lz4 -O atime=off -O xattr=sa -O dnodesize=auto -O dedup=off \
  ${POOL} ${VDEV_ARGS}
zpool status ${POOL}
INNER

cat <<'EOF'

============================================================
 Pool "tank" created. Next:
   1. Reboot the node once and re-run this script — it must
      print "already exists" (auto-import via zfs extension).
      If the pool does NOT import on boot, fix that BEFORE any
      data lands on it.
   2. Push the 04-storage ClusterProfile (zfs-localpv) and the
      StorageClasses — Sveltos installs the CSI driver.
============================================================
EOF
