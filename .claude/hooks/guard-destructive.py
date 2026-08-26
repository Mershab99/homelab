#!/usr/bin/env python3
"""PreToolUse guard for the contraxia worker fan-out.

Two independent jobs:

1. Block destructive infrastructure operations regardless of Claude Code
   permission mode. Per Claude Code docs, a PreToolUse hook that exits with
   code 2 blocks the tool call even under --permission-mode bypassPermissions,
   where `permissions.allow` is inert and prefix-based `deny` patterns are
   easily evaded by flag ordering (e.g. `talosctl --talosconfig X -e Y upgrade`).

2. Block `git add` / `git commit` that would put PLAINTEXT credential material
   into git. See `check_secret_commit`. This exists because
   `github.com/Mershab99/homelab` is intentionally PUBLIC
   (docs/security-posture.md) and the repo's only automated scanner — the
   gitleaks job in .github/workflows/validate.yaml — has not produced a single
   job run on the last five pushes to main (startup failure). The local hook is
   the guard that actually runs.

Contract: reads the tool call as JSON on stdin, exits 2 with a reason on
stderr to block, exits 0 to allow.

Self-test:  python3 .claude/hooks/guard-destructive.py --self-test
"""
import json
import os
import re
import shlex
import subprocess
import sys

# (compiled pattern, human-readable reason)
# Patterns run against the whole normalized command string, so flag order,
# extra whitespace, and env prefixes do not let an operation slip through.
BLOCKED = [
    # --- Talos: node-mutating / destructive ---
    (r"\btalosctl\b.*\bupgrade\b",
     "talosctl upgrade reboots the single control-plane node"),
    (r"\btalosctl\b.*\bapply-config\b",
     "talosctl apply-config drops all 15 UserVolumeConfigs (destroys data-disk partitioning)"),
    (r"\btalosctl\b.*\bpatch\s+machineconfig\b",
     "talosctl patch machineconfig mutates the live node config"),
    (r"\btalosctl\b.*\bwipe\b",
     "talosctl wipe disk is irreversible data destruction"),
    (r"\btalosctl\b.*\breset\b",
     "talosctl reset destroys STATE and EPHEMERAL (rebuilds etcd)"),
    (r"\btalosctl\b.*\b(reboot|shutdown)\b",
     "power-cycling the node is operator hand-run only"),
    (r"\btalosctl\b.*\bupgrade-k8s\b",
     "Kubernetes upgrade is out of scope for this refit"),

    # --- The pool script: review-only, execution is operator-gated ---
    # Match EXECUTION only (leading ./, or via an interpreter). Must not match
    # `git add bootstrap/zfs/create-pool.sh`, which is issue #1's own deliverable.
    (r"(^|[;&|]\s*)(\./)?\S*create-pool\.sh\b",
     "create-pool.sh creates the ZFS pool and wipes disks; execution is operator-gated"),
    (r"\b(ba)?sh\s+\S*create-pool\.sh\b",
     "create-pool.sh creates the ZFS pool and wipes disks; execution is operator-gated"),
    (r"\bzpool\s+(create|destroy|add|remove|labelclear|replace)\b",
     "zpool mutation is operator-gated"),
    (r"\bzfs\s+(destroy|create|rename|rollback)\b",
     "zfs dataset mutation is operator-gated"),

    # --- Kubernetes: this whole fan-out is read-only against the cluster ---
    (r"\bkubectl\b.*\b(apply|delete|patch|replace|edit|create|scale|drain|cordon|uncordon|annotate|label)\b",
     "cluster mutations are forbidden; this fan-out is read-only against contraxia"),
    (r"\bhelm\b.*\b(install|uninstall|upgrade|rollback|delete)\b",
     "helm mutations are forbidden; Sveltos owns chart delivery"),
    (r"\bflux\b.*\b(reconcile|suspend|resume|delete)\b",
     "flux mutations are forbidden"),

    # --- Git: protect the dirty shared repo and the GitHub remote ---
    (r"\bgit\s+add\s+(-A|--all|\.)(\s|$)",
     "git add -A / git add . sweeps unrelated dirty files; stage explicit paths only"),
    (r"\bgit\s+push\b.*\bgithub\b",
     "github is the GitHub mirror; push to 'origin' (git.mershab.com) instead"),
    (r"\bgit\s+push\b.*(--force|-f)(\s|$)",
     "force push is forbidden"),
    (r"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f)",
     "destructive git operation on a shared checkout"),

    # --- Secrets ---
    (r"\bsecrets/.*\.(secret|key)\.ya?ml\b",
     "reading decrypted secret material is forbidden"),
]

