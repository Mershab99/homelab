# Architecture

A flat-network, single-bare-metal Talos cluster running KubeVirt + CAPI +
Kamaji + vCluster. One Dex federates OIDC across every kube-apiserver and UI.

## 1. Topology

```
Bare-metal Talos cluster (R730 → +R820)
├── Infra: Cilium, Multus, ingress-nginx (internal+external), chisel-operator,
│   cert-manager, external-dns, ZFS LocalPV, KubeVirt HCO,
│   CAPI core + CAPK + CABPK + kamaji-operator
├── Platform: Sveltos, Dex
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
| Sveltos registration        | CAPI integration (push) for tenant; event-driven auto-registration for vClusters (exportKubeConfig Secret → hub EventTrigger → SveltosCluster) |
| Autoscaling                 | cluster-autoscaler (CAPI provider) delivered via Sveltos |
| Storage                     | OpenEBS LocalPV-ZFS on bare-metal — zpool `tank`, 7×2 mirrors + 1 warm spare, created once by `bootstrap/zfs/create-pool.sh`. Classes: `fast-zfs` (default, dataset), `fast-block` (zvol+ext4, KubeVirt disks), `db-zfs` (16k recordsize); snapshots via `zfs-snapclass`. Tenants consume it through kubevirt-csi passthrough (`kubevirt` class → hub `fast-block`). |
| GitOps                      | Flux **source + helm controllers only** (helm-installed); helm-controller installs Sveltos via one HelmRelease, a root `ClusterProfile` self-manages the rest. **No Flux Operator/Kustomizations, no ArgoCD.** |
| Secrets                     | plaintext manifests, gitignored, applied by hand (`secrets/`); SOPS only for Talos machineconfig |
| CNI                         | Cilium primary + Multus for KubeVirt secondary NICs |
| LB classes                  | `external` (chisel-operator → DO droplet) for public; Cilium LB-IPAM + L2 announce (`lan-pool` 192.168.2.240–250, hub only) for LAN — the arrakis CP Service claims 192.168.2.240. |

## 3. Network

- **Edge:** Bell Hub 3000 (DHCP, NAT). **Switch:** Aruba S2500 (L2 only).
  Single flat subnet, no VLANs.
- Talos node IPs pinned in machineconfig — do not rely on Bell Hub DHCP.
- Cilium LB-IPAM `lan-pool` (192.168.2.240–250) + L2 announcer on the hub
  (`bootstrap/helm/cilium-lb-lan.yaml`, applied by `01-cilium.sh`). The arrakis
  CP Service claims 192.168.2.240 — the LAN kubectl path. Public = chisel
  tunnel → DO droplet (`k8s-home.mershab.com`).
- **LAN-attached pods:** host bridge `br0` on every Talos node. Bare-metal NAD
  `lan-bridge` (macvlan over br0). Every tenant worker VM gets a secondary NIC
  on `br0`. Tenant-side Sveltos profile installs a DaemonSet that builds
  `br-lan` on the VMs over eth1, plus a tenant NAD `lan`. vCluster pods
  annotate `k8s.v1.cni.cncf.io/networks: lan` to attach.

## 4. Label taxonomy (Sveltos) — one `persona` dimension

ClusterProfiles select on a SINGLE label, `persona`. No `needs.*` sprawl. Each
cluster IS one persona; a profile targets the persona that owns its bundle.

| `persona` | Cluster | Owns |
|---|---|---|
| `infra` | contraxia (hub) | hypervisor/provider plane: olm, storage, virt-host, capi, autoscaler, arrakis-API tunnel, tenant-arrakis (CAPI), observability-backend |
| `platform` | arrakis (AIO estate) | multus, cilium, kubevirt-csi, gpu, tenant-ingress, auth (Dex), db, vcluster, all apps |
| `ai` | every persona vCluster (family, mershab) | mcp-baseline (kagent-crds/KMCP), oidc-rbac; per-vcluster apps via the extra `vcluster: <name>` label |

Cross-persona bundles use `matchExpressions: {key: persona, operator: In, values: […]}`:
- `tls-stack`, `dns`, `observability-core` → `In [infra, platform]`.
- `oidc-rbac` → `persona: ai` ONLY — vClusters are the only apiservers that
  federate to Dex. arrakis HOSTS Dex, so its apiserver does not (cert-auth only).

The `persona` label is set in git on the arrakis Cluster CR
(`tenants/arrakis/infra/cluster.yaml`) and by hand on the mgmt SveltosCluster
(bootstrap) + each vCluster at registration. `sveltos.projectsveltos.io/type`
and `tier` remain as structural metadata but are no longer selected on.
Sveltos is for **capability fanout**, not per-instance config.

## 5. Hard rules

- **No secrets in Git.** Cluster secrets are plaintext + gitignored
  (`*.secret.yaml`), applied by hand (`secrets/`). SOPS (`.sops.yaml`) covers
  only the Talos machineconfig.
- **Bare-metal cluster is not disposable.** etcd snapshots are non-negotiable.
- **Storage is ZFS on the host, not a replicated overlay.** The `zfs` system
  extension is version-COUPLED to the Talos release it was built against: before
  any `talosctl upgrade`, re-POST `bootstrap/talos/r730-schematic.yaml` for the
  target version and confirm the extension exists for it. A mismatch leaves
  `tank` unimportable and every PVC offline. The pool itself is below the GitOps
  line; only LocalPV-ZFS and the StorageClasses are git-driven.
- **Dex lives on bare-metal.** It is the auth backbone for every UI (Grafana,
  and any future OIDC app) **and** for every kube-apiserver above the
  bare-metal one (tenant Kamaji + each vCluster). Connector is the built-in
  password-db (users + bcrypt'd passwords in the plaintext `dex-config` Secret) — no upstream
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
- **Sveltos delivers everything, including to bare-metal. Flux only fetches +
  installs Sveltos.** Flux runs two controllers (helm-installed,
  `bootstrap/helm/02-flux.sh`): source-controller reconciles the `homelab`
  GitRepository + the Sveltos chart into artifacts; helm-controller installs
  Sveltos from the single HelmRelease in `bootstrap/flux/`. There is no Flux
  Operator, no `FluxInstance`, no kustomize-controller, and no ArgoCD.
  Bootstrap is two helm installs (Cilium → Flux) plus
  `kubectl apply -f bootstrap/flux/` (done by the script), then one imperative
  `kubectl apply -f clusters/baremetal/sveltos-root.yaml`. That
  **root `ClusterProfile`** kustomize-builds `clusters/baremetal/infrastructure/`
  (namespaces + Cilium runtime CRs) and `platform/sveltos/clusterprofiles/`
  (every other `ClusterProfile` CR) onto `mgmt` — Sveltos manages Sveltos from
  there, replacing the old Flux Kustomization tree. Everything else —
  cert-manager, external-dns, Traefik, chisel-operator, Multus, Dex,
  LocalPV-ZFS, OLM + KubeVirt HCO, CAPI/Kamaji, OTel, Loki, Grafana — is a
  label-selected `ClusterProfile`. The bare-metal cluster auto-registers as
  `SveltosCluster/mgmt`; the same profiles match tenant + vClusters when they
  come online — no rewrite needed.
- **vCluster boundary is API-only, not data-plane.** Observability and
  networking happen at the host (tenant) layer.

## 6. Growth properties

- **Add R820:** `bootstrap/talos/r820.yaml`, `talosctl apply-config`. KubeVirt
  sees it; MachineDeployments can schedule more VMs.
- **More tenant workers:** bump `replicas` in MachineDeployment (or let CAS
  do it via the autoscaler annotations).
- **New worker pool:** add KubeVirtMachineTemplate + KubeadmConfigTemplate +
  MachineDeployment under `tenants/arrakis/infra/`. Label so matching
  ClusterProfiles target it.
- **New workload:** `cp -r tenants/arrakis/vclusters/_template
  tenants/arrakis/vclusters/<name>`; edit labels; add `apps/`. Add `OAuth2Client`
  if it has a UI.
- **Second tenant cluster:** `cp -r tenants/arrakis tenants/<name>`. Platform
  layer (`platform/sveltos/`) unchanged.
