# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture

Two-cluster bare metal homelab using GitOps-first design:

- **Hub cluster** (K3s, SQLite): Runs on Supermicro (server, 32GB) + Dell Optiplex (agent, 8GB). Hosts all infrastructure operators and the workload cluster's control plane.
- **Workload cluster** (Kamaji-hosted CP): Pure worker nodes on Dell R720 (Tesla K80) + Dell R830 (Quadro P2000), provisioned via Metal3/Ironic PXE boot. Control plane runs as TenantControlPlane pods on the hub.

### GitOps Flow

Flux is the GitOps engine; Sveltos is the addon manager. Both are installed at day-zero via K3s HelmChart manifests (placed in `/var/lib/rancher/k3s/server/manifests/`). After bootstrap, the only manual `kubectl` is connecting Flux to Git — everything else is reconciled from this repo.

```
Git → Flux (reconciles) → Sveltos ClusterProfiles + CAPI resources + BareMetalHosts
                         → Sveltos (deploys) → Helm charts/addons to hub and workload clusters
```

### Hub Cluster Components (Sveltos-deployed)

CAPI Operator (manages Core, CABPK, CAPM3, Kamaji CP providers), Baremetal Operator (with Ironic enabled), Kamaji Operator, Rancher + Turtles, Cert-manager. Heavy pods (Rancher, Kamaji TCP, Ironic) pinned to Supermicro via `topology.homelab.dev/chassis: supermicro`; lightweight controllers pinned to Optiplex via `node-role.kubernetes.io/agent: ""`.

### Workload Cluster Components (Sveltos-deployed)

Cilium + Hubble (CNI), NVIDIA GPU Operator, Knative Operator, Envoy Gateway (Gateway API), Chisel Operator (tunnels to exit nodes for ingress without opening home network ports).

## Development Environment

All development happens inside a devcontainer (VS Code "Reopen in Container" or `devcontainer up`). The container includes all required tools: `task`, `kubectl`, `helm`, `flux`, `clusterctl`, `sveltosctl`, `sops`, `age`, `k9s`, `yq`, `qemu-img`, `virt-customize`, `ipmitool`, Docker-in-Docker.

- `KUBECONFIG` points to `.kubeconfig` in workspace root — copy your cluster kubeconfig there
- Host `~/.ssh` is bind-mounted read-only
- Runs privileged (required for `virt-customize` and Docker-in-Docker)
- Secrets encrypted with SOPS + age

### Shell Aliases (configured in post-create.sh)

```
k=kubectl  kgp=get pods  kgs=get svc  kgn=get nodes  kga=get all
kgbmh=get baremetalhost -A  kgtcp=get tenantcontrolplane -A  kgcp=get clusterprofile -A
fgk=flux get kustomizations  fgh=flux get helmreleases  fgs=flux get sources all  fr=flux reconcile
```

## Common Commands

```bash
# Image build automation (Taskfile.yaml)
task --list              # Show all available tasks
task all                 # Build everything: VyOS ISO + Ubuntu image + IPA images
task vyos:iso            # Build VyOS 1.4.x (sagitta) ISO from source via Docker
task ubuntu:image        # Download, customize (virt-customize), convert Ubuntu 20.04 for Metal3
task ipa:download        # Download Ironic Python Agent kernel + initramfs
task collect             # Copy all built images into .build/image-server/
task serve               # Serve images on localhost:8080 (for testing)
task deps:check          # Verify required tools are installed
task clean               # Remove all .build/ artifacts
```

### Key Taskfile Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `VYOS_BRANCH` | `sagitta` | VyOS branch (sagitta=1.4.x LTS) |
| `UBUNTU_VERSION` | `20.04` | Ubuntu cloud image version |
| `UBUNTU_IMAGE_FORMAT` | `raw` | Output format (raw for Ironic direct deploy) |
| `IPA_BRANCH` | `stable-2024.1` | IPA version (must match Ironic version) |
| `SSH_PUB_KEY_FILE` | `~/.ssh/id_ed25519.pub` | SSH key injected into Ubuntu image |

