# Local image supply chain — registry, mirror, in-cluster builds

**Track K** · branch `feat/local-image-pipeline` · 2026-08-26
Profiles **33-registry.yaml** (parked) and **34-forge-runner.yaml**.
Runbook: [`docs/runbooks/local-image-build.md`](../runbooks/local-image-build.md).

> The user's ask: *"also just use a local registry/mirror some kind (spegel) and
> build it locally (build it locally/with tilt or some sleek mechanism now so we
> can get this moving without pure public stuff), maybe with gitea and some sort
> of k8s based runner"*

---

## 1. Headline

**The writable local registry already existed and needed nothing built.** Gitea
1.27 serves an OCI registry on its own web port, and `21-forge.yaml` has been
running it on the LAN VIP since round 1. Verified live from the Mac:

```console
$ curl -i http://192.168.2.244:3000/v2/
HTTP/1.1 401 Unauthorized
Content-Type: application/json
Docker-Distribution-Api-Version: registry/2.0
Www-Authenticate: Bearer realm="http://192.168.2.244:3000/v2/token",service="container_registry",scope="*"
Www-Authenticate: Basic realm="Gitea Container Registry"
```

`401` is the correct answer for an anonymous `/v2/` probe on an authenticated
registry — the endpoint is live. So the shape of the answer is:

| Layer | Decision | Status |
|---|---|---|
| **Writable registry** | Gitea's built-in `/v2/` — no chart, no profile, no new VIP | **live already** |
| **Node can pull from it** | Talos `machine.registries` plain-HTTP mirror | patch written, **operator applies** |
| **Build, today** | Mac `docker buildx --platform linux/amd64 --push` | runbook §2 |
| **Build, durable** | Gitea Actions runner (`34-forge-runner`) | profile written, needs a token |
| **P2P mirror** | Spegel (`33-registry`) | **PARKED** — one node, no peers |

**orca-0's actual blocker was never storage.** It is one 403 and one missing
Secret, and this track removes both by moving the image in-house.

---

## 2. The live blocker, verified

```console
$ kubectl --context admin@contraxia -n cell get pods
NAME     READY   STATUS             RESTARTS   AGE
orca-0   0/1     ImagePullBackOff   0          41m

$ kubectl --context admin@contraxia -n cell describe pod orca-0 | tail
Warning  Failed  Failed to pull image "ghcr.io/mershab99/orca:v1.4.188":
  failed to resolve reference "ghcr.io/mershab99/orca:v1.4.188": failed to
  authorize: failed to fetch anonymous token: unexpected status from GET
  request to https://ghcr.io/token?scope=repository%3Amershab99%2Forca%3Apull
  &service=ghcr.io: 403 Forbidden
Warning  FailedToRetrieveImagePullSecret  (x119)  Unable to retrieve some image
  pull secrets (ghcr-pull); attempting to pull the image may not succeed.
```

Two independent faults: the package is private under `mershab99` (this Mac holds
`mershab-integratrace`), **and** the `ghcr-pull` Secret was never created. The
403 is a hard fail regardless of the Secret.

### ⚠️ The brief's storage caveat is stale — storage landed

`10-COMMON-EDGE.md` says the `tank` zpool does not exist and PVCs will sit
Pending. As of 2026-08-26 that is no longer true:

```console
$ kubectl --context admin@contraxia get zfsnode -A
NAMESPACE   NAME   AGE
openebs     r730   30m

$ kubectl --context admin@contraxia get pvc -A | grep -E 'cell|gitea'
cell    data-orca-0            Bound   100Gi  RWO  fast-zfs
gitea   gitea-shared-storage   Bound    40Gi  RWO  fast-zfs
gitea   gitea-pg-1             Bound    10Gi  RWO  db-zfs
```

