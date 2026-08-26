# Security posture

> **Read this before "fixing" anything you find in `bootstrap/talos/`.**
> Last reviewed 2026-08-25. Owner: @Mershab99.

## TL;DR

| Thing | Status |
|---|---|
| `github.com/Mershab99/homelab` visibility | **PUBLIC, on purpose** |
| `bootstrap/talos/{controlplane.yaml,worker.yaml,talosconfig}` | plaintext lab PKI, **accepted risk, deliberately not rotated** |
| Everything else with a real credential | must **never** land in git in plaintext |
| Enforcement that actually runs | `.claude/hooks/guard-destructive.py` (local, PreToolUse) |
| Enforcement that is currently dead | the gitleaks job in `.github/workflows/validate.yaml` |

## 1. The repo is public on purpose

This repo is a homelab reference. It is public so it can be read, linked, and
copied. That is a deliberate choice, not an oversight, and it is not going to
change. Design every commit for a public audience.

## 2. `bootstrap/talos/*` is a known, accepted exposure — do not panic

`bootstrap/talos/controlplane.yaml`, `bootstrap/talos/worker.yaml`, and
`bootstrap/talos/talosconfig` are tracked **unencrypted** and contain Talos
cluster PKI and bootstrap tokens. They have been in history since `7ea2665`.

**This is decided. Do not:**

- rewrite git history (`git filter-repo`, BFG) — the material is already
  published; rewriting only breaks every clone and worktree;
- flip the repo to private;
- rotate the Talos PKI;
- delete or `git rm` those files — `talosctl` and the bootstrap runbook read
  them as plaintext;
- SOPS-encrypt them in place — nothing on the consuming side does decryption
  today, so this breaks cold-start (see §4);
- open an issue about it. It is this file.

**Why it is acceptable:** they are throwaway credentials for a single
LAN-attached bare-metal lab cluster. The Talos API is not reachable from the
internet, the cluster holds no third-party data, and rebuilding it from scratch
is a documented, routine operation (`docs/bootstrap.md`). The cost of rotation
exceeds the risk.

**What that acceptance does NOT cover:** a *second* node's machineconfig, a
*new* `talosconfig`, or any Talos file created after 2026-08-25. Those are not
grandfathered — encrypt them (§4) before they are committed. The commit guard
(§5) exempts exactly the three filenames above, by exact path, and scans
everything else under `bootstrap/talos/`.

## 3. How the leak happened — the actual bug

`.sops.yaml` carried a single rule:

```yaml
creation_rules:
  - path_regex: bootstrap/talos/.*secrets.*
```

No file under `bootstrap/talos/` has ever had `secrets` in its name. The rule
matched **zero files** and SOPS silently never encrypted anything. Nothing
warned, because a `creation_rules` entry that matches nothing is not an error —
it is just a rule that never fires.

The lesson generalises: **a secrets control that matches by filename guess is
not a control.** The rules are now directory-scoped (`^bootstrap/talos/`,
`^secrets/`) and deliberately over-match; see the comments in `.sops.yaml`.

## 4. What IS protected, and how

### Cluster secrets — plaintext + gitignored, applied by hand

The settled posture (2026-07-13) is that Kubernetes Secrets for the cluster are
**not** SOPS-encrypted, not sealed-secrets, and not External Secrets Operator.
They are:

- filled in as `secrets/**/*.secret.yaml`, which `.gitignore` excludes;
- applied out-of-band with `./secrets/apply.sh`;
- represented in git only by `*.example.yaml` templates carrying
  `REPLACE_WITH_` placeholders.

CI enforces the "no filled secrets committed" half of this
(`.github/workflows/validate.yaml`, job `sops + secret leaks`), and the commit
guard enforces the other half locally.

### SOPS + age — Talos machineconfig only

`.sops.yaml` covers `bootstrap/talos/**` and, as a safety net, `secrets/**`.

⚠️ **The age recipient in `.sops.yaml` is still a placeholder string.** `sops`
will refuse to encrypt until a real key is generated and pasted in:

```sh
age-keygen -o ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
grep '^# public key:' ~/.config/sops/age/keys.txt   # paste the age1... value into .sops.yaml
```

