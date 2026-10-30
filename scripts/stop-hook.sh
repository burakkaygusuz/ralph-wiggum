#!/usr/bin/env bash
set -euo pipefail
umask 077

RAW_INPUT="$(cat || true)"
HOOK_DIR="$(printf '%s' "$RAW_INPUT" | jq -r '.cwd // .workspacePaths[0] // empty' 2>/dev/null || true)"
cd "${HOOK_DIR:-.}" 2>/dev/null || exit 0

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$PROJECT_ROOT"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"
PLAN_FILE="$STATE_DIR/fix_plan.md"

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

command -v jq >/dev/null || { echo "Ralph loop: jq is required by the stop hook." >&2; exit 1; }

# TEST_COMMAND is read from this file and executed on every stop, so refuse a state file another user owns
if [[ ! -O "$STATE_FILE" ]]; then
  echo "Ralph loop: refusing $STATE_FILE because it is not owned by the current user." >&2
  exit 0
fi

if [[ -n "$(git ls-files ':(icase).ralph')" ]]; then
  echo "Ralph loop: refusing $STATE_DIR because it is tracked by git." >&2
  exit 0
fi

# The headless CLI advances the loop itself; the plugin hook must not run during its agent calls.
CLI_PID="$(cat "$STATE_DIR/cli.pid" 2>/dev/null || true)"
if [[ -z "${RALPH_CLI:-}" && -n "$CLI_PID" ]] && kill -0 "$CLI_PID" 2>/dev/null; then
  exit 0
fi

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

acquire_lock
trap 'rm -rf "$STATE_DIR/.lock" 2>/dev/null || true' EXIT

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

ITERATION=1
MAX_ITERATIONS=10
COMPLETION_PROMISE=""
TEST_COMMAND=""
BASE_COMMIT=""
INITIAL_TASK_COUNT=1
STARTED_AT=""

while IFS="=" read -r key val || [[ -n "$key" ]]; do
  case "$key" in
    ITERATION) [[ "$val" =~ ^[0-9]+$ ]] && ITERATION="$val" ;;
    MAX_ITERATIONS) [[ "$val" =~ ^[0-9]+$ ]] && MAX_ITERATIONS="$val" ;;
    COMPLETION_PROMISE) COMPLETION_PROMISE="$val" ;;
    TEST_COMMAND) TEST_COMMAND="$val" ;;
    BASE_COMMIT) BASE_COMMIT="$val" ;;
    INITIAL_TASK_COUNT) [[ "$val" =~ ^[0-9]+$ ]] && INITIAL_TASK_COUNT="$val" ;;
    STARTED_AT) STARTED_AT="$val" ;;
  esac
done < "$STATE_FILE"

IS_ANTIGRAVITY="$(printf '%s' "$RAW_INPUT" | jq -r 'has("executionNum")' 2>/dev/null || true)"
LAST_MSG="$(printf '%s' "$RAW_INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)"

