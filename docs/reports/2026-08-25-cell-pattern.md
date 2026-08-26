# TRACK H — the reproducible cell pattern, and a refinement pass over 19–26

**Date:** 2026-08-26 (dispatched under the 2026-08-25 brief set)
**Branch:** published to `gitea` as **`refactor/cell-pattern`**. The Orca worktree
created the local branch as `cell-pattern`, so it was pushed with
`git push gitea cell-pattern:refactor/cell-pattern` — the remote name matches the
brief. `origin` is untouched (denied by design; the coordinator pushes).
**Cluster under audit:** contraxia — single Talos control-plane node `r730`,
`192.168.2.70`, k8s v1.36.2
**Profile owned:** 31 (`31-cell-TEMPLATE.yaml`)
**Deliverable:** `platform/sveltos/clusterprofiles/31-cell-TEMPLATE.yaml` + six
refactors, all on `refactor/cell-pattern`.

Everything asserted here is backed by a command that was run and read. Anything
that could not be proven is marked **UNVERIFIED** and says why.

---

## 0. TL;DR

1. **`31-cell-TEMPLATE.yaml` ships** — a single self-contained file (ClusterProfile
   + the payload documents) that a future agent handed only that file can copy
   into a working cell. Excluded from `kustomization.yaml`, so the build stays
   green. `kustomize build platform/sveltos/clusterprofiles` passes.
2. **Six defects found, four fixed, one needs the operator, one proposed.** The
   highest-value one is not a manifest bug at all: **the devbox root disk could
   never have imported** on `fast-block`, and nobody would have noticed from the
   YAML.
3. **`orca-0` is misdiagnosed in round 1's report.** It is not (yet) a
   nonexistent image tag. The `ghcr-pull` Secret **does not exist in ns `cell`**;
   the kubelet says so every 15 seconds. The 403 is what an *anonymous* pull of a
   private package returns, and it is indistinguishable from "no such package".
   Exact remediation in §4.
4. **The brief's storage warning is stale, in a good way.** The `tank` zpool now
   EXISTS — `zfsnode/r730` is present and every PVC on the cluster is `Bound`.
5. **kagent: keep it parked, but for the right reason.** The ownership question
   the profile parked on is already answered in the GPU plan. The real blocker is
   that there is no model endpoint to point it at.
6. **Delete nothing. Merge nothing.** Concrete reasoning in §6, including why
   folding `26-infra-db` into `21-forge` would recreate a documented deadlock.

---

## 1. The standard cell shape

A **cell** = one hub workload with a name, storage, an identity, and an access
path. It is not a tenant app (those go on `persona: platform`) and not a nested
cluster (that is `25-vcluster-cell-TEMPLATE.yaml`).

