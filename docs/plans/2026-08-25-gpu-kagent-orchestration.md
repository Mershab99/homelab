# GPU + kagent small-model orchestration on contraxia — recon and plan

**Status:** PLAN ONLY. Nothing in this document has been deployed. No manifests were
shipped. Every YAML block below is illustrative.
**Date:** 2026-08-25
**Branch:** `docs/gpu-kagent-plan`
**Cluster under study:** contraxia (single Talos control-plane node `r730`, `192.168.2.70`)

---

## TL;DR — the four findings that decide everything

1. **The R730 has two NVIDIA GPUs and neither is usable for this workload.** A Tesla K80
   (dead toolchain — no current inference runtime targets it) and a Quadro P2000 (live
   toolchain, but 5 GB VRAM, which does not hold a 30B model). Verified: the PCI devices
   are enumerated in-repo; the node advertises **zero** `nvidia.com/*` resources today.

2. **IOMMU is OFF on the running node and deliberately deferred.** `intel_iommu` and
   `pcirebind` are absent from the live kernel cmdline and were *intentionally held back*
   from the ZFS upgrade cycle. GPU passthrough to KubeVirt VMs is blocked until a
   dedicated later Talos upgrade. This is documented, not accidental.

3. **The economic thesis is half-right, and the half that's wrong is the half the user
   named.** "Small model + large context, locally, for free" is exactly the workload CPU
   inference is *worst* at — because large context means large **prefill**, prefill is
   compute-bound, and this box is Broadwell with AVX2 and no AVX-512. The thesis holds
   strongly for high-volume *short-context* batch work. Whether it holds for large context
   depends on one number nobody has measured yet (see Phase 0).

4. **But there is a better reason to do it anyway, and it isn't tokens-per-second.** The
   Mac is out of headroom; LM Studio is holding 19.61 GB resident *right now* for one 30B
   model at only **8192 context**. Moving that model to a box with 94 GiB frees the Mac
   AND unlocks a context window the Mac can never reach. **RAM capacity, not GPU
   bandwidth, is what a large-context orchestrator actually needs.** The R730 wins on the
   axis that matters and loses on the axis that doesn't.

**Recommendation:** ignore both GPUs. Ship one `llama.cpp` CPU server on contraxia,
serving the GGUF the user already owns, exposed on a LAN VIP, consumed by kagent
ModelConfigs. Measure prefill first (Phase 0, one Job, ~30 minutes). Do not buy hardware,
do not touch IOMMU, do not build the Hermes A2A image.

---

## 1. Hardware truth

### 1.1 What is actually in the box

**GPUs — enumerated from this R730 on 2026-08-25 via `talosctl get pcidevices`, recorded
in `bootstrap/talos/controlplane.yaml:158-164`:**

| BDF | Device | Note |
| --- | --- | --- |
| `0000:06:00.0` | NVIDIA GK210GL [Tesla K80] | die 0 of the K80 card |
| `0000:07:00.0` | NVIDIA GK210GL [Tesla K80] | die 1 — **same physical card** |
| `0000:82:00.0` | NVIDIA GP106GL [Quadro P2000] | |
| `0000:82:00.1` | GP106 HD Audio | P2000 function 1 |
| `0000:0e:00.0` | Matrox G200eR2 | console VGA — **never rebind** |

Corroborated live. KubeVirt's `permittedHostDevices` on the running cluster names the
matching PCI vendor IDs (`kubectl get kubevirt -n kubevirt-hyperconverged -o jsonpath=...`):

```
{"pciHostDevices":[
  {"pciVendorSelector":"10DE:102D","resourceName":"nvidia.com/GK210GL_TESLA_K80"},
  {"pciVendorSelector":"10DE:1C30","resourceName":"nvidia.com/GP106GL_QUADRO_P2000"}]}
```

> **The K80 is a dual-GPU board presenting two dies.** `controlplane.yaml` flags this as
> "the load-bearing finding" — an earlier draft listed only `06:00.0`, and without die 1
> the card cannot be handed to a VM cleanly. Carry both BDFs or neither.

**Node capacity** (`kubectl get node r730 -o json`):

```
cpu=32   memory=98849752Ki (~94.3 GiB)   pods=250   ephemeral-storage=485893320Ki
allocatable: cpu=31950m  memory=98223064Ki
```

**Live usage** (`kubectl top node`, at recon time): `3513m` CPU (10%), `14406Mi` (15%).
**Requests** (`kubectl describe node`): cpu `7645m` (23%), memory `18718381440` (18%).
→ roughly **24 cores and 70+ GiB genuinely free.**

**CPU generation** — inferred from the KubeVirt node-labeller, not from `lscpu`:

- `host-model-cpu.node.kubevirt.io/Broadwell-IBRS=true` → Broadwell (Xeon E5 v4 family).
- `cpu-timer.node.kubevirt.io/tsc-frequency=2099998000` → 2.1 GHz base.
- Present: `avx`, `avx2`, `fma`, `bmi1`, `bmi2`, `f16c`. **Absent: any `avx512*` label.**
- `cpumanager=false`, `hugepages-1Gi=0`, `hugepages-2Mi=0`.

The absent AVX-512 is the operative fact for CPU inference and it is a *direct
observation* (the labeller enumerates every feature it finds; there are no avx512 entries
in a 400-label dump).

`UNVERIFIED`: exact SKU, socket count, DIMM population, and memory clock. `talosctl` is
unusable from this worktree (§1.4) and Talos has no host shell. 32 logical CPUs at
2.1 GHz on a dual-socket R730 is *consistent with* 2× 8-core/16-thread E5-2620 v4, but
**that is an inference, not a measurement** — do not plan capacity on it.

**Talos system extensions installed** (from node labels — this is exhaustive):

```
extensions.talos.dev/intel-ucode=20260512
extensions.talos.dev/iscsi-tools=v0.2.0
extensions.talos.dev/util-linux-tools=2.41.4
```

**No `nonfree-kmod-nvidia`. No `nvidia-container-toolkit`. No `nvidia-open-gpu-kernel-modules`.**
On Talos, GPU compute is impossible without those — they are the only way a kernel module
lands. Their absence is dispositive regardless of what silicon is in the slots.

### 1.2 The GPUs are advertised but not present

