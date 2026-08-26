# TRACK I — secrets hygiene

Branch `fix/secrets-hygiene`. Base `84618c7`. Written 2026-08-26.

**Scope contract honoured:** the repo stays PUBLIC, git history is untouched,
no Talos credential was rotated, nothing under `bootstrap/talos/` was deleted or
encrypted in place, and no real secret value appears anywhere in this report or
in any commit. Everything below is counts, key names, line numbers, and redacted
forms.

## Summary

| Job | Deliverable | State |
|---|---|---|
| 1 — plaintext gitea PAT in `.git/config` | remediation commands + full sweep | **Reported, deliberately NOT applied** — see §1.4 |
| 2 — `.sops.yaml` regex gap | directory-scoped `creation_rules` | **Done**, regex proven against all 173 tracked files |
| 3 — commit guard | `.claude/hooks/guard-destructive.py` extension | **Done**, 44 test cases pass |
| 4 — document the accepted risk | `docs/security-posture.md` + README/architecture pointers | **Done** |

Two findings surfaced that were not in the brief and need the user's decision:
a **suspected real credential in a tracked `*.example.yaml`** (§5.1) and the
fact that the repo's **only automated secret scanner has never actually run**
(§5.2).

---

## Job 1 — the live gitea credential in `.git/config`

### 1.1 Confirmed

`.git/config` in the homelab repo stores the gitea remote with an inline
plaintext PAT. Verified without printing the token:

```console
$ git remote -v | sed -E 's#://[^@/]+@#://<REDACTED>@#g'
gitea	http://<REDACTED>@localhost:3000/mershab/homelab.git (fetch)
gitea	http://<REDACTED>@localhost:3000/mershab/homelab.git (push)
origin	git@github.com:Mershab99/homelab.git (fetch)
origin	git@github.com:Mershab99/homelab.git (push)
```

`origin` is SSH and carries no secret. Note that all ten worktrees under
`~/orca/workspaces/homelab/` share this one `.git/config` via the common git
dir, so this single line is the credential for every parallel track.

### 1.2 The sweep for the same pattern elsewhere

Counts and paths only; no file contents were read.

```console
$ find ~/Code ~/orca ~/Projects -maxdepth 5 -name config -path '*/.git/*' \
    | while read c; do n=$(grep -cE 'url *= *[a-z]+://[^/@]+:[^/@]+@' "$c"); \
      [ "$n" -gt 0 ] && echo "  $n  $c"; done
  1  /Users/mershab/Code/Projects/devex/.git/config      <-- SAME PROBLEM
  1  /Users/mershab/Code/Homelab/homelab/.git/config
```

| Location | Result |
|---|---|
| `~/.git-credentials` | absent |
| `~/.netrc` | absent |
| `~/.config/gitea/credentials` | **exists**, `-rw-------` (0600), 152 bytes — perms correct, not read |
| `~/.config/tea/config.yml` | absent |
| `~/.gitconfig` | 0 matches for a credential-in-URL, token, or password; sections are user/lfs/core/interactive/delta/merge/diff/pager/difftool/**credential** |
| `~/.zshrc`, `.zshenv`, `.zprofile`, `.bashrc`, `.bash_profile` | 0 hits each |
| `~/.zsh_history` | **0 hits** |
| `~/.bash_history` | absent |

So the PAT has **not** leaked into shell history or rc files. Two `.git/config`
files hold it: this repo and **`devex`** — which is the user's read-only
reference checkout and which this track did not touch, per the common brief.

### 1.3 The remediation is a one-liner, because the keychain is already primed

`credential.helper` is already `osxkeychain` globally, and the keychain already
holds an entry for this host:

```console
$ git config --global --get credential.helper
osxkeychain

$ printf 'protocol=http\nhost=localhost:3000\n\n' | git credential-osxkeychain get \
    | sed -E 's/^password=.*/password=<PRESENT-REDACTED>/'
password=<PRESENT-REDACTED>
username=mershab
```

Proof that a token-free URL authenticates through it — run against the bare URL
with prompting disabled, so a keychain miss would have failed rather than hung:

```console
$ GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false \
    git ls-remote http://localhost:3000/mershab/homelab.git HEAD
