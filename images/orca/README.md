# images/orca

Build context for the Orca cell's server image (`19-orca-cell.yaml`).

Copied verbatim 2026-08-26 from `devex` `images/orca/` (the source of the
ghcr build). It lives here now because the image is built from THIS repo:
`.gitea/workflows/orca-image.yaml` needs the Dockerfile in the repo the runner
checks out, and a second copy nobody edits beats a submodule.

Produces `192.168.2.244:3000/mershab/orca:v<ORCA_VERSION>` — Gitea's own OCI
registry. Two ways to produce it, both in
[`docs/runbooks/local-image-build.md`](../../docs/runbooks/local-image-build.md):

| | where | speed | when |
|---|---|---|---|
| `docker buildx --push` | the Mac | slow — arm64 host, `--platform linux/amd64` runs the whole `apt-get` set under QEMU | today, no CI needed |
| Gitea Actions | the R730 | native amd64 | once `34-forge-runner` has a registration token |

## Version pins are load-bearing

`ORCA_VERSION` **must** match the Mac's Orca build (`orca status --json` →
`result.runtime.appVersion`) — the client refuses to pair across an app version
gap. Bumping it means bumping `platform/sveltos/manifests/orca-cell/orca.yaml`
in the same commit.

## Drift

If `devex` `images/orca/` changes, re-copy. There is no automation keeping these
in sync, deliberately: devex is read-only reference here.
