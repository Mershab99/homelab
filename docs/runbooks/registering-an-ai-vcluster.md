# AI vclusters: how registration works (hands-free)

vclusters (Loft OSS, e.g. `ai` from `12-vcluster-ai.yaml`) self-register with
the hub Sveltos — there are NO manual steps. This runbook documents the
machinery and how to verify/debug it.

## The chain

1. **vcluster exports its kubeconfig** — `exportKubeConfig.additionalSecrets`
   writes Secret `<name>-export-kubeconfig` in the host ns (e.g.
   `vcluster-ai/ai-export-kubeconfig`), with `server:` rewritten to the edge
   hostname (`https://k8s-ai.mershab.com:443` — nginx SNI ssl-passthrough on
   the one chisel LB, so the API is reachable from mgmt and anywhere else).
2. **EventSource `vcluster-exported-kubeconfig`** (hub,
   `clusters/baremetal/infrastructure/vcluster-autoregister.yaml`) matches
   Secrets named `*-export-kubeconfig` on persona=platform clusters and
   collects them.
3. **EventTrigger `vcluster-autoregister`**:
   - `secretGenerator` copies the Secret to mgmt ns `projectsveltos` (key
     stays `config`);
   - deploys the instantiated `SveltosCluster projectsveltos/<name>` (labeled
     `persona: ai`) into the mgmt cluster itself (`destinationCluster:
     mgmt/mgmt`).
4. persona=ai profiles (`12-vcluster-baseline`, `11-oidc-rbac`) fan in — the
   vcluster apiservers are the only ones federated to Dex.

## Naming convention

Export secret MUST be named `<vcluster>-export-kubeconfig` — the trigger
derives the SveltosCluster name by trimming the suffix.

## Verify

```bash
kubectl --context admin@arrakis get secret -n vcluster-ai ai-export-kubeconfig
kubectl --context admin@contraxia get secret -n projectsveltos ai-export-kubeconfig
kubectl --context admin@contraxia get sveltoscluster -n projectsveltos ai
# READY true → baseline/oidc-rbac fan in

# API through the edge (SNI passthrough):
curl -k https://k8s-ai.mershab.com/version   # → 401 Unauthorized = reachable
```

## Debug

- No mgmt secret? Check EventSource/EventTrigger status:
  `kubectl --context admin@contraxia get eventsource,eventtrigger -o yaml`
  and the event-manager logs in ns `projectsveltos`.
- SveltosCluster not READY? The hub can't reach the API — test the curl
  above; check the vcluster Ingress + `--enable-ssl-passthrough` on the
  arrakis ingress-nginx controller (12-tenant-ingress).
- Human access: grab the same exported kubeconfig —
  `kubectl --context admin@arrakis get secret -n vcluster-ai ai-export-kubeconfig -o jsonpath='{.data.config}' | base64 -d > ~/.kube/ai.yaml`
