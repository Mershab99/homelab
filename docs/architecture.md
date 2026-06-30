# Architecture

A flat-network, single-bare-metal Talos cluster running KubeVirt + CAPI +
Kamaji + vCluster. One Dex federates OIDC across every kube-apiserver and UI.

## 1. Topology

```
Bare-metal Talos cluster (R730 → +R820)
├── Infra: Cilium, Multus, ingress-nginx (internal+external), chisel-operator,
│   cert-manager, external-dns, ZFS LocalPV, KubeVirt HCO,
│   CAPI core + CAPK + CABPK + kamaji-operator
├── Platform: Sveltos, Dex, sealed-secrets, Headlamp
├── Observability: OTel Operator + TargetAllocator, prometheus-operator CRDs,
│   Loki (single-binary, MinIO S3 backend), Grafana Operator, Grafana
│
└── Tenant cluster "home"
    ├── Control plane: KamajiControlPlane (pods on bare-metal, OIDC to Dex)
    ├── Workers (KubeVirt VMs, Ubuntu, kubeadm via CABPK):
    │     general (autoscale 1-5) / gpu-k80 (2) / gpu-p2000 (1)
    │
    ├── Platform addons (Sveltos ClusterProfiles, push via CAPI integration):
    │     kubevirt-csi, Multus, GPU operator (NVIDIA), OTel agent,
    │     prometheus-operator CRDs, cluster-autoscaler, OIDC RBAC
    │
    └── vClusters (vCluster OSS, one per workload, agent-mode applier bundled):
        ├── home-assistant — Multus NAD into LAN
        ├── frigate         — GPU: p2000
        ├── jellyfin        — GPU: p2000 (time-sliced with frigate)
        └── ollama          — GPU: k80
```

## 2. Locked decisions

| Topic                       | Decision |
|-----------------------------|----------|
| Tenant control plane        | **Kamaji** (CP as pods on bare-metal) |
| Hardware                    | R730 day-1, **R820** later |
| Tenant pools                | 3: `general` (autoscale 1–5), `gpu-k80` (2), `gpu-p2000` (1) |
| DNS                         | Cloudflare only (ExternalDNS). No internal CoreDNS. |
| Domain                      | `mershab.com` |
| Sveltos registration        | CAPI integration (push) for tenant; agent mode (pull) for vClusters |
| Autoscaling                 | cluster-autoscaler (CAPI provider) delivered via Sveltos |
| Storage                     | ZFS LocalPV (zpool `tank`, 7 mirrors) on bare-metal; kubevirt-csi passthrough in tenant |
| GitOps                      | Flux Operator → Flux on bare-metal only. **No Flux in tenant or vClusters.** |
| Secrets                     | sealed-secrets for v1 (SOPS still configured) |
| CNI                         | Cilium primary + Multus for KubeVirt secondary NICs |
| LB classes                  | `internal` (Cilium LAN IP); `external` (chisel-operator → VPS) |

## 3. Network

- **Edge:** Bell Hub 3000 (DHCP, NAT). **Switch:** Aruba S2500 (L2 only).
  Single flat subnet, no VLANs.
- Talos node IPs pinned in machineconfig — do not rely on Bell Hub DHCP.
- Cilium LB IPAM pool: `192.168.2.200–240` (carved from the Bell Hub subnet).
- Cilium L2 announcer ARPs LB IPs on the LAN.
- **LAN-attached pods:** host bridge `br0` on every Talos node. Bare-metal NAD
  `lan-bridge` (macvlan over br0). Every tenant worker VM gets a secondary NIC
  on `br0`. Tenant-side Sveltos profile installs a DaemonSet that builds
  `br-lan` on the VMs over eth1, plus a tenant NAD `lan`. vCluster pods
  annotate `k8s.v1.cni.cncf.io/networks: lan` to attach.

## 4. Label taxonomy (Sveltos)

| Label                                    | Values                          | Gates                  |
|------------------------------------------|----------------------------------|------------------------|
| `sveltos.projectsveltos.io/type`         | `tenant`, `vcluster`             | top-level kind         |
| `tier`                                   | `platform`, `workload`           | broad fanout           |
| `workload`                               | `home-assistant`, `frigate`, ... | per-vCluster overrides |
| `needs.lan`                              | `"true"` / `"false"`             | Multus + NAD           |
| `needs.gpu`                              | `"k80"`, `"p2000"`, `"false"`    | GPU plugin tweaks      |
| `needs.storage`                          | `zfs`                            | StorageClass plumbing  |
| `oidc.enabled`                           | `"true"`                         | OIDC RBAC              |

Per-instance config lives in `tenants/home/vclusters/<name>/apps/`.
Sveltos is for **capability fanout**, not per-instance config.

## 5. Hard rules

- **No inline secrets, ever.** Sealed or SOPS. `.sops.yaml` at repo root.
- **Bare-metal cluster is not disposable.** etcd snapshots are non-negotiable.
- **Dex lives on bare-metal.** It is the auth backbone for every UI (Headlamp,
  Grafana, per-app oauth2-proxy) **and** for every kube-apiserver above the
  bare-metal one (tenant Kamaji + each vCluster). Connector is the built-in
  password-db (users + bcrypt'd passwords in a sealed Secret) — no upstream
  IdP yet. Never nest in a vCluster.
- **Bare-metal kube-apiserver is the OIDC exception.** It hosts Dex, so it
  cannot federate to Dex (chicken-and-egg). It stays on local Talos kubeconfig
  + ServiceAccount tokens. Every kube-apiserver *above* it (tenant + vClusters)
  uses OIDC against Dex.
- **Dashboards-as-code.** Never import from the Grafana UI — commit a
  `GrafanaDashboard` CR.
- **One `OAuth2Client` per UI.** Per-app secrets, per-app redirect URIs.
- **One OIDC client (`kubernetes`) for every OIDC-enabled kube-apiserver.**
  Tenant + all vClusters share it. One group taxonomy
  (`oidc:platform-admins`, `oidc:viewers`). One kubeconfig with N contexts.
- **Sveltos delivers everything that fans out, including to bare-metal.**
  Flux installs only the bare-metal bootstrap minimum (Cilium runtime CRs,
  sealed-secrets, Sveltos itself, CAPI/Kamaji, KubeVirt HCO, ZFS LocalPV).
  Everything else — cert-manager, external-dns, ingress-nginx, chisel-operator,
  Multus, Dex, Headlamp, OTel, Loki, Grafana — is a `ClusterProfile` in
  `platform/sveltos/clusterprofiles/` selected by label. The bare-metal
  cluster auto-registers as a `SveltosCluster` named `mgmt` and receives
  profiles matching its labels. Same profiles match tenant + vClusters when
  those come online — no rewrite needed.
- **vCluster boundary is API-only, not data-plane.** Observability and
  networking happen at the host (tenant) layer.

## 6. Growth properties

- **Add R820:** `bootstrap/talos/r820.yaml`, `talosctl apply-config`. KubeVirt
  sees it; MachineDeployments can schedule more VMs.
- **More tenant workers:** bump `replicas` in MachineDeployment (or let CAS
  do it via the autoscaler annotations).
- **New worker pool:** add KubeVirtMachineTemplate + KubeadmConfigTemplate +
  MachineDeployment under `tenants/home/infra/`. Label so matching
  ClusterProfiles target it.
- **New workload:** `cp -r tenants/home/vclusters/_template
  tenants/home/vclusters/<name>`; edit labels; add `apps/`. Add `OAuth2Client`
  if it has a UI.
- **Second tenant cluster:** `cp -r tenants/home tenants/<name>`. Platform
  layer (`platform/sveltos/`) unchanged.
