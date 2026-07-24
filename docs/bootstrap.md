# Bootstrap

Cold-start the bare-metal cluster from zero. Run top to bottom. Each section
ends in a `Verify` block — do not move on until it passes.

Reference targets:
- Domain: `mershab.com`
- Talos node IP: `192.168.2.70` (R730, pinned)
- Tenant cluster name: `arrakis`

## Prerequisites (workstation)

```bash
# Tools (mise / asdf / brew — whichever you use)
brew install talosctl helm cilium-cli flux sops age yq kubectl kustomize
brew install fluxcd/tap/flux  # operator-aware client
brew install go-task/tap/go-task
```

- A Cloudflare API token with DNS edit permission on the `mershab.com` zone
  (for cert-manager DNS-01 + ExternalDNS).
- A GitHub PAT with repo+workflow scope (used only if/when adopting Flux
  bootstrap-via-CLI; for Flux Operator we use SSH or HTTPS deploy keys instead).
- An age private key for SOPS:
  ```bash
  age-keygen -o ~/.config/sops/age/keys.txt
  export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
  ```
  Paste the resulting `age1...` public key into `.sops.yaml`.

## 1. Network

- Bell Hub 3000: DHCP enabled on `192.168.2.0/24`. FULL-REMOTE: no LB pool to
  carve out — nothing is exposed via a LAN LoadBalancer IP.
- Aruba S2500: L2-only; no VLAN config required. Confirm all interfaces in
  the default VLAN.
- Reserve `192.168.2.70` for the R730 in Bell Hub's DHCP, but Talos will
  static-config the address regardless — the reservation is belt-and-braces.

**Verify**: from your workstation, `arp -a` shows the R730 mgmt iDRAC and
the switch, and you can `ping 192.168.2.1` (Bell Hub).

## 2. Talos on the R730

```bash
# Generate machineconfig secrets (encrypts to .sops)
task talos:secrets

# Build R730 ISO via Talos Image Factory
task talos:r730:schematic
task talos:r730:iso

# Generate the machineconfig from bootstrap/talos/r730.yaml + patches
task talos:r730:config

# Flash + boot the R730 from the ISO (use IPMI virtual media or USB)
# Apply the machineconfig in maintenance mode:
talosctl apply-config --insecure \
  --nodes 192.168.2.70 \
  --file gen/talos-r730-machineconfig.yaml

# Bootstrap etcd (only on the FIRST control-plane node, ever)
talosctl --nodes 192.168.2.70 --endpoints 192.168.2.70 bootstrap

# Pull the kubeconfig out
talosctl --nodes 192.168.2.70 --endpoints 192.168.2.70 kubeconfig ./.kubeconfig
export KUBECONFIG=$PWD/.kubeconfig
```

**Verify**:
```bash
kubectl get nodes -o wide        # Ready, internal IP on br0
talosctl --nodes 192.168.2.70 dmesg | grep -i iommu   # IOMMU enabled
talosctl --nodes 192.168.2.70 read /proc/cmdline       # pcirebind.rebind=... present
```

## 3. Cilium

```bash
bootstrap/helm/01-cilium.sh
```

This installs Cilium with kube-proxy replacement and Hubble enabled.
FULL-REMOTE: L2 announce + LB IPAM stay OFF and no LB CRs are delivered —
there is no LAN LoadBalancer path.

**Verify**:
```bash
cilium status --wait
cilium connectivity test --test no-policies   # subset; full suite optional
kubectl -n kube-system get pods -l k8s-app=cilium
```

## 4. Flux (source + helm controllers) → installs Sveltos

```bash
export FLUX_REPO_PAT=<github-pat-with-repo-read>   # or pre-create flux-repo-pat
bootstrap/helm/02-flux.sh
```

This is the whole delivery bootstrap. It helm-installs Flux with only two
controllers — source-controller (git + chart fetcher) and helm-controller
(reconciles HelmReleases) — creates the git secret, then
`kubectl apply -f bootstrap/flux/`. That directory holds the `homelab`
GitRepository plus the Sveltos HelmRepository + HelmRelease. helm-controller
installs Sveltos, which auto-registers the cluster as `SveltosCluster/mgmt`.
No Flux Operator, no `FluxInstance`, no kustomize-controller, no ArgoCD.

**Verify**:
```bash
kubectl -n flux-system get gitrepository homelab     # Ready=True
kubectl -n flux-system get helmrelease sveltos       # Ready=True
kubectl -n projectsveltos get pods                   # Sveltos controllers Running
kubectl -n mgmt get sveltoscluster mgmt              # registered
```