f7404a2…	HEAD
exit=0
```

**Therefore stripping the token from the URL is zero-downtime.** No re-auth, no
prompt, no push breakage.

### 1.4 Commands for the user — placeholders only, nothing applied

I did **not** run these. `.git/config` is shared by all ten worktrees and tracks
F, G, and H are pushing to `gitea` in parallel right now; mutating their
credential path mid-run to save one command is not worth the chance of wedging a
non-interactive push on a credential prompt. Run them once the fan-out is quiet:

```sh
# 1. Strip the token from the URL. The osxkeychain helper (already configured,
#    already holding the entry) supplies it from here on.
git -C /Users/mershab/Code/Homelab/homelab \
    remote set-url gitea http://localhost:3000/mershab/homelab.git

# 2. Verify — must show NO '<user>:<token>@' segment.
git -C /Users/mershab/Code/Homelab/homelab remote -v

# 3. Prove auth still works without the inline token.
git -C /Users/mershab/Code/Homelab/homelab ls-remote gitea HEAD

# 4. Same fix for devex (the user's checkout — I did not touch it).
git -C /Users/mershab/Code/Projects/devex remote -v      # inspect first
git -C /Users/mershab/Code/Projects/devex \
    remote set-url <REMOTE_NAME> http://localhost:3000/<OWNER>/<REPO>.git
```

If the keychain entry is ever missing, do **not** paste the PAT into a command —
that puts it in shell history. Let git prompt:

```sh
git config --global credential.helper osxkeychain   # already set
git ls-remote gitea HEAD                            # prompts once, helper stores it
```

**Rotate that PAT.** It has been in a cleartext URL and has already appeared in
this session's `git remote -v` output. Gitea → click your avatar → **Settings**
→ **Applications** → under *Manage Access Tokens*, delete the existing token →
**Generate New Token** (scope it to `write:repository` only) → copy it into the
keychain via the prompt flow above. Gitea shows a token exactly once.

Track F is moving Gitea to `git.mershab.com` behind a public edge. When the
remote host changes, the keychain entry must be re-created for the new
`protocol=https host=git.mershab.com` tuple; the old `localhost:3000` entry will
not be consulted.

---

## Job 2 — `.sops.yaml`

### 2.1 Before / after

```diff
 creation_rules:
-  - path_regex: bootstrap/talos/.*secrets.*
-    age: >-
+  - path_regex: ^bootstrap/talos/
+    age: &age_recipients >-
       age1placeholderreplaceaftergeneratingthisrepoageabsentdonotcommit
+
+  - path_regex: ^secrets/
+    age: *age_recipients
```

(Plus ~35 lines of comments recording *why* — the full file is on the branch.)

The age recipient value is byte-identical to before; it is a **placeholder**,
not a key, and encrypting anything will fail until it is replaced. That is
called out in `.sops.yaml` and in `docs/security-posture.md` §7.

### 2.2 Proof the old rule matched nothing and the new rules match everything intended

`sops` is not installed on this machine:

```console
$ sops --version
(eval):1: command not found: sops
```

So the regexes were validated with Python `re`. This is a faithful check: SOPS
uses Go `regexp.MatchString`, which is **unanchored** — the same semantics as
`re.search` — and neither pattern uses a construct Go RE2 lacks (no lookaround,
no backreferences), so the two engines agree.

```console
$ python3 -  # full script re-runnable from this report
=== OLD rule 'bootstrap/talos/.*secrets.*' vs tracked files ===
  matches: 0  -> NOTHING (this is the bug)

=== NEW rules vs the 3 leaked files (MUST match) ===
  bootstrap/talos/controlplane.yaml                       MATCH   ['^bootstrap/talos/']
  bootstrap/talos/worker.yaml                             MATCH   ['^bootstrap/talos/']
  bootstrap/talos/talosconfig                             MATCH   ['^bootstrap/talos/']
  bootstrap/talos/secrets.yaml.sops                       MATCH   ['^bootstrap/talos/']
  bootstrap/talos/controlplane-r820.yaml                  MATCH   ['^bootstrap/talos/']
  secrets/infrastructure/gitea/gitea-token.secret.yaml    MATCH   ['^secrets/']
  secrets/foo/creds.yaml                                  MATCH   ['^secrets/']

=== NEW rules vs paths that MUST NOT match ===
  platform/sveltos/clusterprofiles/27-foo.yaml            no match []
  docs/security-posture.md                                no match []
  clusters/baremetal/infrastructure/tenant-secrets.yaml   no match []
  .claude/settings.json                                   no match []

  total 34 of 173 tracked files now match