```
$ kubectl get node r730 -o json | jq .status.allocatable
# → cpu, memory, pods, ephemeral-storage, hugepages-*,
#   devices.kubevirt.io/{kvm,tun,vhost-net}, bridge.network.kubevirt.io/br0
#   NO nvidia.com/* entries.

$ kubectl get pods -A | grep -iE 'nvidia|gpu|device-plugin|dcgm'
# → NONE
$ kubectl get ns | grep -iE 'nvidia|gpu'
# → NONE
$ kubectl get runtimeclass
# → No resources found
```

So: HCO *asks* for the devices, and the node supplies **zero**. This exactly reproduces
the state already written up in `bootstrap/talos/gpu-remediation-plan.md` (2026-07-22),
where `arrakis-gpu-k80-*` and `arrakis-gpu-p2000-*` Machines sat in `Provisioning` with
`FailedScheduling … Insufficient nvidia.com/GK210GL_TESLA_K80`.

### 1.3 ⚠️ IOMMU is off, and that is on purpose

`bootstrap/talos/controlplane.yaml:144-183` carries an explicit deferral block:

> ```
> ┌─ GPU passthrough args are DEFERRED — do not re-add in this cycle ──┐
> │ This upgrade changes ONLY the extension set (+zfs, -iscsi-tools)   │
> │ and the ZFS ARC cap. The IOMMU/vfio args are held back on purpose. │
> │ Why: extraKernelArgs take effect only at install/upgrade time, and │
> │ no install has run since these args were first written here — so   │
> │ /proc/cmdline on the live node has NO intel_iommu and NO pcirebind │
> │ (confirmed 2026-08-25).                                            │
> └────────────────────────────────────────────────────────────────────┘
> ```

The live `extraKernelArgs` is a single entry: `zfs.zfs_arc_max=21474836480`.

**Consequence: VM passthrough is off the table.** Not "hard" — *off*. It requires a Talos
`apply-config` + reboot of the only control-plane node, which is a separate change from
the storage refit currently landing, and the repo has correctly refused to stack them.

**But note the fork the brief did not assume.** IOMMU is required for handing a GPU to a
*VM*. It is **not** required to run an inference container on contraxia itself. Those two
paths are mutually exclusive per card and they need opposite things:

| | Host-side GPU compute | Passthrough to arrakis VMs |
| --- | --- | --- |
| IOMMU / `pcirebind` | not needed | **required** |
| nvidia kernel driver on host | **required** (Talos extension) | must **NOT** load — fights vfio |
| Talos schematic change | yes (`nonfree-kmod-nvidia` + toolkit) | yes (kernel args) |
| Delivered by | gpu-operator would be *wrong* here | `11-tenant-gpu.yaml` inside arrakis |

`gpu-remediation-plan.md:26-30` states the house rule plainly: *"Do NOT add nvidia
gpu-operator to contraxia … gpu-operator on the host loads the nvidia kernel driver and
would fight vfio for the cards. Wrong layer."* That rule was written for the passthrough
design. **If contraxia ever wants host-side inference, that rule has to be renegotiated,
not worked around** — you cannot have both on the same card.

### 1.4 What I could not verify, and why

`UNVERIFIED — could not enumerate PCI devices live.` Reason:

```
$ talosctl -e 192.168.2.70 -n 192.168.2.70 get pcidevices
rpc error: code = Unavailable desc = connection error: desc = "transport: authentication
handshake failed: tls: failed to verify certificate: x509: certificate signed by unknown
authority (possibly because of \"x509: Ed25519 verification failure\" while trying to
verify candidate authority certificate \"talos\")"

$ talosctl config contexts
CURRENT  NAME              ENDPOINTS   NODES
         cluster           127.0.0.1
         talos-default-*   127.0.0.1     (dozens of stale local test contexts)
```

The workstation `~/.talos/config` has **no contraxia context at all** — only `127.0.0.1`
entries from local Docker/QEMU test clusters. The repo's `bootstrap/talos/talosconfig` is
deny-listed for reading per the guard rails, so I did not attempt it. This reproduces the
error the coordinator hit; it is a **client-side config problem, not a node problem** (the
kube API on the same host answers fine).

All hardware claims in §1.1 therefore rest on the in-repo enumeration recorded *today*
plus the live KubeVirt/node cross-checks — which agree with each other. Nothing here is
guessed.

Also `UNVERIFIED`, and worth settling before anyone restores the kernel args
(`controlplane.yaml:178-183` raises it and I could not resolve it either): `pcirebind.rebind=…_nvidia+vfio-pci`
names `nvidia` as the driver to rebind *from*, but no nvidia kernel-module extension is
installed, so no nvidia driver is loaded. Whether that is a harmless no-op or a boot error
has never been confirmed.

### 1.5 Verdict on the silicon

Published NVIDIA specifications, **not measured on this host** — confirm with `nvidia-smi`
if drivers ever load:

| | Tesla K80 | Quadro P2000 |
| --- | --- | --- |
| GPU | 2× GK210 (Kepler) | GP106 (Pascal) |
| Compute capability | **3.7** | **6.1** |
| VRAM | 24 GB total = **2× 12 GB**, not pooled | **5 GB** |
| Board power | ~300 W, passive (needs server airflow) | ~75 W, slot-powered |
| Last driver branch | **470.x** (CUDA 11.4 ceiling) | current LTS (repo pins 535.183.06) |

Both figures are consistent with `11-tenant-gpu.yaml`, which independently pins the K80 to
`470.141.10` with the comment *"last CUDA 11.4 driver supporting Kepler GK210"* — that pin
was chosen by someone who hit the same ceiling.

**Why each is unusable for large-context small-model serving:**

- **K80 — dead toolchain.** vLLM requires compute capability ≥ 7.0; 3.7 is far below it.
  llama.cpp's CUDA backend targets ≥ 5.0 by default and needs a toolkit that still emits
  `sm_37`, which means CUDA 11.x archaeology. Even if you got a binary, the 24 GB is
  **two separate 12 GB pools** — a 30B model at Q4 (~17-19 GB) does not fit in either, and
  splitting an MoE across two Kepler dies over PCIe is not a thing anyone should attempt
  in a homelab. Add 300 W of passive-cooled heat into a chassis that also holds 15 SSDs.
- **P2000 — live toolchain, wrong size.** Pascal `sm_61` still works with llama.cpp and is
  still (deprecated but) present in CUDA 12. vLLM still says no (< 7.0). The blocker is
  **5 GB**. That holds a 7-8B at Q4 with a *small* context, which is the precise opposite
  of "small model with a large context window." A 262k-token KV cache alone is many times
  5 GB.
