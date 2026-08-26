#!/usr/bin/env bash
# Fingerprint the LAN NAS before wiring it up as contraxia's backup target.
#
# Usage:  ./scripts/fingerprint-nas.sh [ip]     (default 192.168.2.2)
#
# Run this from the Mac the moment the NAS is powered on. It answers the four
# questions that decide the whole backup architecture:
#   1. Is it up, and what MAC/vendor is it (confirms it IS the TeraStation)?
#   2. Does it speak NFS at all, and which VERSION (v3 needs rpcbind; v4 does not)?
#   3. What are the export paths and their allowed-host rules?
#   4. Does it expose anything better than NFS (S3? SMB? rsync?)
#
# Nothing here writes to the NAS. Read-only reconnaissance.
set -uo pipefail

IP="${1:-192.168.2.2}"

hr() { printf '\n\033[1;36m── %s ─────────────────────────────────\033[0m\n' "$1"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

hr "1. REACHABILITY  ($IP)"
if ping -c 2 -W 1000 "$IP" >/dev/null 2>&1; then
  ok "responds to ICMP"
else
  no "no ICMP response — powered off, wrong IP, or ICMP blocked"
  echo "     (continuing anyway; some NAS boxes drop ping but serve NFS)"
fi

MAC=$(arp -n "$IP" 2>/dev/null | awk '{print $4}')
if [ -n "${MAC:-}" ] && [ "$MAC" != "(incomplete)" ]; then
  ok "MAC $MAC"
  # Buffalo OUIs: 00:0D:0B, 00:16:01, 00:1D:73, 00:24:A5, 4C:E6:76, 10:6F:3F …
  case "$MAC" in
    0:d:b:*|00:0d:0b:*|0:16:1:*|00:16:01:*|0:1d:73:*|00:1d:73:*|\
    0:24:a5:*|00:24:a5:*|4c:e6:76:*|10:6f:3f:*|dc:fb:2:*|de:fb:02:*)
      ok "OUI looks like BUFFALO — consistent with a TeraStation" ;;
    *)
      echo "     OUI not a known Buffalo prefix; look it up to confirm the device" ;;
  esac
else
  no "no ARP entry — device is not on the LAN (this is the 'unplugged' signature)"
fi

hr "2. OPEN PORTS"
# Ports that matter, and why:
#   22   ssh (scriptable mgmt?)      111  rpcbind/portmap (NFSv3 REQUIRES this)
#   139/445 SMB                      2049 nfs (v4 needs ONLY this)
#   80/81/443/9000 web admin UI      873  rsync daemon
#   5000/5001 (Synology-style)       21   ftp
for p in 21 22 80 81 111 139 443 445 873 2049 3260 5000 5001 8080 9000 20048; do
  if nc -z -G 2 "$IP" "$p" 2>/dev/null; then
    case $p in
      21)   ok "$p     ftp" ;;
      22)   ok "$p     ssh          <- scriptable management surface" ;;
      80)   ok "$p     http         <- web admin UI" ;;
      81)   ok "$p     http-alt     <- Buffalo admin UI often lives here" ;;
      111)  ok "$p    rpcbind      <- NFSv3 present" ;;
      139)  ok "$p    netbios-ssn  (SMB)" ;;
      443)  ok "$p    https" ;;
      445)  ok "$p    smb" ;;
      873)  ok "$p    rsync daemon <- viable backup transport" ;;
      2049) ok "$p   nfs          <- NFS DATA PORT" ;;
      3260) ok "$p   iscsi        <- block target, interesting alternative" ;;
      9000) ok "$p   http-alt     <- admin UI or S3-compatible endpoint" ;;
      20048) ok "$p  mountd       (NFSv3 mount protocol)" ;;
      *)    ok "$p" ;;
    esac
  fi
done

hr "3. NFS: EXPORTS AND VERSIONS"
echo "  showmount -e (NFSv3 mount protocol; silent on a v4-only server):"
showmount -e "$IP" 2>&1 | sed 's/^/     /'

echo
echo "  rpcinfo (which NFS versions are actually registered):"
if rpcinfo -p "$IP" 2>/dev/null | sed 's/^/     /' | grep -E 'nfs|mountd|portmapper|status'; then
  :
else
  echo "     (no rpcbind response — either down, or NFSv4-only which needs no portmapper)"
fi

echo
echo "  NFSv4 pseudo-root probe (v4 exports everything under a single root '/'):"
TMPMNT=$(mktemp -d /tmp/nasprobe.XXXXXX)
if timeout 15 mount -t nfs -o vers=4,ro,soft,timeo=50,retrans=1 "$IP:/" "$TMPMNT" 2>/dev/null; then
  ok "NFSv4 mount of '$IP:/' SUCCEEDED — v4 is available"
  echo "     contents of the v4 pseudo-root:"
  ls -la "$TMPMNT" 2>&1 | sed 's/^/       /'
  umount "$TMPMNT" 2>/dev/null
else
  no "NFSv4 mount of '$IP:/' failed (expected if the box is NFSv3-only)"
fi
rmdir "$TMPMNT" 2>/dev/null

hr "4. WEB ADMIN SURFACE"
for port in 80 81 443 9000; do
  scheme=http; [ "$port" = 443 ] && scheme=https
  hdr=$(curl -sS -m 4 -k -i "$scheme://$IP:$port/" 2>/dev/null | head -20)
  if [ -n "$hdr" ]; then
    echo "  --- $scheme://$IP:$port/ ---"
    echo "$hdr" | grep -iE '^HTTP/|^Server:|^Location:|^Set-Cookie:|<title>' | sed 's/^/     /'
  fi
done

hr "5. BUFFALO NAS NAVIGATOR DISCOVERY (UDP 22936)"
# Buffalo devices answer a broadcast probe on UDP 22936 with model/name/IP.
echo "  Sending discovery probe (best effort; needs the device on the same L2):"
(printf '\x01\x08\x00\x01\x00\x00\x00\x00' | nc -u -w 3 "$IP" 22936 2>/dev/null | xxd | head -12 | sed 's/^/     /') \
  || echo "     (no response)"

hr "SUMMARY / WHAT TO DO NEXT"
cat <<'EOF'
  Decision table from the results above:

    Port 2049 open + NFSv4 mount worked
        -> BEST CASE. Use NFSv4. No rpcbind dependency.

    Port 111 + 2049 open, showmount lists exports, v4 mount failed
        -> NFSv3 only. Workable, but the mount MUST pin vers=3 and the
           NAS must allow the k8s node IP (192.168.2.70) in its export rules.

    Neither 111 nor 2049 open
        -> NFS is not enabled yet. Enable it in the TeraStation web UI
           (Shared Folders -> the share -> NFS -> enable, then add
           192.168.2.0/24 as an allowed host with read-write).

    Port 873 open
        -> rsync daemon available; a viable transport if NFS proves flaky.

  Whatever the result, record it in docs/runbooks/ before building on it.
EOF
echo
