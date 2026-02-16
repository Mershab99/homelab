# Homelab Infrastructure Plan

## Overview

A two-cluster homelab architecture using a K3s hub cluster for infrastructure management and a Kamaji-hosted workload cluster for application workloads. The hub cluster runs on a VyOS router (Supermicro) and a lightweight agent node (Dell Optiplex), while the workload cluster runs on Metal3-provisioned bare metal servers (Dell R720 + R830) with GPU acceleration.

All software is deployed declaratively via Flux (GitOps engine) and Sveltos (addon manager), both installed at day-zero through K3s HelmChart manifests. CAPI Operator, Baremetal Operator, and Kamaji Operator manage the lifecycle of the workload cluster. Rancher + Turtles provides a multi-cluster UI.

---

## Hardware Inventory

| Host | Role | CPU | RAM | GPU | BMC | Notes |
|------|------|-----|-----|-----|-----|-------|
| Supermicro 5018D-MF | Hub K3s server + VyOS router | Intel Xeon E3-1230 V3 (4C/8T @ 3.3GHz) | 32GB DDR3 ECC | — | IPMI | 2x Intel GbE, 1U rackmount |
| Dell Optiplex | Hub K3s agent | TBD | 8GB | — | None (consumer) | Lightweight controller node |
| Dell R720 | Workload worker | TBD | TBD | Tesla K80 | iDRAC (IPMI/Redfish) | GPU compute worker |
| Dell R830 | Workload worker | TBD (4-socket) | TBD | Quadro P2000 | iDRAC (IPMI/Redfish) | GPU compute worker |

---

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│                    Hub Cluster (K3s)                       │
│           Flux + Sveltos installed via K3s HelmChart      │
│                                                           │
│  Supermicro (server, 32GB)        Optiplex (agent, 8GB)   │
│  ┌─────────────────────────┐  ┌─────────────────────────┐ │
│  │ VyOS native             │  │ Flux controllers        │ │
│  │ K3s server              │  │ Sveltos manager         │ │
│  │ Ironic (PXE/L2)         │  │ CAPI Operator           │ │
│  │ Image server            │  │ Baremetal Operator       │ │
│  │ Rancher (~1.5GB)        │  │ Kamaji controller        │ │
│  │ Kamaji TCP pods (~1.5GB)│  │ Turtles                 │ │
│  │                         │  │ Cert-manager            │ │
│  │ ~6.4GB / 32GB           │  │ ~2.4GB / 8GB            │ │
│  └─────────────────────────┘  └─────────────────────────┘ │
│              │                                            │
│         PXE/IPMI                                          │
└──────────────┼────────────────────────────────────────────┘
               │
               ▼