| Decision | The standard | Why |
|---|---|---|
| **Numbering** | `NN-<name>.yaml`, claimed in `kustomization.yaml` **in your first commit, before writing the profile** | The kustomization is the only registry. Claiming first turns a parallel-agent collision into a one-line merge conflict instead of two files sharing a prefix (round 1 shipped a duplicate `20-`). Numbers are a human ordering hint only — Sveltos orders on `dependsOn` and identifies by `metadata.name`. **Never renumber a live profile.** |
| **`clusterSelector`** | `matchLabels: {persona: infra}` | The hub is where the idle cores, the `tank` pool and KubeVirt live. `platform` = arrakis. `matchExpressions ... In [infra, platform]` = both. |
| **`dependsOn`** | `storage` if the cell has **any** PVC, including one a chart creates. Plus `virt-host` (VM/DataVolume), `infra-db` (CNPG `Cluster` CR), `tls-stack` (Certificate / cert-annotated Ingress). | `dependsOn` gates **first deployment only** — it never undeploys a provisioned profile. So "the observer must survive the observed" is not a reason to omit it (see D-3). |
| **CRD/CR split** | An operator's chart and a CR of its CRD **must be different profiles** | Sveltos runs the Helm feature and the Resources feature independently; a CR beside its own chart races its own CRD on first reconcile. This is why `26-infra-db` is separate from `21-forge`, and the same trap `04-storage` documents for `VolumeSnapshotClass`. |
| **Storage** | `fast-zfs` (default) for everything; `db-zfs` for Postgres; `fast-block` **only** for kubevirt-csi hot-plug. Name the class explicitly even when it is the default. | All three are `WaitForFirstConsumer`, thin, expandable. Oversizing buys nothing. A claim that rides `(default)` silently follows a future default change elsewhere. **Do not use `fast-block` for a CDI http/registry import** — see D-1. |
| **Access path** | In order of preference: **(1)** ClusterIP + `port-forward`; **(2)** Ingress on the hub edge with a real `*.mershab.com` name; **(3)** LAN VIP; **(4)** NetBird mesh. | port-forward costs no address and no attack surface, and *already requires cluster credentials* — which restores authentication to apps that have none. `ClusterIssuer/letsencrypt-prod` is `Ready` (verified) and uses Cloudflare DNS-01, so a cert issues with **no inbound HTTP** — the edge does not have to be reachable to get TLS. |
| **VIP claim** | ARP-probe first, then add the row to `docs/vip-allocation.md` **in the same commit**, then pin with `lbipam.cilium.io/ips` | `lan-pool` (`.240–.250`) overlaps the router's DHCP scope. Cilium assigns squatted addresses happily and the Service shows a healthy `EXTERNAL-IP` that is unreachable — this hit Gitea on `.242`. |
| **`loadBalancerClass`** | **Never** set it on a LAN VIP Service. Exactly one Service in the estate carries `chisel.mershab.com/external`: the edge ingress controller's. | chisel-operator claims only classed Services and then overwrites their `status.loadBalancer.ingress` — a classed LAN Service gets its VIP stolen and flaps. chisel binds one Service per ExitNode (1:1), so everything public rides one ingress → one droplet. |
| **Namespace** | In the cell's own `manifests/<name>/namespace.yaml`. **Exception:** if a hand-applied Secret must land before the first reconcile, put it in `clusters/baremetal/infrastructure/namespaces.yaml` instead. | The cell owns its namespace; `git rm` of the cell removes it. The exception is why `cell` and `velero` are declared centrally. A namespace that exists only as `releaseNamespace` is auto-created by Helm and **cannot be labelled** — use an explicit object the moment you need a PSA label. |
| **PSA** | No label by default. `enforce: privileged` only for workloads that drive host kernel state. | contraxia enforces no restricted default (verified: `workspaces`, `gitea`, `kubewall`, `cell` all carry no PSA label and all run fine). Only `openebs`, `velero`, `projectsveltos` are labelled. |
| **Secrets** | Named in the profile header with a `kubectl create secret` line using **placeholders only**. `optional: true` wherever the cell can start without it. | A missing *required* pull secret does not fail loudly — it degrades to an anonymous pull whose 403 is indistinguishable from a bad tag. That is exactly how `orca-0` was misdiagnosed. |
| **Resources** | Every cell states requests. Memory limit as the guard rail; usually no CPU limit. | No requests ⇒ BestEffort ⇒ first evicted, on a single node with nowhere to reschedule. Round 1 shipped the **forge of record** as BestEffort. |

### Add a cell in 5 steps

```sh
# 1. CLAIM THE NUMBER FIRST — its own commit.
cp platform/sveltos/clusterprofiles/31-cell-TEMPLATE.yaml \
   platform/sveltos/clusterprofiles/32-widget.yaml
sed -i '' 's/CHANGEME/widget/g' platform/sveltos/clusterprofiles/32-widget.yaml
# add `- 32-widget.yaml` to kustomization.yaml
git add platform/sveltos/clusterprofiles/{32-widget.yaml,kustomization.yaml}
git commit -m "chore(platform): claim profile 32 for the widget cell"

# 2. Payload — namespace, Services, CRs, NetworkPolicy.
mkdir -p platform/sveltos/manifests/widget
#   the last three documents of 31-cell-TEMPLATE.yaml are the starting point

# 3. dependsOn + selector + storage class, in 32-widget.yaml.

# 4. VERIFY — all five, no exceptions.
kustomize build platform/sveltos/clusterprofiles                  # must pass
helm show chart <repo>/<chart> --version <v>                      # version exists?
helm show values <chart> --version <v> | grep -n '<each key>'     # key exists?
helm template w <chart> --version <v> -n widget -f /tmp/vals.yaml # renders? which images?
ping -c1 -W700 192.168.2.<n>; arp -n 192.168.2.<n>                # only if claiming a VIP

# 5. Commit, `git push gitea <branch>`. The coordinator pushes to origin;
#    Flux fetches, Sveltos applies. `kubectl apply` is denied on purpose.
```

The template file carries all of this inline, including the payload documents, so
an agent handed only `31-cell-TEMPLATE.yaml` has everything.

---

## 2. Defect table

