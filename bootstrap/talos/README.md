# Talos bootstrap

Per-host configuration for the bare-metal Talos cluster.

## Layout

```
bootstrap/talos/
├── _patches/                         # shared (applied in order)
│   ├── 00-cni-none.yaml              # disable built-in CNI + kube-proxy (Cilium replaces)
│   ├── 01-features.yaml              # rbac, stableHostname, apidCheckExtKeyUsage, diskQuotaSupport
│   ├── 02-kubelet.yaml               # rotate-server-certificates, seccomp default, max-pods=250
│   ├── 03-apiserver-hardening.yaml   # PodSecurity admission + audit policy
│   ├── 04-extra-manifests.yaml       # kubelet-serving-cert-approver + metrics-server
│   ├── 05-discovery.yaml             # discovery explicitly OFF (no phone-home)
│   └── 06-vfio.yaml                  # IOMMU + Talos pcirebind for GPU passthrough
├── r730.yaml                         # host-specific patch (hostname, NIC, br0, install disk, IP)
├── r730-schematic.yaml               # Image Factory schematic
└── r820.yaml                         # added when R820 lands
```

## How it composes

`talosctl gen config` builds a base machineconfig, then `--config-patch`
overlays each patch in order. The host-specific patch (`r730.yaml`) is
applied LAST so it can override `_patches/` for things like the install
disk and network.

```bash
task talos:r730:config
# →
talosctl gen config homelab https://192.168.2.70:6443 \
  --with-secrets gen/.talos-secrets.yaml \
  --output-types controlplane \
  --config-patch @bootstrap/talos/_patches/00-cni-none.yaml \
  --config-patch @bootstrap/talos/_patches/01-features.yaml \
  --config-patch @bootstrap/talos/_patches/02-kubelet.yaml \
  --config-patch @bootstrap/talos/_patches/03-apiserver-hardening.yaml \
  --config-patch @bootstrap/talos/_patches/04-extra-manifests.yaml \
  --config-patch @bootstrap/talos/_patches/05-discovery.yaml \
  --config-patch @bootstrap/talos/_patches/06-vfio.yaml \
  --config-patch @bootstrap/talos/r730.yaml \
  --output gen/talos-r730-machineconfig.yaml
```

## Hardware-specific TODOs before first boot

`r730.yaml` and `_patches/06-vfio.yaml` ship with templates — verify each on
the actual hardware via the Talos maintenance-mode dashboard
(`talosctl --insecure --nodes <ip> dashboard`) before applying:

| What | How to check | Default |
|---|---|---|
| Primary NIC name | `talosctl --insecure get links` | `eno1` (R730's first onboard 1GbE) |
| Install disk | `talosctl --insecure get disks` | `/dev/sdb` |
| GPU PCI BDFs | `talosctl --insecure get pcidevices` or `lspci -nn` from a live USB | placeholders in `_patches/06-vfio.yaml` |
| Static IP | LAN policy | `192.168.2.70/24`, gateway `192.168.2.1` |
| Hostname | choose | `r730.mershab.com` |

## pcirebind kernel arg

`_patches/06-vfio.yaml` uses Talos's `pcirebind.rebind=<bdf>_<from>+<to>`
kernel arg to bind specific PCI slots to `vfio-pci` at boot. This is
per-slot rather than per-device-ID, so we can pass through one K80 die
while leaving the other on `nvidia` (useful if we ever want a host-side
GPU). If `pcirebind` isn't picked up out-of-the-box, add the
`siderolabs/pcirebind` system extension to `r730-schematic.yaml`.

## metrics-server

Talos's official path for metrics-server is `extraManifests` (see
`_patches/04-extra-manifests.yaml`) combined with
`rotate-server-certificates: true` on the kubelet
(`_patches/02-kubelet.yaml`). The cert-approver auto-signs the rotated
kubelet serving certs so metrics-server can verify TLS without
`--kubelet-insecure-tls`. Reference:
https://docs.siderolabs.com/kubernetes-guides/monitoring-and-observability/deploy-metrics-server.

## Outbound calls / telemetry surface

With the patches above, Talos's only outbound calls are:

| What | Where | Purpose | Why we allow |
|---|---|---|---|
| NTP | `time.cloudflare.com` | clock sync | Talos default; required for TLS to work |
| Image Factory | `factory.talos.dev` | ISO + schematic | one-time, build-time |
| `extraManifests` | `raw.githubusercontent.com`, `github.com` | metrics-server + cert-approver YAML | one-time, boot-time |

**Explicitly off:** `cluster.discovery` (no `discovery.talos.dev`),
`siderolink` (Omni), `machine.events`, `machine.logging.destinations`,
`machine.kmsg.destinations`, `cluster.externalCloudProvider`. None are set
in any patch — Talos doesn't enable them by default. The `05-discovery.yaml`
patch makes discovery's-off explicit so it can't drift back on.

## Auth

The Talos machineconfig deliberately does **not** wire kube-apiserver OIDC.
Dex lives at the platform layer and federates **UIs only** (Headlamp,
Grafana, etc.) via per-app `OAuth2Client`s. kube-apiserver authentication
stays on the local Talos-admin kubeconfig + ServiceAccount tokens.