- **Both — Talos delivery.** Getting *either* onto the host needs the
  `nonfree-kmod-nvidia` + `nvidia-container-toolkit` extensions in `r730-schematic.yaml`.
  That is a new image factory hash, a reboot of the only control-plane node, and a
  **version coupling between the extension and the Talos release** — the exact landmine
  the ZFS refit is currently walking through. And Talos ships one production driver
  branch; it is not going to be 470.x. **K80 on the host is effectively impossible.**

> **A well-argued negative result:** there is no GPU path here worth taking. Both cards
> predate the era of the workload. This is not a "wire it up" task; it is a "recognise the
> hardware is the wrong hardware" task.

---

## 2. Serving stack decision

### 2.1 The comparison

| Option | Verdict | Reason |
| --- | --- | --- |
| **vLLM (GPU)** | ❌ | Requires CC ≥ 7.0. K80=3.7, P2000=6.1. Neither qualifies. |
| **vLLM (CPU backend)** | ❌ | The x86 CPU backend is oriented at AVX-512/AMX. This host has **neither**. Also markedly more operational surface than llama.cpp for a single-node homelab. |
| **Ollama** | 🟡 | Works (llama.cpp underneath), serves `/v1/chat/completions`. But it interposes its own model store and naming, and gives less direct control over `--ctx-size`, slot count, and cache reuse — the three knobs this whole plan turns on. |
| **llama.cpp `llama-server`** | ✅ **Pick this** | Best AVX2 CPU path available; native OpenAI-compatible endpoint; explicit context/parallel/cache-reuse flags; consumes the exact GGUF already on the Mac; official container images published by the project. |
| **LM Studio on the Mac** | ✅ **Keep, for a different job** | It is a desktop GUI app, not a container workload. Keep it for the interactive/vision companion persona. Do not try to containerise it. |

### 2.2 Why CPU is genuinely competitive here — and where it isn't

Two costs, and they behave oppositely:

**Generation (decode) is memory-bandwidth-bound.** Per output token you stream the active
weights once. For an MoE like Qwen3-30B-A3B only ~3.3B of 30.5B params are active:

```
tok/s_ceiling ≈ memory_bandwidth_GBps / (active_params × bytes_per_param)
              ≈ BW / (3.3e9 × ~0.55 B)      # Q4_K_M ≈ 4.4 bits/param
              ≈ BW / 1.8 GB
```

At a plausible single-socket DDR4 realised bandwidth this lands in the **tens of tok/s**.
That is a *stated arithmetic model with its inputs on the table* — **not a benchmark, not
a measurement, and not a number to quote to anyone.** Real llama.cpp on Broadwell lands
below roofline. `UNVERIFIED`: actual memory bandwidth (DIMM speed unknown, §1.1) and
whether the process gets one socket's channels or interleaves across both (`cpumanager=false`,
so no NUMA pinning today).

**Prefill (prompt processing) is compute-bound.** It is a dense GEMM over the whole prompt,
scaling with context length, and it uses AVX2 at 2.1 GHz with no AVX-512 and no AMX.

> **This is the crux, and it is the honest answer to "does the thesis hold?"**
> The user asked for *"smaller models with large context window for orchestration."*
> Large context is precisely what makes prefill expensive, and prefill is precisely what
> this CPU is worst at. **A 128k-token prompt processed cold on Broadwell AVX2 will not
> feel like an orchestrator; it will feel like a batch job.**

**The lever that decides it: prefix caching.** Orchestration prompts are usually a long
*stable* prefix (system prompt, tool schemas, repo context) plus a short varying tail. If
llama.cpp can reuse the cached prefix, a 100k cold prefill becomes a ~2k warm prefill and
the whole objection evaporates. llama-server supports slot-based KV reuse
(`--cache-reuse`, slot save/restore). **Whether the real prompt shapes hit that cache is
the single number Phase 0 must measure.** Everything downstream is contingent on it.

### 2.3 The argument that does not depend on tok/s at all

Right now, on the Mac (`lms ps`, verified at recon time):

```
IDENTIFIER                                    STATUS            SIZE       CONTEXT  PARALLEL
huihui-qwen3-vl-30b-a3b-instruct-abliterated  PROCESSINGPROMPT  19.61 GB   8192     4
```

**Context: 8192.** On a 32 GiB Mac holding a 19.61 GB model, there is no room left for a
large KV cache. The user wants a large context window and their current hardware
structurally cannot give them one. `docs/orca-mobile-kagent-chat.md` records the same wall
from the other side: *"LM Studio only fits **one** 30B model in memory."*

On contraxia: 94 GiB total, ~70 GiB free. Model resident ≈ 18 GB. **Everything else is KV
cache.** That is a context window the Mac cannot reach at any speed.

> **For LARGE CONTEXT specifically, RAM capacity beats VRAM bandwidth — because you cannot
> run a context you cannot store.** A used 24 GB GPU would hold the model with ~6 GB left
> for KV; 94 GiB of DDR4 holds the model with ~70 GiB left. The R730 wins the axis the
> user actually named and loses the axis they didn't.

And it frees 19.61 GB on the Mac immediately, which is the stated problem
("out of headroom") — independent of how fast the R730 turns out to be.

### 2.4 Simplification vs. the devex design: drop agentgateway

The laptop design routes ModelConfigs through **agentgateway** purely for token metrics,
because — verified in `apps/laptop/agentgateway/agentgateway.yaml:4-8` — kagent 0.9.12
emits no token metrics anywhere:

```
kagent-tools-metrics:8085/metrics -> 200, Go runtime stats only
kagent-controller:8083/metrics    -> 404
<agent>.kagent.svc:8080/metrics   -> 404
```

That reasoning was sound **for LM Studio**, which has no metrics endpoint. It does not
carry over: `llama-server --metrics` exposes a Prometheus endpoint natively with prompt
and generation token counters. Adding agentgateway to contraxia would mean a new
GatewayClass, new CRDs, and a proxy hop — for a counter the server already emits.

Cost of adding it here, concretely:
- contraxia has Gateway API CRDs (`bundle-version: v1.2.1`, standard channel, installed
  2026-07-15) but **`kubectl get gatewayclass` → No resources found**. No controller.
  agentgateway would bring its own `gatewayClassName: agentgateway`.
  `UNVERIFIED`: whether agentgateway v1.4.1 accepts a v1.2.1 CRD bundle (devex vendored
  **v1.6.1** for Cilium on shamu — that is a two-minor gap worth checking before assuming).