has_exact_promise() {
  local text="$1"
  local expected="$2"
  [[ -z "$expected" ]] && return 1

  printf "%s\n" "$text" | awk -v expected="$expected" '
    BEGIN { matched = 0 }
    {
      while (match($0, /<promise>[[:space:]]*[^<]*[[:space:]]*<\/promise>/)) {
        block = substr($0, RSTART, RLENGTH)
        val = block
        sub(/^<promise>[[:space:]]*/, "", val)
        sub(/[[:space:]]*<\/promise>$/, "", val)
        if (val == expected) {
          matched = 1
          exit 0
        }
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
    END { exit(matched ? 0 : 1) }
  '
}

has_unchecked_items() {
  local plan_file="$1"
  [[ ! -f "$plan_file" ]] && return 1
  if grep -Eq "^[[:space:]]*- \[ \]" "$plan_file"; then
    return 0
  else
    return 1
  fi
}

TEST_FEEDBACK=""
TEST_STATUS=0

if [[ -n "$TEST_COMMAND" ]]; then
  TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
  set +e
  TEST_OUTPUT=$(${TIMEOUT_CMD:+"$TIMEOUT_CMD" 120} bash -c "$TEST_COMMAND" 2>&1)
  TEST_STATUS=$?
  set -e

  if [[ "$TEST_STATUS" -ne 0 ]]; then
    TEST_FEEDBACK=$'\n\n'"[Automated Verification Failed for '$TEST_COMMAND']:"$'\n'"$TEST_OUTPUT"
  else
    TEST_FEEDBACK=$'\n\n'"[Automated Verification Passed for '$TEST_COMMAND' (Exit code: 0)]"
  fi
fi

TEST_PATH_RE='(^|/)(tests?|__tests__|specs?)/|(^|/)test_[^/]*\.py$|[._](test|spec)\.|(Test|Tests)\.(java|kt|cs)$'
if ! DELETED_FILES="$(git -c core.quotePath=false diff --no-renames --name-only --diff-filter=D "$BASE_COMMIT")"; then
  DELETED_TESTS="unknown (git diff against $BASE_COMMIT failed)"
else
  DELETED_TESTS="$(grep -E "$TEST_PATH_RE" <<< "$DELETED_FILES" || true)"
fi
if [[ -n "$DELETED_TESTS" ]]; then
  TEST_FEEDBACK+=$'\n\n'"[Test Integrity Guard Alert: Existing test files were deleted: $DELETED_TESTS. Revert deletions and fix application code.]"
fi

TOTAL_TASKS=$(grep -Ec "^[[:space:]]*- \[([ xX])\]" "$PLAN_FILE" 2>/dev/null || true)
TOTAL_TASKS=${TOTAL_TASKS:-0}
if [[ "$TOTAL_TASKS" -lt "$INITIAL_TASK_COUNT" ]]; then
  TEST_FEEDBACK+=$'\n\n'"[Plan Integrity Guard Alert: Work items were deleted from fix_plan.md ($TOTAL_TASKS < $INITIAL_TASK_COUNT). Restore required tasks.]"
fi

PROMISE_MATCHED=false
if [[ -n "$COMPLETION_PROMISE" ]]; then
  if has_exact_promise "$LAST_MSG" "$COMPLETION_PROMISE"; then
    PROMISE_MATCHED=true
  fi
else
  if has_exact_promise "$LAST_MSG" "COMPLETE" || has_exact_promise "$LAST_MSG" "DONE"; then
    PROMISE_MATCHED=true
  fi
fi

if [ "$PROMISE_MATCHED" = true ] && [ "$TEST_STATUS" -eq 0 ] && [[ -z "$DELETED_TESTS" ]] && [[ "$TOTAL_TASKS" -ge "$INITIAL_TASK_COUNT" ]]; then
  if ! has_unchecked_items "$PLAN_FILE"; then
    echo "Ralph loop: Verified with test command '$TEST_COMMAND' and all plan items complete!" >&2
    rm -rf "$STATE_DIR"
    if [ "$IS_ANTIGRAVITY" = true ]; then
      echo '{"decision": "stop"}'
    else
      echo '{"decision": "allow"}'
    fi
    exit 0
  else
    TEST_FEEDBACK+=$'\n\n'"[Notice: Verification passed, but unchecked work items remain in fix_plan.md. Complete all tasks before exiting.]"
  fi
fi

if [[ "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
  echo "Ralph loop: Max iterations ($MAX_ITERATIONS) reached without satisfying completion criteria." >&2
  rm -rf "$STATE_DIR"
  if [ "$IS_ANTIGRAVITY" = true ]; then
    echo '{"decision": "stop"}'
  else
    echo '{"decision": "allow"}'
  fi
  exit 0
fi

NEXT_ITER=$((ITERATION + 1))

cat > "$STATE_FILE.tmp" <<EOF
ITERATION=$NEXT_ITER
MAX_ITERATIONS=$MAX_ITERATIONS
COMPLETION_PROMISE=$COMPLETION_PROMISE
TEST_COMMAND=$TEST_COMMAND
BASE_COMMIT=$BASE_COMMIT
INITIAL_TASK_COUNT=$INITIAL_TASK_COUNT
STARTED_AT=$STARTED_AT
EOF
mv "$STATE_FILE.tmp" "$STATE_FILE"

GIT_PARTS=""
GIT_STATUS="$(git status --short 2>/dev/null || true)"
GIT_DIFF="$(git diff --stat 2>/dev/null || true)"
GIT_CACHED="$(git diff --cached --stat 2>/dev/null || true)"

if [[ -n "$GIT_STATUS" ]]; then
  GIT_PARTS+=$'Working Tree:\n'"$GIT_STATUS"$'\n\n'
fi
if [[ -n "$GIT_DIFF" ]]; then
  GIT_PARTS+=$'Unstaged Diff:\n'"$GIT_DIFF"$'\n\n'
fi
if [[ -n "$GIT_CACHED" ]]; then
  GIT_PARTS+=$'Staged Diff:\n'"$GIT_CACHED"$'\n\n'
fi

GIT_CTX=""
if [[ -n "$GIT_PARTS" ]]; then
  GIT_CTX=$'\n\n['"${GIT_PARTS%$'\n\n'}"$']'
fi

PLAN_BODY=""
if [[ -f "$PLAN_FILE" ]]; then
  PLAN_BODY="$(cat "$PLAN_FILE")"
fi

FEEDBACK="${PLAN_BODY}${GIT_CTX}${TEST_FEEDBACK}"

if [ "$IS_ANTIGRAVITY" = true ]; then
  jq -n --arg reason "$FEEDBACK" '{decision: "continue", reason: $reason}'
else
  if [[ "$MAX_ITERATIONS" -gt 0 ]]; then
    SYS_MSG="Ralph loop iteration $NEXT_ITER of $MAX_ITERATIONS"
  else
    SYS_MSG="Ralph loop iteration $NEXT_ITER"
  fi

  jq -n --arg reason "$FEEDBACK" --arg msg "$SYS_MSG" \
    '{decision: "block", reason: $reason, followup_message: $reason, systemMessage: $msg}'
fi