┌───────────────────────────────────────────────────────────┐
│          Workload Cluster (Kamaji-hosted CP)               │
│          Pure workers — CP runs on hub                     │
│          Addons deployed by Sveltos ClusterProfiles        │
│          Auto-imported into Rancher via Turtles            │
│                                                           │
│  R830 (worker)               R720 (worker)                │
│  ┌─────────────────────┐  ┌─────────────────────────────┐ │
│  │ Quadro P2000        │  │ Tesla K80                   │ │
│  │ App workloads       │  │ GPU / AI workloads          │ │
│  │ Knative pods        │  │ Knative pods                │ │
│  │ Envoy GW dataplane  │  │                             │ │
│  │ Cilium agent        │  │ Cilium agent                │ │
│  └─────────────────────┘  └─────────────────────────────┘ │
└───────────────────────────────────────────────────────────┘
```

---

## Hub Cluster Design

### Node Roles and Labels

| Node | K3s Role | Labels |
|------|----------|--------|
| Supermicro | Server | `topology.homelab.dev/chassis: supermicro` |
| Optiplex | Agent | `node-role.kubernetes.io/agent: ""`, `topology.homelab.dev/chassis: optiplex` |

K3s runs with embedded SQLite (single server). The Optiplex joins as an agent node — multi-server would require embedded etcd with a 3-node quorum minimum, which is unnecessary here.

### Workload Placement

The Supermicro server node has the default control-plane taint. Heavy pods that need the 32GB headroom are scheduled there with tolerations. Lightweight controllers are pinned to the Optiplex agent via nodeSelector.

**Supermicro (tolerates control-plane taint, nodeSelector: supermicro):**

| Component | Approx RAM | Reason |
|-----------|------------|--------|
| VyOS native (not in K3s) | ~512MB | Host-level router |
| K3s server (SQLite) | ~1.6GB | Control plane |
| Metal3 Ironic | ~1GB | Must be here — PXE/L2 adjacency |
| Nginx image server | ~64MB | Ironic pulls OS images from here |
| Rancher | ~1.5GB | Heavy, needs the RAM headroom |
| Kamaji TenantControlPlane pods | ~1.5GB | Workload cluster CP (API server, etcd, scheduler, controller-manager) |
| **Total** | **~6.4GB / 32GB** | |

**Optiplex (nodeSelector: agent):**

| Component | Approx RAM | Reason |
|-----------|------------|--------|
| OS + K3s agent | ~775MB | Baseline |
| Flux controllers | ~384MB | GitOps reconciliation |
| Sveltos manager | ~256MB | Addon deployment |
| CAPI Operator | ~256MB | Manages all CAPI providers |
| Baremetal Operator (BMO) | ~256MB | Controller only, talks to Ironic on Supermicro |
| Kamaji controller | ~256MB | Manages TenantControlPlane CRDs |
| Turtles | ~128MB | Auto-imports CAPI clusters into Rancher |
| Cert-manager | ~128MB | Certificate management |
| **Total** | **~2.4GB / 8GB** | |

### VyOS Configuration

VyOS runs natively on the Supermicro (not inside K3s). It handles routing, firewall, DHCP, VLANs, and exposes its HTTP API for config management. K3s runs as a VyOS native container.

VyOS configuration is stored in Git and synced via a Kubernetes CronJob running on the hub cluster. The CronJob uses `vyconfigure` or Ansible (`vyos.vyos` collection) to push config changes to the VyOS HTTP API.

---

## Day-Zero Bootstrap: K3s HelmChart Manifests

K3s has a built-in Helm controller. Any `HelmChart` CRD placed in `/var/lib/rancher/k3s/server/manifests/` is auto-installed on startup. Flux and Sveltos are installed this way — no manual `flux bootstrap` or `helm install` required.

### flux.yaml

```yaml
# /var/lib/rancher/k3s/server/manifests/flux.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: flux
  namespace: kube-system
spec:
  repo: https://fluxcd-community.github.io/helm-charts
  chart: flux2
  version: "2.x"
  targetNamespace: flux-system
  createNamespace: true
  valuesContent: |
    helmController:
      nodeSelector:
        node-role.kubernetes.io/agent: ""
    kustomizeController:
      nodeSelector:
        node-role.kubernetes.io/agent: ""
    sourceController:
      nodeSelector:
        node-role.kubernetes.io/agent: ""
    notificationController:
      nodeSelector:
        node-role.kubernetes.io/agent: ""
```

### sveltos.yaml

```yaml
# /var/lib/rancher/k3s/server/manifests/sveltos.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: projectsveltos
  namespace: kube-system
spec:
  repo: https://projectsveltos.github.io/helm-charts
  chart: projectsveltos
  version: "1.x"
  targetNamespace: projectsveltos
  createNamespace: true
  valuesContent: |
    manager:
      nodeSelector:
        node-role.kubernetes.io/agent: ""
```

Once K3s starts, both are installed automatically. Flux connects to Git and reconciles everything else. Sveltos watches for ClusterProfile CRDs that Flux lays down.

---

## Flux + Sveltos Division of Labor

**Sveltos** is the first-class citizen for software deployment. It manages nearly all addons via ClusterProfiles — both on the hub cluster itself and on workload clusters.

**Flux** is the GitOps engine and source provider. It reconciles the Git repo and lays down Sveltos ClusterProfiles, CAPI resources, BareMetalHost resources, and supplementary raw YAML (Secrets, ConfigMaps, namespaces).

```
Git Repo
  │
  ▼
Flux (source + reconciliation)
  │
  ├── Reconciles: Sveltos ClusterProfiles
  ├── Reconciles: CAPI Cluster + KamajiControlPlane + MachineDeployment
  ├── Reconciles: BareMetalHost resources
  ├── Reconciles: Kamaji DataStore
  ├── Reconciles: VyOS sync CronJob
  └── Reconciles: Raw YAML (secrets, configmaps, namespaces)
  │
  ▼
