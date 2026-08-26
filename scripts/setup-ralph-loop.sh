#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"
PLAN_FILE="$STATE_DIR/fix_plan.md"

MAX_ITERATIONS=10
COMPLETION_PROMISE=""
TEST_CMD=""
PROMPT=""
FORCE=false

if [ "$#" -eq 1 ] && [[ "$1" == *"--"* ]]; then
  input="$1"
  if [[ "$input" =~ --force ]]; then
    FORCE=true
    input="${input//--force/}"
  fi
  if [[ "$input" =~ --max-iterations[[:space:]]+([0-9]+) ]]; then
    MAX_ITERATIONS="${BASH_REMATCH[1]}"
    input="${input//${BASH_REMATCH[0]}/}"
  fi
  if [[ "$input" =~ --completion-promise[[:space:]]+(\"([^\"]+)\"|\x27([^\x27]+)\x27|([^[:space:]]+)) ]]; then
    COMPLETION_PROMISE="${BASH_REMATCH[2]:-${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}}"
    input="${input//${BASH_REMATCH[0]}/}"
  fi
  if [[ "$input" =~ --test-cmd[[:space:]]+(\"([^\"]+)\"|\x27([^\x27]+)\x27|([^[:space:]]+)) ]]; then
    TEST_CMD="${BASH_REMATCH[2]:-${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}}"
    input="${input//${BASH_REMATCH[0]}/}"
  fi
  PROMPT="${input#"${input%%[![:space:]]*}"}"
  PROMPT="${PROMPT%"${PROMPT##*[![:space:]]}"}"
else
  prompt_parts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) FORCE=true; shift ;;
      --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
      --completion-promise) COMPLETION_PROMISE="$2"; shift 2 ;;
      --test-cmd) TEST_CMD="$2"; shift 2 ;;
      *) prompt_parts+=("$1"); shift ;;
    esac
  done
  PROMPT="${prompt_parts[*]:-}"
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-iterations must be a non-negative integer" >&2
  exit 1
fi

if [[ -z "$PROMPT" ]]; then
  echo "Error: Prompt cannot be empty" >&2
  exit 1
fi

if [[ -f "$STATE_FILE" ]] && [ "$FORCE" = false ]; then
  echo "Error: An active Ralph loop already exists. Run ./scripts/cancel-ralph.sh or pass --force." >&2
  exit 1
fi

mkdir -p "$STATE_DIR"

cat <<EOF > "$PLAN_FILE"
# Ralph Implementation Plan & State Scheduler

> **Discipline:** Select exactly ONE highest-priority task per turn. Implement, run verification tests, record learnings, and check \`[x]\`.

## 1. Specification & Objective
$PROMPT

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

INITIAL_TASK_COUNT=$(grep -Ec "^[[:space:]]*- \[([ xX])\]" "$PLAN_FILE" || echo "3")

cat <<EOF > "$STATE_FILE"
ITERATION=1
MAX_ITERATIONS=$MAX_ITERATIONS
COMPLETION_PROMISE=$COMPLETION_PROMISE
TEST_COMMAND=$TEST_CMD
INITIAL_TASK_COUNT=$INITIAL_TASK_COUNT
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "Ralph loop initialized (Iteration 1, Max: ${MAX_ITERATIONS:-unlimited}, Promise: ${COMPLETION_PROMISE:-none})"
