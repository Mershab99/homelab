# Infra Talos Bootstrap (Sidero-driven)

Phase 4+: bare-metal Talos nodes (R730, R830) provisioned by Sidero. This directory holds:

- `schematic.yaml` — Image Factory schematic for kernel + initramfs Sidero serves to nodes via PXE.
- `machineconfig/` — populated in Phase 4 with config patches applied per Sidero ServerClass.

## Schematic

- Extensions: `qemu-guest-agent`, `iscsi-tools`, `intel-ucode`, `i915-ucode`.
- Kernel cmdline: `intel_iommu=on iommu=pt` — required for KubeVirt GPU passthrough on the K80/P2000 boxes (Phase 6).

## How Sidero consumes this

The CI workflow `.github/workflows/talos-images.yaml` POSTs this schematic to
Talos Image Factory and pushes the resulting kernel + initramfs as an OCI artifact
to `ghcr.io/<org>/<repo>/talos-infra:<schematic-id>`.

Sidero's `Environment` CR (Phase 4) references those URLs directly — either the
Image Factory canonical URL or the OCI artifact, depending on whether the infra
cluster has internet egress.