Sveltos (addon deployment via ClusterProfiles)
  │
  ├── Hub ClusterProfiles (clusterSelector: cluster-type=hub):
  │   ├── CAPI Operator (manages Core + CABPK + CAPM3 + Kamaji CP provider)
  │   ├── Baremetal Operator
  │   ├── Kamaji Operator
  │   ├── Rancher
  │   ├── Turtles
  │   └── Cert-manager
  │
  └── Workload ClusterProfiles (clusterSelector: cluster-type=workload):
      ├── Cilium + Hubble
      ├── NVIDIA GPU Operator
      ├── Knative Operator
      ├── Envoy Gateway
      ├── Chisel Operator
      └── Rancher monitoring agent
```

---

## Operator-First Component Strategy

| Component | Operator / Method | Deployed By | Notes |
|-----------|-------------------|-------------|-------|
| CAPI | cluster-api-operator | Sveltos (hub profile) | Single operator manages Core, CABPK, CAPM3, Kamaji CP provider via CRDs |
| Metal3 | baremetal-operator (standalone) | Sveltos (hub profile) | Controller on Optiplex, Ironic on Supermicro |
| Kamaji | kamaji operator (Helm) | Sveltos (hub profile) | Creates TenantControlPlane CRDs |
| Rancher | Helm chart | Sveltos (hub profile) | Pinned to Supermicro (RAM) |
| Turtles | rancher-turtles operator | Sveltos (hub profile) | Watches CAPI Clusters, auto-imports into Rancher |
| Cert-manager | Helm chart | Sveltos (hub profile) | Standard |
| NVIDIA GPU | nvidia-gpu-operator | Sveltos (workload profile) | On workload cluster workers |
| Knative | knative-operator | Sveltos (workload profile) | Manages KnativeServing CR |
| Envoy Gateway | Helm chart | Sveltos (workload profile) | Gateway API implementation |
| Chisel | chisel-operator | Sveltos (workload profile) | Tunnel to exit nodes |
| Cilium | Helm chart | Sveltos (workload profile) | CNI + Hubble observability |

### CAPI Operator Provider Declarations

Once the CAPI Operator is installed by Sveltos, Flux reconciles these provider CRDs:

```yaml
apiVersion: operator.cluster.x-k8s.io/v1alpha2
kind: CoreProvider
metadata:
  name: cluster-api
spec:
  version: v1.9.0
---
apiVersion: operator.cluster.x-k8s.io/v1alpha2
kind: BootstrapProvider
metadata:
  name: kubeadm
spec:
  version: v1.9.0
---
apiVersion: operator.cluster.x-k8s.io/v1alpha2
kind: ControlPlaneProvider
metadata:
  name: kamaji
spec:
  version: v0.12.0
---
apiVersion: operator.cluster.x-k8s.io/v1alpha2
kind: InfrastructureProvider
metadata:
  name: metal3
spec:
  version: v1.9.0
```

---

## Workload Cluster Design

### Kamaji-Hosted Control Plane

The workload cluster's control plane (API server, etcd, scheduler, controller-manager) runs as a `TenantControlPlane` pod on the hub cluster (pinned to Supermicro for RAM). R720 and R830 are pure worker nodes — they only run kubelet pointing at the Kamaji-hosted API server.

Benefits:
- No etcd on bare metal, no split-brain risk
- Both R720 and R830 are identical workers, fully replaceable
- If a worker dies, Metal3 reprovisions it automatically
- Control plane is protected on the hub cluster

### CAPI + Kamaji + Metal3 Flow

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: workload
  namespace: workload-cluster
  labels:
    cluster-type: workload
spec:
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1alpha1
    kind: KamajiControlPlane
    name: workload-cp
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: Metal3Cluster
    name: workload
---
apiVersion: controlplane.cluster.x-k8s.io/v1alpha1
kind: KamajiControlPlane
metadata:
  name: workload-cp
  namespace: workload-cluster
spec:
  replicas: 1
  version: "v1.29.0"
  dataStoreName: default
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: workload-workers
  namespace: workload-cluster
spec:
  replicas: 2
  template:
    spec:
      clusterName: workload
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
          kind: KubeadmConfigTemplate
          name: workload-worker-bootstrap
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: Metal3MachineTemplate
        name: workload-worker-template
```