| # | File | Defect | Evidence | Status |
|---|---|---|---|---|
| **D-1** | `manifests/cpu-workspace/virtualmachine.yaml` | Root disk on `fast-block` + `volumeMode: Block`. **The CDI importer cannot open a raw zvol** — it runs as uid 107, non-root, with no fsGroup. The VM could never have booted. | `kubectl -n workspaces logs importer-prime-3c23fabb-…` → `blockdev: cannot open /dev/cdi-block-volume: Permission denied` at `importer.GetAvailableSpaceBlock`. `get dv` → `devbox-home` (fast-zfs, Filesystem) **Succeeded 100%**, `devbox-root` (fast-block, Block) `ImportInProgress`, **9 restarts**, 36 min. `get vm devbox` → `DataVolumeError`. `get csidriver zfs.csi.openebs.io` → `fsGroupPolicy: ReadWriteOnceWithFSType` (applies fsGroup only to volumes with an fsType — never a raw block volume). `get pv` → the **only** Block PV on the cluster is the failing one. | **FIXED** → `fast-zfs` / `Filesystem`. **+1 operator step:** `kubectl -n workspaces delete dv devbox-root` (KubeVirt does not recreate an existing DV when its template changes). |
| **D-2** | `21-forge.yaml`, `manifests/forge/postgres.yaml` | Gitea and both Postgres instances have **no resource requests** → BestEffort QoS → first evicted under node pressure, on a single node. This is the forge of record. | `kubectl -n gitea get pods -o custom-columns=…resources.requests` → `<none> <none>` for all three. Chart default is `resources: {}` (`helm show values gitea/gitea --version 12.7.0`, line 298). | **FIXED** — sized off `kubectl top pod -n gitea` (gitea 1m/86Mi, pg-1 10m/73Mi, pg-2 6m/60Mi). Re-rendered: `helm template` now emits `requests {cpu 100m, memory 512Mi} / limits {memory 2Gi}`. |
| **D-3** | `21-forge.yaml`, `23-kubewall.yaml` | Both create PVCs on `fast-zfs`/`db-zfs` but **neither had `dependsOn: storage`**. kubewall's header justified the omission with "the observer must stay up when the observed breaks" — which misreads what `dependsOn` does: it gates first deployment and never undeploys. So the omission bought nothing and risked a PVC being created before `04-storage` reconciled. | `21-forge.yaml` had only `dependsOn: [infra-db]`; `23-kubewall.yaml` had none. Both own PVCs: `gitea-shared-storage` (fast-zfs), `gitea-pg-{1,2}` (db-zfs), `kubewall-data` (fast-zfs) — all four visible in `kubectl get pvc -A`. | **FIXED** on both; kubewall's header correction states the actual `dependsOn` semantics. |
| **D-4** | `23-kubewall.yaml` | Residual risk was **stated and then left open**: the API is unauthenticated and reachable from every pod in the cluster on its ClusterIP. On a cluster that also runs an agent cell, that is a privilege-escalation gadget — one unauthenticated HTTP call gives any compromised pod cluster-wide `view`, plus `POST /api/v1/app/config/kubeconfigs` which hot-loads an attacker-supplied kubeconfig with no restart. | `kubectl -n kubewall get svc` → ClusterIP `10.105.156.198:8443`, no NetworkPolicy in the namespace. | **FIXED** — `manifests/kubewall/networkpolicy.yaml`, default-deny ingress. **Access is preserved**: port-forward enters from the host netns, not the pod network. Verified live against `flux-operator-mcp` (whose chart NetworkPolicy admits only ns `mcp` + `cell`): port-forward + MCP `initialize` → **HTTP 200**. |
| **D-5** | `19-orca-cell.yaml` / ns `cell` | `orca-0` `ImagePullBackOff`. Round 1's report blames the image tag. **The proximate cause is a missing Secret**, and the tag question is still open. | `kubectl -n cell get secrets` → **`No resources found`**. `describe pod orca-0` → `FailedToRetrieveImagePullSecret … (ghcr-pull); attempting to pull the image may not succeed` **×97**, then `403 Forbidden` from the *anonymous* ghcr token endpoint. Separately: the earlier `FailedScheduling … not enough free storage` is **gone** — the pod is `Scheduled`, `data-orca-0` is `Bound` (100Gi, fast-zfs). | **NEEDS USER** — §4. |
| **D-6** | `22-mcp-levers.yaml` | The header's own trigger has fired: *"WHEN THE ORCA CELL LANDS and creates namespace `cell` … any agent in that namespace gets cluster-admin over the hub."* Namespace `cell` now exists and the NetworkPolicy admits it. | Live NetworkPolicy: `ingress.from` = `namespaceSelector kubernetes.io/metadata.name: mcp` **and** `: cell`, port 9090. `helm show values … 0.58.1` → `rbac.create: true` = "Grant the cluster-admin role to the flux-operator-mcp service account". | **PROPOSED, not applied** — §5. |

