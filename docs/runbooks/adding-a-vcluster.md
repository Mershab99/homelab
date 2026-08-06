# Adding a vCluster (AI/MCP isolation only)

**First: do you actually need a vCluster?** The default home for a workload is a
**flat namespace on arrakis**, not a vCluster. vClusters are reserved for the
**AI/MCP layer** — throwaway, RBAC-isolated groups of kagent Agents / KMCP MCP
servers that want a hard blast-radius boundary. The `ai` vCluster is the first
and (today) only one.

- **Normal app** (public or private) → flat namespace. Add
  `tenants/arrakis/apps/<app>/` manifests + a tenant-selector ClusterProfile
  (model on `13-app-web.yaml` for public, `13-app-home-assistant.yaml` for a
  private LAN app). No vCluster involved.
- **A new AI/MCP group** that must be isolated from the `ai` vCluster → a new
  vCluster, per the steps below. (Start by just adding CRs to `ai`; split only
  when a real trust boundary appears.)

vClusters run on **arrakis** via **Loft vcluster (OSS)** — plain API
isolation. Both generic CR sync (`sync.toHost.customResources`) and the
`integrations.*` (certManager etc.) are vCluster PRO — the OSS syncer
crashloops on them. kagent + kmcp therefore run INSIDE each vcluster
(`16-ai-helpers`, persona=ai); shared from the host: nodes/CNI/CSI, storage
classes, the edge.

## Steps

1. **Add a vcluster ClusterProfile** — copy
   `platform/sveltos/clusterprofiles/12-vcluster-ai.yaml` to
   `12-vcluster-<name>.yaml`: change releaseName/ns to `<name>`/
   `vcluster-<name>`, the Ingress host, and the export secret name
   `<name>-export-kubeconfig` (the suffix is the auto-registration
   convention). Add a host-ns NAD dir if the workloads attach to the LAN
   (model on `platform/sveltos/manifests/vcluster-ai/`). List the profile in
   `clusterprofiles/kustomization.yaml`.

2. **Push.** Flux reconciles → Sveltos installs the vcluster chart on arrakis
   → the exported kubeconfig Secret appears → the hub EventTrigger registers
   `SveltosCluster projectsveltos/<name>` (persona=ai) automatically — see
   [registering-an-ai-vcluster.md](registering-an-ai-vcluster.md). Then
   `16-ai-helpers` + `11-oidc-rbac` fan in.

3. **Helpers fan in automatically:** `16-ai-helpers` (persona=ai) installs
   kagent + kmcp inside every registered vcluster; author kagent/kmcp CRs
   there. Only add a per-vcluster profile for extras beyond that.

## Verify

```bash
# vcluster Running on arrakis
kubectl --context admin@arrakis get pods -n vcluster-<name>

# auto-registered with the hub
kubectl --context admin@contraxia get sveltoscluster -n projectsveltos <name> -o yaml | yq .status

# API through the edge (SNI ssl-passthrough)
curl -k https://k8s-<name>.mershab.com/version   # 401 = reachable
```