### Metal3 Provisioning Flow

1. BareMetalHost resources for R720 and R830 are reconciled by Flux from Git
2. Baremetal Operator (on Optiplex) registers hosts with Ironic (on Supermicro)
3. CAPI MachineDeployment triggers provisioning
4. Ironic contacts iDRAC via IPMI → powers on machine → PXE boots → streams Ubuntu 20.04 to disk
5. Cloud-init configures networking and runs `kubeadm join` pointing at Kamaji TCP endpoint
6. Worker node joins workload cluster
7. Sveltos detects cluster is Ready → deploys platform stack via ClusterProfiles
8. Turtles detects CAPI Cluster → auto-imports into Rancher UI

### Workload Cluster Software (Sveltos-Deployed)

| Component | Purpose |
|-----------|---------|
| Cilium + Hubble | CNI, network policy, observability |
| NVIDIA GPU Operator | K80 + P2000 driver/runtime management |
| Knative Operator | Scale-to-zero serverless workloads |
| Envoy Gateway | Gateway API ingress |
| Chisel Operator | Tunnel to exit nodes (avoids opening home network ports) |
| Rancher monitoring agent | Metrics visible in Rancher UI |

---

## Sveltos ClusterProfiles

### Hub Infrastructure Profile

```yaml
apiVersion: config.projectsveltos.io/v1beta1
kind: ClusterProfile
metadata:
  name: hub-infrastructure
spec:
  clusterSelector:
    matchLabels:
      cluster-type: hub
  helmCharts:
    - repositoryURL: https://kubernetes-sigs.github.io/cluster-api-operator
      chartName: cluster-api-operator
      chartVersion: "0.15.x"
      releaseName: capi-operator
      releaseNamespace: capi-operator-system
      values: |
        nodeSelector:
          node-role.kubernetes.io/agent: ""

    - repositoryURL: https://metal3-io.github.io/baremetal-operator/charts
      chartName: baremetal-operator
      chartVersion: "0.9.x"
      releaseName: baremetal-operator
      releaseNamespace: baremetal-operator-system
      values: |
        nodeSelector:
          node-role.kubernetes.io/agent: ""

    - repositoryURL: https://clastix.github.io/charts
      chartName: kamaji
      chartVersion: "1.x"
      releaseName: kamaji
      releaseNamespace: kamaji-system
      values: |
        nodeSelector:
          node-role.kubernetes.io/agent: ""

    - repositoryURL: https://charts.jetstack.io
      chartName: cert-manager
      chartVersion: "1.16.x"
      releaseName: cert-manager
      releaseNamespace: cert-manager
      values: |
        installCRDs: true
        nodeSelector:
          node-role.kubernetes.io/agent: ""
```

### Hub Rancher Profile

```yaml
apiVersion: config.projectsveltos.io/v1beta1
kind: ClusterProfile
metadata:
  name: hub-rancher
spec:
  clusterSelector:
    matchLabels:
      cluster-type: hub
  helmCharts:
    - repositoryURL: https://releases.rancher.com/server-charts/stable
      chartName: rancher
      chartVersion: "2.10.x"
      releaseName: rancher
      releaseNamespace: cattle-system
      values: |
        hostname: rancher.homelab.dev
        replicas: 1
        nodeSelector:
          topology.homelab.dev/chassis: supermicro

    - repositoryURL: https://rancher.github.io/turtles
      chartName: rancher-turtles
      chartVersion: "0.13.x"
      releaseName: rancher-turtles
      releaseNamespace: rancher-turtles-system
      values: |
        nodeSelector:
          node-role.kubernetes.io/agent: ""
```

### Workload Networking Profile

```yaml
apiVersion: config.projectsveltos.io/v1beta1
kind: ClusterProfile
metadata:
  name: workload-networking
spec:
  clusterSelector:
    matchLabels:
      cluster-type: workload
  helmCharts:
    - repositoryURL: https://helm.cilium.io
      chartName: cilium
      chartVersion: "1.16.x"
      releaseName: cilium
      releaseNamespace: kube-system
      values: |
        hubble:
          relay:
            enabled: true
          ui:
            enabled: true
```

### Workload GPU Profile

