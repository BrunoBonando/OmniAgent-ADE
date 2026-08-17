#!/bin/sh
set -euo pipefail

# Usage:
#  scripts/sync-instructions.sh            # regenerate AGENTS/CLAUDE/CODEX/ANTIGRAVITY from .github/copilot-instructions.md
#  scripts/sync-instructions.sh CLAUDE.md  # promote CLAUDE.md as authoritative and propagate to others (and update .github/copilot-instructions.md)

DEFAULT_AUTH=".github/copilot-instructions.md"
ALLOWED=("$DEFAULT_AUTH" AGENTS.md CLAUDE.md CODEX.md ANTIGRAVITY.md)

src="$DEFAULT_AUTH"
if [ $# -ge 1 ] && [ -n "$1" ]; then
  src="$1"
fi

# validate source
valid=false
for a in "${ALLOWED[@]}"; do
  if [ "$a" = "$src" ]; then
    valid=true
    break
  fi
done

if [ "$valid" = false ]; then
  echo "Error: source must be one of: ${ALLOWED[*]}" >&2
  exit 1
fi

if [ ! -f "$src" ]; then
  echo "Error: source file $src not found" >&2
  exit 1
fi

# read source content
SRC_CONTENT=$(cat "$src")

for dst in "${ALLOWED[@]}"; do
  # skip writing the source file to itself
  if [ "$dst" = "$src" ]; then
    continue
  fi

  echo "Generating $dst from $src"
  # mktemp, not "/tmp/generated_$dst": a destination name may contain a slash
  # (.github/copilot-instructions.md), which named a file inside a directory
  # that does not exist -- so promoting an agent file as authoritative always
  # died here. It also keeps two concurrent runs off the same path.
  tmp=$(mktemp)
  {
    echo "<!-- GENERATED from $src — do not edit directly. To change this content, edit $src or run: scripts/sync-instructions.sh $src -->"
    echo
    echo "$SRC_CONTENT"
  } > "$tmp"

  if [ ! -f "$dst" ] || ! cmp -s "$tmp" "$dst"; then
    mv "$tmp" "$dst"
    git add "$dst" || true
    echo "$dst updated and staged"
  else
    rm "$tmp"
  fi
done

# If an agent file was used as source (not the default), also update the authoritative file
if [ "$src" != "$DEFAULT_AUTH" ]; then
  echo "Updating authoritative file $DEFAULT_AUTH from $src"
  tmp=$(mktemp)
  {
    echo "<!-- GENERATED from $src — promoted as authoritative by sync script. Edit $src to change. -->"
    echo
    echo "$SRC_CONTENT"
  } > "$tmp"

  if [ ! -f "$DEFAULT_AUTH" ] || ! cmp -s "$tmp" "$DEFAULT_AUTH"; then
    mv "$tmp" "$DEFAULT_AUTH"
    git add "$DEFAULT_AUTH" || true
    echo "$DEFAULT_AUTH updated and staged"
  else
    rm "$tmp"
  fi
fi

# done
