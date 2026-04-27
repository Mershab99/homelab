# Talos system extensions — rationale

This file documents *why* each extension was chosen for the hub and infra schematics. Update it when changing `schematic.yaml` so the next person doesn't have to guess.

## Hub (`bootstrap/talos/hub/schematic.yaml`)

| Extension                       | Why                                                                                              |
|---------------------------------|--------------------------------------------------------------------------------------------------|
| `siderolabs/qemu-guest-agent`   | Hub will be virtualized eventually for HA. Also useful if hub is ever migrated.                  |
| `siderolabs/iscsi-tools`        | Rook-Ceph clients running on hub need iSCSI userspace tooling.                                   |
| `siderolabs/intel-ucode`        | Supermicro Xeon CPUs benefit from runtime microcode updates. Belt-and-suspenders security fix.   |

**No IOMMU args on hub.** GPU passthrough lives on the infra cluster (R730/R830). VyOS-VM-on-hub uses Multus bridge CNI, not PCI passthrough — bridges are sufficient for VyOS to be the lab gateway.

## Infra (`bootstrap/talos/infra/schematic.yaml`)

| Extension                       | Why                                                                                              |
|---------------------------------|--------------------------------------------------------------------------------------------------|
| `siderolabs/qemu-guest-agent`   | Workload VMs running on KubeVirt benefit from guest agent on the host too (for VM-in-VM cases). |
| `siderolabs/iscsi-tools`        | Rook-Ceph OSDs and clients.                                                                      |
| `siderolabs/intel-ucode`        | Same rationale as hub.                                                                           |
| `siderolabs/i915-ucode`         | Some R730 BMC/iDRAC models have integrated i915. Not load-bearing but cheap insurance.           |
| `extraKernelArgs: intel_iommu=on iommu=pt` | **Required** for KubeVirt GPU passthrough — K80 and P2000 to GPU VMs (Phase 6). |

## Adding an extension

1. Edit the relevant `schematic.yaml`.
2. Re-run `task talos:<target>:schematic` locally to confirm Image Factory accepts it.
3. Update this file with the rationale.
4. Open a PR — CI's `validate-schematic` job will fail if the extension isn't in the catalog.
5. After merge, tag `talos-image-vX.Y.Z` to trigger a rebuild + release.

## Extensions not chosen and why

- `siderolabs/nvidia-container-toolkit-*` — defer to NVIDIA GPU Operator on the infra cluster; the toolkit lives in user-space inside containers, not the host. (See Phase 6.)
- `siderolabs/nonfree-kmod-nvidia` — would let the host kernel load NVIDIA drivers directly, but we want PCI passthrough to a VM, so the *host* must NOT bind the GPU. Including this would prevent vfio-pci from claiming the device.
- `siderolabs/zfs` — not using ZFS; Rook-Ceph on raw block devices instead.
