# VyOS Initial Setup Guide

Step-by-step guide for installing VyOS on the Supermicro server and bootstrapping the hub cluster.

## Prerequisites

- VyOS ISO built: `task vyos:iso` (or download from VyOS releases)
- USB flash drive (2GB+)
- IPMI access to Supermicro (or physical console)
- Images built: `task all && task collect`

## Step 1: Flash VyOS ISO to USB

```bash
# From devcontainer or host machine
dd if=.build/image-server/vyos-sagitta.iso of=/dev/sdX bs=4M status=progress
sync
```

## Step 2: Install VyOS

1. Boot the Supermicro from USB (via IPMI virtual media or physical USB)
2. Log in with default credentials: `vyos` / `vyos`
3. Run the installer:

```
install image
```

4. Follow prompts:
   - Select disk to install to
   - Set image name (default is fine)
   - Set root partition size (use all available space)
   - Set admin password

5. Reboot and remove USB: `reboot`

## Step 3: Initial Network Configuration

Log in to VyOS and configure the basic network:

```
configure

# System
set system host-name vyos-supermicro
set system domain-name homelab.dev
set system time-zone UTC
set system name-server 1.1.1.1

# WAN interface (adjust for your ISP)
set interfaces ethernet eth0 description WAN
set interfaces ethernet eth0 address dhcp

# LAN interface
set interfaces ethernet eth1 description LAN
set interfaces ethernet eth1 address 192.168.1.1/24

# BMC VLAN
set interfaces ethernet eth1 vif 10 description 'BMC VLAN'
set interfaces ethernet eth1 vif 10 address 10.0.10.1/24

# DHCP server
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 default-router 192.168.1.1
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 dns-server 192.168.1.1
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 range 0 start 192.168.1.100
set service dhcp-server shared-network-name LAN subnet 192.168.1.0/24 range 0 stop 192.168.1.200

# DNS forwarding
set service dns forwarding listen-address 192.168.1.1
set service dns forwarding allow-from 192.168.1.0/24

# NAT masquerade
set nat source rule 100 outbound-interface eth0
set nat source rule 100 source address 192.168.1.0/24
set nat source rule 100 translation address masquerade

# Firewall — basic WAN protection
set firewall name WAN-IN default-action drop
set firewall name WAN-IN rule 10 action accept
set firewall name WAN-IN rule 10 state established enable
set firewall name WAN-IN rule 10 state related enable

commit
save
```

## Step 4: Enable VyOS HTTP API

The HTTP API is required for the config sync CronJob.

```
configure

set service https api-restrict virtual-host vyos-supermicro.homelab.dev
set service https api keys id my-api key '<GENERATE-A-STRONG-KEY>'

commit
save
```

Test the API:

```bash
curl -k -X POST https://192.168.1.1/retrieve \
  -H "Content-Type: application/json" \
  -d '{"op": "showConfig", "path": [], "key": "<YOUR-API-KEY>"}'
```

## Step 5: Configure K3s Container

VyOS runs K3s as a native Podman container:

```
configure

set container name k3s image rancher/k3s:v1.29-k3s1
set container name k3s allow-host-networks
set container name k3s restart on-failure
set container name k3s cap-add net-admin
set container name k3s cap-add sys-admin
set container name k3s memory 0
set container name k3s environment K3S_TOKEN value '<GENERATE-A-TOKEN>'
set container name k3s volume k3s-data source /var/lib/rancher/k3s
set container name k3s volume k3s-data destination /var/lib/rancher/k3s
set container name k3s volume k3s-data mode rw
set container name k3s volume k3s-config source /etc/rancher/k3s
set container name k3s volume k3s-config destination /etc/rancher/k3s
set container name k3s volume k3s-config mode rw

commit
save
```

Verify K3s is running:

```bash
sudo podman ps
sudo /var/lib/rancher/k3s/data/current/bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes
```

## Step 6: Copy Day-Zero Manifests

Copy the K3s HelmChart manifests so Flux and Sveltos are auto-installed:

```bash
sudo cp k3s-manifests/flux.yaml /var/lib/rancher/k3s/server/manifests/
sudo cp k3s-manifests/sveltos.yaml /var/lib/rancher/k3s/server/manifests/
```

K3s will automatically detect and install both Helm charts. Verify:

```bash
kubectl get pods -n flux-system
kubectl get pods -n projectsveltos
```

## Step 7: Upload Images

Copy the built images to the image server directory on the Supermicro:

```bash
sudo mkdir -p /opt/homelab/images
sudo cp .build/image-server/ubuntu-20.04.raw /opt/homelab/images/
sudo cp .build/image-server/ubuntu-20.04.raw.md5sum /opt/homelab/images/
sudo cp .build/image-server/ipa.kernel /opt/homelab/images/
sudo cp .build/image-server/ipa.initramfs /opt/homelab/images/
```

## Step 8: Connect Flux to Git

This is the **last manual kubectl** — everything after is GitOps:

```bash
kubectl apply -f hub-cluster/sources/git-repo.yaml
kubectl apply -f hub-cluster/kustomization.yaml
```

## What Happens Next

1. Flux reconciles Git repo -> all manifests appear in the cluster
2. Sveltos deploys hub infrastructure (CAPI Operator, BMO, Kamaji, Rancher, etc.)
3. CAPI providers install and register
4. BareMetalHosts register with Ironic
5. Workload cluster control plane starts (Kamaji)
6. Workers PXE boot and join workload cluster
7. Sveltos deploys workload addons (Cilium, GPU Operator, Knative, etc.)
8. Turtles imports workload cluster into Rancher

See `plan.md` for the full bootstrap sequence details.
