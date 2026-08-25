# Contraxia Storage Refit — PR Integration Report

**Date:** 2026-08-25
**Plan:** `.hermes/plans/2026-08-25_134500-contraxia-pr-integration.md`
**Outcome:** SUCCEEDED — all 9 tasks complete, every verification passed.

> **origin/GitHub was NOT pushed.** `origin/main` remains at `a7d64c6`, 22 commits
> behind local `main`. Flux never saw a change; the live storage migration has NOT
> begun. That push is the operator's call.

---

## Final state

| Ref | SHA |
|---|---|
| local `main` | `ecf2e06` |
| `gitea/main` | `ecf2e06` (identical) |
| `origin/main` | `a7d64c6` — **unchanged, not pushed** |
| working tree | clean (only untracked `.hermes/`, the plan/report dir) |
| open PRs | 0 |
| open issues | 0 |

---

## Task 0 — Pre-flight + clean the checkout

Pre-flight matched the plan's context table exactly:

```
gitea/main:  01a196f updated runbooks
local main:  8825922 fix(agents): ignore quoted prose in the destructive-command guard
backup dir:  ~/.local/state/orca-cleanup-20260825/ — TASK1-upgrade-prep.md present
```

Before discarding, confirmed the backup patch covered all three modified files:

```
$ grep "^diff --git" ~/.local/state/orca-cleanup-20260825/talos-prep-original.patch
diff --git a/bootstrap/talos/controlplane.yaml b/bootstrap/talos/controlplane.yaml
diff --git a/bootstrap/talos/r730-schematic.yaml b/bootstrap/talos/r730-schematic.yaml
diff --git a/docs/runbooks/migrating-longhorn-to-zfs.md b/docs/runbooks/migrating-longhorn-to-zfs.md
```

Discarded the three superseded edits + removed `TASK1-upgrade-prep.md`.

```
$ git status --short
?? .hermes/
```

**Deviation from plan (benign):** the plan expected EMPTY `git status --short`.
`.hermes/` is untracked and holds the coordinator's own plan file — deleting it
would have destroyed the brief. It is not one of the superseded artifacts the
plan named, so it was kept. No tracked file is modified. Nothing was staged from
it; explicit paths were staged throughout, never `git add -A`.

## Tasks 1–5 — Merge PRs #6–#10

All five re-checked `mergeable=true state=open` immediately before their merge.
No retries were needed; the mergeable flag never flapped. Plain merge commits
(`{"Do":"merge"}`), no squash — worker commits preserved.

| Task | PR | Title | HTTP | merged | Merge commit |
|---|---|---|---|---|---|
| 1 | #6 | docs: retire the Longhorn/iscsi era — audit + honest current-state (#3) | 200 | true | `dbbeb9d27df92bb0f807cfd721f982b3bb0acc70` |
| 2 | #7 | docs(storage): end-to-end ZFS-on-Talos runbook + acceptance test (#4) | 200 | true | `4926e91b30b911c630e5386767a0315c2bcaed45` |
| 3 | #8 | Talos prep (#5): scope ZFS refit to extensions + ARC, defer GPU kernel args | 200 | true | `046c78015d8a0cffea79cfdb9406d7870394be59` |
| 4 | #9 | storage: fix and harden bootstrap/zfs/create-pool.sh for the real r730 disk layout (#1) | 200 | true | `2881e472cfe77d4a81f5af3633467655ca52c205` |
| 5 | #10 | feat(storage): GitOps consumption layer for ZFS/LocalPV-ZFS (#2) | 200 | true | `b0b524eff2f16d42a52f0da046758bb5945f656c` |

