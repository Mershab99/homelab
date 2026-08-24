# Adding a vCluster (one per persona)

**Model: one vcluster per persona** — a personal context holding that
persona's apps AND MCP servers behind one RBAC/API boundary. Today:
`family` (Home Assistant, mediaserver, PhotoPrism) and `mershab`
(Vaultwarden, website, MCP servers). Infra/platform services (edge, DNS,
TLS, storage, Dex, operators) stay on arrakis flat namespaces — a vcluster
never runs its own cert-manager/ingress/external-dns.

vClusters run on **arrakis** via **Loft vcluster (OSS)** — plain API
isolation. Both generic CR sync (`sync.toHost.customResources`) and the
`integrations.*` (certManager etc.) are vCluster PRO — the OSS syncer
crashloops on them. Consequences:

- kmcp (+ kagent-crds) runs INSIDE each vcluster (`16-mcp-baseline`,
  persona=ai) — a host controller can't see in-vcluster CRs.
- App exposure uses `sync.toHost.ingresses` (OSS): Ingresses created inside
  the vcluster materialize in the host ns, where the arrakis edge nginx +
  cert-manager + external-dns handle class/TLS/DNS.
- Shared from the host: nodes/CNI/CSI, the `kubevirt` StorageClass, the edge.

## Steps

1. **Add a vcluster ClusterProfile** — copy
   `platform/sveltos/clusterprofiles/12-vcluster-family.yaml` to
   `12-vcluster-<name>.yaml`: change releaseName/ns to `<name>`/
   `vcluster-<name>`, the Ingress host `k8s-<name>.mershab.com`, and the
   export secret name `<name>-export-kubeconfig` (the suffix is the
   auto-registration convention). Add a host-ns NAD dir if the workloads
   attach to the LAN (model on `platform/sveltos/manifests/vcluster-family/`).
   List the profile in `clusterprofiles/kustomization.yaml`.

2. **Add the persona's apps profile** — `NN-<name>-apps.yaml` with
   `clusterSelector: matchLabels: {vcluster: <name>}` (the autoregister
   template stamps that label). Model on `17-family-apps.yaml` /
   `18-mershab-apps.yaml`. Sensitive helm values go through `valuesFrom` →
   a mgmt Secret in ns `tenant-secrets` (template under `secrets/apps/`).

3. **Push.** Flux reconciles → Sveltos installs the vcluster chart on arrakis
   → the exported kubeconfig Secret appears → the hub EventTrigger registers
   `SveltosCluster projectsveltos/<name>` (persona=ai + vcluster=<name>)
   automatically — see [registering-a-vcluster.md](registering-a-vcluster.md).
   Then `16-mcp-baseline` + `11-oidc-rbac` + the apps profile fan in.

4. **MCP servers:** hand-apply MCPServer CRs into the vcluster
   (`task vc:kubeconfig VC=<name>`) — see
   `platform/sveltos/manifests/mcp-baseline/README.md`.

## Verify

```bash
# vcluster Running on arrakis
kubectl --context admin@arrakis get pods -n vcluster-<name>

# auto-registered with the hub
kubectl --context admin@contraxia get sveltoscluster -n projectsveltos <name> --show-labels

# API through the edge (SNI ssl-passthrough)
curl -k https://k8s-<name>.mershab.com/version   # 401 = reachable

# app ingresses synced to the host ns (edge serves them)
kubectl --context admin@arrakis get ingress -n vcluster-<name>
```