`orca-0` is scheduled with its volume attached. Only the image is missing.
(`workspaces/devbox-root` on `fast-block` is still Pending — not this track's.)

---

## 3. Registry / mirror decision table

| Option | Writable? | Value on contraxia **today** | Cost | Verdict |
|---|---|---|---|---|
| **Gitea built-in OCI registry** | ✅ | Already running, auth + UI + `fast-zfs` PVC for free | zero — it is already deployed | **ADOPTED** |
| **Spegel** | ❌ (mirror only) | **Zero.** P2P among 1 node = no peers. Any image it could serve is already unpacked locally, so containerd was never going to pull it | hostPath on the containerd socket (root-equivalent), PSA `privileged` ns, a containerd machineconfig change that ~doubles image-store footprint, and a new dependency in the image-pull path on a single-node cluster | **PARKED** — un-park with node #2 |
| Harbor / Zot / `registry:2` | ✅ | Duplicates what Gitea already gives, plus its own storage, auth and exposure | a whole new deployment | rejected — rung 2 of the ladder: it is already in this codebase |
| Keep using ghcr | ✅ | — | the exact thing the user asked to escape | rejected |

### Why Spegel is parked rather than deleted

`33-registry.yaml` is fully written, pinned and rendered — it is a decision made,
not a decision skipped. Un-parking is three steps, listed in its header. The
honest reason not to run it today: **on one node it is pure cost.** Its whole
mechanism is "node A serves node B", and there is no node B.

One non-obvious hazard captured in that header, because it will bite whoever
un-parks it: Talos's CRI registry config path is `/etc/cri/conf.d/hosts`, which
is *the same directory* Talos generates `hosts.toml` into from
`machine.registries.mirrors` — i.e. where `07-registries.yaml` puts the Gitea
plain-HTTP entry. Spegel owns that directory by default.
`spegel.prependExisting: true` (set in the profile) is what stops Spegel
deleting the Gitea mirror config and breaking every local pull.

---

## 4. Build mechanism — what was evaluated

| Option | Verdict |
|---|---|
| **Mac `docker buildx --push`** | **Adopted as the TODAY path.** Zero infrastructure. Slow: the Mac is `arm64` (`uname -m`) and `--platform linux/amd64` runs the Dockerfile's two `apt-get` sets under QEMU. Estimate 15–40 min — **UNVERIFIED**, not run (the build needs `docker login` against a registry that has no users yet). |
| **Tilt** | Rejected for *this* problem. devex's `Tiltfile` is an inner-loop tool driving from the Mac at OrbStack; pointing it at contraxia means `custom_build` + a push to the same registry — i.e. exactly the Mac path above with extra machinery. It stays useful as a dev loop; it is not a CI loop. |
| **Gitea Actions runner (`act_runner`) + DinD** | **Adopted as the CI path.** Native amd64 on the R730, no QEMU, and it is literally the "k8s based runner" the user named. |
| kaniko / buildah / rootless buildkit | Rejected. See §5 — none of them escape the PSA problem, and each adds parts the official chart already has. |

The first real pipeline is the orca image. `images/orca/` (Dockerfile +
`entrypoint.sh`) is now copied verbatim from devex into this repo, because the
runner builds from the repo it checks out and a second copy nobody edits beats a
submodule. `images/orca/README.md` records the drift risk.

---

## 5. PSA / rootless findings

**Talos enforces PodSecurity `baseline` on every namespace except
`kube-system`.** From the live cluster's own apiserver config
(`bootstrap/talos/_patches/03-apiserver-hardening.yaml`, confirmed present in
`bootstrap/talos/controlplane.yaml` lines 378–395):

```yaml
defaults: {enforce: baseline, audit: restricted, warn: restricted}
exemptions: {namespaces: [kube-system], runtimeClasses: [], usernames: []}
```

`kubectl get ns -o custom-columns=...enforce` confirms only `openebs`,
`velero`, `kubevirt-hyperconverged`, `projectsveltos` (privileged), `operators`
(baseline) and `olm`/`kubelet-serving-cert-approver` (restricted) carry explicit
labels. Everything else — including `gitea` and `cell` — inherits `baseline`.

**Finding 1 — the actions chart's DinD sidecar is unconditionally privileged.**
Rendered chart 0.1.2 both ways:

```console
$ helm template ... --set statefulset.dind.rootless=true --set statefulset.dind.uid=1000
        - name: dind
          image: "docker.io/docker:29.5.2-dind"
          securityContext:
            privileged: true        # ← unchanged by rootless=true
```

`statefulset.dind.rootless` only moves the socket path and uid. So the runner
needs a `privileged` namespace no matter what.

**Finding 2 — rootless buildkit would not have saved it.** Upstream's rootless
buildkit pod spec requires `seccompProfile: {type: Unconfined}` and AppArmor
`unconfined`. Baseline forbids both (it allows `RuntimeDefault`, `Localhost`, or
unset — and Talos's kubelet sets `seccompDefault: true`, so unset means
`RuntimeDefault`). Same namespace label, three more moving parts, no security
win. **Not adopted.** (Kaniko needs no privilege and would fit baseline, but
it is effectively unmaintained and cannot run `docker buildx`-style builds
against a daemon — not worth the trade for one image.)

**Decision:** a dedicated `forge-runner` namespace labelled
`pod-security.kubernetes.io/enforce: privileged`, pre-created in
`clusters/baremetal/infrastructure/namespaces.yaml`. Deliberately **not** the
`gitea` namespace — relaxing PSA for the runner must not relax it for the forge
and its Postgres.

**Finding 3 — Spegel needs the same, and upstream says so.** From
<https://spegel.dev/docs/getting-started/>: *"Talos comes with Pod Security
Admission pre-configured. The default Talos security profile is too restrictive
to allow Spegel to operate."* Rendering confirms four hostPath mounts
(containerd sock, content store, `/etc/cri/conf.d/hosts`, `/var/lib/spegel`) and
`hostPort: 30020` — hostPath and hostPort are both baseline violations.

---

## 6. The runner-cache answer (devex decision #8 left this open)

Three distinct caches; they are not one problem.

**(a) `actions/cache` — SOLVED.** act_runner ships a built-in cache server. From
upstream's `config.example.yaml`:

```yaml
cache:
  #enabled: true
  # Directory where cache blobs are stored on disk. Default: $HOME/.cache/actcache
  #dir: ""
  # Outbound IP or hostname that job containers use to reach this runner's cache server.
  # ... If the runner itself runs in Docker, automatic detection can choose an
  # address on the runner container's network that job containers cannot reach
  # when the runner creates a separate per-job network. In that case, set this to
  # a hostname/IP reachable from job containers, and set port to a fixed
  # published port or put the job containers on a shared Docker network.
```

That warning describes our topology exactly. `34-forge-runner.yaml` therefore
sets `cache.dir: /data/actcache` (on the RWO PVC, so it survives restarts) and
`container.network: bridge` — upstream's own "shared Docker network" fix, so the
auto-detected cache host stays reachable. **No S3 driver needed, no RWX needed.**
UNVERIFIED end-to-end: no runner has ever run here.

**(b) Docker layer cache — ACCEPTED COLD, deliberately.** The DinD sidecar's
`/var/lib/docker` is its own writable layer and is discarded on pod restart. The
orca image is one `apt-get` set plus a `.deb`; rebuilding it perhaps once per
Orca release is not worth a second PVC. Two upgrade paths are written down in
`.gitea/workflows/orca-image.yaml`:

- buildx registry cache (`--cache-to type=registry,ref=…/orca:buildcache`), which
  parks the cache in the Gitea registry itself and needs no volume at all —
  preferred;
- a PVC on `/var/lib/docker` via `statefulset.extraVolumes` +
  `statefulset.dind.extraVolumeMounts`. **It must use `fast-block`, not
  `fast-zfs`**: `fast-block` is a zvol formatted ext4, `fast-zfs` is a ZFS
  dataset, and dockerd's `overlay2` driver cannot run on ZFS.

**(c) Scaling past one runner would break (a).** One RWO PVC, one cache dir.
`replicas: 1` is pinned with a comment saying so. The answer at N runners is
act_runner's `cache.external_server` (a shared `gitea-runner cache-server`), not
RWX.

---

## 7. Every pin, and how it was verified

All commands run 2026-08-26.

| Pin | Evidence |
|---|---|
| `gitea/actions` chart **0.1.2**, appVersion 0.261.3 | `helm search repo gitea-charts/actions -l` → 0.1.2 newest |
| runner image `docker.gitea.com/runner:2.0.1` | rendered by `helm template` of 0.1.2; `docker manifest inspect` → EXISTS |
| dind image `docker.io/docker:29.5.2-dind` | rendered; `docker manifest inspect` → EXISTS |
| init image `busybox:1.38.0` | rendered; `docker manifest inspect` → EXISTS |
| `enabled: true` is required | `helm template` without it renders an **empty** manifest — a silently-green profile |
| `global.storageClass` is the only SC lever | rendered → `storageClassName: "fast-zfs"` in the volumeClaimTemplate; there is no `persistence.storageClass` key |
| `statefulset.dind.extraArgs` exists | present in `helm show values`; rendered → `- --insecure-registry=192.168.2.244:3000` |
| `dind.rootless` does not drop privileged | rendered both ways; `privileged: true` unchanged |
| every key in the 34 values block | full `helm template -f` of the extracted values block renders clean |
| `spegel` chart **0.7.4**, appVersion v0.7.4 | `helm show chart oci://ghcr.io/spegel-org/helm-charts/spegel` |
| spegel image pinned by **digest** by the chart | rendered → `ghcr.io/spegel-org/spegel@sha256:26c60b05e08a…` — no tag drift |
| `containerdRegistryConfigPath` / `prependExisting` / `mirroredRegistries` | rendered → `--containerd-registry-config-path=/etc/cri/conf.d/hosts`, `--prepend-existing=true`, `--mirrored-registries …` |
| Spegel-on-Talos requirements | upstream <https://spegel.dev/docs/getting-started/>, Talos status 🟡; the `machine.files` stanza in `08-spegel-containerd.yaml` is copied verbatim from it |
| Talos registries patch schema | `talosctl machineconfig patch` a throwaway v1.13 controlplane + `talosctl validate --mode metal` → **"is valid for metal mode"** (both 07 and 08 merged together) |
| node has **no** registry config today | `talosctl get rc -o yaml` → `spec: {}` |
| Gitea registry is live | `curl -i http://192.168.2.244:3000/v2/` → 401 + `Docker-Distribution-Api-Version: registry/2.0` |
| Gitea has zero users | `kubectl -n gitea exec deploy/gitea -- gitea admin user list` → header row only |
| `.244` is not squatted | `arp -n 192.168.2.244` → `18:66:da:ed:9b:c4` (r730) |
| pods can reach the registry VIP | `kubectl -n gitea exec gitea-… -- wget … http://192.168.2.244:3000/v2/` → `HTTP/1.1 401 Unauthorized` |
| job image has the tooling | `docker run --rm --platform linux/amd64 docker.gitea.com/runner-images:ubuntu-latest` → docker `/usr/bin/docker`, git, bash, node 24.18.0, `docker buildx 0.35.0-2` |
| PSA default is baseline | `bootstrap/talos/controlplane.yaml` L378–395 + `kubectl get ns -o custom-columns=…/enforce` |
| storage is up | `kubectl get zfsnode -A` → `openebs/r730`; `data-orca-0` **Bound** |
| kustomize | `kustomize build platform/sveltos/clusterprofiles` and `.../infrastructure` both pass; 29 ClusterProfiles render |
| orca `.deb` exists for the pinned version | `curl -I https://github.com/stablyai/orca/releases/download/v1.4.188/orca-ide_1.4.188_amd64.deb` → 200 |

**No new VIP claimed.** The registry rides Gitea's existing `.244`; Spegel uses a
hostPort. `docs/vip-allocation.md` is unchanged, on purpose.

---

## 8. UNVERIFIED

Things I could not test, because the guard denies cluster mutations and nothing
downstream of "Gitea has an admin" exists yet:

1. **The end-to-end pull.** No image has been pushed (needs a Gitea user), the
   Talos patch is not applied, and `gitea-pull` does not exist. The chain is
   reasoned and each link is individually verified; the chain as a whole is not.
2. **Whether `talosctl patch mc --mode=auto` reboots.** `machine.registries` is
   a controller-owned resource (`RegistryConfigs.cri.talos.dev`, owner
   `cri.RegistriesConfigController`), which suggests no-reboot, but I did not
   confirm it. r730 is a single control-plane node — assume the worst and expect
   ~1 minute of API downtime.
3. **QEMU cross-build wall-clock** on the Mac. The 15–40 min figure is an
   estimate from the Dockerfile's shape, not a measurement.
4. **act_runner cache-host auto-detection** with `container.network: bridge`.
   Upstream documents this as the fix; nobody has run it here.
5. **Docker Hub anonymous rate limits.** `docker:29.5.2-dind`, `busybox:1.38.0`
   and `catthehacker`-derived runner images are all unauthenticated Docker Hub
   pulls. A cold node could hit the anonymous cap. (Ironic given the track's
   goal, and a genuine argument for Spegel later.)
6. **`docker login` from the Mac over plain HTTP.** Docker Desktop usually
   allows HTTP for RFC1918 hosts; if it refuses, the runbook says to add
   `insecure-registries`.

---

## 9. Cross-track notes

**Track H (owns refactors of 19–26) — I changed two files you own:**

- `platform/sveltos/manifests/orca-cell/orca.yaml`
  - `image:` `ghcr.io/mershab99/orca:v1.4.188` → `192.168.2.244:3000/mershab/orca:v1.4.188`
  - `imagePullSecrets:` `ghcr-pull` → `gitea-pull`
- `platform/sveltos/clusterprofiles/19-orca-cell.yaml` — header only: the
  prerequisite Secret and the image-source rationale.

Nothing else in 19–26 is touched. `21-forge.yaml` is **unmodified** — the
registry was already on; no values change was needed.

**Track F (owns domains + the edge):** the registry is LAN plain HTTP, per this
track's brief. It is **not** on the public edge and must not be until TLS+auth is
proven. The clean end state is yours: give the forge `git.mershab.com` with a
`letsencrypt-prod` cert (DNS-01, so no inbound HTTP is required to issue), after
which `bootstrap/talos/_patches/07-registries.yaml` can be **deleted entirely** —
a publicly-trusted cert needs no mirror entry — and images re-tagged
`git.mershab.com/mershab/orca:…`. Note that the reference host must resolve from
*both* the node's netns (kubelet pulls) and pod netns (runner pushes), which is
why an IP is used today and why a cluster Service name can never be used.

---

## 10. Files

```
platform/sveltos/clusterprofiles/33-registry.yaml      new — Spegel, PARKED (not in kustomization)
platform/sveltos/clusterprofiles/34-forge-runner.yaml  new — act_runner + DinD, ns forge-runner
platform/sveltos/clusterprofiles/kustomization.yaml    lists 34; documents why 33 is parked
platform/sveltos/clusterprofiles/19-orca-cell.yaml     header: new image source + prerequisite
platform/sveltos/manifests/orca-cell/orca.yaml         image ref + imagePullSecret
clusters/baremetal/infrastructure/namespaces.yaml      + forge-runner ns (PSA privileged)
bootstrap/talos/_patches/07-registries.yaml            new — plain-HTTP registry mirror
bootstrap/talos/_patches/08-spegel-containerd.yaml     new — PARKED with 33
bootstrap/talos/README.md                              layout + gen list + live-patch commands
images/orca/{Dockerfile,entrypoint.sh}                 copied verbatim from devex
images/orca/README.md                                  new — build paths + drift warning
.gitea/workflows/orca-image.yaml                       new — the CI build
docs/runbooks/local-image-build.md                     new — TODAY path + CI path
docs/reports/2026-08-25-local-image-pipeline.md        this file
```

## 11. Operator's shortest path to a Running orca-0

1. `talosctl patch mc` with `07-registries.yaml` (runbook §1.1)
2. `gitea admin user create --admin --username mershab …` (§1.2)
3. mint a PAT with `read:package` + `write:package` (§1.3)
4. `docker login` + `docker buildx build --platform linux/amd64 --push` (§2.1) —
   the long one
5. `kubectl -n cell create secret docker-registry gitea-pull …` (§2.4)
6. merge this branch; after Sveltos reconciles, `kubectl -n cell delete pod orca-0`

The Actions runner (§3) is the follow-up and changes nothing about steps 1–6.