COMPILED = [(re.compile(p, re.IGNORECASE), r) for p, r in BLOCKED]


# ---------------------------------------------------------------------------
# Plaintext-secret commit guard
# ---------------------------------------------------------------------------
# Design note on false positives: a guard that cries wolf gets disabled, which
# is strictly worse than no guard. Every rule below was run against all 173
# tracked files in this repo; the ONLY hits are the three accepted-risk Talos
# files listed in ACCEPTED_RISK. Tracks F/G/H are committing in parallel to
# platform/, clusters/, and docs/ — none of those trip it.

# Deliberately un-rotated, publicly exposed lab credentials. The user decided
# to accept this exposure (docs/security-posture.md, 2026-08-25): do not panic,
# do not rotate, do not delete. Editing these files must stay committable, so
# they are exempt BY EXACT PATH — a NEW file under bootstrap/talos/ is still
# scanned, because the next node's machineconfig is not covered by that
# decision.
ACCEPTED_RISK = frozenset({
    "bootstrap/talos/controlplane.yaml",
    "bootstrap/talos/worker.yaml",
    "bootstrap/talos/talosconfig",
})

# This file necessarily contains the very patterns it searches for.
SELF = ".claude/hooks/guard-destructive.py"

# Filenames that are credential material by convention. Mirrors .gitignore and
# the "No filled secrets committed" step in .github/workflows/validate.yaml.
SECRET_PATH_RE = re.compile(
    r"(^|/)("
    r".*\.(secret|key)\.ya?ml"
    r"|[^/]*\.env(\..+)?"
    r"|.*\.age\.key|age\.key"
    r"|id_rsa|id_ecdsa|id_ed25519"
    r"|.*\.kubeconfig|kubeconfig"
    r")$",
    re.IGNORECASE,
)

# A SOPS-wrapped file carries both of these. If present, the credential
# material is ciphertext and committing it is the desired outcome.
SOPS_MARKERS = (re.compile(r"^\s*sops:", re.MULTILINE), re.compile(r"ENC\[|^\s*mac:", re.MULTILINE))

# PEM private key header. Assembled from fragments so that this line does not
# itself match — otherwise the guard blocks its own commit (a real bug the
# previous version of this hook shipped twice).
PEM_RE = re.compile(r"-{5}BEGIN [A-Z ]{0,20}PRIVATE KEY-{5}")

# scheme://user:password@host — a credential inlined in a URL. The password
# group is validated by _is_url_password() rather than matched raw, because
# documentation legitimately writes the SHAPE of this pattern in prose
# ("scheme://user:password@host") and blocking that is a false positive.
URL_CRED_RE = re.compile(r"[a-z][a-z0-9+.\-]*://[^/\s\"'@:]+:([^/\s\"'@]+)@")

# key: value  /  key = value  (YAML, .env, ini, TOML)
KV_RE = re.compile(
    r"""^\s*-?\s*["']?([A-Za-z0-9_.\-/]{2,60})["']?\s*[:=]\s*["']?([^\s"'#,]{20,})["']?\s*,?\s*$"""
)

