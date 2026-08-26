#!/usr/bin/env bash
set -euo pipefail

# PAIRING_ADDRESS is the DNS name clients use to reach this pod: the NetBird name of the
# published orca resource on mesh cells, the OrbStack LoadBalancer domain on the local cell.
# It is only the client-advertised address — bind is always 0.0.0.0:$ORCA_PORT.
: "${PAIRING_ADDRESS:?set PAIRING_ADDRESS to the DNS name clients use to reach this orca resource}"

# The deb's Linux executableName is orca-ide, not orca (upstream avoids the Ubuntu GNOME
# Orca conflict); after-install.sh symlinks /usr/bin/orca-ide -> the resources/bin shim.
# A Service named `orca` makes kubelet inject ORCA_PORT=tcp://<clusterIP>:6768 (legacy
# service env links), which shadows this knob and makes orca serve exit with
# "Invalid --port value: tcp://...". Only a bare number is ours.
[[ "${ORCA_PORT:-}" =~ ^[0-9]+$ ]] || ORCA_PORT=6768

ORCA_BIN="$(command -v orca-ide || command -v orca || echo /opt/Orca/resources/bin/orca-ide)"

# ponytail: --no-sandbox only if the node blocks unprivileged userns; set ORCA_NO_SANDBOX=1 then
pre=()
[ "${ORCA_NO_SANDBOX:-0}" = "1" ] && pre+=(--no-sandbox)
post=()
[ "${ORCA_MOBILE_PAIRING:-0}" = "1" ] && post+=(--mobile-pairing)

exec "$ORCA_BIN" "${pre[@]}" serve \
    --port "$ORCA_PORT" \
    --pairing-address "$PAIRING_ADDRESS" \
    "${post[@]}"