### Chart / version / values audit — 19–26

Mechanical sweep. Every pinned chart version and every pinned values key was
checked against the real registry, not against memory.

| Profile | Chart | Pinned | Exists? | Pinned values keys present in `helm show values`? |
|---|---|---|---|---|
| 21-forge | `gitea/gitea` | 12.7.0 | ✅ appVersion 1.27.0 | ✅ 29/29. The 15 "absent" leaves are all `gitea.config.*` (a free-form ini map) and a Service annotation — both are by-design open maps, not typos. |
| 22-mcp-levers | `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator-mcp` | 0.58.1 | ✅ | ✅ 4/4 (`transport` enum includes `http`; `readonly`; `networkPolicy.create`; `networkPolicy.ingress.namespaces`) |
| 22-mcp-levers | `oci://ghcr.io/containers/charts/kubernetes-mcp-server` | 0.1.0 | ✅ app 0.0.66 | ✅ 5/5. `image.version: "v0.0.66"` — the round-1 `v`-prefix fix is correct and the pod is `Running`. |
| 23-kubewall | `oci://ghcr.io/kubewall/charts/kubewall` | 0.0.22 | ✅ | ✅ 13/13 (`serviceAccount.create/name`, `service.listen`, `pvc.*`, `resources.*`) |
| 24-kagent-router | `oci://ghcr.io/kagent-dev/kagent/helm/{kagent-crds,kagent}` | 0.9.12 | ✅ both | ✅ 23/23. Renders clean (`helm template` rc=0). **The header's claims check out**: `kagent-crds` renders 8 CRDs and nothing else; `kagent` renders exactly one `ModelConfig` = `provider: OpenAI` / `model: gpt-4.1-mini` / `apiKeySecret: kagent-openai` — i.e. paid OpenAI billing against a Secret that does not exist. |
| 25-template | `loft/vcluster` | 0.36.1 | ✅ | n/a (template) |
| 26-infra-db | `cloudnative-pg/cloudnative-pg` | 0.29.0 | ✅ operator 1.30.0 | ✅ (no values pinned) |

**No version or key defects found.** The remaining tag risk is `orca` (§4) and
`docker.io/library/postgres:18.3-alpine` inside the parked kagent chart — both
**UNVERIFIED**, and both irrelevant until someone acts on §4/§5.

### Convention divergences across the six (documented, not churned)

Real but low-severity. I did **not** rewrite working profiles to make them
uniform — the template is the forward contract.

- **Resource requests:** `flux-operator-mcp` 10m/64Mi→1/1Gi (chart default),
  `kubernetes-mcp-server` 100m/128Mi Guaranteed (chart default), `kubewall`
  100m/128Mi→500m/512Mi (explicit), `orca` 4/16Gi→(mem 48Gi) (explicit), gitea +
  CNPG **none** (fixed, D-2). Standard going forward: state requests; memory
  limit as guard rail; skip the CPU limit.
- **Probes:** only `orca-cell` writes one by hand (readiness, tcpSocket:6768, no
  liveness). Everything else uses chart defaults. Acceptable — a hand-written
  liveness probe on a single-replica pet is a restart loop waiting to happen.
- **securityContext:** `orca-cell` sets `fsGroup: 1000` only; the kubewall,
  gitea and flux-mcp charts each ship a full restricted-profile context. Since
  contraxia enforces no PSA default this is not exploitable today. Flagged, not
  changed — hardening `orca-cell` is a change to the one pod that cannot be
  tested until D-5 is cleared.
- **Namespace creation:** three different mechanisms in six profiles — central
  (`cell`), policyRef (`workspaces`, `gitea`, `kubewall`), Helm auto-create
  (`mcp`, `cnpg-system`). Standardised in the template: **policyRef by default,
  central only when a hand-applied Secret must precede the first reconcile.** The
  existing files already follow that rule; no churn needed.
- **`dependsOn`:** fixed in D-3. After the fix, all six are correct.

---

## 3. Facts in the brief that reality has moved past