# Substrings in a key NAME that mean "the value is a credential".
# NOTE: no "pat" — it is a substring of "path", and hostPath values are long,
# slash-separated, and everywhere in this repo's DaemonSets.
SECRET_WORDS = (
    "key", "token", "secret", "password", "passwd", "passphrase",
    "credential", "auth", "apikey",
)
# ...unless the key name also says the value is PUBLIC. Certificates, CA
# bundles, public keys, and digests are all long base64 and all safe.
PUBLIC_WORDS = (
    "public", "pub", "cabundle", "ca.crt", "tls.crt", "certificate-authority",
    "fingerprint", "checksum", "sha256", "sha512", "digest", "thumbprint",
    "keyring", "keyserver", "keyname", "keyref", "keyword",
)
# Substrings that mean the value is a placeholder, not a real credential.
PLACEHOLDER_WORDS = (
    "replace_with", "replace-with", "changeme", "change_me", "placeholder",
    "example", "redacted", "your_", "your-", "dummy", "fake", "notarealkey",
    "xxxxx", "aaaaa", "<", ">", "{{", "${", "$(",
)
VALUE_SHAPE_RE = re.compile(r"^[A-Za-z0-9+/=_.\-]{40,}$")

MAX_SCAN_BYTES = 2 * 1024 * 1024


def _is_placeholder(value: str) -> bool:
    low = value.lower()
    if any(w in low for w in PLACEHOLDER_WORDS):
        return True
    # A single repeated character ("xxxxxxxx...", "00000000...").
    return len(set(value)) <= 2


def _is_url_password(pw: str) -> bool:
    """True when the userinfo password in a URL looks like a real credential.

    Rejects the literal words documentation uses to describe the pattern
    ("password", "TOKEN", "<REDACTED>") — a real PAT is long and mixes classes.
    """
    if len(pw) < 12 or _is_placeholder(pw):
        return False
    return any(c.isdigit() for c in pw) or (
        any(c.isupper() for c in pw) and any(c.islower() for c in pw)
    )


def _looks_like_credential(name: str, value: str) -> bool:
    low = name.lower()
    if any(w in low for w in PUBLIC_WORDS):
        return False
    if not any(w in low for w in SECRET_WORDS):
        return False
    if not VALUE_SHAPE_RE.match(value):
        return False
    if _is_placeholder(value):
        return False
    # Filesystem paths and URLs are long and base64-legal but are not secrets.
    if value.startswith(("/", "./", "../")) or "://" in value or value.count("/") > 2:
        return False
    # Real keys/tokens mix letters and digits; prose and long paths do not.
    return any(c.isdigit() for c in value) and any(c.isalpha() for c in value)


def scan_text(path: str, text: str):
    """Return a redacted reason string if `text` holds plaintext credentials."""
    if all(m.search(text) for m in SOPS_MARKERS):
        return None  # SOPS-encrypted: this is what we WANT committed.

    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#") or stripped.startswith("//"):
            continue  # commented-out documentation examples
        if PEM_RE.search(line):
            return f"{path}:{lineno} contains a PEM private key block"
        url_cred = URL_CRED_RE.search(line)
        if url_cred and _is_url_password(url_cred.group(1)):
            return f"{path}:{lineno} embeds a credential in a URL userinfo segment"
        m = KV_RE.match(line)
        if m and _looks_like_credential(m.group(1), m.group(2)):
            return (f"{path}:{lineno} sets '{m.group(1)}' to a "
                    f"{len(m.group(2))}-char credential-shaped value in plaintext")
    return None


