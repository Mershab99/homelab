# Adding a vCluster (new workload)

Use when you want a new logically-isolated API surface for a workload
(home-assistant, jellyfin, ollama, frigate are existing examples).

## Steps

1. **Copy the template:**
   ```bash
   cp -r tenants/home/vclusters/_template tenants/home/vclusters/<name>
   ```
2. **`tenant-side/`** lives in the tenant cluster. The HelmRelease there spins
   up the vCluster itself **and** bundles `sveltos-applier` via
   `experimental.deploy.vcluster.helm` so the vCluster registers itself with
   the bare-metal Sveltos controller. Edit:
   - vCluster name
   - kube-apiserver OIDC extraArgs (rarely changes — same `kubernetes`
     OAuth2Client)
   - `experimental.deploy.vcluster.helm[0].values.sveltosCluster.name` to the
     vCluster name (used as the slot label key)
3. **`baremetal-side/`** lives on the bare-metal cluster. The
   `SveltosCluster` slot CR there has labels that decide which
   `ClusterProfile`s fire into the vCluster:
   ```yaml
   metadata:
     labels:
       sveltos.projectsveltos.io/type: vcluster
       workload: <name>
       needs.lan: "true"         # if it needs a host bridge attach
       needs.gpu: "p2000"        # or "k80" or "false"
       oidc.enabled: "true"
   ```
4. **`apps/`** is what runs inside the vCluster (deployments, services, NADs,
   ingresses, oauth2-proxy, etc.). A Flux Kustomization targeting the vCluster
   kubeconfig deploys it.
5. **`OAuth2Client`** if the workload has a UI: add a CR under
   `clusters/baremetal/identity/oauth2clients/<name>.yaml`. Per-app secret,
   per-app redirect URIs.
6. **Push.** Flux reconciles the tenant-side HelmRelease + baremetal-side
   SveltosCluster slot. Once the vCluster is up and the applier dials home,
   matching ClusterProfiles fan out platform addons (Multus, OIDC RBAC,
   prometheus annotations). Then `apps/` reconciles into the vCluster.

## Verify

```bash
# vCluster is up and registered
kubectl --kubeconfig=vc-<name>.kubeconfig get nodes
kubectl --kubeconfig=vc-<name>.kubeconfig -n projectsveltos get pod
kubectl get sveltoscluster -n vclusters <name> -o yaml | yq .status

# Workload is reachable + observable
kubectl --kubeconfig=vc-<name>.kubeconfig get all -A
# Grafana shows pods tagged `vcluster=<name>`
```
