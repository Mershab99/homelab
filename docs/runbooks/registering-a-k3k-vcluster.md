# Registering a k3k vCluster with the hub Sveltos

k3k has no equivalent of Loft's bundled `sveltos-applier` (which self-registered
the vCluster back to mgmt). Instead we register each k3k vCluster with the hub
Sveltos in **push mode**, from the kubeconfig k3k generates. This is the one
runtime step per vCluster — everything else (the k3k `Cluster` CR, the app
ClusterProfiles) is declarative in Git.

Prereq: the k3k `Cluster` (e.g. `mershab` in ns `k3k-mershab` on arrakis) is
Ready and its API server is reachable from mgmt (`192.168.2.70`). mgmt and the
arrakis KubeVirt VMs share the LAN, so a LAN-reachable address works.

## Steps (run against the **arrakis** tenant, then the **mgmt** hub)

1. **Get the vCluster kubeconfig** (on a box with `k3kcli`, pointed at arrakis):
   ```bash
   k3kcli kubeconfig generate --namespace k3k-mershab --name mershab \
     --kubeconfig-server https://<LAN-reachable-k3k-api>:<port> \
     > mershab.kubeconfig
   ```
   `--kubeconfig-server` must be an address mgmt can reach (the k3k `expose`
   LoadBalancer/NodePort address on the arrakis LAN), not the in-cluster
   ClusterIP.

2. **Create the kubeconfig Secret on the mgmt hub** in ns `vclusters`:
   ```bash
   kubectl --context mgmt -n vclusters create secret generic mershab-kubeconfig \
     --from-file=value=mershab.kubeconfig
   ```

3. **Register the SveltosCluster** on mgmt (drives the app ClusterProfile
   selectors — matches `13-app-mershab-web` which targets `mershab`/`vclusters`):
   ```yaml
   apiVersion: lib.projectsveltos.io/v1beta1
   kind: SveltosCluster
   metadata:
     name: mershab
     namespace: vclusters
     labels:
       sveltos.projectsveltos.io/type: vcluster
       workload: mershab
       needs.lan: "true"
       oidc.enabled: "true"
   spec:
     kubeconfigName: mershab-kubeconfig
   ```
   (For `family`, substitute name/namespace/label `workload: family`.)

## Verify

```bash
kubectl --context mgmt get sveltoscluster -n vclusters mershab -o yaml | yq .status
# Ready: true  → app ClusterProfiles fan out into the vCluster
```

## Notes

- The kubeconfig Secret is the only out-of-Git artifact per vCluster (the
  kubeconfig is generated at runtime by k3k). Rotate by regenerating and
  replacing the Secret.
- Once registered, `12-vcluster-baseline` (LAN NAD, selector `type=vcluster`)
  and `11-oidc-rbac` (selector `oidc.enabled`) fan in automatically.
