# Adding a tenant MachineDeployment (new worker pool)

Use when you need a new class of worker in the tenant cluster (e.g. a new GPU
type, an ARM pool, a high-memory pool).

## Steps

1. **KubeVirtMachineTemplate** at
   `tenants/home/infra/kubevirtmachinetemplates/<pool>.yaml`. Copy the closest
   existing template. Define:
   - vCPU + memory request
   - root disk size (PVC dataVolume on `ceph-block-rbd`)
   - GPU `hostDevices` entry (must match `permittedHostDevices` on the
     HyperConverged) — if applicable
   - Two interfaces: `pod` (default) + `lan` (NAD `lan-bridge` for LAN attach)
2. **KubeadmConfigTemplate** at
   `tenants/home/infra/kubeadmconfigtemplates/<pool>.yaml`. Cloud-init for the
   in-VM Ubuntu — driver install, kubelet flags, `kubeadm join` args.
3. **MachineDeployment** at
   `tenants/home/infra/machinedeployments/<pool>.yaml`. Set replicas, or
   annotate for autoscaling:
   ```yaml
   metadata:
     annotations:
       cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size: "1"
       cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size: "5"
   ```
4. **Labels**: add a node label that selects the pool, e.g.
   `node.mershab.com/pool: <pool>`. Use it in workload `nodeSelector`s.
5. **Commit + push**. Flux reconciles the bare-metal cluster, CAPI builds the
   VMs, Kamaji's tenant kubeadm reaps the new nodes once they `kubeadm join`.
6. **Verify**:
   ```bash
   kubectl --kubeconfig=tenant.kubeconfig get nodes -l node.mershab.com/pool=<pool>
   clusterctl describe cluster home -n tenants
   ```
