#!/bin/bash
# k3s-agent-join.sh — Run on Dell Optiplex to join the hub cluster as a K3s agent.
# Usage: ./k3s-agent-join.sh <supermicro-ip> <k3s-token>
set -euo pipefail

SUPERMICRO_IP="${1:?Usage: $0 <supermicro-ip> <k3s-token>}"
K3S_TOKEN="${2:?Usage: $0 <supermicro-ip> <k3s-token>}"
OPTIPLEX_HOSTNAME="${3:-optiplex}"

echo "=== Joining K3s cluster as agent ==="
echo "Server: https://${SUPERMICRO_IP}:6443"

# Install K3s agent
curl -sfL https://get.k3s.io | K3S_URL="https://${SUPERMICRO_IP}:6443" K3S_TOKEN="${K3S_TOKEN}" sh -

echo "=== K3s agent installed ==="
echo ""
echo "Run the following on a machine with kubectl access to label this node:"
echo ""
echo "  kubectl label node ${OPTIPLEX_HOSTNAME} node-role.kubernetes.io/agent=\"\""
echo "  kubectl label node ${OPTIPLEX_HOSTNAME} topology.homelab.dev/chassis=optiplex"
echo ""
echo "And label the Supermicro server node:"
echo ""
echo "  kubectl label node <supermicro-hostname> topology.homelab.dev/chassis=supermicro"
echo ""
echo "=== Done ==="