## 5. Label mgmt + apply the root ClusterProfile

Label `mgmt` with its **persona** so ClusterProfiles target it (Sveltos owns the
SveltosCluster spec; we own its labels). ONE label — `persona` is the single
selector dimension (no `needs.*` sprawl):

```bash
kubectl -n mgmt label sveltoscluster mgmt \
  sveltos.projectsveltos.io/type=mgmt \
  tier=platform \
  persona=infra
# persona=infra = the hypervisor/provider plane (olm, storage, virt-host, capi,
# autoscaler, the arrakis API tunnel, tenant-arrakis, observability-backend).
# NO auth on infra — Dex runs on the platform (arrakis). tls/dns/observability-core
# also match arrakis via `persona In [infra, platform]`.
# arrakis is labelled persona=platform in git (tenants/arrakis/infra/cluster.yaml).
```

Then apply the **root ClusterProfile** — the single object that replaces the
old Flux Kustomization tree:

```bash
kubectl apply -f clusters/baremetal/sveltos-root.yaml
```

It kustomize-builds two dirs from the `homelab` GitRepository onto mgmt:
`clusters/baremetal/infrastructure/` (namespaces + Cilium runtime CRs) and
`platform/sveltos/clusterprofiles/` (every other ClusterProfile CR — Sveltos
manages Sveltos from here). The cluster then lights up in dependency order:
cert-manager, external-dns, Traefik, chisel-operator, Multus, Dex,
Longhorn, OLM + KubeVirt HCO, CAPI + Kamaji, observability.

### 5a. Apply secrets (plaintext, by hand)

There's no sealed-secrets / SOPS / ESO — cluster secrets are plaintext,
gitignored, applied by hand (see `secrets/README.md`). Fill each
`*.example.yaml` → `*.secret.yaml`, then:

```bash
./secrets/apply.sh    # applies secrets/**/*.secret.yaml to mgmt
```

Charts consume these by name (cloudflare token, dex-config, grafana OIDC,
minio). Their namespaces are created by the charts, so
`apply.sh` is **re-runnable** — run it once after the root profile has created
the namespaces, and Sveltos requeues any chart that was waiting on its secret.
The tenant's `infra-cluster-credentials` (kubevirt-csi) is applied separately,
against the tenant — not by this script.

**Verify**:
```bash
kubectl get clusterprofiles                         # root + all others present
kubectl get clustersummaries -A                     # one per (profile, cluster) — all Provisioned
kubectl get ciliumloadbalancerippool                # infra dir applied
kubectl -n cert-manager get clusterissuer letsencrypt-prod
kubectl -n longhorn-system get pods                 # storage up
kubectl get hyperconverged -n kubevirt-hyperconverged  # Deployed
kubectl get providers -A                            # core, capk, cabpk, kamaji
```

## 6. Verify Dex + OAuth2Clients

```bash
curl -sI https://auth.mershab.com/.well-known/openid-configuration   # 200
kubectl get oauth2clients -A                                         # all sync
# Grafana → Dex login (generic_oauth) → lands authenticated.
```

OAuth2Client CRs (per-UI) are part of the `dex` ClusterProfile — they ship
inline with the Helm release so each UI's client_id + redirect URIs land
the moment Dex comes up.

## 7. Observability layer

The observability ClusterProfiles (`07-observability-*`) deliver the stack
(this comes up as part of step 5; the checks below confirm it):

1. otel-operator (Operator + TargetAllocator CRs)
2. prometheus-operator-crds (ServiceMonitor/PodMonitor; no Prometheus controller)
3. otel-agent (DaemonSet, per-node TA) + otel-gateway (Deployment, exports
   metrics/logs to Loki + traces wherever)
4. loki (single-binary, MinIO S3 backend)
5. grafana-operator + Grafana CR
6. Datasources + dashboards (all `GrafanaDashboard` CRs from Git)

**Verify**:
```bash
kubectl -n observability get pods                  # all Running
# Grafana → Datasources → Loki + Prometheus(OTel) both OK
# Explore: see node + cluster metrics flowing
```

## 8. Tenant cluster

```bash
# The tenant-arrakis ClusterProfile delivers tenants/arrakis/infra/ — confirm CAPI sees it
kubectl get cluster -A
clusterctl describe cluster home -n tenants
```

CAPI's chain:
- `Cluster home` references a `KamajiControlPlane` (pods on bare-metal) + a
  `KubeVirtCluster` (infrastructure).
- `KamajiControlPlane` provisions a tenant kube-apiserver (OIDC against Dex —
  the `kubernetes` OAuth2Client), etcd (StatefulSet on `zfs`), and
  a Cilium LB Service for the API.
