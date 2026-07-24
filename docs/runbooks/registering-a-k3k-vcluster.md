# Registering a k3k vCluster with the hub Sveltos

k3k has no equivalent of Loft's bundled `sveltos-applier` (which self-registered
the vCluster back to mgmt). Instead we register each k3k vCluster with the hub
Sveltos in **push mode**, from the kubeconfig k3k generates. This is the one
runtime step per vCluster — everything else (the k3k `Cluster` CR, the helpers
ClusterProfile) is declarative in Git.

vClusters are reserved for the AI/MCP layer; `ai` is the running example below.

Prereq: the k3k `Cluster` (e.g. `ai` in ns `k3k-ai` on arrakis) is Ready and its
API server is reachable from mgmt (`192.168.2.70`). mgmt and the arrakis KubeVirt
VMs share the LAN, so a LAN-reachable address works.

## Steps (run against the **arrakis** tenant, then the **contraxia** hub)

1. **Get the vCluster kubeconfig** (on a box with `k3kcli`, pointed at arrakis):
   ```bash
   k3kcli kubeconfig generate --namespace k3k-ai --name ai \
     --kubeconfig-server https://<LAN-reachable-k3k-api>:<port> \
     > ai.kubeconfig
   ```
   `--kubeconfig-server` must be an address mgmt can reach (the k3k `expose`
   LoadBalancer/NodePort address on the arrakis LAN), not the in-cluster
   ClusterIP.

2. **Create the kubeconfig Secret on the contraxia hub** in ns `vclusters`:
   ```bash
   kubectl --context admin@contraxia -n vclusters create secret generic ai-kubeconfig \
     --from-file=value=ai.kubeconfig
   ```

3. **Register the SveltosCluster** on contraxia with `persona: ai` (the single
   selector — drives `16-ai-helpers`, `12-vcluster-baseline`, and `11-oidc-rbac`,
   the only apiservers that federate to Dex):
   ```yaml
   apiVersion: lib.projectsveltos.io/v1beta1
   kind: SveltosCluster
   metadata:
     name: ai
     namespace: vclusters
     labels:
       persona: ai
   spec:
     kubeconfigName: ai-kubeconfig
   ```
   (For a future AI/MCP vCluster, substitute name/namespace; keep `persona: ai`.)

## Verify

```bash
kubectl --context admin@contraxia get sveltoscluster -n vclusters ai -o yaml | yq .status
# Ready: true  → helpers ClusterProfiles fan out into the vCluster
```

## Notes

- The kubeconfig Secret is the only out-of-Git artifact per vCluster (the
  kubeconfig is generated at runtime by k3k). Rotate by regenerating and
  replacing the Secret.
- Once registered, `12-vcluster-baseline` and `11-oidc-rbac` (both `persona=ai`)
  fan in automatically. `11-oidc-rbac` applies to vClusters ONLY — arrakis hosts
  Dex, so its apiserver does not federate to it.