| Brief says | Reality, 2026-08-26 | Consequence |
|---|---|---|
| "The zpool `tank` does NOT exist yet … PVCs will sit Pending" | `kubectl get zfsnode -n openebs` → `r730`. **Every PVC on the cluster is `Bound`** except `devbox-root` (D-1) — including `data-orca-0` 100Gi, `gitea-shared-storage` 40Gi, `gitea-pg-{1,2}` 10Gi, `kubewall-data` 1Gi, `devbox-home` 265Gi. | PHASE 3 ran. `Pending` is no longer the expected state; a Pending claim now IS a bug. |
| "`orca-0` … `FailedScheduling … did not have enough free storage`" | Last seen 22 min before the audit; the pod is now `Scheduled` on `r730` with an interface. | Storage is no longer an `orca-0` blocker. Only the pull secret is. |
| "`.242`/`.245` burned, `.246`–`.250` free" | Re-probed: `.241`/`.243`/`.244` → `18:66:da:ed:9b:c4` (r730, correct). `.246`–`.250` → ARP incomplete (free). | Still true. `docs/vip-allocation.md` needs no edit and I claimed no address. |
| Round 1 table: "`21-forge` … RUNNING, HTTP 200" | Still true — `curl http://192.168.2.244:3000/` → **200**, `gitea-pg-{1,2}` both `1/1 Running`. | The forge is the one fully-working cell. |

All six ClusterSummaries are `Provisioned` (`orca-cell`, `cpu-workspace`,
`forge`, `infra-db`, `kubewall`, `mcp-levers`) — Sveltos delivery is healthy; the
failures are inside the workloads, not in the delivery path.

---

## 4. `orca-0` — precise diagnosis and exact remediation

**Two causes were proposed in round 1. One is dead, one was wrong, and the real
one is a missing Secret.**

```
$ kubectl --context admin@contraxia -n cell get secrets
No resources found in cell namespace.

$ kubectl --context admin@contraxia -n cell describe pod orca-0
  Warning FailedToRetrieveImagePullSecret  2m9s (x97 over 22m)  kubelet
      Unable to retrieve some image pull secrets (ghcr-pull);
      attempting to pull the image may not succeed.
  Warning Failed  20m (x4 over 22m)  kubelet
      failed to resolve reference "ghcr.io/mershab99/orca:v1.4.188":
      failed to authorize: failed to fetch anonymous token: … 403 Forbidden
```

1. **`FailedScheduling … not enough free storage` — RESOLVED.** The `tank` pool
   landed; `data-orca-0` is `Bound` and the pod is `Scheduled`.
2. **`Secret/ghcr-pull` does not exist.** `19-orca-cell.yaml` correctly documents
   it as a hand-applied prerequisite; it was never applied. The StatefulSet's
   `imagePullSecrets: [ghcr-pull]` therefore resolves to nothing.
3. **The 403 is a *consequence* of (2), not evidence about the tag.** With no
   pull secret the kubelet falls back to an **anonymous** token request, and ghcr
   returns `403 Forbidden` for a private package. I confirmed this is not
   diagnostic:

   ```
   https://ghcr.io/token?scope=repository:mershab99%2Forca:pull      -> HTTP 403
   https://ghcr.io/token?scope=repository:mershab99%2Fnope-xyz-123:pull -> HTTP 403
   https://ghcr.io/token?scope=repository:kubewall%2Fcharts%2Fkubewall:pull -> HTTP 200
   ```

   A private package and a nonexistent one are **indistinguishable** anonymously.
   `gh api /users/mershab99/packages/container/orca/versions` → `404 Package not
   found`, which is also what GitHub returns to a non-owner for a private
   package — and this Mac's `gh` is authenticated as **`mershab-integratrace`**,
   not `mershab99`. `gh auth status` → scopes `delete:packages, gist, read:org,
   repo, write:packages`. The token is not short on package scopes; it is on the
   wrong account.

   **⇒ Whether `ghcr.io/mershab99/orca:v1.4.188` exists is UNVERIFIED and cannot
   be verified from this machine.**

### What the user must do

```sh
# 1. A ghcr PAT for the mershab99 account with `read:packages`.
#    github.com/settings/tokens (classic) → read:packages. Do NOT paste it into
#    this repo; secrets/ is plaintext and gitignored, and this credential is not
#    covered by that posture (a package token can also grant package:write).
kubectl --context=admin@contraxia -n cell create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=mershab99 \
  --docker-password='<GHCR_PAT_WITH_read:packages>' \
  --docker-email='<EMAIL>'

# 2. Confirm the tag exists, from a shell logged in as mershab99:
echo '<GHCR_PAT>' | docker login ghcr.io -u mershab99 --password-stdin
docker manifest inspect ghcr.io/mershab99/orca:v1.4.188   # must not 404
#    If it 404s, the image was never pushed — build and push it from devex:
#      make shamu-image        # linux/amd64, per devex decisions #3/#11

# 3. Kick the pod (it will retry on its own within ~5 min anyway):
kubectl --context=admin@contraxia -n cell delete pod orca-0

# 4. Verify:
kubectl --context=admin@contraxia -n cell get pod orca-0 -w
```