- **There is no Prometheus running on contraxia to scrape it.** `kubectl get pods -n monitoring`
  returns only `minio` and `otel-operator`; `07-observability-core.yaml` and
  `07-observability-backend.yaml` are both commented out of
  `platform/sveltos/clusterprofiles/kustomization.yaml` ("minimal:"). So the metrics
  would have no consumer either way.

**Decision: skip agentgateway in this design.** Revisit only if (a) observability comes
back on contraxia *and* (b) a second, non-llama.cpp backend appears that needs unifying.
Keep the devex file as the reference for that day — its findings are good, its premise
just doesn't apply here.

---

## 3. Model shortlist

**The selection rule, which matters more than the list:** on a CPU with no AVX-512,
**Mixture-of-Experts with a low active-parameter count is the only architecture that
works.** Decode cost scales with *active* params, not total. A dense 24B streams ~13 GB
per token and is bandwidth-dead on this box; a 30B MoE with 3.3B active streams ~1.8 GB
and is roughly 7× cheaper per token at similar quality. **Do not put a dense model on this
machine.**

| Model | Total / active | Context (published) | Q4 on-disk | Fit |
| --- | --- | --- | --- | --- |
| **Qwen3-30B-A3B-Instruct-2507** | 30.5B / **3.3B** MoE | 262,144 | **17.19 GB — verified on disk** | ✅ **primary** |
| **Qwen3-Coder-30B-A3B-Instruct** | 30.5B / 3.3B MoE | ~256k | ~18 GB | ✅ code/diff work |
| **gpt-oss-20b** | ~21B / ~3.6B MoE | 128k | ~12 GB (MXFP4) | ✅ strong alternate |
| **Qwen3-4B-Instruct-2507** | 4B dense | 262,144 | ~2.5 GB | ✅ cheap router tier |
| huihui-qwen3-vl-30b-a3b (VL) | 30B / 3B MoE | — | **19.61 GB — verified on disk** | 🟡 keep on the Mac |
| Mistral-Small-3.2-24B | 24B **dense** | 128k | ~14 GB | ❌ dense — bandwidth-dead |
| Gemma 3 12B / 27B | dense | 128k | — | ❌ same reason |
| Llama 3.1 8B | 8B dense | 128k | ~4.7 GB | 🟡 workable fallback only |

**Verified** entries come from `lms ls` on the Mac at recon time. **Everything else —
parameter counts, context windows, quantised sizes — is vendor-published and `UNVERIFIED`
on this host.** Confirm at deploy time: `llama-server` prints `n_ctx_train` and
`KV self size = …` at startup; that startup log is ground truth, the model card is not.

**Start with what is already on disk.** `qwen/qwen3-30b-a3b-2507` (17.19 GB) is present,
the user already trusts it, and it has the best MoE ratio in the list. Adding a second
model is a Phase-3 problem.

> **KV cache sizing — get this from the tool, never from a table.**
> `KV_bytes = 2 × n_layers × n_kv_heads × head_dim × ctx_len × bytes_per_element`
> The head geometry must be read from the GGUF metadata, and llama-server prints the
> resulting figure on startup. I am deliberately **not** putting an illustrative number
> here, because a plausible-looking wrong KV figure is exactly how a capacity plan goes
> bad. Read it off the first boot and write it into this document.

---

## 4. kagent wiring

### 4.1 Where things stand on contraxia today

| Fact | Evidence |
| --- | --- |
| No kagent/kmcp namespace on contraxia | `kubectl get ns` — 29 namespaces, none matching |
| No kagent/kmcp/nvidia/gpu CRDs | `kubectl get crd \| grep -iE 'kagent\|mcp\|nvidia\|gpu'` → none |
| `16-mcp-baseline.yaml` targets **persona=ai vclusters**, not the hub | file `clusterSelector: {matchLabels: {persona: ai}}` |
| kagent **controller is PARKED** in that file | lines commented, *"PARKED 2026-08-06 — heavy default-agent fleet (~10 pods + postgres + ui), not needed yet"* |
| A stale `ai-helpers` ClusterProfile is still live | `kubectl get clusterprofile ai-helpers` — 33d old, matches `SveltosCluster/ai`, but **no longer exists in the repo** (superseded by `16-mcp-baseline`). Orphan drift; not mine to clean, flagging it. |

`16-mcp-baseline.yaml` already contains the exact hook this plan needs:

```yaml
# ── FILL (only if the kagent controller gets un-parked) ──
#   - A ModelConfig + its API-key Secret (secrets/infrastructure/kagent/)
#     applied inside the target vcluster.
```

**That comment is the deliverable of the follow-up task.** This plan's job is to make
filling it mechanical.

### 4.2 Which reference to port — the laptop one, not shamu's

devex has two kagent app dirs. **Port `apps/laptop/kagent/`, not `apps/shamu/kagent/`.**

`apps/shamu/kagent/kagent.yaml` states in its header that `default-model-config` points at
a self-hosted endpoint — but its `values:` block **sets no `providers.*` key at all**
(verified: `grep -rn 'providers' apps/shamu/` returns only an unrelated CAPI file). With
`providers` unset, the chart renders its default, which is OpenAI. **The shamu file does
not do what its own comment says it does.** It is a design sketch.

`apps/laptop/kagent/kagent.yaml` is the *working, verified* version — it actually sets:

```yaml
providers:
  default: openAI
  openAI:
    config:
      baseUrl: "http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1"
    model: "qwen/qwen3-30b-a3b-2507"
    apiKey: "not-used-by-lm-studio"
```

Port that shape; swap the `baseUrl` for the llama.cpp VIP; drop the agentgateway hop (§2.4).

### 4.3 Gotchas to carry forward verbatim

Each of these is recorded as *verified* in devex and each one costs a debugging session if
lost:

1. **`kmcp.enabled: false` in BOTH charts.** kagent-crds 0.9.12 and standalone kmcp-crds
   0.3.0 both ship `mcpservers.kagent.dev`; two Helm releases cannot own one CRD →
   `invalid ownership metadata`, plus a second controller reconciling the same CRs.
   homelab's `16-mcp-baseline.yaml` already encodes the resolution (kagent-crds owns the
   CRD, kmcp-crds is deliberately absent) — **do not "fix" that by adding kmcp-crds.**
2. **`spec.apiKeySecret` is a STRING**, with a sibling `spec.apiKeySecretKey`. The object
   form `{name:, key:}` is rejected by the v1alpha2 CRD with
   `strict decoding error: unknown field spec.apiKeySecret.key/.name`.
   (devex verified this with `kubectl explain modelconfig.spec.apiKeySecret`.)