## Repository Structure

```
homelab/
├── Taskfile.yaml                    # Image build automation
├── devcontainer.json                # VS Code devcontainer config
├── Dockerfile                       # Devcontainer image with all tools
├── post-create.sh                   # Shell completions, aliases, verification
├── k3s-manifests/                   # Day-zero: K3s auto-installs these HelmCharts
│   ├── flux.yaml                    # Flux2 (GitOps engine)
│   └── sveltos.yaml                # Sveltos (addon manager)
├── hub-cluster/                     # Flux Kustomization root
│   ├── kustomization.yaml           # Root Flux Kustomization (dependency ordering)
│   ├── sources/                     # Flux GitRepository
│   │   └── git-repo.yaml
│   ├── sveltos-profiles/            # ClusterProfiles (hub + workload)
│   │   ├── hub-infrastructure.yaml  # CAPI Op, BMO+Ironic, Kamaji, cert-mgr
│   │   ├── hub-rancher.yaml         # Rancher + Turtles
│   │   ├── workload-networking.yaml # Cilium + Hubble
│   │   ├── workload-gpu.yaml        # NVIDIA GPU Operator
│   │   ├── workload-knative.yaml    # Knative Operator
│   │   └── workload-ingress.yaml    # Envoy GW + Chisel
│   ├── capi-providers/              # CAPI Operator provider CRDs
│   │   ├── core-provider.yaml       # cluster-api v1.9.0
│   │   ├── bootstrap-provider.yaml  # kubeadm v1.9.0
│   │   ├── controlplane-provider.yaml # kamaji v0.12.0
│   │   └── infra-provider.yaml      # metal3 v1.9.0
│   ├── clusters/workload/           # CAPI Cluster + Kamaji CP + MachineDeployment
│   │   ├── namespace.yaml
│   │   ├── cluster.yaml
│   │   ├── kamaji-cp.yaml
│   │   └── workers.yaml
│   ├── baremetalhosts/              # BareMetalHost CRDs + BMC secrets
│   │   ├── r720.yaml
│   │   └── r830.yaml
│   ├── kamaji/                      # Kamaji DataStore config
│   │   └── datastore.yaml
│   ├── image-server/                # Nginx serving OS images (pinned to Supermicro)
│   │   ├── namespace.yaml
│   │   └── deployment.yaml
│   └── vyos/                        # VyOS config + sync CronJob
│       ├── config.boot
│       └── sync-cronjob.yaml
├── workload-apps/                   # Application workloads (placeholder)
│   ├── my-services/
│   └── ai-workloads/
└── bootstrap/                       # One-time setup documentation
    ├── vyos-initial.md              # VyOS install + bootstrap guide
    └── k3s-agent-join.sh            # Optiplex join script
```

## Key Design Decisions

- **K3s over multi-server etcd**: SQLite sufficient for 2-node hub, avoids 3-node quorum requirement
- **Flux over ArgoCD**: Lighter, no UI needed on hub, Helm chart install (no bootstrap CLI)
- **Sveltos over direct Helm**: First-class ClusterProfile CRD for multi-cluster addon management
- **Kamaji over KubeadmControlPlane**: Workload CP as pods on hub, workers are pure compute
- **Metal3 over Sidero/Tinkerbell**: Better fit for hardware with IPMI/iDRAC BMC
- **Chisel over port forwarding**: Secure tunnels to exit nodes, no open home network ports
- **Cilium over other CNIs**: eBPF-based with Hubble observability built in
- **Ironic via BMO chart**: Deployed as part of the Baremetal Operator Helm chart (ironic.enabled: true)

## Reference

The full architecture blueprint, hardware inventory, bootstrap procedure, and all example manifests are in `plan.md`.