- `MachineDeployment`s (general / gpu-k80 / gpu-p2000) → CAPK creates
  `KubeVirtMachine`s → KubeVirt boots Ubuntu VMs with 2 NICs (pod + lan).
- CABPK supplies cloud-init that runs `kubeadm join` against the Kamaji-hosted
  CP. New nodes appear in the tenant cluster.

**Verify**:
```bash
TKUBECONFIG=tenant.kubeconfig
clusterctl get kubeconfig home -n tenants > $TKUBECONFIG
kubectl --kubeconfig=$TKUBECONFIG get nodes
# expect: 1 general + 2 gpu-k80 + 1 gpu-p2000 Ready

# OIDC: after `kubectl oidc-login` (or kubelogin) is wired in your kubeconfig,
# the tenant apiserver accepts your Dex-issued token:
kubectl --kubeconfig=$TKUBECONFIG auth whoami
# → Username: oidc:<email>, Groups: [oidc:platform-admins]
```

## 9. Tenant platform (Sveltos fan-out)

Sveltos auto-registered the tenant via the CAPI integration (the `Cluster`
CR's labels). ClusterProfiles in `tenants/arrakis/platform/clusterprofiles/`
should already be matching.

**Verify**:
```bash
kubectl get clusterprofiles
kubectl get clustersummaries -A    # one per matched (profile, cluster) pair
kubectl --kubeconfig=$TKUBECONFIG get crd | grep network-attachment   # Multus
kubectl --kubeconfig=$TKUBECONFIG -n kube-system get ds nvidia-device-plugin-daemonset
# scale a Deployment past pool capacity → cluster-autoscaler bumps replicas:
kubectl --kubeconfig=$TKUBECONFIG run scaletest --image=pause --replicas=20
kubectl get machinedeployment -A -w     # general replicas climb
```

## 10. First vCluster — home-assistant

```bash
# k3k creates the vCluster on the tenant; register it with the bare-metal
# Sveltos controller by hand (kubeconfig Secret + SveltosCluster) — see
# docs/runbooks/registering-a-k3k-vcluster.md. Matching ClusterProfiles then
# fan in.
kubectl get sveltoscluster -n vclusters home-assistant
```

Once registered, matching ClusterProfiles fire into the vCluster (Multus NAD,
OIDC RBAC bindings — the vCluster apiserver federates to Dex using the same
`kubernetes` OAuth2Client, prometheus annotations). The `apps/` Flux
Kustomization (targeting the vCluster kubeconfig) deploys HA.

**Verify**:
```bash
VKC=vc-home-assistant.kubeconfig
# pull from the vCluster's auto-generated Secret in the tenant
kubectl --kubeconfig=$TKUBECONFIG -n vclusters get secret vc-home-assistant-kubeconfig \
  -o jsonpath='{.data.config}' | base64 -d > $VKC
kubectl --kubeconfig=$VKC get nodes
kubectl --kubeconfig=$VKC -n projectsveltos get pod   # sveltos-applier Running
# HA pod has two interfaces:
kubectl --kubeconfig=$VKC -n home-assistant exec -it home-assistant-0 -- ip a
# expect eth0 (pod CIDR) + net1 (LAN, 192.168.2.x)
```

## 11. Remaining vClusters

Repeat step 11 for `frigate`, `jellyfin`, `ollama` (their manifests already
live in `tenants/arrakis/vclusters/`). Each adds an `OAuth2Client` CR for its UI.

## 12. etcd backup

Verify the etcd-backup CronJob fires on its first schedule:

```bash
kubectl -n etcd-backup get cronjob
kubectl -n etcd-backup get jobs --sort-by=.metadata.creationTimestamp
# Confirm the off-box destination (Hetzner storage box / B2) has the file.
```

## 13. R820 (later)

When the R820 arrives:

1. Write `bootstrap/talos/r820.yaml` (copy r730 + adjust hardware specifics).
2. Build ISO, flash, boot, `talosctl apply-config`.
3. The node joins as a worker (or control plane joiner if scaling CP to 3).
4. If the R820 brings new GPUs, extend `permittedHostDevices` in
   `clusters/baremetal/infrastructure/kubevirt-hco/hyperconverged.yaml`.
5. The R820 is HDD — give it its own zpool + StorageClass (e.g. `zfs-hdd`);
   do NOT extend `tank` across nodes (ZFS LocalPV is node-local).

See `docs/runbooks/adding-a-bare-metal-node.md` for the full procedure.