```yaml
apiVersion: config.projectsveltos.io/v1beta1
kind: ClusterProfile
metadata:
  name: workload-gpu
spec:
  clusterSelector:
    matchLabels:
      cluster-type: workload
  helmCharts:
    - repositoryURL: https://helm.ngc.nvidia.com/nvidia
      chartName: gpu-operator
      chartVersion: "24.x"
      releaseName: gpu-operator
      releaseNamespace: gpu-operator
```

### Workload Knative Profile

```yaml
apiVersion: config.projectsveltos.io/v1beta1
kind: ClusterProfile
metadata:
  name: workload-knative
spec:
  clusterSelector:
    matchLabels:
      cluster-type: workload
  policyRefs:
    - name: knative-operator-manifests
      namespace: workload-addons
      kind: ConfigMap
```

### Workload Ingress Profile

```yaml
apiVersion: config.projectsveltos.io/v1beta1
kind: ClusterProfile
metadata:
  name: workload-ingress
spec:
  clusterSelector:
    matchLabels:
      cluster-type: workload
  helmCharts:
    - repositoryURL: https://gateway.envoyproxy.io/charts
      chartName: gateway-helm
      chartVersion: "1.x"
      releaseName: envoy-gateway
      releaseNamespace: envoy-gateway-system
    - repositoryURL: https://chisel-operator.github.io/charts
      chartName: chisel-operator
      chartVersion: "0.x"
      releaseName: chisel-operator
      releaseNamespace: chisel-operator-system
```

---

## Network Exposure via Chisel

Chisel Operator provides LoadBalancer services via tunnels to pre-provisioned exit nodes, avoiding opening any ports on the home network.

Traffic flow: `Internet → Exit Node → Chisel tunnel → Cilium/Gateway API → Workload pods`

Exposed services:
- Rancher UI (from hub, via Supermicro)
- Application ingress (from workload cluster, via Envoy Gateway)

---

## Git Repository Structure

```
homelab/
├── .devcontainer/                      # Development environment
│   ├── devcontainer.json               # VS Code / GitHub Codespaces config
│   ├── Dockerfile                      # All build + cluster management tools
│   └── post-create.sh                  # Shell completions, aliases, verification
├── Taskfile.yaml                       # Image build automation (VyOS ISO, Ubuntu, IPA)
├── k3s-manifests/                      # Copied to K3s manifests dir
│   ├── flux.yaml                       # HelmChart → Flux (day-zero)
│   └── sveltos.yaml                    # HelmChart → Sveltos (day-zero)
│
├── hub-cluster/                        # Flux Kustomization root
│   ├── sources/                        # Flux GitRepository, HelmRepository
│   │   └── git-repo.yaml
│   ├── sveltos-profiles/               # ClusterProfiles (Flux reconciles)
│   │   ├── hub-infrastructure.yaml     # CAPI Op, BMO, Kamaji, cert-mgr
│   │   ├── hub-rancher.yaml            # Rancher + Turtles
│   │   ├── hub-ironic.yaml             # Ironic (pinned to Supermicro)
│   │   ├── workload-networking.yaml    # Cilium for workload cluster
│   │   ├── workload-gpu.yaml           # GPU Operator for workload
│   │   ├── workload-knative.yaml       # Knative Operator for workload
│   │   └── workload-ingress.yaml       # Envoy GW + Chisel for workload
│   ├── capi-providers/                 # CRDs for CAPI Operator
│   │   ├── core-provider.yaml
│   │   ├── bootstrap-provider.yaml
│   │   ├── controlplane-provider.yaml  # Kamaji
│   │   └── infra-provider.yaml         # Metal3
│   ├── clusters/
│   │   └── workload/
│   │       ├── namespace.yaml
│   │       ├── cluster.yaml            # CAPI Cluster
│   │       ├── kamaji-cp.yaml          # KamajiControlPlane
│   │       └── workers.yaml            # MachineDeployment
│   ├── baremetalhosts/
│   │   ├── r720.yaml                   # BareMetalHost + iDRAC creds
│   │   └── r830.yaml                   # BareMetalHost + iDRAC creds
│   ├── kamaji/
│   │   └── datastore.yaml              # Kamaji DataStore config
│   ├── ironic/                         # Ironic deployment (nodeSelector: supermicro)
│   │   └── kustomization.yaml
│   ├── image-server/                   # Nginx serving OS images (nodeSelector: supermicro)
│   └── vyos/
│       ├── config.boot                 # VyOS configuration
│       └── sync-cronjob.yaml           # CronJob to sync config via HTTP API
│
├── workload-apps/                      # Sveltos deploys via ClusterProfile
│   ├── my-services/
│   └── ai-workloads/
│
└── bootstrap/                          # One-time reference documentation
    ├── vyos-initial.md                 # VyOS initial setup guide
    └── k3s-agent-join.sh              # Optiplex join script
```

