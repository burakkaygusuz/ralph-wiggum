#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ralph-cli.sh [-h|--help]

Runs the Ralph loop of the current git repository without a plugin host. Each iteration runs "$AGENT_BIN -p" with the plan in .ralph/fix_plan.md.
Start the loop first with setup-ralph-loop.sh. Takes no arguments. Loop settings come from .ralph/state.env.

Environment:
  AGENT_BIN   Agent command to run (default: claude)

Example:
  AGENT_BIN=claude ralph-cli.sh

Exit codes:
  0    Loop finished: the tests passed and every plan item is checked
  1    Unexpected failure: the agent exited non-zero, or the state was removed without verification
  2    Invalid arguments or usage
  3    Precondition failed: no initialized loop, or another ralph-cli is already running
  4    Iteration limit reached without a verified completion
  130  Interrupted by Ctrl-C, TERM or HUP; the loop state is deleted
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "Error: unknown option $1" >&2; exit 2 ;;
esac

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"
PID_FILE="$STATE_DIR/cli.pid"
PLAN_FILE="$STATE_DIR/fix_plan.md"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_BIN="${AGENT_BIN:-claude}"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/step.sh"

[[ ! -f "$PLAN_FILE" || ! -f "$STATE_FILE" ]] && { echo "Error: Ralph loop not initialized. Run ${SCRIPT_DIR}/setup-ralph-loop.sh first." >&2; exit 3; }

if [[ -f "$PID_FILE" ]]; then
  EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || true)
  if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    echo "Error: Another ralph-cli process (PID $EXISTING_PID) is already running in this repo." >&2
    exit 3
  fi
fi

echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"; release_lock' EXIT

# shellcheck disable=SC2329 # called through trap
cleanup() {
  echo -e "\nRalph loop canceled by user."
  rm -rf "$STATE_DIR"
  exit 130
}
trap cleanup INT TERM HUP

read_state
echo "Starting Ralph Loop on '$PLAN_FILE' with '$AGENT_BIN' (Max: $([[ "$MAX_ITERATIONS" -gt 0 ]] && echo "$MAX_ITERATIONS" || echo unlimited))..."

CALLER_DIR="$PWD"
CURRENT_PROMPT="$(cat "$PLAN_FILE")"
EXIT_CODE=0

while :; do
  read_state
  [[ "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -gt "$MAX_ITERATIONS" ]] && { echo "Max iterations ($MAX_ITERATIONS) reached."; EXIT_CODE=4; break; }

  [[ "$MAX_ITERATIONS" -gt 0 ]] && LIMIT=" of $MAX_ITERATIONS" || LIMIT=""
  echo "=== [Iteration $ITERATION$LIMIT] ==="
  OUTPUT=$(RALPH_CLI_AGENT=1 "$AGENT_BIN" -p "$CURRENT_PROMPT" </dev/null) || {
    echo "Agent process exited on iteration $ITERATION."
    EXIT_CODE=1
    break
  }
  printf '%s\n' "$OUTPUT"

  if [[ ! -f "$STATE_FILE" ]]; then
    echo "Ralph loop: state removed without verification." >&2
    EXIT_CODE=1
    break
  fi

  cd "$PROJECT_ROOT" # the step runs git and the test command from the project root
  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Error: $PROJECT_ROOT is no longer inside a git repository." >&2
    EXIT_CODE=1
    break
  fi
  check_state_safe || { EXIT_CODE=1; break; }
  lock_state || { echo "Ralph loop: state removed without verification." >&2; EXIT_CODE=1; break; }
  STEP_STATUS=0
  ralph_step || STEP_STATUS=$?
  [[ "$STEP_STATUS" -ne 3 ]] || ralph_advance || STEP_STATUS=1
  release_lock
  cd "$CALLER_DIR"
  case "$STEP_STATUS" in
    0) echo "Ralph loop finished successfully."; break ;;
    4) EXIT_CODE=4; break ;;
    3) ;;
    *) EXIT_CODE=1; break ;;
  esac

  CURRENT_PROMPT="$FEEDBACK"
done

exit "$EXIT_CODE"
