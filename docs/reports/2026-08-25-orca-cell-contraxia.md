# Orca cell on contraxia — port report (2026-08-25)

Track A of the "put shamu there" fleet. Branch `feat/orca-cell-contraxia`.

Goal: `orca serve` runs on the R730 (32 cpu / ~94 GiB, idling at ~9% cpu / ~14%
mem) instead of the MacBook, so agent terminals stop competing with a 12 GiB
OrbStack VM for 32 GiB and the Mac can sleep without killing the work.

Status: **manifests written and committed; nothing applied.** Two hard blockers
remain and both are outside the git write path — the container image and the
`ghcr-pull` Secret. See [Blockers](#blockers).

---

## 1. VIP claim

> **Track A claims `192.168.2.241`** from the Cilium `lan-pool`.

Verified state at write time:

```
$ kubectl --context admin@contraxia --request-timeout=60s get ciliumloadbalancerippool
NAME       DISABLED   CONFLICTING   IPS AVAILABLE   AGE
lan-pool   false      False         10              22d

$ kubectl ... get svc -A --field-selector spec.type=LoadBalancer
NAMESPACE   NAME             TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)                         AGE
tenants     kmc-arrakis-lb   LoadBalancer   10.96.12.118   192.168.2.240   6443:31916/TCP,8132:32095/TCP   22d
```

Pool is `192.168.2.240–250` (11 addresses, 1 consumed by the arrakis control
plane → the 10 reported free). `.241` is the first free address.
**Tracks B and C: start at `.242`.** I found no competing claim — neither
`02-CPU-WORKSPACES.md` nor `03-SHAMU-PLATFORM.md` names an IP, and
`docs/reports/` did not exist before this file.

Annotation used: `lbipam.cilium.io/ips`. Cilium here is **v1.19.5**
(`kubectl -n kube-system get ds cilium -o jsonpath='{...containers[0].image}'`
→ `quay.io/cilium/cilium:v1.19.5`). The repo's existing pin
(`tenants/arrakis/infra/cluster.yaml`) uses `io.cilium/lb-ipam-ips`, which is the
deprecated spelling of the same key — I used the current one per the brief and
left the arrakis object alone. `kmc-arrakis-lb` carries **no**
`loadBalancerClass`, which confirms classless Services are what Cilium LB-IPAM
claims on this cluster; the `external` class belongs to chisel-operator.

---

## 2. What was written

| File | What |
|---|---|
| `platform/sveltos/manifests/orca-cell/orca.yaml` | StatefulSet `orca` + Service `orca` (ns `cell`) |
| `platform/sveltos/clusterprofiles/19-orca-cell.yaml` | ClusterProfile `orca-cell`, `persona: infra`, `dependsOn: [storage]` |
| `platform/sveltos/clusterprofiles/kustomization.yaml` | added `19-orca-cell.yaml` to the resource list |
| `clusters/baremetal/infrastructure/namespaces.yaml` | added Namespace `cell` |

Validation actually run (the guard denies `kubectl apply`, including
`--dry-run`, so this is static only):

```
$ kustomize build platform/sveltos/clusterprofiles      # OK
$ kustomize build clusters/baremetal/infrastructure     # OK
$ python3 -c "yaml.safe_load_all(...)"                  # parses; kinds/names as expected
```

`kubeconform`/`kubeval` are not installed on this machine — **no schema
validation was performed. UNVERIFIED.**

---

## 3. Divergences from the shamu design, and why

Ported from devex `apps/cell/orca/{base,overlays/shamu}` + `images/orca/`.
Every deliberate change:

1. **No kustomize base/overlay split — raw manifests under
   `platform/sveltos/manifests/orca-cell/`.**
   This repo delivers through Sveltos `policyRefs` (raw YAML dirs); only the
   root profile uses `kustomizationRefs`, and only because
   `clusters/baremetal/infrastructure` and `platform/sveltos/clusterprofiles`
   carry their own `kustomization.yaml`. `manifests/storage/` and
   `manifests/coder/` are flat YAML with no kustomization — I matched them.
   A base + one overlay is indirection for a single consumer. Cell #2 = copy the
   dir and add a numbered profile.

2. **No NetBird sidecar (devex `overlays/mershab`, decision #7).**
   `kubectl get all -n netbird` → *"No resources found in netbird namespace"*.
   NetBird was ripped from this repo (`08-netbird.yaml removed 2026-08-05 —
   Netbird ripped` in `clusterprofiles/kustomization.yaml`). Porting a sidecar
   that registers against a control plane which does not exist would produce a
   CrashLooping container beside a working one. Off-LAN reach is the chisel edge
   (`k8s-home.mershab.com`), not the mesh — and no route to `:6768` is published
   today, so **the cell is LAN-only.** Adding one is a follow-up, not this track.
   The devex design's peer-state-on-the-PVC trick (`subPath: netbird-state`)
   still applies unchanged if the mesh returns.

3. **`type: LoadBalancer`, not Gateway API.**
   Verified: `kubectl get gatewayclass` → *"No resources found"*. Cilium's
   Gateway API support is off here (enabling it needs the Gateway CRDs
   pre-installed plus a Cilium values change — out of scope, and the base
   already wanted a plain Service anyway).

4. **`storageClassName: fast-zfs`, not `openebs-zfs`.**
   shamu named its class `openebs-zfs`; this repo's LocalPV-ZFS classes are
   `fast-zfs` (default) / `fast-block` / `db-zfs`
   (`platform/sveltos/manifests/storage/storageclasses.yaml`). Named explicitly
   rather than relying on the default, so the claim can never silently follow a
   future default change.

5. **`dependsOn: [storage]` added.**
   No devex equivalent (shamu had no Sveltos). Without it the StatefulSet would
   sit Pending on a nonexistent StorageClass for the entire Longhorn→ZFS window.

6. **Namespace `cell` moved out of the payload into
   `clusters/baremetal/infrastructure/namespaces.yaml`.**
   The `ghcr-pull` Secret is hand-applied and must land *before* the pod first
   schedules. That file already carries exactly this pattern for `velero`
   ("Pre-created so the velero-b2 Secret (secrets/apply.sh) can land before the
   ClusterProfile installs the chart"). No PSA label: the pod is uid 1000, no
   capabilities, no hostPath.

7. **`enableServiceLinks: false` added.**
   The Service is named `orca`, so legacy service links inject
   `ORCA_PORT=tcp://10.x.x.x:6768` and `orca serve --port` dies with
   *"Invalid --port value"*. `images/orca/entrypoint.sh` already sanitises this
   at runtime; turning the links off removes the class of failure instead of
   relying on a shell guard surviving a future image rebuild. Both mechanisms
   are now in place.

8. **Resources raised: requests `cpu: 4` / `memory: 16Gi`, limit `memory: 48Gi`,
   no CPU limit** (shamu base: `cpu: 2` / `memory: 8Gi`, limit `16Gi`).
   This is the point of the track. Node capacity is 32 cpu / 98849752Ki with
   ~28 cores idle. No CPU limit so a compile burst eats idle cores instead of
   being CFS-throttled; the memory limit is the real guard rail. QoS is
   Burstable. If Track B's Coder workspaces land on the same node, the 16 GiB
   request is the number to revisit first — it is a hard reservation.

9. **`ORCA_NO_SANDBOX` declared explicitly as `"0"`.**
   devex leaves it unset and tells you to add it if Chromium dies. Declaring it
   makes the knob discoverable in `kubectl get sts orca -o yaml` instead of
   requiring someone to read the entrypoint. Flip to `"1"` if the pod crashes on
   the sandbox.

**Not diverged (carried verbatim, on purpose):** StatefulSet with `replicas: 1`
(`orca serve` is single-host; never scale it), `fsGroup: 1000`, `PAIRING_ADDRESS`
as the client-advertised address only, the optional `github-mcp-token` envFrom,
the tcpSocket readiness probe, port 6768, and `100Gi`.

### PVC sizing — why 100 GiB

Kept the shamu number, and the class makes the number cheap:
`fast-zfs` is `thinprovision: "yes"`, `allowVolumeExpansion: true`,
`reclaimPolicy: Retain`, `volumeBindingMode: WaitForFirstConsumer`. So:

- **Thin** — 100 GiB reserves nothing on `tank`; it costs what is written.
- **Expandable** — if worktrees + `node_modules` + model caches outgrow it, edit
  the number; no migration. Oversizing today buys nothing.
- **Retain** — deleting the PVC does not reap the dataset. This volume holds
  every agent's OAuth state, the git worktrees, and (if the mesh ever returns)
  the NetBird identity. Losing it means re-authenticating every agent by hand
  through `kubectl exec`, which is the single most annoying failure in this
  design.

---

## 4. Blockers

### B1 — the container image is not verifiably present. **UNVERIFIED.**

```
$ docker manifest inspect ghcr.io/mershab99/orca:v1.4.188   → manifest unknown
$ docker manifest inspect ghcr.io/mershab99/orca:latest     → manifest unknown
$ docker manifest inspect ghcr.io/mershab99/zzz-not-a-real-repo:v1  → manifest unknown   (control)
$ docker manifest inspect ghcr.io/actions/actions-runner:latest     → OK                 (control)
```

The plumbing works (public control succeeds), but ghcr returns the *same*
`manifest unknown` for a missing tag and for a private repo you cannot read, so
these two cases are indistinguishable. And this machine cannot read
`mershab99`'s private packages:

```
$ docker-credential-osxkeychain list   → https://ghcr.io -> mershab-integratrace
$ gh auth status                       → Logged in to github.com account mershab-integratrace
$ gh api "user/packages?package_type=container"          → (empty)
$ gh api "users/Mershab99/packages?package_type=container" --jq '.[].name'  → git-repo-stats
```

The registry credential and the `gh` session both belong to
**`mershab-integratrace`**, while the image lives under **`mershab99`** (and
`origin` is `git@github.com:Mershab99/homelab.git`). So: *the image may well
exist and simply be invisible from here.* Resolve with runbook step 1.

Consequence for the `ghcr-pull` Secret: it must be built from a **Mershab99**
PAT with `read:packages`, not the `mershab-integratrace` one already in the
keychain.

### B2 — `fast-zfs` does not exist yet (the in-flight ZFS migration).

```
$ kubectl --context admin@contraxia --request-timeout=60s get sc
NAME                 PROVISIONER          RECLAIMPOLICY   ...
longhorn (default)   driver.longhorn.io   Delete
longhorn-static      driver.longhorn.io   Delete
```

`dependsOn: [storage]` makes Sveltos hold `orca-cell` until the `storage`
profile has reconciled, so this is *handled*, not merely noted — but nothing
about this track can be smoke-tested until the migration lands. Track E is
watching it.

Also `kubectl get ns cell` → `Error from server (NotFound)`, i.e. nothing from
this track is live yet, as expected.

---

## 5. Runbook — manual steps

Everything below is manual **by design**: the git write path cannot create
registry credentials, cannot run `orca account add`'s interactive OAuth, and
cannot hold a pairing code. Run in order.

### Step 0 — precondition

The `storage` ClusterProfile is reconciled and `kubectl get sc` shows
`fast-zfs (default)`, `fast-block`, `db-zfs`. If it does not, stop: everything
below will sit Pending.

### Step 1 — confirm (or build) the image

```sh
# Log the registry in as the account that OWNS the package.
docker login ghcr.io -u Mershab99          # PAT needs read:packages (+ write:packages to push)

docker manifest inspect ghcr.io/mershab99/orca:v1.4.188
```

If that prints a manifest, skip to step 2. If it still says `manifest unknown`,
build and push it from the **devex** repo:

```sh
cd ~/Code/Projects/devex
make shamu-image        # docker buildx build --platform linux/amd64 --push
                        #   -t ghcr.io/mershab99/orca:v$(ORCA_VERSION)   [ORCA_VERSION := 1.4.188]
```

`linux/amd64` is correct for contraxia (Talos v1.13.5 / amd64). The tag
`v1.4.188` **must** equal the Mac's Orca version — see [Risks](#6-risks) R1.

### Step 2 — the `ghcr-pull` Secret (hand-applied, never in git)

```sh
kubectl --context admin@contraxia -n cell create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=Mershab99 \
  --docker-password='<GITHUB_PAT_WITH_read:packages>' \
  --docker-email='<YOUR_EMAIL>'
```

The `cell` namespace is created by the root ClusterProfile from
`clusters/baremetal/infrastructure/namespaces.yaml`, so it exists as soon as
this branch is on `main`. If the command fails with `namespaces "cell" not
found`, Flux has not pulled yet — `flux reconcile source git homelab` and retry.

**Optional**, for `github-mcp-server` in http mode (the pod starts without it):

```sh
kubectl --context admin@contraxia -n cell create secret generic github-mcp-token \
  --from-literal=GITHUB_PERSONAL_ACCESS_TOKEN='<GITHUB_PAT>'
```

Placeholders only — do not paste real values into any file in this repo.
House convention for hand-applied cluster secrets is
`secrets/**/*.secret.yaml` (gitignored) + `./secrets/apply.sh`; I did not add
files there because reading `secrets/**` is guard-denied and neither of these
belongs in a repo that also holds the git remote credential.

### Step 3 — merge and let Sveltos apply

The coordinator pushes `feat/orca-cell-contraxia` to `origin/main`. Then:

```sh
flux --context admin@contraxia -n flux-system reconcile source git homelab

kubectl --context admin@contraxia --request-timeout=60s get clusterprofile orca-cell
kubectl --context admin@contraxia --request-timeout=60s -n cell get pod,pvc,svc -w
```

Expect: `orca-0` `Running 1/1`, `data-orca-0` `Bound` on `fast-zfs`,
`svc/orca` `EXTERNAL-IP 192.168.2.241`.

If the pod is `ImagePullBackOff` → step 1 or 2 is wrong.
If it is `Pending` on the PVC → step 0 is not done.
If it crashes with a Chromium sandbox error → set `ORCA_NO_SANDBOX` to `"1"` in
`platform/sveltos/manifests/orca-cell/orca.yaml`, commit, reconcile, and record
it here.

### Step 4 — sanity-check reachability from the Mac

```sh
nc -vz 192.168.2.241 6768
```

Must succeed **before** you try to pair. This is LAN-only (see divergence #2).

### Step 5 — authenticate the agents inside the pod

```sh
kubectl --context admin@contraxia -n cell exec -it orca-0 -- orca account add                 # claude
kubectl --context admin@contraxia -n cell exec -it orca-0 -- orca account add --agent codex   # codex
```

> ⚠️ **Prefer `claude /login` over Orca-managed Claude activation.**
> There is a recorded incident where Orca's managed-Claude activation wiped the
> macOS keychain item `Claude Code-credentials` and deauthenticated the Mac's
> `claude`. If `orca account add` offers a managed-Claude path, decline it and
> do this instead — the image already carries
> `@anthropic-ai/claude-code@2.1.235` globally:
> ```sh
> kubectl --context admin@contraxia -n cell exec -it orca-0 -- claude
> #   then type /login at the prompt and follow the URL it prints
> ```
> This runs entirely inside the pod and writes to the PVC (`HOME=/data`) — it
> cannot touch the Mac's keychain. **UNVERIFIED for this specific image build**:
> I could not run either command (no image, no pod). Treat the warning as live
> until someone confirms otherwise on a throwaway keychain.

Repeat step 5 on every fresh PVC. That is the whole reason the class is
`reclaimPolicy: Retain`.

### Step 6 — pair the Mac to the cell

```sh
# 1. Get the pairing code from the server's logs.
kubectl --context admin@contraxia -n cell logs orca-0 | grep -i 'orca://pair'

# 2. On the Mac, register it.
orca environment add --name contraxia --pairing-code 'orca://pair?code=…'

# 3. Confirm.
orca environment list --json     # was {"environments": []} before this track
```

GUI equivalent: Orca → Settings → Remote Orca Servers.

Mobile pairing (optional): restart the pod once with `ORCA_MOBILE_PAIRING=1` set
on the container and scan the QR from the logs. Not wired up here.

### Step 7 — snapshot the volume

`fast-zfs` is `reclaimPolicy: Retain` and the cluster has a default
`VolumeSnapshotClass` `zfs-snapclass` (shipped inside the piraeus
snapshot-controller release, per `04-storage.yaml`). Take a `VolumeSnapshot` of
`data-orca-0` the same day pairing works, before the agent OAuth state becomes
load-bearing. A scheduled snapshot CronJob is **not** part of this track.

---

## 6. Risks

**R1 — client/server version skew. Highest-probability failure.**
The image pins `v1.4.188`; the Mac reported `appVersion 1.4.188`
(`orca status --json` → `result.runtime.appVersion`, 2026-08-25). Orca ships
~daily and the pairing handshake is version-sensitive. Orca on the Mac
auto-updates (`remoteUpdateSupport.automatic: true` in the same output), so
**the Mac will drift away from this pin on its own.** When pairing fails,
check versions first. Bumping means: bump `ORCA_VERSION` in devex's `Makefile`,
`make shamu-image`, bump the tag in
`platform/sveltos/manifests/orca-cell/orca.yaml`, commit. Never one side alone.

**R2 — the keychain/deauth hazard.** See step 5. Orca-managed Claude activation
has previously wiped `Claude Code-credentials` on the Mac. Use `claude /login`
inside the pod.

**R3 — storage dependency.** The PVC needs `fast-zfs`, which the in-flight
Longhorn→ZFS migration creates. `dependsOn: [storage]` gates it, but if the
migration stalls or `zfs-localpv` CrashLoops (it does, on any Talos image
without the zfs system extension — see `04-storage.yaml`), this track is stuck
with no diagnostic of its own. Symptom will be `orca-cell` never deploying, not
a pod error.

**R4 — LAN-only.** No mesh, no chisel route to `:6768`. Off the home LAN the
cell is unreachable, so "the Mac can sleep" only holds at home. Fix is either a
NetBird sidecar (design intact, decision #7) or a chisel TCP route — neither is
in this track.

**R5 — image pull identity mismatch.** The registry credential on this Mac
belongs to `mershab-integratrace`; the package is under `mershab99`. A
`ghcr-pull` Secret built from the wrong PAT produces `ImagePullBackOff` with an
*authorization* error that looks like a missing image. See B1.

**R6 — resource reservation.** `requests.cpu: 4` / `requests.memory: 16Gi` is a
hard reservation on a node Tracks B and C also want. Nothing is over-committed
today (~28 cores and ~80 GiB idle), but this is the first number to cut if
scheduling gets tight.

**R7 — `.241` claim is advisory.** Tracks B and C are picking from the same pool
concurrently. If two Services annotate the same IP, Cilium marks the pool
`CONFLICTING` and one Service gets no address. Re-check
`kubectl get ciliumloadbalancerippool` after all three tracks merge.

---

## 7. Everything I could not verify

- **The image exists.** B1. Ambiguous registry error + wrong-account credentials.
- **The manifests are schema-valid.** No `kubeconform`/`kubeval` installed;
  `kubectl apply --dry-run` is guard-denied. Only `kustomize build` + a YAML
  parse were run.
- **Sveltos accepts the profile.** Not applied. `dependsOn`, `policyRefs` path
  and `persona: infra` all match live/committed precedent
  (`SveltosCluster mgmt/mgmt` carries `persona=infra`, verified via
  `kubectl get sveltoscluster -A --show-labels`), but the object has never been
  reconciled.
- **The pod runs / pairing works / `orca account add` behaves.** Steps 3–6 are
  written from `devex/docs/runbook-shamu.md` §6 and §8 plus the entrypoint
  source, not from execution. Nothing in this track has been executed against a
  running cell.
- **Whether `ORCA_NO_SANDBOX` is needed on Talos v1.13.5.** Left at `"0"`.
- **The `claude /login`-inside-the-pod workaround.** Reasoned from the image
  contents (`@anthropic-ai/claude-code@2.1.235` is installed globally) — not run.
