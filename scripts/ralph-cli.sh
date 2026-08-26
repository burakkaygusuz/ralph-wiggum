#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"
PID_FILE="$STATE_DIR/cli.pid"
PLAN_FILE="${1:-$STATE_DIR/fix_plan.md}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_BIN="${AGENT_BIN:-claude}"
STOP_HOOK="$SCRIPT_DIR/stop-hook.sh"

[[ ! -f "$PLAN_FILE" || ! -f "$STATE_FILE" ]] && { echo "Error: Ralph loop not initialized. Run ./scripts/setup-ralph-loop.sh first." >&2; exit 1; }

if [[ -f "$PID_FILE" ]]; then
  EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || true)
  if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    echo "Error: Another ralph-cli process (PID $EXISTING_PID) is already running in this repo." >&2
    exit 1
  fi
fi

echo "$$" > "$PID_FILE"

cleanup() {
  echo -e "\nRalph loop canceled by user."
  rm -rf "$STATE_DIR"
  exit 130
}
trap cleanup INT TERM

read_state() {
  ITERATION=1
  MAX_ITERATIONS=10
  COMPLETION_PROMISE=""
  TEST_COMMAND=""
  STARTED_AT=""
  while IFS="=" read -r key val || [[ -n "$key" ]]; do
    case "$key" in
      ITERATION) [[ "$val" =~ ^[0-9]+$ ]] && ITERATION="$val" ;;
      MAX_ITERATIONS) [[ "$val" =~ ^[0-9]+$ ]] && MAX_ITERATIONS="$val" ;;
      COMPLETION_PROMISE) COMPLETION_PROMISE="$val" ;;
      TEST_COMMAND) TEST_COMMAND="$val" ;;
      STARTED_AT) STARTED_AT="$val" ;;
    esac
  done < "$STATE_FILE"
}

extract_feedback() {
  local json="$1"
  printf "%s\n" "$json" | awk -F"\"reason\": \"" '
    NF > 1 {
      val = $2
      sub(/",[\r\n[:space:]]*"followup_message".*/, "", val)
      sub(/",[\r\n[:space:]]*"decision".*/, "", val)
      sub(/"[\r\n[:space:]]*}[[:space:]]*$/, "", val)
      gsub(/\\n/, "\n", val)
      gsub(/\\t/, "\t", val)
      gsub(/\\"/, "\"", val)
      gsub(/\\\\/, "\\", val)
      print val
    }
  '
}

read_state
echo "Starting Ralph Loop on '$PLAN_FILE' with '$AGENT_BIN' (Max: $MAX_ITERATIONS)..."

CURRENT_PROMPT="$(cat "$PLAN_FILE")"

while :; do
  [[ ! -f "$STATE_FILE" ]] && { echo "Ralph loop completed or state removed."; break; }

  read_state
  ITER="${ITERATION:-1}"
  [[ "$MAX_ITERATIONS" -gt 0 && "$ITER" -gt "$MAX_ITERATIONS" ]] && { echo "Max iterations ($MAX_ITERATIONS) reached."; break; }

  echo "=== [Iteration $ITER${MAX_ITERATIONS:+ of $MAX_ITERATIONS}] ==="
  OUTPUT=$("$AGENT_BIN" --print -p "$CURRENT_PROMPT" 2>&1) || {
    echo "Agent process exited on iteration $ITER."
    break
  }
  echo "$OUTPUT"

  if [[ -x "$STOP_HOOK" ]]; then
    HOOK_RESULT=$(printf '%s\n' "$OUTPUT" | "$STOP_HOOK" 2>&1 || true)
    [[ ! -d "$STATE_DIR" ]] && { echo "Ralph loop finished successfully."; break; }

    FEEDBACK=$(extract_feedback "$HOOK_RESULT")
    if [[ -n "$FEEDBACK" ]]; then
      CURRENT_PROMPT="$FEEDBACK"
    elif [[ -f "$PLAN_FILE" ]]; then
      CURRENT_PROMPT="$(cat "$PLAN_FILE")"
    fi
  fi
done

rm -f "$PID_FILE" 2>/dev/null || true