**Version-skew rule stands:** the tag must match the Mac's Orca app version or
`orca environment add` refuses to pair. `orca --version` on this Mac prints only
usage text, so the client version could not be read here — get it from
`orca status --json` → `result.runtime.appVersion` before bumping either side.
(**UNVERIFIED** that the Mac is still on 1.4.188.)

**A structural fix, applied to the pattern rather than to this profile:** the
template's SECRETS section now states that a missing *required* pull secret
degrades silently into an anonymous 403 that reads like a bad tag. That is the
class of mistake, and it cost round 1 a full misdiagnosis.

---

## 5. Proposed, NOT applied

### P-1 — narrow `flux-operator-mcp` off cluster-admin (D-6)

The header of `22-mcp-levers.yaml` names its own trigger and the trigger has
fired: namespace `cell` exists, the chart NetworkPolicy admits it, and
`rbac.create: true` binds the MCP ServiceAccount to **cluster-admin** on the
cluster that holds the arrakis kubeconfig, the Sveltos management token and
`tenant-secrets`. Any agent in `cell` — not just Orca — inherits that, through an
endpoint with **no authentication**.

Not applied, because narrowing it degrades tools I cannot test without applying:
`flux-operator-mcp`'s generic `get_kubernetes_resources` reads arbitrary kinds,
so a Flux-only ClusterRole would break real functionality. That is a judgement
call for the user, not a silent refactor.

Sketch, for whoever takes it:

```yaml
# 22-mcp-levers.yaml, flux-operator-mcp values
rbac:
  create: false          # drops the chart's cluster-admin ClusterRoleBinding
serviceAccount:
  create: true
# + in a new policyRef manifests/mcp-levers/rbac.yaml:
#   ClusterRole: full verbs on source.toolkit.fluxcd.io, helm.toolkit.fluxcd.io,
#                kustomize.toolkit.fluxcd.io, notification.toolkit.fluxcd.io
#   + aggregate the stock `view` ClusterRole for read-only everything-else
#   ClusterRoleBinding: that role -> ServiceAccount flux-operator-mcp/mcp
```

**Verify before committing** that `serviceAccount.create` and `rbac.create` are
independent in chart 0.58.1 (they are separate keys in `helm show values`, but
the binding-template gating was **not** rendered and checked — do that first,
the way `23-kubewall` did for its own BYO-SA escape).

**Cheaper interim, one line, zero functionality lost:** set
`networkPolicy.ingress.namespaces: []`. That removes `cell` from the allow-list
while leaving `mcp` (the chart adds its own release namespace unconditionally).
The write lever then reaches only via port-forward — i.e. only a human with
cluster credentials — until the agent workflow that needs it actually exists.
Recommended if the user wants the risk closed today.

### P-2 — nothing else

I found no other change worth proposing that I was not confident enough to apply.

---

## 6. kagent — recommendation

**Keep `24-kagent-router.yaml` parked. Do not delete it. Do not enable it yet.**

**The ownership question it parked on is already answered**, in the plan the
brief pointed me at. `docs/plans/2026-08-25-gpu-kagent-orchestration.md` §4.7
("Composing with Track C") is explicit:

> - **Track C owns:** the HelmRelease/ClusterProfile that installs the kagent
>   chart, its version pins, namespace, and exposure.
> - **This plan owns:** the ModelConfig, the dummy-key Secret, the llama.cpp
>   serving layer, the VIP, and the routing policy.
> The join is exactly one string — `ModelConfig.spec.openAI.baseUrl`.

`24-kagent-router.yaml` **is** the Track C artifact. So: **this profile is the
owner of the chart**, and the GPU plan explicitly does not contest it. The
parking note's stated reason ("two ClusterProfiles would fight over one Helm
release") is resolved — there is only one, and it is this file.

**But the profile still must not be enabled, for three concrete reasons:**

