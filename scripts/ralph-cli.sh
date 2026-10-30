#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || { echo "Error: Ralph loop requires jq." >&2; exit 1; }

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"
PID_FILE="$STATE_DIR/cli.pid"
PLAN_FILE="${1:-$STATE_DIR/fix_plan.md}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_BIN="${AGENT_BIN:-claude}"
STOP_HOOK="$SCRIPT_DIR/stop-hook.sh"

[[ ! -f "$PLAN_FILE" || ! -f "$STATE_FILE" ]] && { echo "Error: Ralph loop not initialized. Run ${SCRIPT_DIR}/setup-ralph-loop.sh first." >&2; exit 1; }

if [[ -f "$PID_FILE" ]]; then
  EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || true)
  if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    echo "Error: Another ralph-cli process (PID $EXISTING_PID) is already running in this repo." >&2
    exit 1
  fi
fi

echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

cleanup() {
  echo -e "\nRalph loop canceled by user."
  rm -rf "$STATE_DIR"
  exit 130
}
trap cleanup INT TERM HUP

read_state() {
  ITERATION=1
  MAX_ITERATIONS=10
  COMPLETION_PROMISE=""
  TEST_COMMAND=""
  STARTED_AT=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      ITERATION) [[ "$val" =~ ^[0-9]+$ ]] && ITERATION="$val" ;;
      MAX_ITERATIONS) [[ "$val" =~ ^[0-9]+$ ]] && MAX_ITERATIONS="$val" ;;
      COMPLETION_PROMISE) COMPLETION_PROMISE="$val" ;;
      TEST_COMMAND) TEST_COMMAND="$val" ;;
      STARTED_AT) STARTED_AT="$val" ;;
    esac
  done < "$STATE_FILE"
}

read_state
echo "Starting Ralph Loop on '$PLAN_FILE' with '$AGENT_BIN' (Max: $([[ "$MAX_ITERATIONS" -gt 0 ]] && echo "$MAX_ITERATIONS" || echo unlimited))..."

CURRENT_PROMPT="$(cat "$PLAN_FILE")"
EXIT_CODE=0

while :; do
  read_state
  ITER="$ITERATION"
  [[ "$MAX_ITERATIONS" -gt 0 && "$ITER" -gt "$MAX_ITERATIONS" ]] && { echo "Max iterations ($MAX_ITERATIONS) reached."; EXIT_CODE=1; break; }

  [[ "$MAX_ITERATIONS" -gt 0 ]] && LIMIT=" of $MAX_ITERATIONS" || LIMIT=""
  echo "=== [Iteration $ITER$LIMIT] ==="
  OUTPUT=$(RALPH_CLI_AGENT=1 "$AGENT_BIN" --print -p "$CURRENT_PROMPT" </dev/null) || {
    echo "Agent process exited on iteration $ITER."
    EXIT_CODE=1
    break
  }
  echo "$OUTPUT"

  HOOK_ERR_FILE="$(mktemp)"
  HOOK_RESULT=$(printf '%s' "$OUTPUT" | jq -Rs '{last_assistant_message: .}' | RALPH_CLI_AGENT= "$STOP_HOOK" 2>"$HOOK_ERR_FILE" || true)
  HOOK_ERR="$(cat "$HOOK_ERR_FILE")"
  rm -f "$HOOK_ERR_FILE"
  [[ -n "$HOOK_ERR" ]] && echo "$HOOK_ERR" >&2

  if [[ ! -f "$STATE_FILE" ]]; then
    if grep -q '^Ralph loop: Verified' <<< "$HOOK_ERR"; then
      echo "Ralph loop finished successfully."
    else
      [[ "$HOOK_ERR" == *"Max iterations"* ]] || echo "Ralph loop: state removed without verification." >&2
      EXIT_CODE=1
    fi
    break
  fi

  read_state
  if [[ "$ITERATION" -le "$ITER" ]]; then
    echo "Error: stop hook did not advance the loop past iteration $ITER." >&2
    EXIT_CODE=1
    break
  fi

  FEEDBACK="$(jq -r '.reason // empty' <<< "$HOOK_RESULT" 2>/dev/null || true)"
  CURRENT_PROMPT="${FEEDBACK:-$(cat "$PLAN_FILE")}"
done

exit "$EXIT_CODE"
