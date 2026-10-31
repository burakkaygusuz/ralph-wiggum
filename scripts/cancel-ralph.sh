#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"

if [[ -n "$(git -C "$PROJECT_ROOT" ls-files ':(icase).ralph' 2>/dev/null)" ]]; then
  echo "Error: .ralph is tracked by git. Refusing to delete it." >&2
  exit 1
fi

if [[ -d "$STATE_DIR" || -f "$STATE_FILE" ]]; then
  if [[ -f "$STATE_FILE" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
    read_state
    echo "Ralph loop canceled at iteration $ITERATION."
  else
    echo "Ralph loop canceled."
  fi
  rm -rf "$STATE_DIR"
else
  echo "No active Ralph loop found."
fi