3. **The dummy API key is required.** llama.cpp checks nothing, but the CRD field is
   mandatory. One Secret, one junk value.
4. **kagent emits no token metrics** (§2.4). Do not go looking for them.
5. **Sveltos v1.12 rejects `.x` chartVersion wildcards** — pin EXACT versions. Note that
   `07-observability-*.yaml` still carries `14.0.x` / `6.x` / `5.x` wildcards; those files
   are commented out of the kustomization, which is presumably why they haven't bitten.
   **Anything this plan adds must be exact.**
6. **Fleet off.** All 10 built-in agents, `kagent-tools`, `grafana-mcp`, `querydoc`
   (default-on and wants an OpenAI key — off twice over), `substrate`, `oauth2-proxy`.

### 4.4 Topology — where each piece lives

The inference server and the agent harness do **not** belong in the same place.

```
  contraxia (hub, 94 GiB)                        arrakis / persona vclusters
  ┌────────────────────────────────┐             ┌──────────────────────────────┐
  │  llama-server (CPU)            │             │  kagent controller           │
  │   Deployment + PVC(fast-zfs)   │◄────────────┤   ModelConfig.openAI.baseUrl │
  │   Service type=LoadBalancer    │  LAN VIP    │   Agent CRs (Declarative)    │
  │   lbipam.cilium.io/ips: .241   │  :8080/v1   │   kmcp 0.3.0 → MCPServers    │
  └────────────────────────────────┘             └──────────────────────────────┘
```

**Rationale:** the RAM is on contraxia, so the model goes there. The agents live where
`16-mcp-baseline` already puts their CRDs (persona=ai vclusters on arrakis). They are in
*different clusters*, so the endpoint must be reachable over the LAN, not by
`.svc.cluster.local`.

**VIP allocation:** Cilium LB-IPAM pool `lan-pool` = `192.168.2.240–.250`. `.240` is taken
by `tenants/kmc-arrakis-lb`. **Take `.241`**, pinned with
`lbipam.cilium.io/ips: "192.168.2.241"`. (Coordinate with the other tracks in this Run —
they are allocating from the same pool.)

**Storage:** the model PVC targets **`fast-zfs`**. As of recon the cluster still shows
`longhorn (default)` and `longhorn-static` — the ZFS migration has not landed yet, and
`longhorn-system` is still up (with pre-existing `Error` pods). **This plan has a hard
dependency on that migration completing.** Do not hardcode `longhorn`.

**Getting the GGUF in:** `llama-server -hf <repo>/<file>` downloads from Hugging Face
directly into the model dir. One flag, one PVC, no init container, no image bake, no
`kubectl cp`. Take it.

### 4.5 Illustrative shape only — DO NOT APPLY

```yaml
# ILLUSTRATIVE. Not a deliverable. Shows the join between the pieces.
# Real version → platform/sveltos/clusterprofiles/NN-local-inference.yaml
#                + platform/sveltos/manifests/local-inference/
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: llama-server
          image: ghcr.io/ggml-org/llama.cpp:server          # verify tag at deploy time
          args:
            - -hf
            - <hf-repo>/<gguf-file>                          # Qwen3-30B-A3B-Instruct-2507 Q4_K_M
            - --host
            - 0.0.0.0
            - --port
            - "8080"
            - --ctx-size
            - "<from Phase 0>"                               # do NOT guess this
            - --parallel
            - "<from Phase 0>"
            - --threads
            - "<= 24, leave headroom for the rest of the hub>"
            - --cache-reuse
            - "256"                                          # the prefix-cache lever, §2.2
            - --metrics                                      # replaces agentgateway, §2.4
          resources:
            requests: {cpu: "8",  memory: 24Gi}
            limits:   {cpu: "24", memory: 40Gi}               # bound it; the hub is shared
          volumeMounts: [{name: models, mountPath: /models}]
      volumes:
        - name: models
          persistentVolumeClaim: {claimName: llama-models}    # StorageClass: fast-zfs
---
apiVersion: v1
kind: Service
metadata:
  annotations:
    lbipam.cilium.io/ips: "192.168.2.241"
spec:
  type: LoadBalancer
---
# ILLUSTRATIVE — the kagent side, inside a persona=ai vcluster
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata: {name: local-qwen3-moe, namespace: kagent}
spec:
  provider: OpenAI
  model: <exact id llama-server reports at /v1/models>
  apiKeySecret: kagent-model-router          # STRING, not an object — §4.3(2)
  apiKeySecretKey: OPENAI_API_KEY
  openAI:
    baseUrl: "http://192.168.2.241:8080/v1"
```

⚠️ **CPU limits are load-bearing.** contraxia is the hub — it runs CAPI, k0smotron,
KubeVirt, Sveltos, Flux and the ZFS stack. An unbounded llama.cpp will take every core and
starve the API server. `docs/orca-mobile-kagent-chat.md` already records that exact failure
on the Mac: *"kube-apiserver starved (check `uptime` — load > 30 …). Nothing to fix in
code. Shed load and wait."* **Do not let that happen to the hub.** Also note
`cpumanager=false` — there is no static CPU pinning today, so the limit is the only
control you have.

### 4.6 The Hermes A2A blocker — real, but the wrong thing to unblock

The blocker is real and correctly diagnosed. OSS kagent 0.9.12 has **no RemoteAgent CRD**
and no URL-only registration (devex verified this against 0.9.12 CRDs *and* 0.10-rc types).
`spec.byo.deployment.image` is required; the controller deploys the image itself and
expects A2A on `:8080` (agent card at `/.well-known/agent.json` + JSON-RPC `message/send`).
`hermes-agent.yaml` is kustomization-excluded with `image: CHANGEME`. Clearing it means
building and maintaining an A2A server image.

**Cost to clear:** a new container image, an A2A protocol implementation (kagent's Python
SDK `KAgentApp` wraps it), a ghcr push pipeline, and ongoing maintenance — for a fixed
0.9.12 target with a 0.10 API drift already visible on the horizon.

**My recommendation: don't build it. Close `TODO(hermes-a2a)` as won't-do.**

The reason is architectural, not effort. **The user's multi-agent runtime is Orca** —
`worker-start`, dispatch, `worker_done`, escalation. This document was produced by an Orca
worker under an Orca coordinator. Building hermes-a2a makes *kagent* the orchestrator and
Orca a callee. That is a second orchestrator competing with the one that already works,
and the brief is right to ask whether these compete: **they do, if you build that image.**

