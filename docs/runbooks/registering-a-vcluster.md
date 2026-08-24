# vclusters: how registration works (hands-free)

vclusters (Loft OSS — `family`, `mershab` from `12-vcluster-*.yaml`)
self-register with the hub Sveltos — there are NO manual steps. This runbook
documents the machinery and how to verify/debug it.

## The chain

1. **vcluster exports its kubeconfig** — `exportKubeConfig.additionalSecrets`
   writes Secret `<name>-export-kubeconfig` in the host ns (e.g.
   `vcluster-family/family-export-kubeconfig`), with `server:` rewritten to
   the edge hostname (`https://k8s-<name>.mershab.com:443` — nginx SNI
   ssl-passthrough on the one chisel LB, so the API is reachable from mgmt
   and anywhere else).
2. **EventSource `vcluster-exported-kubeconfig`** (hub,
   `clusters/baremetal/infrastructure/vcluster-autoregister.yaml`) matches
   Secrets named `*-export-kubeconfig` on persona=platform clusters and
   collects them.
3. **EventTrigger `vcluster-autoregister`** renders its policyRef template
   (ConfigMap `vcluster-sveltoscluster-template`, instantiated with the event
   resource) into the mgmt cluster itself (`destinationCluster: mgmt/mgmt`):
   - a copy of the kubeconfig Secret in mgmt ns `projectsveltos` (key `config`);
   - `SveltosCluster projectsveltos/<name>` labeled **`persona: ai`** (any
     vcluster — shared bundles) **+ `vcluster: <name>`** (this one — its
     per-persona app profile).
   (NOT secretGenerator — generators reference template Secrets that must
   already exist in the MGMT cluster; they cannot read the event resource.)
4. Profiles fan in: `16-mcp-baseline` + `11-oidc-rbac` (persona=ai) and the
   per-vcluster apps profile (`17-family-apps` / `18-mershab-apps`,
   vcluster=<name>). The vcluster apiservers are the only ones federated to Dex.

## Naming convention

Export secret MUST be named `<vcluster>-export-kubeconfig` — the trigger
derives the SveltosCluster name (and the `vcluster` label) by trimming the
suffix.

## Verify

```bash
kubectl --context admin@arrakis get secret -n vcluster-family family-export-kubeconfig
kubectl --context admin@contraxia get secret -n projectsveltos family-export-kubeconfig
kubectl --context admin@contraxia get sveltoscluster -n projectsveltos family --show-labels
# READY true + labels persona=ai,vcluster=family → profiles fan in

# API through the edge (SNI passthrough):
curl -k https://k8s-family.mershab.com/version   # → 401 Unauthorized = reachable
```

## Debug

- No mgmt secret? Check EventSource/EventTrigger status:
  `kubectl --context admin@contraxia get eventsource,eventtrigger -o yaml`
  and the event-manager logs in ns `projectsveltos`.
- SveltosCluster not READY? The hub can't reach the API — test the curl
  above; check the vcluster Ingress + `--enable-ssl-passthrough` on the
  arrakis ingress-nginx controller (12-tenant-ingress).
- Human access: `task vc:kubeconfig VC=<name>` — or grab the exported secret:
  `kubectl --context admin@arrakis get secret -n vcluster-family family-export-kubeconfig -o jsonpath='{.data.config}' | base64 -d > ~/.kube/family.yaml`
