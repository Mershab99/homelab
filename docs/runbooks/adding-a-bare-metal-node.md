# Adding a bare-metal node

Procedure for adding the R820 (or any future bare-metal node) to the cluster.

## Prerequisites

- Node hardware racked, networked into the Aruba S2500.
- IPMI / iDRAC accessible from the LAN (note its IP and credentials).
- Node has data disks free for its ZFS pool (in addition to the boot disk).

## Steps

1. **Reserve an IP**: Bell Hub admin → DHCP reservations → pin the node to a
   stable IP outside the `192.168.1.200–240` LB pool.
2. **Write the machineconfig**: copy `bootstrap/talos/r730.yaml` to
   `bootstrap/talos/<host>.yaml`. Adjust:
   - hostname
   - install disk path (check via Talos installer maintenance mode dashboard)
   - NIC name (R820 may differ from R730)
   - any GPU `vfio-pci` entries new to this host
3. **Build the ISO** (Talos Image Factory):
   ```bash
   task talos:r820:schematic
   task talos:r820:iso
   ```
4. **Boot to maintenance mode** via IPMI virtual media using the ISO.
5. **Apply machineconfig** as a control plane joiner (HA later) or worker:
   ```bash
   talosctl apply-config --insecure \
     --nodes <node-ip> \
     --file gen/talos-r820-machineconfig.yaml
   ```
6. **Verify**: `talosctl --nodes <node-ip> dashboard` — node Ready in the
   bare-metal cluster, `br0` up, vfio bound to any GPUs declared.
7. **Update KubeVirt**: edit
   `clusters/baremetal/infrastructure/kubevirt-hco/hyperconverged.yaml` to
   include any GPUs new to this host under `permittedHostDevices`.
8. **Create the node's ZFS pool**: LocalPV-ZFS is node-local — each node owns
   its own pool, created below the GitOps line. Copy
   `bootstrap/zfs/create-pool.sh`, adjust `POOL` / `MODEL_PATTERN` /
   `DATA_DISKS` / the vdev layout (RAIDZ2 suits the R820's spinning disks), and
   run it once. Then add a matching StorageClass (e.g. `zfs-hdd`, `poolname:`
   the new pool) to `platform/sveltos/manifests/storage/storageclasses.yaml`.
   Don't extend `tank` across nodes. Verify by re-running the script — it must
   print `already exists` after a reboot.

   The node's Talos image needs the `zfs` system extension, same coupling rule
   as the R730 (`bootstrap/talos/r730-schematic.yaml`).