**They compose cleanly if you don't:**

| Layer | Owner | Job |
| --- | --- | --- |
| Orchestration — decompose, dispatch, gate, escalate | **Orca** | already the runtime; holds the human in the loop |
| Frontier reasoning | **Claude via Orca workers** | billing already lives on the account |
| Model routing + small-agent harness | **kagent** | ModelConfigs, Declarative Agent CRs, tool scoping |
| Local inference | **llama.cpp on contraxia** | the endpoint kagent routes to |
| Tools | **kmcp / MCPServer CRs** | already deployed per §4.1 |

Escalation from cheap to expensive happens **in Orca** (dispatch a worker with a bigger
model) — not inside kagent. kagent then never needs to call outward, so it never needs
RemoteAgent, so the blocker stops mattering.

**What would change my mind:** if the user wants agents reachable from a phone/browser with
no Orca session running — the `docs/orca-mobile-kagent-chat.md` use case. But that path
**already works today** with a `Declarative` Agent + a local ModelConfig; it needs no A2A
egress. So even that doesn't require hermes-a2a.

### 4.7 Composing with Track C

Track C may port the kagent chart delivery. At recon time `feat/shamu-platform-contraxia`
had **no commits ahead of `main`** (`git log --oneline feat/shamu-platform-contraxia -3`
shows `cc2918c` = current main), so there was nothing to read.

Clean split, no overlap:

- **Track C owns:** the HelmRelease/ClusterProfile that installs the kagent chart, its
  version pins, namespace, and exposure.
- **This plan owns:** the ModelConfig, the dummy-key Secret, the llama.cpp serving layer,
  the VIP, and the routing policy (§5).

The join is exactly one string — `ModelConfig.spec.openAI.baseUrl` → `http://192.168.2.241:8080/v1`.
If Track C's chart values set `providers.openAI.config.baseUrl`, that is the same string in
the chart's own words. **Whoever lands second just fills in the URL.**

---

## 5. The orchestration design

### 5.1 The routing rule

Not "small tasks local, big tasks remote" — that framing produces confident garbage,
because task *size* is not what small models fail at.

> **Route to the local model only when the output is cheaply verifiable by something that
> is not a model.**

A router's output is verifiable: is the returned label in the enum? A schema extraction is
verifiable: does it parse and satisfy the constraints? A summary is **not** verifiable —
you would need to read the source to check it, at which point the summary saved nothing.

| Route **local** | Escalate to **opus (via Orca)** |
| --- | --- |
| Classify into a fixed taxonomy | Decide what the taxonomy should be |
| Extract to a JSON schema with a validator | Judge whether the extraction matters |
| "Did this ClusterSummary go non-provisioned? yes/no" | Diagnose *why* it did |
| Draft a commit message from a diff | Decide whether the diff is correct |
| Rank N candidates against stated criteria | Choose the criteria |
| Mechanical rewrite with a diff-check | Multi-file refactor |
| Rerank/embed for retrieval | Architecture, planning, tradeoffs |

Everything in the left column has a **deterministic checker**. That is the whole rule.
When there is no checker, the local model's failure mode is a plausible wrong answer that
costs more to catch than it saved.

### 5.2 Does the economic thesis hold? Partially — and the failing half is the named half

The brief asks for an honest verdict. Here it is:

**Where it holds — strongly:** high-volume, independent, **short-context**, schema-checked
work. Cron-style cluster watchers. Log/event triage. PR-diff summaries. Commit messages.
Embeddings and reranking. These are batch-shaped, prefix-stable, individually cheap, and
collectively expensive in frontier tokens. Moving them local is a straightforward win.

**Where it does not hold — the case the user actually described:** *"smaller models with
large context window for orchestration."* Two independent problems.

1. **Prefill.** Large context = expensive prefill; prefill is compute-bound; this CPU is
   AVX2 Broadwell. This is the technical objection and it is contingent on Phase 0.
2. **The context is already loaded somewhere else.** In Orca, the coordinator making the
   dispatch decisions *is already* a frontier model that *already has* the context in its
   window. Routing that decision to a local model means **serialising the context out and
   prefilling it again on the R730.** You pay a large prefill to save a small number of
   output tokens on a decision that is a handful of tokens long. **The arithmetic is
   against you**, and it is against you regardless of how fast the R730 turns out to be.

> **So: don't move orchestration decisions off the coordinator.** Move the high-volume
> *leaf* work — the watching, triaging, extracting, summarising — that today either burns
> frontier tokens or doesn't happen at all. That is where the local model pays, and it is
> a different (and larger) win than the one that was asked for.

Framed sharply: **the local model is not a cheaper coordinator. It is a fleet of cheap
sensors that report to an expensive coordinator.** That is a better architecture anyway —
it is what makes the frontier model's context worth spending.

### 5.3 Orca vs kagent — complementary, not competing (if you keep it that way)

Per §4.6. Orca orchestrates; kagent routes models and hosts small scoped agents; kmcp
supplies tools; llama.cpp supplies tokens. **The only thing that turns them into competing
orchestrators is building hermes-a2a — so don't.**

Concretely, the local model reaches Orca-side work through MCP, not A2A: an MCP server
exposing the local endpoint (or the existing kagent MCP bridge pattern from
`docs/orca-mobile-kagent-chat.md`, which already works over service DNS with no
port-forward) lets an Orca worker call `ask_<persona>` as a **tool**. Tool-shaped, not
agent-shaped. The expensive model stays in charge and decides when to spend a cheap call.

### 5.4 Tool scoping — inherit the persona-agents discipline

`apps/laptop/kagent/persona-agents.yaml` already establishes the right rules, and they
should carry over unchanged:

- **`toolNames` is not a safety boundary.** It is configuration — a YAML list a person
  edits. The real boundary is which *binary* is built and what code paths exist in it.
  Separate MCPServer images per capability tier; `toolNames` as defence-in-depth on top.
- **`tools: []` is a real security property.** The `huihui` persona's system prompt
  disables refusals; combining "will not refuse" with "can act on the cluster" is the
  failure mode. **Companion personas get zero tools, permanently.** If that persona moves
  to contraxia — the *hub*, running CAPI and KubeVirt — this rule gets **more** important,
  not less.
- **Untrusted text is data, not instructions.** Logs, STATUSTEXT, PR bodies, issue titles
  are attacker-controlled. A local model triaging them is a prompt-injection surface, and
  a small model is *easier* to injure than a frontier one. Any agent whose input is
  external text gets a read-only tool surface, full stop.