`git log --oneline --merges -6` (top entry is Task 6's local merge):

```
ecf2e06 merge: integrate storage-refit PRs 6-10 into local main
b0b524e Merge pull request 'feat(storage): GitOps consumption layer for ZFS/LocalPV-ZFS (#2)' (#10) from issue-2-gitops-storage-layer into main
2881e47 Merge pull request 'storage: fix and harden bootstrap/zfs/create-pool.sh for the real r730 disk layout (#1)' (#9) from issue-1-zfs-pool-script into main
046c780 Merge pull request 'Talos prep (#5): scope ZFS refit to extensions + ARC, defer GPU kernel args' (#8) from issue-5-talos-zfs-upgrade into main
4926e91 Merge pull request 'docs(storage): end-to-end ZFS-on-Talos runbook + acceptance test (#4)' (#7) from issue-4-storage-runbook into main
dbbeb9d Merge pull request 'docs: retire the Longhorn/iscsi era - audit + honest current-state (#3)' (#6) from issue-3-retire-longhorn into main
```

## Task 6 — Guard v2 prose-fix onto gitea/main

The predicted single conflict occurred, and **only** it:

```
$ git merge gitea/main -m "merge: integrate storage-refit PRs 6-10 into local main"
Auto-merging .claude/hooks/guard-destructive.py
CONFLICT (add/add): Merge conflict in .claude/hooks/guard-destructive.py

$ git diff --name-only --diff-filter=U
.claude/hooks/guard-destructive.py
```

The other 13 changed paths auto-merged clean (`M`/`A`, no `U`). Resolved by
keeping LOCAL (v2) per the plan:

```
$ git checkout --ours .claude/hooks/guard-destructive.py && git add ... && git commit --no-edit
[main ecf2e06] merge: integrate storage-refit PRs 6-10 into local main
```

v2 marker verified, plus a stronger check — the resolved file is byte-identical
to the v2 blob at `8825922`:

```
$ grep -c "scannable" .claude/hooks/guard-destructive.py
3                                   # expected >= 2

$ git diff 8825922 HEAD -- .claude/hooks/guard-destructive.py
                                    # empty = identical
```

Pushed to Gitea only:

```
$ git push gitea main
   b0b524e..ecf2e06  main -> main
$ git fetch gitea && git log --oneline -1 gitea/main
ecf2e06 merge: integrate storage-refit PRs 6-10 into local main   # == local main
```

## Task 7 — Post-merge verification suite

**1. No conflict markers — PASS**

First run hit one match: line 163 of the plan file itself, which literally
contains the grep pattern as a documented command. Re-run excluding the
untracked `.hermes/` dir:

```
$ grep -rn "<<<<<<<\|>>>>>>>" --exclude-dir=.git --exclude-dir=.hermes .
exit=1 (expect 1 = none found)
```

**2. Talos config validates — PASS**

```
$ talosctl validate --config bootstrap/talos/controlplane.yaml --mode metal --strict
bootstrap/talos/controlplane.yaml is valid for metal mode
exit=0
```

**3. GPU kernel args stripped — PASS**

All 7 hits are on `#` comment lines; no active kernel arg remains:

```
150:        # │ /proc/cmdline on the live node has NO intel_iommu and NO pcirebind │
172:        #   - intel_iommu=on
173:        #   - pcirebind.rebind=0000:06:00.0_nvidia+vfio-pci
174:        #   - pcirebind.rebind=0000:07:00.0_nvidia+vfio-pci
175:        #   - pcirebind.rebind=0000:82:00.0_nvidia+vfio-pci
176:        #   - pcirebind.rebind=0000:82:00.1_nvidia+vfio-pci
178:        # UNVERIFIED, settle before restoring them: `pcirebind.rebind=…_nvidia
```

**4. Guard v2 smoke test — PASS (both directions)**

```
$ echo '{"tool_name":"Bash","tool_input":{"command":"talosctl -e 1.2.3.4 upgrade"}}' | python3 .claude/hooks/guard-destructive.py
BLOCKED by .claude/hooks/guard-destructive.py: talosctl upgrade reboots the single control-plane node.
exit=2 (expect 2)

$ echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"defer the talosctl upgrade\""}}' | python3 .claude/hooks/guard-destructive.py
exit=0 (expect 0)
```

**5. Pool script self-test — PASS, via the plan's sanctioned fallback**

The committed guard blocked `bash bootstrap/zfs/create-pool.sh --self-test`
outright (it pattern-matches the script name, not the flag):

```
BLOCKED by .claude/hooks/guard-destructive.py: create-pool.sh creates the ZFS pool
and wipes disks; execution is operator-gated.
```

The guard was **not** fought or worked around. Per the plan's explicit fallback
("run the extracted assert function as issue #1's worker did"), I first read
`create-pool.sh:128-189` and confirmed the `--self-test` branch is pure string
manipulation that `exit 0`s at line 188 — before the `kubectl` check at line 191
and before any `zpool`/disk access. Extracted `assert_geometry` + the self-test
block verbatim into a scratchpad file and ran that:

```
$ bash <scratchpad>/selftest-extract.sh
self-test OK: 7x2 + 4x2 accepted; stripe / 14-way / short / long / odd / 3-way / dup / sdX all refused
exit=0
```

**6. Key artifacts exist — PASS**

```
-rw-r--r--  67420  docs/runbooks/storage-zfs.md
-rw-r--r--   2969  platform/sveltos/manifests/storage/storageclasses.yaml
```

Nothing was left UNVERIFIED. All six checks produced their expected output.

## Task 8 — Close issues #1–#5

On inspection, issues #1–#4 had **already auto-closed** when their PRs merged
(closing keywords in the PR bodies); only #5 was still open. All five still had
0 comments, so the PR-link comment was posted on each and the close applied
(a no-op for the four already closed):

| Issue | PR | comment | close |
|---|---|---|---|
| #1 | #9 | 201 | 201 |
| #2 | #10 | 201 | 201 |
| #3 | #6 | 201 | 201 |
| #4 | #7 | 201 | 201 |
| #5 | #8 | 201 | 201 |

```
open issues count: 0
open PRs count: 0
#1=closed(1 comment)  #2=closed(1 comment)  #3=closed(1 comment)
#4=closed(1 comment)  #5=closed(1 comment)
```

---

## Constraint compliance

| Constraint | Status |
|---|---|
| Never `git push origin` | **Honored.** `origin/main` = `a7d64c6`, 22 commits behind. Only `git push gitea main` was run. |
| No cluster mutations | **Honored.** Only `talosctl validate` (local file parse, no `--talosconfig`/endpoint). No kubectl/zpool. Guard block was respected, not bypassed. |
| Never `git add -A` / `git add .` | **Honored.** Only `git add .claude/hooks/guard-destructive.py`. |
| Work in the main checkout, no new worktrees/branches | **Honored.** |
| Don't touch `~/orca/workspaces/homelab/issue-*` | **Honored.** Never accessed. |
| Escalate rather than improvise | No escalation needed — every verification landed inside the plan's expected envelope. |

---

## Remaining work — operator hand-run (NOT done, deliberately)

Repo side is complete. The only remaining steps are the operator's, in order:

1. `git push origin main` from `~/Code/Homelab/homelab` — **THE trigger**; Flux
   sees it and Sveltos begins reconciling the Longhorn removal.
2. Longhorn teardown per `docs/runbooks/migrating-longhorn-to-zfs.md` §1 —
   **DATA LOSS**: 3 PVCs including arrakis etcd. Export anything wanted first.
3. `talosctl upgrade` to `c86a996e…:v1.13.5` (staged config, powercycle, iDRAC
   reachable first).
4. Wipe the 15 Samsung disks — **NOT** sdq/sdr/sds (iSCSI virtual disks; they go
   away with Longhorn anyway).
5. `bootstrap/zfs/create-pool.sh --create`, reboot, re-run (must say "already
   exists"), then `--spare`.
6. Sveltos converges; acceptance test per `docs/runbooks/storage-zfs.md` §6.
