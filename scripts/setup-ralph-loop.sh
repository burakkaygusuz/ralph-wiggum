#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: setup-ralph-loop.sh [--max-iterations N] [--completion-promise TEXT] [--test-cmd CMD] [--force] (PROMPT... | --prompt-file FILE)

Starts a Ralph loop in the current git repository. Writes .ralph/state.env and .ralph/fix_plan.md.

Options:
  --max-iterations N          Iteration limit (default: 10, 0 = unlimited)
  --completion-promise TEXT   Text the agent prints in <promise>TEXT</promise> to finish (default: COMPLETE or DONE)
  --test-cmd CMD              Command the stop hook runs from the repo root on every stop, before it accepts completion (120 s limit if timeout or gtimeout is installed; default: none)
  --prompt-file FILE          Read the task from FILE instead of arguments (a relative path resolves from the current directory)
  --force                     Replace an active loop
  -h, --help                  Show this help (first argument only)

Example:
  setup-ralph-loop.sh --max-iterations 5 --completion-promise DONE --test-cmd "npm test" "Fix the login bug"

Exit codes:
  0  Loop initialized
  1  Unexpected failure
  2  Invalid arguments or usage
  3  Precondition failed: not a git repository, no commit yet, .ralph tracked by git, or a loop is already active (use --force)
EOF
}

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { usage; exit 0; }

CALLER_DIR="$PWD"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Error: Ralph loop must run inside a git repository." >&2; exit 3; }
cd "$PROJECT_ROOT"
EXCLUDE_FILE="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$EXCLUDE_FILE")"
grep -qxF '.ralph/' "$EXCLUDE_FILE" 2>/dev/null || printf '\n.ralph/\n' >> "$EXCLUDE_FILE" || echo "Warning: cannot write $EXCLUDE_FILE (read-only .git in a sandbox?). Add .ralph/ to your git ignore rules yourself." >&2

STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"
PLAN_FILE="$STATE_DIR/fix_plan.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/state.sh"

MAX_ITERATIONS=$DEFAULT_MAX_ITERATIONS
COMPLETION_PROMISE=""
TEST_CMD=""
PROMPT=""
FORCE=false
PROMPT_FILE=""

prompt_parts=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --max-iterations) [[ $# -ge 2 ]] || { echo "Error: --max-iterations requires a value" >&2; exit 2; }; MAX_ITERATIONS="$2"; shift 2 ;;
    --completion-promise) [[ $# -ge 2 ]] || { echo "Error: --completion-promise requires a value" >&2; exit 2; }; COMPLETION_PROMISE="$2"; shift 2 ;;
    --test-cmd) [[ $# -ge 2 ]] || { echo "Error: --test-cmd requires a value" >&2; exit 2; }; TEST_CMD="$2"; shift 2 ;;
    --prompt-file) [[ $# -ge 2 ]] || { echo "Error: --prompt-file requires a value" >&2; exit 2; }; PROMPT_FILE="$2"; shift 2 ;;
    --*) echo "Error: unknown option $1" >&2; exit 2 ;;
    *) prompt_parts+=("$1"); shift ;;
  esac
done

if [[ -n "$PROMPT_FILE" ]]; then
  [[ ${#prompt_parts[@]} -eq 0 ]] || { echo "Error: pass the prompt either as arguments or with --prompt-file, not both" >&2; exit 2; }
  [[ "$PROMPT_FILE" == /* ]] || PROMPT_FILE="$CALLER_DIR/$PROMPT_FILE"
  [[ -f "$PROMPT_FILE" ]] || { echo "Error: prompt file $PROMPT_FILE not found" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
else
  PROMPT="${prompt_parts[*]:-}"
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-iterations must be a non-negative integer" >&2
  exit 2
fi
MAX_ITERATIONS=$((10#$MAX_ITERATIONS)) # base 10: a leading zero would otherwise be read as octal

if [[ -z "$PROMPT" ]]; then
  echo "Error: Prompt cannot be empty" >&2
  exit 2
fi

if [[ "$COMPLETION_PROMISE$TEST_CMD" == *$'\n'* ]]; then
  echo "Error: --completion-promise and --test-cmd must be single-line" >&2
  exit 2
fi

# The stop hook trims whitespace inside <promise> tags and matches the raw JSON text, where these characters are escaped differently
if [[ "$COMPLETION_PROMISE" == *[\<\\\"\&[:cntrl:]]* ]] || [[ "$COMPLETION_PROMISE" =~ ^[[:space:]]|[[:space:]]$ ]]; then
  echo "Error: --completion-promise cannot contain '<', '\\', '\"', '&' or control characters, and cannot start or end with whitespace" >&2
  exit 2
fi

if [[ -n "$(git -C "$PROJECT_ROOT" ls-files ':(icase).ralph')" ]]; then
  echo "Error: .ralph is tracked by git. Untrack it: TEST_COMMAND must not come from the repository." >&2
  exit 3
fi

if [[ -f "$STATE_FILE" ]] && [ "$FORCE" = false ]; then
  echo "Error: An active Ralph loop already exists. Run $SCRIPT_DIR/cancel-ralph.sh or pass --force." >&2
  exit 3
fi

BASE_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --verify -q HEAD)" || { echo "Error: Ralph loop needs a commit as its baseline for the test integrity guard." >&2; exit 3; }

mkdir -p "$STATE_DIR"
[[ "$FORCE" = false ]] || rm -rf "$STATE_DIR/.lock"

rm -f "$PLAN_FILE" # replace a planted symlink instead of writing through it
cat <<EOF > "$PLAN_FILE"
# Ralph Implementation Plan & State Scheduler

> **Discipline:** Select exactly ONE highest-priority task per turn. Implement, run verification tests, record learnings, and check \`[x]\`.

## 1. Specification & Objective
$PROMPT

> **Completion:** Output \`<promise>${COMPLETION_PROMISE:-COMPLETE}</promise>\` in your final reply only when every work item is checked and verified.

## 2. Working Memory & Cross-Turn Learnings
- [Initial State]: Repository baseline under inspection.
<!-- Record key architectural findings, tricky edge cases, and environment quirks here for future turns -->

## 3. Work Queue (Ordered by Priority)
- [ ] 1. Explore codebase, verify baseline tests, and decompose implementation tasks
- [ ] 2. Core implementation and handling edge cases
- [ ] 3. Automated regression tests and acceptance verification

## 4. Completed Work & Verified Evidence
<!-- Record verified test output traces, diff confirmations, and completed deliverables here -->
EOF

INITIAL_TASK_COUNT=$(grep -Ec "^[[:space:]]*- \[([ xX])\]" "$PLAN_FILE")

STATE_TMP="$(mktemp "$STATE_DIR/state.XXXXXX")"
cat > "$STATE_TMP" <<EOF
ITERATION=1
MAX_ITERATIONS=$MAX_ITERATIONS
COMPLETION_PROMISE=$COMPLETION_PROMISE
TEST_COMMAND=$TEST_CMD
BASE_COMMIT=$BASE_COMMIT
INITIAL_TASK_COUNT=$INITIAL_TASK_COUNT
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
mv "$STATE_TMP" "$STATE_FILE"

echo "Ralph loop initialized (Iteration 1, Max: $([[ "$MAX_ITERATIONS" -gt 0 ]] && echo "$MAX_ITERATIONS" || echo unlimited), Promise: ${COMPLETION_PROMISE:-COMPLETE or DONE})"
