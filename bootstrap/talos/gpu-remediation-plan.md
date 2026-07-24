# GPU remediation plan — arrakis GPU nodes stuck unschedulable

## Status (2026-07-22)

GPU worker VMs exist on the hub but cannot schedule. Tenant-side config is
correct; the blocker is host-side vfio passthrough on contraxia (R730).

Observed via `kubectl --context admin@contraxia`:

- Machines `arrakis-gpu-k80-*` + `arrakis-gpu-p2000-*` → `Provisioning`; VMIs
  `Scheduling`; virt-launcher pods `Pending`.
- Scheduler: `FailedScheduling … Insufficient nvidia.com/GK210GL_TESLA_K80`.
- Node `r730` allocatable advertises **0** `nvidia.com/*` (only
  `devices.kubevirt.io/{kvm,tun,vhost-net}`).
- HCO `permittedHostDevices` **is** correct and live (under
  `.spec.virtualization`): `10DE:102D → nvidia.com/GK210GL_TESLA_K80`,
  `10DE:1C30 → nvidia.com/GP106GL_QUADRO_P2000`.

**Root cause:** KubeVirt advertises 0 GPU devices because no PCI device matching
`10DE:102D` / `10DE:1C30` is bound to `vfio-pci` on the host. Either the
`pcirebind` kernel args were never applied to the running node, or the
placeholder BDFs don't match the real R730 slots.

## Not the fix

- **Do NOT add nvidia gpu-operator to contraxia.** The hub passes GPUs through to
  tenant VMs via `vfio-pci` + KubeVirt `permittedHostDevices`. gpu-operator on the
  host loads the nvidia kernel driver and would fight vfio for the cards. Wrong
  layer. gpu-operator belongs only inside arrakis (`11-tenant-gpu.yaml`, already
  enabled).
- The 4 tenant edits (needs.gpu, kustomization uncomment, both replicas→1) are
  correct and already in effect (VMs are trying to schedule). Not the problem.

## Why we can't finish now

Off-LAN. The kube API is tunneled (`admin@contraxia` works), but the Talos API
(`192.168.2.70:50000`) is not reachable from here (`i/o timeout`). Host inspection
and machineconfig apply must be done from the home LAN.

## Remediation — run on the LAN

From `bootstrap/talos/`:

### 1. Diagnose

```bash
# a) Are the vfio kernel args on the RUNNING node?
talosctl --talosconfig ./talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  read /proc/cmdline | tr ' ' '\n' | grep -Ei 'iommu|pcirebind'

# b) Real BDFs of the P2000 + K80 dies
talosctl --talosconfig ./talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  get pcidevices | grep -i 10de
```

Expected on R730: 1× P2000 (`10DE:1C30`, single BDF) + 1× K80 (`10DE:102D`, two
BDFs `…00.0` / `…00.1`) = 3 entries.

### 2a. If cmdline shows NO iommu/pcirebind → args never applied

Confirm BDFs from step 1b match `_patches/06-vfio.yaml:22-24` /
`controlplane.yaml` install.extraKernelArgs, then apply + reboot:

```bash
talosctl --talosconfig ./talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  apply-config --mode=auto --file controlplane.yaml
# --mode=auto reboots to apply extraKernelArgs
```

> `grubUseUKICmdline` must stay OFF (mutually exclusive with extraKernelArgs).

### 2b. If real BDFs ≠ placeholders `06:00.0` / `82:00.0` / `82:00.1`

Fix the BDFs in **both** files (they duplicate the same list):

- `bootstrap/talos/_patches/06-vfio.yaml:22-24`
- `bootstrap/talos/controlplane.yaml` (install.extraKernelArgs block, ~line 155-159)

Then apply + reboot as in 2a. (Send me the BDFs and I'll patch.)

### 3. Verify host binds the GPUs

```bash
# GPUs now on vfio-pci
talosctl --talosconfig ./talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  read /proc/cmdline | tr ' ' '\n' | grep pcirebind
# KubeVirt now advertises the devices
kubectl --context admin@contraxia get node r730 -o jsonpath='{.status.allocatable}' \
  | tr ',' '\n' | grep nvidia.com
# expect: nvidia.com/GK210GL_TESLA_K80=2  nvidia.com/GP106GL_QUADRO_P2000=1
```

### 4. GPU VMs schedule automatically

Once the node advertises the devices, the already-pending virt-launcher pods
schedule. Then verify the tenant stack:

```bash
kubectl --context admin@arrakis get nodes -l node.mershab.com/pool
kubectl --context admin@arrakis get nvidiadriver   # K80 470.141.10, P2000 535.183.06
kubectl --context admin@arrakis get pods -A | grep -E 'gpu-operator|node-feature|nvidia'
```

K80 caveat: needs `nvidia-driver-470` (CUDA 11.4 ceiling) — see
`docs/runbooks/disaster-recovery.md:68-72`.

## Open question to resolve on-LAN

Earlier assumption was "BDFs already correct" — but the node advertises 0 GPUs,
so either the config was never applied or the BDFs are wrong. Step 1 settles which.