def scan_file(repo_root: str, rel: str):
    if rel in ACCEPTED_RISK or rel == SELF:
        return None
    if SECRET_PATH_RE.search(rel):
        return f"{rel} is credential material by filename convention (see .gitignore)"
    full = os.path.join(repo_root, rel)
    try:
        if os.path.getsize(full) > MAX_SCAN_BYTES:
            return None
        with open(full, "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    if b"\0" in raw[:8192]:
        return None  # binary
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return scan_text(rel, text)


def _norm(repo_root: str, path: str) -> str:
    """Repo-relative form of `path` when it is inside the repo, else absolute.

    NOT `path.lstrip('./')` — lstrip takes a CHARACTER SET, so an absolute
    `/tmp/x.env` became `tmp/x.env` and silently stopped resolving.
    """
    absolute = os.path.abspath(os.path.join(repo_root, path))
    try:
        rel = os.path.relpath(absolute, os.path.abspath(repo_root))
    except ValueError:  # different drive on Windows
        return absolute
    return absolute if rel.startswith("..") else rel


def _git(repo_root: str, *args):
    try:
        out = subprocess.run(
            ("git", *args), cwd=repo_root, capture_output=True, text=True, timeout=20
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if out.returncode != 0:
        return []
    return [p for p in out.stdout.split("\0") if p]


def _segments(command: str):
    """Split a compound shell command into individually-parsed argv lists."""
    for part in re.split(r"&&|\|\||[;|\n]", command):
        try:
            argv = shlex.split(part)
        except ValueError:
            argv = part.split()
        if argv:
            yield argv


def files_for_command(repo_root: str, command: str):
    """Paths a `git add` / `git commit` in `command` would put into a commit."""
    paths = set()
    for argv in _segments(command):
        # Tolerate `env FOO=bar git add ...` and an absolute git path.
        try:
            gi = next(i for i, a in enumerate(argv) if os.path.basename(a) == "git")
        except StopIteration:
            continue
        rest = argv[gi + 1:]
        # Skip `git -C dir add` style global flags to find the subcommand.
        sub, i = None, 0
        while i < len(rest):
            if rest[i].startswith("-"):
                i += 2 if rest[i] in ("-C", "-c", "--git-dir", "--work-tree") else 1
                continue
            sub = rest[i]
            break
        if sub == "add":
            args = [a for a in rest[i + 1:] if a != "--"]
            explicit = [a for a in args if not a.startswith("-")]
            if not explicit:
                continue
            # Resolve dirs/globs, honouring .gitignore...
            paths.update(_git(repo_root, "ls-files", "-coz", "--exclude-standard", "--", *explicit))
            # ...but a literal file argument counts even when ignored, which is
            # exactly the `git add -f secrets/x.secret.yaml` case.
            for a in explicit:
                if os.path.isfile(os.path.join(repo_root, a)):
                    paths.add(_norm(repo_root, a))
        elif sub == "commit":
            flags = rest[i + 1:]
            paths.update(_git(repo_root, "diff", "--cached", "--name-only", "-z"))
            if any(f in ("-a", "--all") or re.fullmatch(r"-[a-zA-Z]*a[a-zA-Z]*", f) for f in flags):
                paths.update(_git(repo_root, "diff", "--name-only", "-z"))
            explicit = flags[flags.index("--") + 1:] if "--" in flags else []
            paths.update(_norm(repo_root, p) for p in explicit
                         if os.path.isfile(os.path.join(repo_root, p)))
    return sorted(paths)


def check_secret_commit(repo_root: str, command: str):
    # Cheap gate: 99% of Bash calls are not git add/commit.
    if not re.search(r"\bgit\b[^;&|]*\b(add|commit)\b", command):
        return None
    for rel in files_for_command(repo_root, command):
        reason = scan_file(repo_root, rel)
        if reason:
            return reason
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        # Fail open on unparseable input: the hook must not wedge every call.
        return 0

    if payload.get("tool_name") != "Bash":
        return 0

    command = (payload.get("tool_input") or {}).get("command", "")
    if not command:
        return 0

    normalized = " ".join(command.split())

    # Strip quoted string literals before matching. Commit messages, PR bodies,
    # and echo/printf text routinely NAME a destructive command in prose
    # ("defer the talosctl upgrade", "do not wipe disk") without invoking it.
    # Matching those is a false positive that blocks legitimate documentation
    # work, so only the executable portion of the line is scanned.
    scannable = re.sub(r"'[^']*'", " ", normalized)
    scannable = re.sub(r'"[^"]*"', " ", scannable)

    for pattern, reason in COMPILED:
        if pattern.search(scannable):
            sys.stderr.write(
                f"BLOCKED by .claude/hooks/guard-destructive.py: {reason}.\n"
                f"Command: {normalized[:300]}\n"
                "This task is repo-side only. If you believe this operation is genuinely "
                "required, do NOT work around the guard -- escalate with:\n"
                "  orca orchestration ask --question \"<why you need it>\" --timeout-ms 600000 --json\n"
            )
            return 2

    # Secret-commit guard runs on the RAW command: `git add` paths are not
    # quoted prose, and stripping quotes would drop quoted path arguments.
    repo_root = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    reason = check_secret_commit(repo_root, command)
    if reason:
        sys.stderr.write(
            "BLOCKED by .claude/hooks/guard-destructive.py: this commit would put PLAINTEXT\n"
            "credential material into a PUBLIC git repository.\n"
            f"  {reason}\n"
            "Read docs/security-posture.md. Fix it, do not work around the guard:\n"
            "  - real credentials belong in a Secret created out-of-band; commit a\n"
            "    *.example.yaml template with REPLACE_WITH_ placeholders instead;\n"
            "  - or SOPS-encrypt the file: task sops:encrypt FILE=<path> (see .sops.yaml);\n"
            "  - if this is a false positive, say so and escalate:\n"
            "      orca orchestration ask --question \"<why this value is not a secret>\" "
            "--timeout-ms 600000\n"
        )
        return 2

    return 0


# ---------------------------------------------------------------------------
# Self-test — `python3 .claude/hooks/guard-destructive.py --self-test`
# ---------------------------------------------------------------------------
# The previous version of this hook shipped two real false positives that only
# testing caught. Every case below asserts on scan_text/scan_file directly so
# it runs without touching the index.

_FAKE_PEM = "-" * 5 + "BEGIN RSA PRIVATE KEY" + "-" * 5

SELF_TEST_BLOCK = [
    ("k8s secret, real base64 token",
     "tls.key: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb3dJQkFBS0NBUUVB\n"),
    ("cloudflare api token",
     "stringData:\n  api-token: 8Kq2xR7vN4pL9wZ3mB6yT1cF5hJ0dS8gQ4nV7bX2\n"),
    ("PEM private key block", _FAKE_PEM + "\nMIIEowIBAAKCAQEA\n"),
    ("credential inlined in a git remote URL",
     "url = http://mershab:9f3a7c21d0be4815a6f2c93d78e01b45@localhost:3000/x.git\n"),
    ("dotenv style", "GITEA_TOKEN=9f3a7c21d0be4815a6f2c93d78e01b45a7d2e9f1\n"),
    ("client_secret in a dex config",
     "    clientSecret: Zx91Qw38Er47Ty56Ui65Op74As83Df92Gh01Jk10\n"),
]

SELF_TEST_PASS = [
    ("example template placeholder",
     "stringData:\n  api-token: REPLACE_WITH_CLOUDFLARE_API_TOKEN_FROM_DASHBOARD_HERE\n"),
    ("sveltos template expansion",
     '      api-token: {{ index (getResource "CF").data "api-token" }}\n'),
    ("webhook caBundle (public cert)",
     "  caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJkekNDQVIyZ0F3SUJBZ0lC\n"),
    ("image digest",
     "  image: ghcr.io/fyralabs/chisel-operator@sha256:3f907c1b2d4e5a6789bc0d1e2f3a4b5c6d7e8f90\n"),
    ("ssh public key",
     "  publicKey: AAAAC3NzaC1lZDI1NTE5AAAAIGx7Qh2vK9pLmN4rT6yU8wZ1aB3cD5eF7gH9\n"),
    ("long non-credential value under a non-secret key",
     "  description: this-is-a-very-long-hyphenated-description-string-value-here\n"),
    ("SOPS-encrypted file",
     "apiVersion: v1\nkind: Secret\ndata:\n  token: ENC[AES256_GCM,data:aBcDeF9012345678,type:str]\n"
     "sops:\n  mac: ENC[AES256_GCM,data:xYz012345678]\n  age: []\n"),
    ("commented-out proxy example from a Talos machineconfig",
     "    #     https_proxy: http://user:passwordlongenoughtotrip@SERVER:PORT/\n"),
    ("prose naming a secret",
     "The gitea PAT lives in ~/.git-credentials, not in the remote URL.\n"),
    # This report/doc text is written by THIS track. The first version of the
    # URL rule blocked its own report — kept as a regression case.
    ("docs describing the URL-credential pattern in prose",
     "a credential inlined in a URL (`scheme://user:password@host`)\n"),
    ("a redacted remote URL in a report",
     "gitea\thttp://<REDACTED>@localhost:3000/mershab/homelab.git (fetch)\n"),
    ("a token-free remediation command",
     "git remote set-url gitea http://localhost:3000/mershab/homelab.git\n"),
    ("helm chart version pin",
     "  chartVersion: 4.15.1\n  targetNamespace: ingress-nginx-external\n"),
]


def self_test() -> int:
    failures = []
    for name, text in SELF_TEST_BLOCK:
        if scan_text("t.yaml", text) is None:
            failures.append(f"SHOULD BLOCK but passed: {name}")
        else:
            print(f"  BLOCK ok   {name}\n             -> {scan_text('t.yaml', text)}")
    for name, text in SELF_TEST_PASS:
        got = scan_text("t.yaml", text)
        if got is not None:
            failures.append(f"FALSE POSITIVE: {name} -> {got}")
        else:
            print(f"  PASS  ok   {name}")

    # Path-convention rules and the accepted-risk exemptions.
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for rel, want_block in [
        ("secrets/infrastructure/dex/dex-config.secret.yaml", True),
        ("secrets/foo/bar.key.yaml", True),
        (".env", True),
        ("age.key", True),
        ("arrakis.kubeconfig", True),
        ("bootstrap/talos/controlplane.yaml", False),   # accepted risk
        ("bootstrap/talos/worker.yaml", False),         # accepted risk
        ("bootstrap/talos/talosconfig", False),         # accepted risk
        (SELF, False),                                  # the guard's own source
        ("secrets/infrastructure/dex/dex-config.example.yaml", False),
        ("docs/security-posture.md", False),
        ("platform/sveltos/clusterprofiles/kustomization.yaml", False),
    ]:
        got = scan_file(root, rel)
        if bool(got) != want_block:
            failures.append(f"path rule {rel}: want block={want_block}, got {got!r}")
        else:
            print(f"  PATH  ok   {'block' if want_block else 'allow'}  {rel}")

    # Tracked files the guard flags on purpose. Real findings, not exemptions:
    # loki-minio.example.yaml:14 sets AWS_SECRET_ACCESS_KEY to a 64-char
    # lowercase-hex value with no REPLACE_WITH_ marker — see
    # docs/reports/2026-08-25-secrets-hygiene.md. Once it is replaced with a
    # placeholder and the credential rotated, drop it from this set.
    KNOWN_FLAGGED = {"secrets/infrastructure/minio/loki-minio.example.yaml"}

    tracked = _git(root, "ls-files", "-z")
    flagged = {p for p in tracked if scan_file(root, p)}
    if flagged - KNOWN_FLAGGED:
        failures.append(f"unexpected tracked files would be blocked: {sorted(flagged - KNOWN_FLAGGED)}")
    if KNOWN_FLAGGED - flagged:
        failures.append(f"KNOWN_FLAGGED is stale, remove: {sorted(KNOWN_FLAGGED - flagged)}")
    if not failures:
        print(f"  SWEEP ok   {len(tracked) - len(flagged)}/{len(tracked)} tracked files committable; "
              f"{len(flagged)} known-flagged: {sorted(flagged)}")

    print()
    for f in failures:
        print("  FAIL:", f)
    print("SELF-TEST:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    sys.exit(main())