---

## Development Environment (Devcontainer)

All build dependencies and cluster management tools run inside a devcontainer — nothing is installed on the host machine except Docker and VS Code.

### What's Included

| Category | Tools |
|----------|-------|
| Image building | `qemu-utils`, `libguestfs-tools` (`virt-customize`), Docker-in-Docker |
| Kubernetes | `kubectl`, `helm`, `k9s`, `flux`, `clusterctl`, `sveltosctl` |
| Secrets | `sops`, `age` |
| BMC management | `ipmitool` |
| Utilities | `task`, `yq`, `jq`, `git`, `curl`, `nmap`, `python3` |
| Shell | `zsh` + Oh My Zsh, completions for all CLI tools, kubectl/flux aliases |

### Usage

```bash
# VS Code — open the repo and accept "Reopen in Container" prompt
code homelab/

# CLI — using devcontainer CLI
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . task --list

# GitHub Codespaces — works out of the box
```

The container runs with `--privileged` (required for `virt-customize` and Docker-in-Docker). The host `~/.ssh` directory is bind-mounted read-only for Git and SSH access to cluster nodes.

### Notes

- Docker-in-Docker is used for the VyOS ISO build (which itself runs in a Docker container)
- The `KUBECONFIG` env var points to `.kubeconfig` in the workspace root — copy your cluster kubeconfig there to use `kubectl`, `k9s`, `flux`, etc. from the devcontainer
- SOPS + age are included for encrypting secrets (iDRAC credentials, Chisel tokens) in Git

---

## Image Build Pipeline (Taskfile)

All images required for the homelab are built or downloaded via a single `Taskfile.yaml` at the repo root. This covers the VyOS installation ISO, the Ubuntu 20.04 deployment image for Metal3, and the Ironic Python Agent (IPA) boot images.

### Prerequisites

