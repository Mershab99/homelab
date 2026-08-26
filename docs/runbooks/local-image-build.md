# Local image build → forge registry → cluster

How this estate builds and serves its own container images without ghcr or any
other public registry. Written 2026-08-26 (Track K, `feat/local-image-pipeline`).

Two paths to the same tag:

- **§2 — TODAY.** Build on the Mac, push to the forge, orca-0 comes up. No CI
  needed. This is the one that unblocks `ImagePullBackOff` right now.
- **§3 — CI.** Gitea Actions runner builds on the R730. The durable path.

Both produce `192.168.2.244:3000/mershab/orca:v1.4.188`.

> Everything in §1 and §2 marked **operator** is a mutation the agent guard
> denies (`kubectl create`, `docker login`, `talosctl patch`). Run them
> yourself. Every command below is copy-pasteable; every `<PLACEHOLDER>` is a
> value that must never enter this repo.

---

## 0. Why any of this exists

`orca-0` in namespace `cell` has been in `ImagePullBackOff` since it was first
scheduled:

```
Failed to pull image "ghcr.io/mershab99/orca:v1.4.188": failed to resolve
reference: failed to authorize: failed to fetch anonymous token: unexpected
status from GET request to https://ghcr.io/token?scope=repository%3Amershab99%2Forca%3Apull
&service=ghcr.io: 403 Forbidden

FailedToRetrieveImagePullSecret  Unable to retrieve some image pull secrets
(ghcr-pull); attempting to pull the image may not succeed.   (x119)
```

The package is private under the GitHub account `mershab99`; this Mac holds
credentials for `mershab-integratrace`. Rather than chase a token, the image
moves in-house.

The writable registry already exists and needed **no** new deployment — Gitea
1.27 serves an OCI registry on its own web port:

```console
$ curl -i http://192.168.2.244:3000/v2/
HTTP/1.1 401 Unauthorized
Docker-Distribution-Api-Version: registry/2.0
Www-Authenticate: Bearer realm="http://192.168.2.244:3000/v2/token",service="container_registry",scope="*"
```

`401` is the correct answer: the endpoint is live and demands auth.

---

## 1. One-time prerequisites (operator)

### 1.1 Teach the node that the registry is plain HTTP

Gitea serves the LAN VIP over HTTP with no TLS. containerd assumes HTTPS for
every reference host, so without this the pull dies in a TLS handshake long
before it looks at any pull secret.

```sh
talosctl --talosconfig bootstrap/talos/talosconfig \
  -e 192.168.2.70 -n 192.168.2.70 \
  patch mc --mode=auto --patch @bootstrap/talos/_patches/07-registries.yaml
```

The patch file is in git and carries no credentials. It also lives in
`_patches/` so a future `talosctl gen config` does not silently drop it — add it
to the `--config-patch` list in `bootstrap/talos/README.md` when regenerating.

Verify:

```sh
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  get rc -o yaml          # RegistryConfigs — `spec: {}` means it did NOT take
talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 \
  read '/etc/cri/conf.d/hosts/192.168.2.244:3000/hosts.toml'
```

> `--mode=auto` lets Talos apply without a reboot when the field allows it.
> **UNVERIFIED** which mode it picks for `machine.registries`. r730 is a single
> control-plane node: if it does schedule a reboot, the API server is gone for
> about a minute.

### 1.2 Create the first Gitea admin

The chart in `21-forge.yaml` deliberately creates none (its default admin
password is a published constant), and today there are zero users:

```console
$ kubectl --context admin@contraxia -n gitea exec deploy/gitea -- gitea admin user list
ID   Username Email IsActive IsAdmin 2FA
```

The username becomes the **registry namespace** — `192.168.2.244:3000/<USER>/…`.
Everything downstream is pinned to `mershab`, so use that:

```sh
kubectl --context admin@contraxia -n gitea exec deploy/gitea -- \
  gitea admin user create --admin \
    --username mershab \
    --email '<ADMIN_EMAIL>' \
    --password '<ADMIN_PASSWORD>' \
    --must-change-password=true
```

Then sign in at <http://192.168.2.244:3000/> and change the password.
Registration is disabled and `REQUIRE_SIGNIN_VIEW` is on, so this account is the
only way in.

### 1.3 Mint a PAT

UI → **Settings → Applications → Generate New Token**. Scopes:

