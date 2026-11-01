#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cancel-ralph.sh [-h|--help]

Cancels the active Ralph loop in the current git repository and deletes the .ralph folder (state and plan).
Takes no arguments.

Exit codes:
  0  Canceled, or no active loop found
  1  Unexpected failure
  2  Unknown option
  3  Precondition failed: .ralph is tracked by git (refused, nothing deleted)
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option $arg" >&2; exit 2 ;;
  esac
done

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"

if [[ -n "$(git -C "$PROJECT_ROOT" ls-files ':(icase).ralph' 2>/dev/null)" ]]; then
  echo "Error: .ralph is tracked by git. Refusing to delete it." >&2
  exit 3
fi

if [[ -d "$STATE_DIR" || -f "$STATE_FILE" ]]; then
  if [[ -f "$STATE_FILE" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
    read_state
    echo "Ralph loop canceled at iteration $ITERATION."
  else
    echo "No active Ralph loop found. Deleted the leftover .ralph folder."
  fi
  rm -rf "$STATE_DIR"
else
  echo "No active Ralph loop found."
fi
