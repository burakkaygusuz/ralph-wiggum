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
  ITER=""
  if [[ -f "$STATE_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == *=* ]] || continue
      key="${line%%=*}"
      val="${line#*=}"
      if [[ "$key" == "ITERATION" && "$val" =~ ^[0-9]+$ ]]; then
        ITER="$val"
      fi
    done < "$STATE_FILE"
  fi
  rm -rf "$STATE_DIR"
  if [[ -n "$ITER" ]]; then
    echo "Ralph loop canceled at iteration $ITER."
  else
    echo "Ralph loop canceled."
  fi
else
  echo "No active Ralph loop found."
fi
