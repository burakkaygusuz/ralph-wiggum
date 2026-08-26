#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"

acquire_lock() {
  local lock_dir="$STATE_DIR/.lock"
  local tries=0
  while :; do
    if mkdir "$lock_dir" 2>/dev/null; then break; fi
    sleep 0.05
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then
      rm -rf "$lock_dir" 2>/dev/null || true
      mkdir "$lock_dir" 2>/dev/null || true
      break
    fi
  done
}

release_lock() {
  rm -rf "$STATE_DIR/.lock" 2>/dev/null || true
}

if [[ -d "$STATE_DIR" || -f "$STATE_FILE" ]]; then
  acquire_lock
  ITER=""
  if [[ -f "$STATE_FILE" ]]; then
    while IFS="=" read -r key val || [[ -n "$key" ]]; do
      if [[ "$key" == "ITERATION" && "$val" =~ ^[0-9]+$ ]]; then
        ITER="$val"
      fi
    done < "$STATE_FILE"
  fi
  release_lock
  rm -rf "$STATE_DIR"
  if [[ -n "$ITER" ]]; then
    echo "Ralph loop canceled at iteration $ITER."
  else
    echo "Ralph loop canceled."
  fi
else
  echo "No active Ralph loop found."
fi