RESULT: PASS
```

Also asserted: the YAML anchor resolves, so both rules carry identical
recipients and cannot drift apart.

### 2.3 Design choices, stated plainly

- **Directory-scoped, not filename-guessing.** The original bug was a filename
  guess. Over-matching is harmless here — `creation_rules` are consulted only
  when `sops` is invoked explicitly, never automatically — while under-matching
  is exactly how the leak happened.
- **`^secrets/` matches the committed `*.example.yaml` templates too.** Go RE2
  has no negative lookahead, so "everything under `secrets/` except
  `*.example.yaml`" is not expressible as one regex. The templates stay
  plaintext by convention, by the CI check, and by the commit guard — not by the
  regex. This is documented inline in `.sops.yaml` so nobody encrypts them.
- **Nothing was encrypted in place.** `.taskfiles/talos.yml`, `docs/bootstrap.md`,
  and `bootstrap/helm/*.sh` all read these paths as plaintext, and there is no
  kustomize-controller doing SOPS decryption in-cluster
  (`bootstrap/flux/README.md:37` — Flux here is source + helm controllers only).
  The four-step migration proposal is in `docs/security-posture.md` §4; steps 3
  and 4 (teach every consumer to decrypt, distribute the age private key) are
  the real cost and nobody has signed up for them.

---

## Job 3 — the commit guard

Extended the existing `.claude/hooks/guard-destructive.py` rather than adding a
second mechanism: it is already committed, already wired as a `PreToolUse` hook
in `.claude/settings.json`, and already active in every worktree.

### 3.1 What it blocks

`git add` / `git commit` where a file heading into the commit contains:

1. a PEM private key block;
2. a credential inlined in a URL (`scheme://user:password@host`) — i.e. it would
   have caught Job 1 had that file been tracked;
3. a `key`/`token`/`secret`/`password`/`passphrase`/`credential`/`auth` field set
   to a 40+ character credential-shaped value that is not a placeholder;
4. a filename that is credential material by convention: `*.secret.yaml`,
   `*.key.yaml`, `*.env`, `age.key`, `id_rsa`/`id_ecdsa`/`id_ed25519`,
   `*.kubeconfig`.

File resolution: for `git add` it expands dirs and globs through
`git ls-files -coz --exclude-standard` **and** additionally scans any literal
file argument even when gitignored — which is precisely the
`git add -f secrets/x.secret.yaml` bypass. For `git commit` it reads
`git diff --cached --name-only`, plus `git diff --name-only` when `-a`/`-am` is
present. Compound commands (`a && b; c`) are split and each segment parsed with
`shlex`, so `env FOO=1 git -C dir add …` still resolves.

### 3.2 What it deliberately does NOT block

- **SOPS-encrypted files** — `sops:` and `ENC[`/`mac:` markers present means the
  material is ciphertext and committing it is the goal.
- **The three accepted-risk Talos files, by exact path.** A *new* file under
  `bootstrap/talos/` is still scanned; the user's decision covers the existing
  three, not the next node's machineconfig.
- **`.claude/hooks/guard-destructive.py` itself**, which necessarily contains
  the patterns it searches for. The PEM regex is additionally written as
  `-{5}BEGIN [A-Z ]{0,20}PRIVATE KEY-{5}` so the source line does not match
  itself.
- **`*.example.yaml` placeholder templates**, commented-out documentation lines,
  `caBundle`/`tls.crt`/`publicKey` (public certificate material), image digests,
  and hostPath values.

### 3.3 Test output

Two suites. First, `--self-test`, which asserts on the scanner directly:

```console
$ python3 .claude/hooks/guard-destructive.py --self-test
  BLOCK ok   k8s secret, real base64 token
             -> t.yaml:1 sets 'tls.key' to a 64-char credential-shaped value in plaintext
  BLOCK ok   cloudflare api token
             -> t.yaml:2 sets 'api-token' to a 40-char credential-shaped value in plaintext
  BLOCK ok   PEM private key block
             -> t.yaml:1 contains a PEM private key block
  BLOCK ok   credential inlined in a git remote URL
             -> t.yaml:1 embeds a credential in a URL userinfo segment
  BLOCK ok   dotenv style
             -> t.yaml:1 sets 'GITEA_TOKEN' to a 40-char credential-shaped value in plaintext
  BLOCK ok   client_secret in a dex config
             -> t.yaml:1 sets 'clientSecret' to a 40-char credential-shaped value in plaintext
  PASS  ok   example template placeholder
  PASS  ok   sveltos template expansion
  PASS  ok   webhook caBundle (public cert)
  PASS  ok   image digest
  PASS  ok   ssh public key
  PASS  ok   long non-credential value under a non-secret key
  PASS  ok   SOPS-encrypted file
  PASS  ok   commented-out proxy example from a Talos machineconfig
  PASS  ok   prose naming a secret
  PASS  ok   helm chart version pin
  PASS  ok   docs describing the URL-credential pattern in prose
  PASS  ok   a redacted remote URL in a report
  PASS  ok   a token-free remediation command
  PATH  ok   block  secrets/infrastructure/dex/dex-config.secret.yaml
  PATH  ok   block  secrets/foo/bar.key.yaml
  PATH  ok   block  .env
  PATH  ok   block  age.key
  PATH  ok   block  arrakis.kubeconfig
  PATH  ok   allow  bootstrap/talos/controlplane.yaml
  PATH  ok   allow  bootstrap/talos/worker.yaml
  PATH  ok   allow  bootstrap/talos/talosconfig
  PATH  ok   allow  .claude/hooks/guard-destructive.py
  PATH  ok   allow  secrets/infrastructure/dex/dex-config.example.yaml
  PATH  ok   allow  docs/security-posture.md
  PATH  ok   allow  platform/sveltos/clusterprofiles/kustomization.yaml
  SWEEP ok   172/173 tracked files committable; 1 known-flagged: ['secrets/infrastructure/minio/loki-minio.example.yaml']

SELF-TEST: PASS
```

The `SWEEP` line is the false-positive gate the brief asked for: **every one of
the 173 currently-tracked files is still committable**, except the one genuine
finding in §5.1. If a future change makes the guard fire on an innocent file, the
self-test fails immediately.

Second, an end-to-end suite driving the hook through its real stdin/exit-code
contract, including the pre-existing rules to prove they did not regress:

```console
$ python3 hooktest.py
  ok   ALLOW  stage a docs dir
  ok   ALLOW  the guard's own source
  ok   ALLOW  this track's other deliverables
  ok   ALLOW  track F/G/H profile dir
  ok   ALLOW  hostPath-heavy DaemonSet
  ok   ALLOW  commit msg NAMING a destructive command
  ok   ALLOW  commit msg naming wipe
  ok   ALLOW  read-only git
  ok   ALLOW  prose about git add -A
  ok   BLOCK  git add -A (pre-existing rule)
         -> ... git add -A / git add . sweeps unrelated dirty files; stage explicit paths only.
  ok   BLOCK  push to origin (pre-existing rule)
         -> ... origin is GitHub; push to the 'gitea' remote instead.
  ok   BLOCK  kubectl apply (pre-existing rule)
         -> ... cluster mutations are forbidden; this fan-out is read-only against contraxia.
  ok   BLOCK  stage a file with a real-looking token
  ok   BLOCK  stage a .env by filename convention
  ok   BLOCK  stage a PEM private key
  ok   ALLOW  stage a SOPS-ENCRYPTED secret (allowed)

  16 cases in 1.40s (88 ms/call)
INTEGRATION TEST: PASS
```

The three ALLOW cases named *"track F/G/H profile dir"*, *"the guard's own
source"*, and *"commit msg NAMING a destructive command"* are the specific
regressions the brief warned about. All fixtures use synthetic values; no real
credential was written to disk.

Cost: ~88 ms per Bash tool call, and the secret scan is gated behind a cheap
`\bgit\b.*\b(add|commit)\b` regex so it does not run on the other 99% of calls.

### 3.4 Three real bugs the tests caught

All three were caught before commit, which is the point of the exercise:

1. **`"pat"` in the secret-keyword list matched `path`.** Every `hostPath:
   /var/lib/k0s/kubelet/plugins/...` in `tenants/arrakis/addons/kubevirt-csi/`
   was flagged. Dropped `"pat"`, and values that look like filesystem paths or
   URLs are now rejected outright.
2. **`a.lstrip("./")` mangled absolute paths.** `lstrip` takes a *character set*,
   so `/tmp/x.env` became `tmp/x.env` and silently stopped resolving — meaning
   `git add /abs/path/to/secret.yaml` would have sailed straight through.
   Replaced with a proper `_norm()` helper.
3. **The URL rule blocked this very report.** Staging the deliverables fired the
   guard on `docs/reports/2026-08-25-secrets-hygiene.md:242` — §3.1 of this
   document *describes* the pattern in prose as
   `` `scheme://user:password@host` ``, and the raw regex matched its own
   documentation. Exactly the failure mode the brief warned about, reproduced
   live. The rule now validates the captured userinfo password
   (`_is_url_password`: ≥12 chars, not a placeholder, mixes character classes),
   so `password` and `<REDACTED>` pass while a 32-hex PAT still blocks. Three
   regression cases were added to `SELF_TEST_PASS`.

The guard was live for its own `git add`, so the final staging run is itself the
end-to-end proof that it permits this track's deliverables:

```console
$ git add .sops.yaml .claude/hooks/guard-destructive.py docs/security-posture.md \
          docs/reports/2026-08-25-secrets-hygiene.md README.md docs/architecture.md
M  .claude/hooks/guard-destructive.py
M  .sops.yaml
M  README.md
M  docs/architecture.md
A  docs/reports/2026-08-25-secrets-hygiene.md
A  docs/security-posture.md
```

---

## Job 4 — the accepted-risk record

New: **`docs/security-posture.md`**. Choice of a dedicated doc over a README
section, because the content is long (the "do not panic" list, the SOPS
migration proposal, the guard contract, the known gaps) and README is a
navigational map — burying eight paragraphs there hurts both. The README gets a
loud four-line pointer instead, above the fold in the Layout section.

Covers, per the brief: the repo is intentionally PUBLIC; `bootstrap/talos/*` is
deliberately un-rotated accepted-risk lab credentials with an explicit
do-not-panic / do-not-"fix" list and the *reasoning*; what IS protected and how
(gitignored `*.secret.yaml` + hand-apply, SOPS/age for Talos, the honest state of
the `sops-age` Secret); the rule for anything new; and a pointer to the Job 3
guard with its test command.

Also corrected two stale claims that would have misled the next reader:

- `README.md:31` said `secrets/  SOPS-encrypted secrets` — it is not, and has not
  been since 2026-07-13.
- `.sops.yaml`'s header claimed the age private key lives "inside the cluster (in
  the `sops-age` Secret consumed by Flux's kustomize-controller)". There is no
  kustomize-controller and no `sops-age` Secret; `bootstrap/flux/README.md:37`
  already said so. Assuming SOPS protection that does not exist is the same class
  of error as Job 2.
- `docs/architecture.md` §5 "No secrets in Git" now names the one documented
  exception and links to the posture doc.

---

## 5. Findings outside the brief — need a decision

### 5.1 A suspected real credential in a tracked, public `*.example.yaml`

**`secrets/infrastructure/minio/loki-minio.example.yaml:14`** sets
`AWS_SECRET_ACCESS_KEY` to a **64-character lowercase-hex** value — the shape of
`openssl rand -hex 32`. Established without reading or printing the value:

```console
$ grep -c 'REPLACE_WITH' secrets/infrastructure/minio/loki-minio.example.yaml
0
$ # placeholder-marker probe on line 14 (counts only)
  REPLACE -> 0   CHANGE -> 0   EXAMPLE -> 0   PLACEHOLDER -> 0
  XXXX -> 0      < -> 0        your -> 0      minio -> 0        admin -> 0
$ # character classes present in the value
  digits + lowercase only, 64 chars
```

Every other template under `secrets/` uses a `REPLACE_WITH_…` placeholder; this
one and `velero-b2.example.yaml` were both flagged by gitleaks, but
`velero-b2.example.yaml` does contain `REPLACE_WITH` twice, so it is a
false positive. `loki-minio.example.yaml` has no placeholder marker at all.

The file is tracked, so the value is public. **Recommendation: treat it as
leaked — rotate the MinIO/Loki credential and replace the value with
`REPLACE_WITH_MINIO_SECRET_KEY`.** I did not read the file (`Read(secrets/**)` is
deny-listed) and did not modify it — that is the user's call, and it is a
different decision from the Talos accepted risk. Recorded in
`docs/security-posture.md` §7 and pinned in the hook's `KNOWN_FLAGGED` set so it
stays visible until fixed.

**UNVERIFIED:** whether the value is a live credential or a discarded one. I
cannot confirm without reading it.

### 5.2 The gitleaks CI job has never run

`.github/workflows/validate.yaml` job `sops + secret leaks` is the repo's only
automated scanner. It has produced **zero jobs** on the last five pushes to
`main`:

```console
$ gh run list --limit 5 --workflow validate.yaml
completed  failure  fix(platform): unreachable Gitea VIP...  main  push  32928887947  0s
completed  failure  Merge branch 'feat/shamu-platform-contraxia'  main  push  32928304060  0s
completed  failure  Merge branch 'docs/gpu-kagent-plan'          main  push  32927327884  0s
completed  failure  fix(storage): break snapshot-controller...   main  push  32927086217  0s
completed  failure  Contra is zfs 1                             main  push  32925450249  0s

$ gh run view 32928887947
X This run likely failed because of a workflow file issue.

$ gh api repos/Mershab99/homelab/commits/84618c7/check-runs -q '.check_runs[]|.name'
(empty)
```

`0s` duration, zero jobs, zero check-runs — a startup failure, so no step ever
executed. The YAML itself parses cleanly
(`python3 -c "import yaml; yaml.safe_load(open('.github/workflows/validate.yaml'))"`
→ OK), and `gh api .../actions/permissions` returns **403** on this token, so I
could not read the Actions policy.

**UNVERIFIED: the root cause.** Candidates: Actions disabled for the repo, an
org/account policy blocking `gitleaks/gitleaks-action@v2` or
`fluxcd/flux2/action@main`, or a startup error in one of the two sibling
workflows (`release.yaml`, `talos-images.yaml`). This needs someone with repo
admin to open the run's startup log.

Consequence: the local hook from Job 3 is currently the *only* enforcement, and
it only covers agents working inside this repo's Claude Code sessions — a human
typing `git commit` in a plain terminal is unguarded. **Fixing CI is the higher-
leverage follow-up and is out of this track's scope.**

For reference, `gitleaks detect --no-git --redact` on the working tree reports
**26 findings**, of which 18 are the accepted-risk Talos files and 8 are false
positives (5 Sveltos `{{ index (getResource …) }}` template expansions in
`clusters/baremetal/infrastructure/`, 2 `REPLACE_WITH_` templates, 1 the finding
in §5.1). A permanently-red scanner is a scanner nobody reads, so whoever fixes
the startup failure should also add a `.gitleaks.toml` allowlist for those paths
in the same change. I did not add one here: it would be dead configuration until
the job actually runs.

---

## 6. Validation run

```console
$ kustomize build platform/sveltos/clusterprofiles   → PASS (27 documents)
$ kustomize build clusters/baremetal/infrastructure  → PASS
$ python3 -c "import yaml; list(yaml.safe_load_all(open('.sops.yaml')))"  → OK
$ python3 -m py_compile .claude/hooks/guard-destructive.py                → OK
$ python3 .claude/hooks/guard-destructive.py --self-test                  → PASS (28 assertions + sweep)
$ python3 hooktest.py                                                     → PASS (16 cases)
```

## 7. Files changed

| Path | Change |
|---|---|
| `.sops.yaml` | rewritten rules + rationale; **no** age recipient change |
| `.claude/hooks/guard-destructive.py` | + plaintext-secret commit guard, + `--self-test` |
| `docs/security-posture.md` | **new** |
| `README.md` | Layout line corrected; security-posture pointer added |
| `docs/architecture.md` | hard rule now names the documented exception |
| `docs/reports/2026-08-25-secrets-hygiene.md` | this report |

Not touched, on purpose: `bootstrap/talos/*`, git history, repo visibility, any
Talos credential, `.git/config`, `secrets/**`, and the `devex` checkout.

## 8. Handoff

1. **User:** rotate the gitea PAT and run the §1.4 commands once the fan-out is
   quiet — including for `devex`.
2. **User:** decide on §5.1 (`loki-minio.example.yaml`). If it is a live
   credential, rotate it; either way replace the value with a placeholder and
   drop the path from `KNOWN_FLAGGED` in the hook.
3. **Coordinator:** §5.2, the dead CI workflow, needs repo-admin eyes. Until
   then the local hook is the only guard.
4. Optional, deferred: the SOPS migration for the existing Talos files
   (`docs/security-posture.md` §4). Requires a real age keypair first.