Install [Task](https://taskfile.dev) and system dependencies:

```bash
# All tools are pre-installed in the devcontainer — just open the repo in VS Code
# If running outside the devcontainer:
sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin
task deps:install
```

### Available Tasks

| Task | Description |
|------|-------------|
| `task all` | Build everything (VyOS ISO + Ubuntu image + IPA images) |
| `task vyos:iso` | Build VyOS ISO from source using Docker |
| `task ubuntu:image` | Download, customize, and convert Ubuntu 20.04 for Metal3 |
| `task ipa:download` | Download Ironic Python Agent kernel + initramfs |
| `task collect` | Copy all images into `.build/image-server/` directory |
| `task serve` | Start local HTTP server on port 8080 to preview images |
| `task deps:check` | Verify all required tools are installed |
| `task clean` | Remove all build artifacts |

### VyOS ISO Build

Builds VyOS from source using the official `vyos-build` Docker container. The default branch is `sagitta` (VyOS 1.4.x LTS). The build process clones the vyos-build repository, pulls the build container, and produces a hybrid ISO suitable for USB or IPMI virtual media.

```bash
task vyos:iso
# Output: .build/vyos/build/live-image-amd64.hybrid.iso
```

### Ubuntu 20.04 Image for Metal3

Downloads the official Ubuntu 20.04 (Focal) cloud image and customizes it for bare metal deployment via Ironic:

1. **Download**: Fetches `focal-server-cloudimg-amd64.img` (qcow2)
2. **Customize** (via `virt-customize`):
   - Installs: `qemu-guest-agent`, `cloud-init`, `open-iscsi`, `multipath-tools`, `nfs-common`
   - Configures cloud-init to use ConfigDrive datasource (Metal3 standard)
   - Enables required systemd services (iSCSI, multipath)
   - Injects SSH public key for root access
   - Truncates `/etc/machine-id` for unique IDs per provision
3. **Convert**: qcow2 → raw format (Ironic direct deploy prefers raw)
4. **Checksum**: Generates MD5 (required by Ironic `BareMetalHost` image spec)

```bash
task ubuntu:image
# Output: .build/images/ubuntu-20.04.raw + .build/images/ubuntu-20.04.raw.md5sum
```

### IPA (Ironic Python Agent) Images

Downloads pre-built IPA kernel and initramfs from OpenDev. These are used by Ironic during the inspection, cleaning, and deployment phases — the IPA boots on the target machine via PXE before the OS image is written to disk.

```bash
task ipa:download
# Output: .build/images/ipa.kernel + .build/images/ipa.initramfs
```

### Collecting Images for the Image Server

After building, collect all images into a single directory for the Nginx image server:

```bash
task collect
# Output: .build/image-server/
#   ├── vyos-sagitta.iso
#   ├── ubuntu-20.04.raw
#   ├── ubuntu-20.04.raw.md5sum
#   ├── ipa.kernel
#   └── ipa.initramfs
```

The Nginx image server pod on the hub cluster (pinned to Supermicro) serves these files. The BareMetalHost and Ironic configuration reference them via HTTP URLs:

```yaml
# In baremetalhosts/r720.yaml
spec:
  image:
    url: http://image-server.image-server.svc.cluster.local/ubuntu-20.04.raw
    checksum: http://image-server.image-server.svc.cluster.local/ubuntu-20.04.raw.md5sum
    checksumType: md5
    format: raw
```

### Configuration Variables

Key variables in `Taskfile.yaml` that may need adjustment:

| Variable | Default | Description |
|----------|---------|-------------|
| `VYOS_BRANCH` | `sagitta` | VyOS branch (`sagitta` = 1.4.x LTS, `equuleus` = 1.3.x) |
| `UBUNTU_VERSION` | `20.04` | Ubuntu version |
| `UBUNTU_IMAGE_FORMAT` | `raw` | Output format (`raw` or `qcow2`) |
| `IPA_BRANCH` | `stable-2024.1` | IPA version (match your Ironic version) |
| `SSH_PUB_KEY_FILE` | `~/.ssh/id_ed25519.pub` | SSH key injected into Ubuntu image |
| `EXTRA_PACKAGES` | see Taskfile | Additional packages installed in Ubuntu image |

---

## Bootstrap Procedure

### Prerequisites

- Devcontainer running (all tools pre-installed) or equivalent local tooling
- Images built: `task all` (produces VyOS ISO, Ubuntu image, IPA images)
- Git repository created with the above structure
- iDRAC credentials for R720 and R830
- Exit node(s) provisioned for Chisel tunneling

### Step 0: Build Images

```bash
task all        # Builds VyOS ISO + Ubuntu image + downloads IPA
task collect    # Collects into .build/image-server/
```

Flash VyOS ISO to USB: `dd if=.build/image-server/vyos-sagitta.iso of=/dev/sdX bs=4M status=progress`

### Step 1: Install VyOS on Supermicro

1. Boot Supermicro from USB, run `install image`
2. Configure interfaces, VLANs, DHCP, firewall rules
3. Enable VyOS HTTP API
4. Install K3s server: `curl -sfL https://get.k3s.io | sh -`
5. Copy `k3s-manifests/flux.yaml` and `k3s-manifests/sveltos.yaml` to `/var/lib/rancher/k3s/server/manifests/`
6. Upload built images (Ubuntu + IPA) to the image server path or configure Nginx to serve from a known directory

### Step 2: Join Optiplex as K3s Agent

```bash
# On Optiplex (Ubuntu 22.04 Server pre-installed)
curl -sfL https://get.k3s.io | K3S_URL=https://<supermicro-ip>:6443 K3S_TOKEN=<token> sh -
```

```bash
# From Supermicro (or any kubectl context)
kubectl label node optiplex node-role.kubernetes.io/agent=""
kubectl label node optiplex topology.homelab.dev/chassis=optiplex
kubectl label node <supermicro-hostname> topology.homelab.dev/chassis=supermicro
```

### Step 3: K3s Auto-Installs Flux + Sveltos

No manual action. K3s Helm controller detects the manifests and installs both. Verify:

```bash
kubectl get pods -n flux-system
kubectl get pods -n projectsveltos
```

### Step 4: Connect Flux to Git (Only Manual kubectl)

```bash
kubectl apply -f hub-cluster/sources/git-repo.yaml
kubectl apply -f hub-cluster/kustomization.yaml
```

This is the **last manual kubectl** command. From this point, all changes are made via Git.

### Step 5: Automated Self-Assembly

Everything from here is automatic:

1. **Flux reconciles** Git repo → Sveltos ClusterProfiles, CAPI resources, BareMetalHosts appear
2. **Sveltos deploys** hub addons → CAPI Operator, BMO, Kamaji, Rancher, Turtles, cert-manager installed
3. **CAPI Operator** installs providers → Core, CABPK, CAPM3, Kamaji CP provider ready
4. **Baremetal Operator** registers R720 + R830 with Ironic via iDRAC
5. **CAPI Cluster resource** triggers Kamaji → TenantControlPlane pods start on Supermicro
6. **CAPI MachineDeployment** triggers Metal3 → Ironic powers on R720 + R830 via IPMI → PXE boot → Ubuntu 20.04 provisioned
7. **Workers join** workload cluster (kubeadm join → Kamaji TCP endpoint)
8. **Sveltos detects** workload cluster Ready → deploys Cilium, GPU Operator, Knative, Envoy GW, Chisel
9. **Turtles detects** CAPI Cluster → auto-imports into Rancher UI
10. **Done** — workload cluster fully operational, visible in Rancher

---

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Router OS | VyOS native on Supermicro | No virtualization layer, maximum network throughput |
| Hub cluster | K3s (SQLite, single server) | Lightweight, built-in Helm controller for day-zero bootstrap |
| GitOps engine | Flux | Lighter than ArgoCD, no UI needed on hub, Helm chart install (no bootstrap CLI) |
| Addon manager | Sveltos (first-class) | ClusterProfile CRD for hub + workload clusters, native CAPI integration |
| CAPI providers | CAPI Operator | Single operator manages all provider lifecycles via CRDs |
| Bare metal | Baremetal Operator + Ironic | R720/R830 have iDRAC (IPMI/Redfish), mature for enterprise hardware |
| Control plane hosting | Kamaji | Workload CP runs as pods on hub — workers are pure compute, no etcd on bare metal |
| Multi-cluster UI | Rancher + Turtles | Auto-imports CAPI clusters, RBAC, monitoring, kubectl shell |
| Network exposure | Chisel Operator | Tunnel to exit nodes, no open ports on home network |
| CNI | Cilium | eBPF-based, Hubble observability |
| Ingress | Envoy Gateway (Gateway API) | Modern Gateway API implementation |
| Serverless | Knative Operator | Scale-to-zero for resource efficiency on homelab |
| GPU | NVIDIA GPU Operator | Manages K80 + P2000 drivers/runtime |

### Decisions Against Complexity

| Rejected | Reason |
|----------|--------|
| Kubernetes Dashboard | Single-cluster only, can't bridge hub + workload |
| ArgoCD | Heavier than Flux for hub, UI unnecessary for infra GitOps |
| Dex | Rancher handles auth natively, Dex optional as upstream OIDC |
| KubeadmControlPlane (KCP) | Kamaji removes need for dedicated CP nodes |
| vCluster | Unnecessary at homelab scale, namespaces + RBAC sufficient |
| Sidero/Tinkerbell | Metal3 better fit for hardware with proper IPMI/BMC |
| Multi-server K3s (etcd) | Needs 3-node quorum minimum, SQLite fine for 2-node hub |

---

## Pending Items

- [ ] Confirm Optiplex exact model and specs
- [ ] Confirm R720 and R830 RAM and CPU specs
- [ ] Verify iDRAC network access and credentials for R720 and R830
- [ ] Determine Supermicro RAM (confirm 32GB installed or procure)
- [ ] Provision exit node(s) for Chisel tunneling
- [ ] Run `task all` to build VyOS ISO + Ubuntu image + IPA images
- [ ] Create initial VyOS configuration (interfaces, VLANs, DHCP, firewall, HTTP API)
- [ ] Set up Git repository with directory structure
- [ ] Document iDRAC IP addresses and BMC network VLAN
- [ ] Verify IPA branch matches planned Ironic version
- [ ] Generate or select SSH key for Ubuntu image injection