---

## 6. Cost / benefit, honestly

### 6.1 CPU inference on contraxia — recommended

| | |
| --- | --- |
| **Hardware cost** | **$0.** The box runs 24/7 at 10% CPU already. |
| **Marginal power** | Dual E5 v4 under sustained load ≈ **+150–250 W** over idle (spec-sheet TDP band, `UNVERIFIED` — measure at the PDU/iDRAC). Cost = `watts/1000 × hours × $/kWh`; I am not inventing a tariff. |
| **RAM cost** | ~18 GB resident for the model + KV. ~70 GiB free today. Fits with room. |
| **Complexity** | **One Deployment, one PVC, one Service, one ClusterProfile.** No kernel args, no Talos schematic change, no reboot, no new operator. |
| **Quality** | A 30B-A3B is not opus. Real drop. Mitigated by §5.1's verifiability rule. |
| **Latency** | Slower per token than the Mac's Metal path; irrelevant for a 5-minute watcher, noticeable when interactive. |
| **Risk** | **Starving the hub API server.** Real, and the one thing to get right (§4.5). |
| **Reversibility** | Delete the ClusterProfile. Nothing else changed. |

### 6.2 Using the existing GPUs — do not

| | |
| --- | --- |
| **K80** | Dead toolchain (CC 3.7, 470.x ceiling). 24 GB is 2× 12 GB, not pooled — a 30B Q4 fits in neither. **~300 W passive** into a chassis with 15 SSDs. Talos ships no 470.x extension. **Effectively impossible, and undesirable if it weren't.** |
| **P2000** | Toolchain alive (`sm_61`, still in CUDA 12; llama.cpp fine). **5 GB VRAM.** Cannot hold a 30B; cannot hold a large KV cache. It is the wrong size for the stated workload by roughly 4×. |
| **Either, on the host** | Needs `nonfree-kmod-nvidia` + `nvidia-container-toolkit` in the schematic → new factory hash, reboot of the only control-plane node, **extension↔Talos version coupling** (the exact class of landmine the ZFS refit is currently in). |
| **Either, to a VM** | Needs `intel_iommu=on` + 4 `pcirebind` args → `apply-config --mode=auto` + reboot. Deliberately deferred (§1.3). Contradicts §1.3's fork: nvidia driver and vfio cannot both own a card. |

### 6.3 Buying a GPU — not now, and here is the trigger

If Phase 0 shows prefill is unacceptable *and* prefix caching doesn't rescue it, the
minimum viable card is **≥ 16 GB VRAM and compute capability ≥ 7.5** (vLLM's floor is 7.0;
7.5 buys you a supported future). Practically: a used RTX 3090 (24 GB) or an A4000 (16 GB).

But apply §2.3 before spending: **a 24 GB card holds an 18 GB model with ~6 GB left for
KV.** For a *large-context* orchestrator that is worse than 70 GiB of DDR4. A GPU buys
throughput, not context. **If the goal is genuinely large context, the R730's RAM is
already the better hardware, and a GPU purchase is solving the wrong problem.**

Chassis constraints if it happens anyway: R730 GPU enablement kit (risers + power cables +
high-airflow fan kit), and an A4000-class 75 W card is a far easier fit than a 350 W 3090.

### 6.4 "Don't do this yet" — the option worth naming

The brief asks for it, so here it is, honestly evaluated:

**Do nothing. Keep LM Studio on the Mac.** It works. The personas work. The mobile chat
bridge works.

**Why I do not recommend it:** it does not solve the stated problem. The Mac is out of
headroom *now* — 19.61 GB is pinned by a model at **8192 context**, which is not a large
context window by any definition. The problem does not get better on its own.

**The conditions under which "don't" is right:**
- If the R730's remaining headroom is already earmarked by other tracks in this Run (Orca
  cell, CPU workspaces, forge, vCluster factory) — **check the sum before committing 24
  GB and 24 cores.** This is a real coordination risk, not a hypothetical.
- If the storage migration to `fast-zfs` doesn't land — there is nowhere to put an 18 GB
  model file. **Hard dependency.**
- If Phase 0 shows prefill so slow that even prefix-cached use is painful.

**The middle path, which is what I actually recommend:** Phase 0 costs one Job and roughly
half an hour and produces the number that settles the argument. **Do not decide this
without it.** Everything past Phase 1 is contingent on what it says.

---

## 7. Phased next-task plan with acceptance criteria

> Phases 0–3 are the recommended path. Phase 4 is explicitly **not** in the critical path.

### Phase 0 — Measure (blocks everything; no persistent deploy)

Run a one-shot Job on contraxia: `llama-bench` plus a `llama-server` smoke test with the
GGUF the user already has.

Record, at **4k / 32k / 128k** context:
- prefill (prompt-processing) tok/s — **cold**
- prefill tok/s — **warm, with `--cache-reuse` and a shared prefix** ← *the decisive number*
- generation tok/s
- resident RSS and the `KV self size` llama-server prints at startup
- peak load average on the node while the bench runs

**Acceptance:** the numbers are written into §2.2 and §3 of this document, replacing the
arithmetic model. `UNVERIFIED` markers in those sections come off. The `n_ctx_train` and
KV figures come from the startup log, not a model card.

**Gate:** if warm prefill at 32k is not usable for the intended cadence, **stop and
re-read §6.4** before proceeding. Report the number either way; a negative result here is
a successful phase.

### Phase 1 — Serve

`platform/sveltos/clusterprofiles/NN-local-inference.yaml` + `platform/sveltos/manifests/local-inference/`
— Deployment, PVC (`fast-zfs`), Service (`type: LoadBalancer`, `lbipam.cilium.io/ips: "192.168.2.241"`).
House style per §4.5. Exact chart/image pins; **no `.x` wildcards**.

**Depends on:** ZFS migration complete (`kubectl get sc` shows `fast-zfs` as default; today
it still shows `longhorn`).

**Acceptance:**
- `curl http://192.168.2.241:8080/v1/models` → 200, from **arrakis**, not just the hub.
- `curl http://192.168.2.241:8080/metrics` → Prometheus text with token counters.
- `kubectl top node r730` under sustained load stays within the configured limit and the
  API server stays responsive (`kubectl get --request-timeout=10s` succeeds throughout).
- Pod survives a restart with the model still on the PVC (no re-download).

### Phase 2 — Route