There is **no `sops-age` Secret in-cluster** and none is needed: Flux here runs
source-controller + helm-controller only, with no Kustomizations and therefore
no kustomize-controller doing SOPS decryption (`bootstrap/flux/README.md`).
Sveltos delivers manifests; it does not decrypt SOPS either.

That is why the existing plaintext Talos files cannot simply be encrypted.
Migrating them later would require, in order:

1. a real age keypair in `.sops.yaml` (above);
2. `sops -e -i bootstrap/talos/controlplane.yaml` (and `worker.yaml`,
   `talosconfig`);
3. teaching every consumer to decrypt first — `.taskfiles/talos.yml` and
   `docs/bootstrap.md` both `talosctl` against these paths directly, and
   `bootstrap/helm/*.sh` reads `talosconfig`;
4. distributing the age private key to any machine that bootstraps the cluster.

Steps 3–4 are the real cost. Until someone commits to them, encrypting in place
just breaks cold-start. **This is a proposal, not a scheduled action.**

### Credentials that never enter the repo at all

- Cloudflare API token → `cloudflare-api-token` Secret, ns `external-dns`.
- DigitalOcean token → `digitalocean-auth` Secret, in the chisel Service's ns.
- Dex static client secrets → `dex-config` Secret, ns `dex`.
- Gitea PAT → macOS keychain via `credential.helper = osxkeychain` (§6).
- Claude Code's own credentials → macOS keychain item, not a file.

## 5. The rule for anything new

**A real credential never lands in this repo in plaintext.** Pick one:

1. create the Secret out-of-band (`kubectl create secret ...`) and commit only a
   `*.example.yaml` template with `REPLACE_WITH_` placeholders; **or**
2. `task sops:encrypt FILE=<path>` and commit the ciphertext.

This is enforced by **`.claude/hooks/guard-destructive.py`**, a committed
PreToolUse hook wired in `.claude/settings.json`. It blocks `git add` and
`git commit` when a file heading into the commit contains:

- a PEM private key block;
- a credential inlined in a URL (`scheme://user:password@host`);
- a `key`/`token`/`secret`/`password`/`auth` field set to a 40+ character
  credential-shaped value that is not a placeholder;
- a filename that is credential material by convention (`*.secret.yaml`,
  `*.key.yaml`, `*.env`, `age.key`, `id_rsa`, `*.kubeconfig`).

It does **not** block SOPS-encrypted files (`sops:` + `ENC[` markers present),
the three accepted-risk Talos files, or `*.example.yaml` placeholder templates.

Run its tests before touching it:

```sh
python3 .claude/hooks/guard-destructive.py --self-test
```

If the guard fires on something that is genuinely not a secret, **fix the guard
and add the case to `SELF_TEST_PASS`** — do not disable it, and do not work
around it. A guard people route around is worse than no guard.

## 6. Forge credentials are not repo credentials

`.git/config` is not tracked, so a token there is not a *public* leak — but it
is still a live credential in cleartext, and it leaks into every `git remote -v`
and any log that captures one. Keep the token out of the URL:

```sh
# token-free remote; the already-configured osxkeychain helper supplies the PAT
git remote set-url gitea http://localhost:3000/mershab/homelab.git
git config --global credential.helper osxkeychain      # already set on this machine
```

Never paste a PAT into a shell command — let git prompt once, and the helper
stores it. Rotate a PAT that has been in a URL: Gitea → Settings → Applications
→ delete the token → Generate New Token.

## 7. Known gaps

- **The gitleaks CI job has never run.** `.github/workflows/validate.yaml` has
  produced zero jobs on the last five pushes to `main` (GitHub reports a
  workflow startup failure, 0s duration). The `sops + secret leaks` job is
  therefore not protecting anything. Until it is fixed, the local hook in §5 is
  the only enforcement — and it only covers agents running inside this repo's
  Claude Code sessions, not a human typing `git commit` in a plain terminal.
- **`secrets/infrastructure/minio/loki-minio.example.yaml:14`** sets
  `AWS_SECRET_ACCESS_KEY` to a 64-character lowercase-hex value with no
  `REPLACE_WITH_` marker, unlike every other template in `secrets/`. It is
  tracked, and therefore public. Treat it as leaked until proven otherwise:
  rotate the MinIO/Loki credential and replace the value with a placeholder.
- **`.sops.yaml`'s age recipient is a placeholder** (§4), so `sops` cannot
  encrypt anything today.