| Scope | Why |
|---|---|
| `write:package` | push images |
| `read:package` | pull images (the cluster's `gitea-pull` Secret) |
| `write:repository` | `git push gitea` (only if this host becomes the git remote) |

Copy it once; Gitea never shows it again. Call it `<GITEA_PAT>` below.
**Never** write it into this repo.

---

## 2. TODAY path — build on the Mac, unblock orca-0

### 2.1 Build

```sh
cd <this repo>
docker login 192.168.2.244:3000 -u mershab       # password: <GITEA_PAT>
docker buildx build --platform linux/amd64 --push \
  --build-arg ORCA_VERSION=1.4.188 \
  -t 192.168.2.244:3000/mershab/orca:v1.4.188 \
  images/orca
```

Notes, all of them load-bearing:

- **`--platform linux/amd64` is mandatory.** The Mac is `arm64` (`uname -m`);
  r730 is `amd64`. Buildx runs the whole `apt-get` set through QEMU, so expect
  **15–40 minutes**, not five. This is the single best argument for §3.
- **`docker login` over plain HTTP.** Docker Desktop allows HTTP registries on
  RFC1918 addresses without an `insecure-registries` entry; if it refuses, add
  `192.168.2.244:3000` under Settings → Docker Engine → `insecure-registries`
  and restart the daemon.
- `images/orca/` is a verbatim copy of devex `images/orca/`. If devex's copy has
  moved on, re-copy first — nothing keeps them in sync.

Confirm it landed:

```sh
curl -u mershab:<GITEA_PAT> -s \
  http://192.168.2.244:3000/v2/mershab/orca/tags/list
# {"name":"mershab/orca","tags":["v1.4.188"]}
```

### 2.2 Verify the node can actually resolve it

```sh
crictl_check() {
  talosctl --talosconfig bootstrap/talos/talosconfig -e 192.168.2.70 -n 192.168.2.70 "$@"
}
crictl_check read '/etc/cri/conf.d/hosts/192.168.2.244:3000/hosts.toml'
```

If that file is missing, §1.1 did not take and the next step will fail on TLS,
not on auth.

### 2.3 The registry is reachable from inside the cluster

Already verified 2026-08-26 from a running pod, so pod-side builds and pulls
have a working path:

```console
$ kubectl --context admin@contraxia -n gitea exec gitea-<pod> -c gitea -- \
    wget -q -S -O /dev/null http://192.168.2.244:3000/v2/
  HTTP/1.1 401 Unauthorized
```

### 2.4 Create the pull secret (operator)

```sh
kubectl --context admin@contraxia -n cell create secret docker-registry gitea-pull \
  --docker-server=192.168.2.244:3000 \
  --docker-username=mershab \
  --docker-password='<GITEA_PAT>'
```

The `cell` namespace is pre-created in
`clusters/baremetal/infrastructure/namespaces.yaml`, so this works before the
ClusterProfile has ever reconciled.

> **Alternative, if per-namespace pull secrets become tedious:** put
> `machine.registries.config."192.168.2.244:3000".auth.{username,password}` in
> `07-registries.yaml` instead and delete every `imagePullSecrets` block. The
> node then authenticates for everything. Rejected here so the patch file can
> stay in git verbatim and credential rotation does not mean a machineconfig
> apply.

### 2.5 Kick the pod

The manifest change (`gitea-pull` + the new image ref) reaches the cluster
through Flux → Sveltos once this branch merges to `main`. After it reconciles:

```sh
kubectl --context admin@contraxia -n cell delete pod orca-0     # operator
kubectl --context admin@contraxia -n cell get pod orca-0 -w
kubectl --context admin@contraxia -n cell describe pod orca-0 | tail -20
```

Expect `Pulling` → `Pulled` → `Running 1/1`. Then pair the Mac against
`192.168.2.241:6768` as before — `PAIRING_ADDRESS` did not change.

**Failure decoder:**

| Symptom | Cause |
|---|---|
| `http: server gave HTTP response to HTTPS client` | §1.1 not applied |
| `401 Unauthorized` / `UNAUTHORIZED` | §2.4 secret wrong, or PAT lacks `read:package` |
| `manifest unknown` | tag never pushed, or pushed under a different owner than `mershab` |
| `FailedToRetrieveImagePullSecret` | §2.4 not run, or run in the wrong namespace |

---

## 3. CI path — Gitea Actions runner

Durable replacement for §2. Builds native amd64 on the R730 in minutes instead
of QEMU-minutes.

### 3.1 Get this repo onto the forge

⚠️ The existing `gitea` remote points at the **OrbStack** forge on the Mac
(`localhost:3000`), not this one. The full cutover — moving repos off OrbStack
and re-pointing Flux — is a point of no return and is explicitly out of scope
here (see `docs/reports/2026-08-25-shamu-platform-port.md`). Use a second remote
so both exist side by side:

```sh
git remote add contraxia-forge http://192.168.2.244:3000/mershab/homelab.git   # once
git push contraxia-forge feat/local-image-pipeline
```

> Do **not** embed the PAT in the remote URL — the existing `gitea` remote does,
> which means `git remote -v` prints a live credential. Use
> `git config --global credential.helper osxkeychain` and let it prompt.

Create the `homelab` repo in the Gitea UI first. Actions must be enabled on it
(repo → Settings → Advanced → Enable Actions); `21-forge.yaml` already set the
instance-wide `actions.ENABLED: true`.

### 3.2 Registration token (operator)

UI → **Site Administration → Actions → Runners → Create new Runner**. Copy the
registration token, then:

```sh
kubectl --context admin@contraxia -n forge-runner create secret generic gitea-runner-token \
  --from-literal=token='<RUNNER_REGISTRATION_TOKEN>'
```

The `forge-runner` namespace is pre-created (and labelled
`pod-security.kubernetes.io/enforce: privileged` — the chart's DinD sidecar
renders `privileged: true` unconditionally and Talos enforces PSA `baseline`
everywhere else).

Until this Secret exists the runner pod sits in `CreateContainerConfigError`.
That is expected.

### 3.3 Repo Actions secrets

Repo → **Settings → Actions → Secrets**:

| Name | Value |
|---|---|
| `REGISTRY_USER` | `mershab` |
| `REGISTRY_TOKEN` | `<GITEA_PAT>` (needs `write:package`) |

The auto-injected `GITEA_TOKEN` is deliberately not used — it is scoped to the
API, not the package registry.

### 3.4 Run it

`.gitea/workflows/orca-image.yaml` fires on a push touching `images/orca/**`, or
manually via **Actions → orca-image → Run workflow** with an `orca_version`
input.

```sh
kubectl --context admin@contraxia -n forge-runner get pods
kubectl --context admin@contraxia -n forge-runner logs sts/forge-runner-runner -c runner
kubectl --context admin@contraxia -n forge-runner logs sts/forge-runner-runner -c dind
```

### 3.5 Rolling a new version out

The cell pins an exact tag with `imagePullPolicy: IfNotPresent`, so **deploying
is a git commit**:

1. bump `ORCA_VERSION` in `images/orca/README.md` and the workflow default,
2. let the workflow push `…/orca:v<new>`,
3. bump the tag in `platform/sveltos/manifests/orca-cell/orca.yaml`,
4. merge to `main`; Flux → Sveltos rolls the StatefulSet.

Re-pushing the **same** tag deploys nothing — the layers are already on the
node. Always bump.

> Keep the Mac's Orca version and this tag in lockstep. The client refuses to
> pair across an app-version gap; `orca status --json` →
> `result.runtime.appVersion` is the number to match.

---

## 4. What is deliberately NOT here

- **Spegel.** `platform/sveltos/clusterprofiles/33-registry.yaml` is written and
  parked. It is a P2P *mirror* between nodes and contraxia has one node, so it
  buys nothing today while adding a hostPath onto the containerd socket and a
  new dependency in the image-pull path. Un-park when the R820 joins; the file's
  header has the three-step checklist.
- **Docker layer cache across CI runs.** The DinD sidecar's `/var/lib/docker` is
  ephemeral, so every run is cold. Upgrade paths, in preference order: a buildx
  registry cache (`--cache-to type=registry`, sketched in the workflow header),
  or a `fast-block` PVC on `/var/lib/docker` — **not** `fast-zfs`, because
  dockerd's overlay2 driver cannot run on a ZFS dataset.
- **TLS on the registry.** LAN plain HTTP for now, per the track brief. The
  clean fix is Track F's: give the forge `git.mershab.com` and a
  `letsencrypt-prod` cert (DNS-01, so no inbound HTTP needed), after which
  `07-registries.yaml` can be deleted entirely and images re-tagged
  `git.mershab.com/mershab/orca:…`. Do not expose the registry on the public
  edge before that.
