#!/usr/bin/env bash
# Seed *.secret.yaml from every *.example.yaml (skips ones you've already made).
# Run once, then edit the *.secret.yaml files to replace the REPLACE_WITH_
# placeholders, then: kubectl apply -k secrets/   (or ./secrets/apply.sh)
#
# *.secret.yaml is gitignored — filled secrets never get committed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while IFS= read -r ex; do
  secret="${ex%.example.yaml}.secret.yaml"
  if [ -e "$secret" ]; then
    echo "skip (exists)  ${secret#"$SCRIPT_DIR"/}"
  else
    cp "$ex" "$secret"
    echo "created        ${secret#"$SCRIPT_DIR"/}"
  fi
done < <(find "$SCRIPT_DIR" -type f -name '*.example.yaml')

echo
echo "Now edit the *.secret.yaml files (replace REPLACE_WITH_ placeholders), then:"
echo "  kubectl apply -k secrets/"