Un-park the kagent controller in `16-mcp-baseline.yaml` (or take Track C's delivery if it
lands first — §4.7). Add the ModelConfig + dummy-key Secret, `baseUrl` → the Phase 1 VIP.

**Acceptance:**
- `kubectl get modelconfig -n kagent` → Ready, in a persona=ai vcluster.
- A `Declarative` Agent answers via `kagent invoke`, and the response is attributable to
  the local model (llama-server's `/metrics` counters move).
- **Zero egress to `api.openai.com` or `api.anthropic.com`** from the kagent namespace —
  verify with a Cilium network-policy audit or flow logs, not by reading YAML.
- `spec.apiKeySecret` is a string (§4.3(2)) — the CRD will tell you loudly if not.

### Phase 3 — Integrate with Orca

Expose the local endpoint to Orca workers **as an MCP tool**, not as an A2A agent (§5.3).
Move one real workload from the left column of §5.1 onto it — the highest-volume, most
schema-checkable one.

**Acceptance:**
- One production routing/triage decision made end-to-end by the local model, with its
  output validated by a deterministic checker.
- A measured before/after on frontier tokens for that workload.
- **The escalation path still runs through Orca.** No RemoteAgent, no hermes-a2a.

### Phase 4 — GPU (CONDITIONAL, not scheduled)

**Entry condition:** Phase 0 failed *and* prefix caching did not rescue it *and* the user
chose to buy a card meeting §6.3. **All three.**

Then, as its **own PR, on its own reboot** — never stacked with another change:
1. Settle the `UNVERIFIED` `pcirebind` question in `controlplane.yaml:178-183`.
2. Decide the §1.3 fork **explicitly**: host-side driver *or* vfio passthrough. Not both
   on one card. This renegotiates `gpu-remediation-plan.md:26-30` — do it in writing.
3. Restore kernel args **from the table in `controlplane.yaml:158-164`, not from memory** —
   both K80 dies, and never the Matrox.
4. Fix a talosconfig first (§1.4) — you cannot do any of this without talosctl.

**Acceptance:** `kubectl get node r730 -o jsonpath='{.status.allocatable}' | grep nvidia.com`
returns non-zero counts, and the ZFS pool is still healthy after the reboot.

---

## 8. Open questions and UNVERIFIED items

| # | Item | Status | How to settle |
| --- | --- | --- | --- |
| 1 | PCI enumeration live | `UNVERIFIED` — talosctl x509, no contraxia context in `~/.talos/config` (§1.4) | Fix talosconfig, then `talosctl get pcidevices`. In-repo enumeration from today + live KubeVirt config agree, so confidence is high. |
| 2 | CPU SKU, socket count, DIMM speed, memory bandwidth | `UNVERIFIED` | `talosctl -n … read /proc/cpuinfo`; iDRAC inventory. **Bandwidth is the input to every §2.2 estimate.** |
| 3 | Prefill throughput at 4k/32k/128k, cold and warm | `UNVERIFIED` — **the decisive unknown** | Phase 0. |
| 4 | K80/P2000 VRAM, TDP, compute capability | published specs, **not measured here** | `nvidia-smi`, only if drivers ever load. Cross-checked against `11-tenant-gpu.yaml`'s independent 470.x pin. |
| 5 | Model context windows / quantised sizes (except the two `lms ls` entries) | vendor-published | `llama-server` startup log: `n_ctx_train`, `KV self size`. |
| 6 | `pcirebind.rebind=…_nvidia+vfio-pci` with no nvidia driver loaded | `UNVERIFIED` — raised in `controlplane.yaml:178-183`, unresolved | Only discoverable at boot. Blocks Phase 4 step 1. |
| 7 | agentgateway v1.4.1 vs Gateway API v1.2.1 on contraxia | `UNVERIFIED` | Moot under §2.4's recommendation. devex vendored v1.6.1 for shamu — two-minor gap if anyone revives it. |
| 8 | Skills `serving-llms-vllm`, `llama-cpp`, `lm-studio`, `local-llm-apple-silicon` | **not installed on this machine** — searched `~/.claude/skills`, `~/.claude/plugins`, `~/.agents`; zero matches | Not consulted. §2 rests on first-principles reasoning plus in-repo verified findings. Flagging so this reads as *unavailable*, not *skipped*. |
| 9 | Does contraxia have headroom after the other tracks land? | **open — coordination risk** | Sum the Orca cell + CPU workspaces + forge + vCluster factory requests before committing 24 GB / 24 cores. |
| 10 | Stale `ai-helpers` ClusterProfile | drift — live (33d) but absent from the repo | Superseded by `16-mcp-baseline.yaml`. Not this track's to clean; flagged. |
| 11 | `.x` chartVersion wildcards in `07-observability-*.yaml` | latent — Sveltos v1.12 rejects them | Currently commented out of the kustomization. Will bite whoever re-enables observability. |
| 12 | `apps/shamu/kagent/kagent.yaml` sets no `providers.*` | **defect in the devex reference** (§4.2) | Would render an OpenAI-pointed `default-model-config`, contradicting its own header. Port the laptop file instead. |

**Reported separately by escalation (out of scope, not repeated here):** a secret-exposure
issue found incidentally in `bootstrap/talos/`. Details went to the coordinator; nothing
about it is reproduced in this document.

---

## 9. One-paragraph answer, if you only read one

contraxia has a Tesla K80 and a Quadro P2000; the K80's toolchain is dead and the P2000
has 5 GB, so neither can serve a large-context 30B — and IOMMU is off by deliberate design
anyway, so passthrough isn't available even if they could. That is fine, because the user's
real constraint is **RAM, not FLOPs**: LM Studio is pinning 19.61 GB on a 32 GiB Mac to run
one model at 8192 context, while contraxia sits at 15% of 94 GiB. Put `llama.cpp` on the
R730's CPU with the Qwen3-30B-A3B GGUF that is already on disk — an MoE with 3.3B active
params is the one architecture that is not bandwidth-dead on AVX2 Broadwell — expose it on
`192.168.2.241`, and point kagent ModelConfigs at it. Route work there **only when a
deterministic checker can validate the output**, keep Orca as the orchestrator, and close
`TODO(hermes-a2a)` as won't-do so kagent never becomes a second one. The whole thing is one
Deployment, one PVC, one Service and one ClusterProfile — **but measure cold-and-warm
prefill first (Phase 0), because large context is exactly what this CPU is worst at, and
that single number is what decides whether the plan is good or merely plausible.**
