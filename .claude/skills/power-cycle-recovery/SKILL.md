---
name: power-cycle-recovery
description: Recover contraxia (R730 Talos hub) after a power cycle — diagnose Sveltos/Flux fallout, unstick Terminating namespaces and orphaned finalizers, reapply secrets, verify arrakis re-provisions. Use after the server was turned off/on, when namespaces are stuck Terminating, when ClusterProfiles vanished, or when the arrakis Cluster is stuck Deleting.
---

# Power-cycle recovery (contraxia)

A hard reboot can interrupt helm-controller mid-reconcile. Known failure mode
(seen 2026-07-16): the `sveltos` HelmRelease gets remediated with a fresh
install, the root ClusterProfile briefly prunes profiles from a stale git
artifact, Sveltos **uninstalls the pruned addons** (CAPI, Longhorn, tenant
cluster...), and their controllers die before clearing finalizers. Result:
namespaces stuck Terminating, dead webhooks blocking everything, arrakis
Cluster stuck Deleting.

Sveltos self-heals the profiles once flux catches up — your job is only to
clear the corpses blocking reinstall. Work the ladder top-down; stop at the
first step that comes back clean.

## 1. Baseline

```bash
kubectl --context admin@contraxia get nodes
kubectl --context admin@contraxia get pods -A | grep -v Running | grep -v Completed
kubectl --context admin@contraxia -n flux-system get gitrepository homelab \
  -o jsonpath='{.status.artifact.revision}'   # compare vs git log origin/main -1
kubectl --context admin@contraxia -n flux-system get helmrelease sveltos
```

Fresh-install marker: events show `Helm install succeeded ... projectsveltos.v1`
→ Sveltos was reinstalled, expect fallout below.

## 2. Compare desired vs actual profiles

```bash
kubectl --context admin@contraxia get clusterprofiles
# desired list:
grep -v '^\s*#' platform/sveltos/clusterprofiles/kustomization.yaml | grep yaml
```

Missing profiles: do NOT hand-apply. Root runs `ContinuousWithDriftDetection`
so it recreates deleted profiles on its own (watch `clustersummaries -A`).
If root somehow lost drift detection, bump the artifact instead: push any
commit, then `kubectl annotate gitrepository homelab -n flux-system
reconcile.fluxcd.io/requestedAt=$(date +%s) --overwrite`.

A profile can also be stuck **dying** (deletionTimestamp set, held by
`clusterprofilefinalizer`): its ClusterSummary loops on
`undeploying failing because of missing permission` and never drains. This
deadlocks every profile that `dependsOn` it (e.g. capi-stack → virt-host).
If the addon it deployed should KEEP running (KubeVirt, cert-manager...),
skip the teardown entirely — strip finalizers on both objects; root
recreates the profile and re-adopts the running addon idempotently:

```bash
kubectl --context admin@contraxia patch clustersummary <name>-sveltos-mgmt -n mgmt \
  --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl --context admin@contraxia patch clusterprofile <name> \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

Only intervene beyond that if addon-controller logs show errors:

```bash
kubectl --context admin@contraxia -n projectsveltos logs deploy/addon-controller \
  --since=15m | grep -iE 'error|fail'
```

`namespace is being terminated` errors → step 3.

## 3. Stuck Terminating namespaces

```bash
kubectl --context admin@contraxia get ns | grep -v Active
# per stuck ns, see exactly what blocks it:
kubectl --context admin@contraxia get ns <NS> \
  -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.message}{"\n"}{end}'
```

Two blocker types, fix in this order:

### 3a. Dead webhooks ("failed calling webhook ... service not found")

Delete only webhook configs whose backing service is gone; reinstall
recreates them. Usual suspects after addon uninstall:

```bash
kubectl --context admin@contraxia delete validatingwebhookconfiguration \
  capi-validating-webhook-configuration \
  capk-validating-webhook-configuration \
  k0smotron-validating-webhook-configuration-control-plane \
  longhorn-webhook-validator --ignore-not-found