1. **There is nothing to route to.** The plan's recommendation is "ship one
   `llama.cpp` CPU server, measure prefill first (Phase 0, one Job, ~30 min)".
   Phase 0 has not been run and no inference endpoint exists on contraxia.
   `providers.*` is deliberately unset in the profile, so — verified by
   rendering the chart — enabling it today creates
   `ModelConfig/default-model-config` = `provider: OpenAI`, `model:
   gpt-4.1-mini`, `apiKeySecret: kagent-openai`. That is **paid OpenAI billing
   pointed at a Secret that does not exist**, violating the plan's own
   "no paid-API billing in-cluster" rule, and the controller has no key to start
   with.
2. **The bundled Postgres has hardcoded `kagent`/`kagent` credentials** (the
   chart calls this "intentional for a dev/eval setup"). `26-infra-db` exists
   precisely so this does not have to be true — the migration recipe is already
   written into the profile's header, and it is a prerequisite, not a follow-up.
3. **`controller.auth.mode: unsecure`.** Survivable only because the Service is
   ClusterIP with no route in. That constraint must be re-checked the moment
   Track F's edge or Track G's mesh could reach it.

**Is it wanted at all, given the plan's conclusion?** Yes, narrowly — the plan's
own §5.1 routing rule ("route to the local model only when the output is cheaply
verifiable by something that is not a model") describes real work: classification
into a fixed taxonomy, schema extraction with a validator. kagent is the harness
for that, and Orca remains the orchestrator; §5.3 keeps them complementary. The
value is real but it is **strictly downstream of an inference endpoint that does
not exist**.

**Un-park checklist, in order:**
1. Run GPU-plan Phase 0 (prefill measurement). If it fails, stop — do not enable.
2. Ship llama.cpp on contraxia, on a **newly ARP-probed** VIP.
   ⚠️ The plan's illustrative example uses `http://192.168.2.241:8080/v1`, and
   **`.241` is the live Orca cell VIP**. Do not copy that literal. `.246`–`.250`
   probed free 2026-08-26.
3. Move kagent to CNPG (`dependsOn: infra-db`, `bundled.enabled: false`,
   `database.postgres.urlFile` — never `.url`, which inlines the credential).
4. Set `providers.openAI.config.baseUrl` to the llama.cpp VIP + the dummy-key
   Secret. Port the shape from devex `apps/laptop/kagent/`, **not**
   `apps/shamu/kagent/` — the plan §4.2 shows shamu's file does not do what its
   own comment says.
5. Add `- 24-kagent-router.yaml` to `kustomization.yaml`.

---

## 7. What to delete or merge — nothing, and here is why

The brief asked me to be opinionated about consolidation. My opinion is that
every candidate is a false economy:

- **`26-infra-db` → fold into `21-forge`? NO.** That would put the CNPG operator
  chart and a `postgresql.cnpg.io/v1` Cluster CR in one profile. Sveltos runs the
  Helm feature and the Resources feature **independently**, so the CR races its
  own CRD on first reconcile — the identical trap `04-storage` documents for
  `VolumeSnapshotClass`, and the one that "deadlocked the first install, forever"
  in round 1. The split is not duplication; it is the fix. It also already has a
  second consumer queued (kagent, §6).
- **`23-kubewall` → drop on security grounds? NO — but only after D-4.** The
  chart's cluster-admin grant is already gone (BYO-SA bound to `view`) and the
  LAN VIP was already dropped. D-4 closes the last hole. What remains is a
  read-only dashboard reachable only by someone who already holds cluster
  credentials. That is proportionate. **I would have recommended deletion had
  D-4 not been fixable in nine lines** — an unauthenticated cluster-reader
  reachable from every pod is not a dashboard, it is a lateral-movement tool.
- **`22-mcp-levers` → split the two servers? NO.** They share one namespace and
  one purpose (the agent's hands and eyes). Splitting doubles the profile count
  and changes nothing about the actual risk, which is RBAC (P-1), not packaging.
- **`24-kagent-router` → delete? NO.** §6. It is a correct, rendered, reviewed
  port that is blocked on an upstream prerequisite. Deleting it discards verified
  work — including the `kmcp.enabled: false` CRD-ownership finding — to save a
  file that costs nothing while unlisted.
- **`19`/`20` → merge into one "workspaces" profile? NO.** Different lifecycles
  (a container pet vs a KubeVirt VM), different `dependsOn` (`storage` vs
  `storage`+`virt-host`), different failure modes. One profile would make a CDI
  import failure block the Orca cell.

**Fewer, better profiles is the right instinct — and six is already the right
number here.** What round 1 actually lacked was a *shared shape*, not fewer
files. That is what `31-cell-TEMPLATE.yaml` supplies.

---

## 8. Files changed

| File | Change |
|---|---|
| `platform/sveltos/clusterprofiles/31-cell-TEMPLATE.yaml` | **NEW.** The cell pattern. Excluded from `kustomization.yaml`. |
| `platform/sveltos/clusterprofiles/kustomization.yaml` | Comment only: points at 31-, and declares this file the profile-number registry with the claim-first rule. **No `resources:` entry added — the build is unchanged.** |
| `platform/sveltos/clusterprofiles/21-forge.yaml` | `+dependsOn: storage` (D-3); `+resources` for the gitea container (D-2). |
| `platform/sveltos/clusterprofiles/23-kubewall.yaml` | `+dependsOn: storage` (D-3); header correction on `dependsOn` semantics; header item 3 for the NetworkPolicy (D-4). |
| `platform/sveltos/manifests/forge/postgres.yaml` | `+spec.resources` on the CNPG Cluster (D-2). |
| `platform/sveltos/manifests/kubewall/networkpolicy.yaml` | **NEW.** Default-deny ingress (D-4). |
| `platform/sveltos/manifests/cpu-workspace/virtualmachine.yaml` | Root disk `fast-block`/`Block` → `fast-zfs`/`Filesystem` (D-1) + the evidence in the header. |

### Coordination — files another track may also touch

- **`platform/sveltos/clusterprofiles/kustomization.yaml`** — Tracks F (27–28)
  and G (29–30) will add `resources:` entries. **My edit is a comment block
  appended at EOF, after the existing 25-template comment**, so a merge should be
  clean; if it conflicts, take both sides.
- **`docs/vip-allocation.md`** — deliberately **not touched**. I claimed no
  address. My ARP re-probe (`.246`–`.250` free, `.241`/`.243`/`.244` correct on
  r730's MAC) is recorded here instead, so F and G can edit that file without a
  conflict against me.
- Nothing else I changed overlaps 27–30.

---

## 9. Build proof

```
$ kustomize build platform/sveltos/clusterprofiles > /dev/null && echo OK
clusterprofiles BUILD OK

$ kustomize build clusters/baremetal/infrastructure > /dev/null && echo OK
infrastructure BUILD OK

$ for f in 31-cell-TEMPLATE 21-forge 23-kubewall \
           manifests/forge/postgres manifests/kubewall/networkpolicy \
           manifests/cpu-workspace/virtualmachine; do python3 -c "yaml.safe_load_all"; done
YAML OK  (all 6)

$ helm template gitea gitea/gitea --version 12.7.0 -n gitea -f <new values>
gitea render OK
gitea {'limits': {'memory': '2Gi'}, 'requests': {'cpu': '100m', 'memory': '512Mi'}}
```

`31-cell-TEMPLATE.yaml` is **not** in `kustomization.yaml`, so kustomize never
reads it — the same discipline as `25-vcluster-cell-TEMPLATE.yaml` and
`24-kagent-router.yaml`.

---

## 10. UNVERIFIED — the honest list

| Claim | Why it could not be proven |
|---|---|
| `ghcr.io/mershab99/orca:v1.4.188` exists | This Mac's `gh`/docker credentials are `mershab-integratrace`; the package is under `mershab99`. Anonymous ghcr returns 403 for private **and** nonexistent alike (probe shown in §4), and the packages API returns 404 to non-owners for private packages. Needs a `mershab99` login. |
| The Mac's current Orca client version | `orca --version` prints usage text only. Round 1 recorded 1.4.188 on 2026-08-25; not re-confirmed. Use `orca status --json` → `result.runtime.appVersion`. |
| That D-1's fix makes `devbox` boot | The manifest change is committed but the wedged `devbox-root` DataVolume must be deleted by hand (mutations are denied to me), so the re-import has not run. The **cause** is proven by the Filesystem/Block A/B on this cluster; the **cure** is inferred from it. |
| That D-2's new requests are re-applied live | Sveltos applies from `origin/main`; this branch has not been pushed to `origin`. The values render correctly (§9) but no live pod carries them yet. |
| `docker.io/library/postgres:18.3-alpine` (rendered by the parked kagent chart) | Not checked — the profile is parked and its Postgres should be replaced by CNPG before it is ever enabled (§6). |
| That `rbac.create: false` leaves `flux-operator-mcp` functional | Not rendered or tested — that is exactly why P-1 is proposed and not applied. |
| Chart-default probe/securityContext behaviour under a future restricted PSA | contraxia enforces no restricted default today; untested against one. |
