# Runbook — Gitea forge cutover + token rollover

**Status: NOT YET RUN.** Written 2026-08-26 (Track J). Execute only when you are
ready for the cutover — step 6 revokes the token every current `gitea` remote is
using, and there is no undo short of minting another one on the old forge.

## What this is for

The forge of record is moving off the Mac. Today `git push gitea` goes to a
Gitea running in **OrbStack on this MacBook** (`http://localhost:3000`), and the
PAT that authenticates it is **embedded in plaintext inside `.git/config` remote
URLs**. The new Gitea runs on contraxia. This runbook creates the first admin on
the new forge, mints a fresh PAT, repoints everything on the Mac at it, and
revokes the old one.

**No real token value appears in this file, and none may be added to it.**
Everywhere a token is needed, the text says `<NEW_PAT>` / `<OLD_PAT>`. When you
run these commands, do not paste the result into a chat, a commit, or an issue.

## Preconditions — verify all four before starting

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | New Gitea answers | `curl -s -o /dev/null -w '%{http_code}\n' http://192.168.2.244:3000/` | `200` |
| 2 | Pod is Running | `kubectl --context admin@contraxia -n gitea get pods` | `gitea-*` 1/1, `gitea-pg-*` 1/1 |
| 3 | It has **no** users yet | `kubectl --context admin@contraxia -n gitea exec deploy/gitea -- gitea admin user list` | header row only |
| 4 | Old forge still up | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/` | `200` — you need it to revoke in step 6 |

All four were true on 2026-08-26 when this was written; check 3 is what makes
step 1 correct rather than a duplicate-user error.

> **Endpoint caveat.** `192.168.2.244:3000` is the LAN VIP the `forge`
> ClusterProfile pins (`21-forge.yaml`, `lbipam.cilium.io/ips`). Track F is
> putting `git.mershab.com` in front of it. **If that has landed, substitute
> `https://git.mershab.com` for `http://192.168.2.244:3000` in every command
> below** — including the `tea` login URL and the `GITEA_HOST` env var — and use
> the hostname, not the IP, so the cert matches. Confirm which is live before
> you start; do not do half of each.

---

## 1. Create the first admin on the new Gitea

The chart deliberately creates no admin: its default admin password is a
published constant, so `21-forge.yaml` sets `gitea.admin.username`/`password`
empty with no `existingSecret`, which makes the chart skip admin bootstrap
entirely (devex `docs/decisions.md` #8). The first account is made by hand.

```sh
kubectl --context admin@contraxia -n gitea exec deploy/gitea -- \
  gitea admin user create \
    --admin \
    --username '<ADMIN_USER>' \
    --email '<ADMIN_EMAIL>' \
    --password '<ADMIN_PASSWORD>' \
    --must-change-password=false
```

`--must-change-password=false` on purpose: with it `true`, the first web login
forces a password change, and until that happens the API refuses PATs — which is
exactly what step 2 needs. Pick a strong password; it goes in your password
manager, never in this repo.

Verify:

```sh
kubectl --context admin@contraxia -n gitea exec deploy/gitea -- gitea admin user list
```

Registration is disabled and sign-in is required on this instance, so this
account is the only way in. Losing it means `exec`ing another one.

## 2. Mint the new PAT

Web UI, `http://192.168.2.244:3000/user/settings/applications` — sign in as the
admin from step 1.

- **Name**: something that identifies the holder, e.g. `mac-mershab-2026-08`.
  Date it: the next rollover wants to know what it is replacing.
- **Scopes**: `write:repository`, `write:user`. Add `write:issue` only if you
  want the Gitea MCP server (step 5) to file issues. **Do not grant `sysadmin`**
  — an admin session already exists for admin work, and this token is going to
  sit in a config file on a laptop.
- Copy the token once. Gitea never shows it again.

Smoke-test it before you rewire anything, so a bad token fails here and not four
steps later:

```sh
curl -s -H "Authorization: token <NEW_PAT>" \
  http://192.168.2.244:3000/api/v1/user | jq -r '.login'
```

Expected: the admin username from step 1.

## 3. Repoint git remotes — **token-free URL + credential helper**

This is the step that fixes the actual defect. The current remote is

```
gitea  http://mershab:<OLD_PAT>@localhost:3000/mershab/homelab.git
```

— the secret is in `.git/config`, which means it leaks into `git remote -v`
output, into any `set -x` shell transcript, and into every screen share. The new
remote carries **no** credential; `credential.helper` supplies it.

> ⚠️ **Track I owns the token-free-remote change.** If that work has already
> landed, this step may be done for you — check `git remote -v` first and skip
> if the URL has no `@`. If it has not landed, doing it here is correct and the
> two changes are idempotent with each other.

Create the repo on the new forge first (UI → New Repository, **private**), then:

```sh
cd /Users/mershab/Code/Homelab/homelab

# Verify what you are about to replace, WITHOUT printing the token:
git remote -v | sed -E 's#//[^@]*@#//<REDACTED>@#g'

git remote set-url gitea http://192.168.2.244:3000/<ADMIN_USER>/homelab.git
git config --local credential.helper osxkeychain     # global default is already this
```

Store the credential in the keychain once, non-interactively:

```sh
printf 'protocol=http\nhost=192.168.2.244:3000\nusername=<ADMIN_USER>\npassword=<NEW_PAT>\n\n' \
  | git credential-osxkeychain store
```

(Over `https://git.mershab.com` use `protocol=https` and `host=git.mershab.com`.)

Push and confirm:

```sh
git push gitea HEAD
git remote -v          # must show NO `@` — the URL is now credential-free
```

**Other repos.** This Mac has more than one checkout pointed at the old forge.
Find them all before step 6 revokes the token:

```sh
find ~/Code ~/orca -name config -path '*/.git/*' -maxdepth 6 2>/dev/null \
  | xargs grep -l 'localhost:3000' 2>/dev/null
```

Repeat this step for each hit. Anything you miss starts failing auth at step 6.

## 4. Update `~/.config/gitea/credentials`

This file exists (mode `0600`, 152 bytes as of 2026-08-26) and holds the old
credential. **Do not `cat` it.** Overwrite it in place — it is a
`git-credential-store` format file, one URL per line:

```sh
umask 077
printf 'http://<ADMIN_USER>:<NEW_PAT>@192.168.2.244:3000\n' > ~/.config/gitea/credentials
chmod 600 ~/.config/gitea/credentials
```

Then confirm nothing still references the old host:

```sh
grep -c 'localhost:3000' ~/.config/gitea/credentials    # want: 0
```

If the count is not 0, something else was in that file — inspect it yourself
(this runbook will not) and re-add the non-Gitea lines.

## 5. Update the two other places the old token lives

Neither is a git remote, and both are easy to forget until something breaks
silently a week later.

**a) The Gitea MCP server** (`~/.claude.json` → `mcpServers.gitea.env`). It is
currently `GITEA_HOST=http://localhost:3000` plus a `GITEA_ACCESS_TOKEN`. Edit
both keys:

```jsonc
"gitea": {
  "type": "stdio",
  "command": "gitea-mcp-server",
  "args": ["-t", "stdio"],
  "env": {
    "GITEA_HOST": "http://192.168.2.244:3000",
    "GITEA_ACCESS_TOKEN": "<NEW_PAT>"
  }
}
```

Restart Claude Code afterwards — the MCP server env is read at process start.

**b) The `tea` CLI.** There is one login named `localgitea` pointing at
`http://localhost:3000` as the default
(`~/Library/Application Support/tea/config.yml`). Add the new one and make it
default, then drop the old:

```sh
tea login add --name contraxia --url http://192.168.2.244:3000 --token '<NEW_PAT>'
tea login default contraxia
tea login list                # confirm `contraxia` is DEFAULT
tea login delete localgitea   # after step 6, not before
```

## 6. Revoke the old token — **point of no return**

Only now. Every remote, the credentials file, the MCP server, and `tea` must
already be on the new forge, or this breaks them.

1. `http://localhost:3000/user/settings/applications` → find the old token →
   **Delete**.
2. Purge the stale keychain entry so git cannot silently reuse it:

   ```sh
   printf 'protocol=http\nhost=localhost:3000\n\n' | git credential-osxkeychain erase
   ```

3. Verify the old credential is dead:

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: token <OLD_PAT>" http://localhost:3000/api/v1/user
   ```

   Expected `401`. A `200` means you deleted the wrong token.

## 7. Acceptance

```sh
cd /Users/mershab/Code/Homelab/homelab
git remote -v                          # gitea URL contains no `@`
git ls-remote gitea >/dev/null && echo "fetch OK"
git push gitea HEAD --dry-run && echo "push OK"
tea repos list | head                  # tea talks to contraxia
grep -rc 'localhost:3000' ~/.claude.json   # want: 0
```

Only after all of these pass should the OrbStack Gitea be shut down. Keep its
volume until you have confirmed every repo exists on the new forge with full
history — `git push gitea --all --tags` per repo, then compare
`git rev-parse HEAD` on both sides.

## What this runbook deliberately does NOT do

- **It does not move Flux's source.** Flux pulls this repo from
  `github.com/mershab99/homelab` with a GitHub PAT, not from Gitea. Making the
  Gitea the Flux source is a separate, larger change (a `GitRepository` + a
  cluster-side Secret + a bootstrap ordering problem) and is not a token
  rollover.
- **It does not enable Gitea SSH.** `21-forge.yaml` leaves it off; devex
  decision #8 explains why (nothing routes it, and a LoadBalancer for it would
  be claimed by chisel-operator and published on the public droplet). Clone over
  HTTP with the PAT.
- **It does not touch `secrets/`.** No Gitea credential belongs in this repo —
  the forge PAT is a laptop credential, kept in the macOS keychain and in the
  two config files named above.