kubectl --context admin@contraxia delete mutatingwebhookconfiguration \
  capi-mutating-webhook-configuration \
  k0smotron-mutating-webhook-configuration-control-plane \
  longhorn-webhook-mutator --ignore-not-found
```

Do NOT touch kubevirt/HCO/cdi/otel webhooks — those controllers stay alive.

### 3b. Orphaned finalizers

SAFETY GATE before stripping any finalizer, verify BOTH:
- the owning controller is gone (its namespace/deployment deleted), AND
- the resources it protects are already gone (`get vm,vmi -A` empty,
  KubevirtCluster / K0smotronControlPlane deleted).

If a controller is alive, let it finish — stripping finalizers under a live
controller orphans real state.

Strip pattern (works for any resource the ns condition names):

```bash
kubectl --context admin@contraxia patch <kind> <name> -n <ns> \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

Known offenders by namespace:
- `capi-system` / `k0sproject-k0smotron-*-system` / `kubevirt-infrastructure-system`:
  `coreproviders,bootstrapproviders,controlplaneproviders,infrastructureproviders`
- `longhorn-system`: `engineimages,engines,nodes.longhorn.io,snapshots.longhorn.io,volumeattachments.longhorn.io,volumes.longhorn.io,replicas.longhorn.io`
  (replicas only appear as a blocker after the volumes clear — re-check ns
  conditions after the first pass). Stripping volume finalizers orphans
  on-disk replica data — fine for a rebuild, not fine if you need the data.
- `tenants`: `machines,machinesets,machinedeployments,clusters.cluster.x-k8s.io`,
  the `kmc-arrakis-lb` Service (chisel finalizer), etcd PVC.
  Loop helper:

```bash
for r in $(kubectl --context admin@contraxia get <kinds-csv> -n <ns> -o name); do
  kubectl --context admin@contraxia patch $r -n <ns> --type=merge -p '{"metadata":{"finalizers":null}}'
done
```

Sveltos clustersummaries in `tenants` clear themselves once the Cluster CR
is gone — don't strip those first.

## 4. Wait for convergence, reapply secrets

Namespaces get recreated by the reinstalling charts within ~1 min. Then:

```bash
./secrets/apply.sh    # re-runnable; recreated namespaces lost their secrets
kubectl --context admin@contraxia get clustersummaries -A   # all → Provisioned
```

Tenant-side secret (`kubevirt-csi` infra-cluster-credentials) is applied
against arrakis, not by apply.sh — do it after arrakis API is reachable.

## 5. Verify arrakis

If the KubevirtCluster was recreated, re-apply the documented k0smotron
v2.0.3 workaround (see comment in tenants/arrakis/infra/cluster.yaml) —
without it machines sit in Pending/WaitingForClusterInfrastructure forever:

```bash
kubectl --context admin@contraxia patch kubevirtcluster arrakis -n tenants \
  --subresource=status --type=merge -p '{"status":{"ready":true}}'
```

Arrakis API is chisel-exposed (NOT cilium): kmc-arrakis-lb binds ExitNode
node-01. chisel-operator is strictly ONE Service per ExitNode — never add a
second LB Service on mgmt or it steals the tunnel and arrakis goes dark.

RackNerd VPS filters inbound ports (only 22 + 9090 pass). Off-LAN access:
`ssh -f -N -L 16443:127.0.0.1:6443 root@72.11.146.116`, kubeconfig server
`https://127.0.0.1:16443`.

Tenant full rebuild: deleting Cluster arrakis leaves the etcd PVC
(`etcd-data-kmc-arrakis-etcd-0`) — delete it too, or the new CP mounts the
old cluster's state (phantom nodes, stale service CIDR).

```bash
kubectl --context admin@contraxia get cluster -n tenants        # Provisioning → Provisioned
kubectl --context admin@contraxia get svc kmc-arrakis-lb -n tenants  # EXTERNAL-IP = VPS
kubectl --context admin@contraxia get vm,vmi -n tenants         # worker VMs boot
kubectl --context admin@contraxia get machines -n tenants
```

Control plane (k0smotron) pods land in `tenants`; workers are KubeVirt VMs.
First provision takes several minutes (image pull + VM boot + kubeadm join).
