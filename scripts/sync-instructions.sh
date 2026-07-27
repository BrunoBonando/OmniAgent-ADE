#!/bin/sh
set -euo pipefail

AUTH_FILE=".github/copilot-instructions.md"

if [ ! -f "$AUTH_FILE" ]; then
  echo "Error: $AUTH_FILE not found" >&2
  exit 1
fi

for dst in AGENTS.md CLAUDE.md; do
  echo "Generating $dst from $AUTH_FILE"
  {
    echo "<!-- GENERATED from $AUTH_FILE — do not edit directly. Update $AUTH_FILE instead. -->"
    echo
    cat "$AUTH_FILE"
  } > "/tmp/generated_$dst"

  if [ ! -f "$dst" ] || ! cmp -s "/tmp/generated_$dst" "$dst"; then
    mv "/tmp/generated_$dst" "$dst"
    git add "$dst" || true
    echo "$dst updated and staged"
  else
    rm "/tmp/generated_$dst"
  fi
done
