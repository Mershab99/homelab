#!/usr/bin/env python3
"""PreToolUse guard for the contraxia storage-refit worker fan-out.

Blocks destructive infrastructure operations regardless of Claude Code
permission mode. Per Claude Code docs, a PreToolUse hook that exits with
code 2 blocks the tool call even under --permission-mode bypassPermissions,
where `permissions.allow` is inert and prefix-based `deny` patterns are
easily evaded by flag ordering (e.g. `talosctl --talosconfig X -e Y upgrade`).

Contract: reads the tool call as JSON on stdin, exits 2 with a reason on
stderr to block, exits 0 to allow.
"""
import json
import re
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
    (r"\bgit\s+push\b.*\borigin\b",
     "origin is GitHub; push to the 'gitea' remote instead"),
    (r"\bgit\s+push\b.*(--force|-f)(\s|$)",
     "force push is forbidden"),
    (r"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f)",
     "destructive git operation on a shared checkout"),

    # --- Secrets ---
    (r"\bsecrets/.*\.(secret|key)\.ya?ml\b",
     "reading decrypted secret material is forbidden"),
]

COMPILED = [(re.compile(p, re.IGNORECASE), r) for p, r in BLOCKED]


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

    return 0


if __name__ == "__main__":
    sys.exit(main())
