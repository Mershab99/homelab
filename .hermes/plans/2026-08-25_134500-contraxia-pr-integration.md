# Contraxia Storage Refit — PR Integration Plan

> **For the worker:** execute task-by-task, in order. Every task ends with a
> verification command whose output proves the claim. Do not mark a task done
> on intent. If any verification fails in a way this plan does not cover,
> STOP and escalate with `orca orchestration ask` — do not improvise.

**Goal:** Land the five reviewed storage-refit PRs (#6–#10) onto Gitea `main`,
land the guard prose-fix on top, close issues #1–#5, and leave the repo in a
state where the ONLY remaining step is the operator's hand-run on the metal.

**Architecture:** Merge via the Gitea API in a fixed order (all five are
independent-lane PRs already verified mergeable). The PR branches carry guard
v1 (`.claude/` cherry-picks with identical content — add/add merges resolve
clean); the v2 prose-fix lives only on the local `main` checkout and lands
LAST to avoid five needless conflicts. Cluster is READ-ONLY throughout; the
GitHub `origin` push is deliberately withheld because Flux watches GitHub and
pushing would begin the live migration.

**Tech Stack:** Gitea REST API (curl + token), git, talosctl (validate only),
bash.

---

## Hard constraints (violating any of these is task failure)

- **NEVER `git push origin`** — origin is GitHub; Flux (`GitRepository/homelab`
  in `flux-system`) watches it. Pushing starts the live storage migration.
  That call is the OPERATOR's, after their own review. Push ONLY to `gitea`.
- **No cluster mutations.** No `kubectl apply/delete/patch`, no destructive
  `talosctl`. Read-only inspection is fine. The committed PreToolUse guard
  enforces this; escalate rather than work around it.
- **Never `git add -A` / `git add .`** — stage explicit paths.
- Work happens in `/Users/mershab/Code/Homelab/homelab` (the main checkout —
  you are dispatched into it). Do not create new worktrees or branches.
- Do not touch `~/orca/workspaces/homelab/issue-*` worktrees; they are done.

## Current context (verified 2026-08-25 by the coordinator; trust it)

| Fact | Value |
|---|---|
| `gitea/main` | `01a196f` |
| local `main` (this checkout) | `8825922` = `01a196f` + `c8e55a1` (guard v1) + `8825922` (guard v2 prose fix) |
| Dirty files in this checkout | `bootstrap/talos/{controlplane,r730-schematic}.yaml`, `docs/runbooks/migrating-longhorn-to-zfs.md`, untracked `TASK1-upgrade-prep.md` — ALL superseded by PR #8 (its work started from these exact edits). Backed up to `~/.local/state/orca-cleanup-20260825/`. Safe to discard. |
| PRs #6,#7,#8,#9,#10 | all `state=open`, `mergeable=true` against `01a196f` |
| PR branch guard files | every branch carries a cherry-pick of `c8e55a1` — IDENTICAL `.claude/settings.json` + guard v1 content, so cross-PR add/add merges resolve clean |
| Gitea token | `grep GITEA_TOKEN ~/.config/gitea/credentials | cut -d= -f2` |
| API base | `http://localhost:3000/api/v1/repos/mershab/homelab` |

Merge order `#6 → #7 → #8 → #9 → #10` (issue order; any order works, keep this
one so the log reads sensibly).

---

### Task 0: Pre-flight + clean the checkout

**Objective:** Prove the state matches this plan, then discard the superseded
dirty files so merges apply to a clean tree.

**Step 1: Verify state matches the table above**

```bash
cd /Users/mershab/Code/Homelab/homelab
git fetch gitea
git log --oneline -1 gitea/main        # expect: 01a196f ...
git log --oneline -1 main              # expect: 8825922 ...
ls ~/.local/state/orca-cleanup-20260825/TASK1-upgrade-prep.md   # backup exists
```

If `gitea/main` is NOT `01a196f` or the backup is missing: STOP, escalate.

**Step 2: Discard superseded local edits (backup verified above)**

```bash
git checkout -- bootstrap/talos/controlplane.yaml bootstrap/talos/r730-schematic.yaml docs/runbooks/migrating-longhorn-to-zfs.md
rm TASK1-upgrade-prep.md
git status --short            # expect: EMPTY output
```

### Tasks 1–5: Merge PRs #6, #7, #8, #9, #10 (one task per PR, identical shape)

**Objective:** Merge one PR via the API and prove it merged.

For N in 6, 7, 8, 9, 10 — complete all steps for one N before the next:

**Step 1: Re-check mergeability (Gitea recomputes after each prior merge)**

```bash
TOKEN=$(grep GITEA_TOKEN ~/.config/gitea/credentials | cut -d= -f2)
curl -s -H "Authorization: token $TOKEN" \
  http://localhost:3000/api/v1/repos/mershab/homelab/pulls/N \
  | jq -r '"mergeable=\(.mergeable) state=\(.state)"'
# expect: mergeable=true state=open
```

If `mergeable=false`: wait 10s and retry once (index lag). Still false → STOP,
escalate with the PR number. Do NOT resolve conflicts ad hoc.

**Step 2: Merge (plain merge commit, no squash — preserves worker commits)**

```bash
curl -s -w '%{http_code}\n' -X POST \
  -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
  -d '{"Do":"merge"}' \
  http://localhost:3000/api/v1/repos/mershab/homelab/pulls/N/merge
# expect: 200
```

**Step 3: Verify merged**

```bash
curl -s -H "Authorization: token $TOKEN" \
  http://localhost:3000/api/v1/repos/mershab/homelab/pulls/N \
  | jq -r '"merged=\(.merged)"'
# expect: merged=true
```

### Task 6: Land the guard v2 prose-fix on Gitea main

**Objective:** Get `8825922` (quoted-prose fix) onto `gitea/main` without
losing any merged content.

**Step 1: Merge the moved gitea/main into local main**

```bash
cd /Users/mershab/Code/Homelab/homelab
git fetch gitea
git merge gitea/main -m "merge: integrate storage-refit PRs 6-10 into local main"
```

Expected: ONE conflict, in `.claude/hooks/guard-destructive.py` only
(local v2 vs branches' v1). Resolve by keeping LOCAL (v2):

```bash
git checkout --ours .claude/hooks/guard-destructive.py
git add .claude/hooks/guard-destructive.py
git commit --no-edit
```

If ANY OTHER file conflicts: `git merge --abort`, STOP, escalate listing the
conflicted paths.

**Step 2: Verify v2 survived (the prose-fix marker string)**

```bash
grep -c "scannable" .claude/hooks/guard-destructive.py    # expect: >= 2
```

**Step 3: Push to Gitea ONLY**

```bash
git push gitea main       # ALLOWED. Pushing origin is FORBIDDEN.
git log --oneline -1 gitea/main   # after: git fetch gitea — matches local main
```

### Task 7: Post-merge verification suite

**Objective:** Prove the integrated main is coherent.

```bash
cd /Users/mershab/Code/Homelab/homelab
# 1. No conflict markers anywhere
grep -rn "<<<<<<<\|>>>>>>>" --exclude-dir=.git . ; echo "exit=$? (expect 1 = none found)"
# 2. Talos config still validates (local-only command — no --talosconfig flag)
talosctl validate --config bootstrap/talos/controlplane.yaml --mode metal --strict
# expect: "... is valid for metal mode"
# 3. GPU args really stripped
grep -c "intel_iommu\|pcirebind" bootstrap/talos/controlplane.yaml | head -1
# expect: matches only inside comment block (verify with grep -n that hits are '#' lines)
# 4. Guard v2 smoke test
echo '{"tool_name":"Bash","tool_input":{"command":"talosctl -e 1.2.3.4 upgrade"}}' \
  | python3 .claude/hooks/guard-destructive.py; echo "exit=$? (expect 2)"
echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"defer the talosctl upgrade\""}}' \
  | python3 .claude/hooks/guard-destructive.py; echo "exit=$? (expect 0)"
# 5. Pool script self-test
bash bootstrap/zfs/create-pool.sh --self-test    # expect: "self-test OK: ..."
# 6. Key artifacts exist
ls docs/runbooks/storage-zfs.md platform/sveltos/manifests/storage/storageclasses.yaml
```

Note: the guard blocks `create-pool.sh` execution patterns; `--self-test` is
explicitly cluster-free but if the guard still blocks it, run the extracted
assert function as issue #1's worker did, or mark UNVERIFIED — do not fight
the guard.

### Task 8: Close issues #1–#5

**Objective:** Close each Gitea issue with a comment linking its PR.

For (issue, PR) in (1,#9) (2,#10) (3,#6) (4,#7) (5,#8):

```bash
# comment
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
  -d '{"body":"Merged via PR #<PR>. Repo-side work complete; execution is operator-gated per docs/runbooks/storage-zfs.md."}' \
  http://localhost:3000/api/v1/repos/mershab/homelab/issues/<issue>/comments   # expect 201
# close
curl -s -o /dev/null -w '%{http_code}\n' -X PATCH \
  -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
  -d '{"state":"closed"}' \
  http://localhost:3000/api/v1/repos/mershab/homelab/issues/<issue>   # expect 201
```

Verify: `curl -s -H "Authorization: token $TOKEN" ".../issues?state=open&limit=10" | jq length` → expect `0`.

### Task 9: Final report (worker_done)

Report per your injected completion contract, `--outcome succeeded`, listing:
merged PR numbers with merge-commit SHAs (`git log --oneline --merges -6`),
the guard-conflict resolution, verification suite results (including anything
UNVERIFIED), and the explicit statement that **origin/GitHub was NOT pushed**.

---

## Out of scope — operator hand-run (do NOT do any of this)

Recorded for the user, in order, after this plan completes:

1. `git push origin main` from `~/Code/Homelab/homelab` — THE trigger; Flux
   sees it and Sveltos begins reconciling the Longhorn removal.
2. Longhorn teardown per `docs/runbooks/migrating-longhorn-to-zfs.md` §1
   (DATA LOSS: 3 PVCs incl. arrakis etcd; export anything wanted first).
3. `talosctl upgrade` to `c86a996e…:v1.13.5` (staged config, powercycle,
   iDRAC reachable first).
4. Wipe the 15 Samsung disks — NOT sdq/sdr/sds (iSCSI virtual disks; gone
   with Longhorn anyway).
5. `bootstrap/zfs/create-pool.sh --create`, reboot, re-run (must say
   "already exists"), then `--spare`.
6. Sveltos converges; acceptance test per `docs/runbooks/storage-zfs.md` §6.

## Risks / notes

- PRs #8 and #9 both carry guard-v1 commits; the add/add content is identical
  so sequential merges stay clean. The ONLY expected conflict in the whole
  plan is Task 6's hook file (v1 vs v2), resolved `--ours`.
- If Gitea's mergeable flag flaps after sequential merges, one 10s retry is
  sanctioned; anything more is escalation territory.
- The coordinator's dirty checkout state is backed up at
  `~/.local/state/orca-cleanup-20260825/` (patch + scratch recon doc).
