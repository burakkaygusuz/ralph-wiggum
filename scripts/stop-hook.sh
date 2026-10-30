#!/usr/bin/env bash
set -euo pipefail
umask 077

# $1 names the host whose output contract applies; Cursor is the only one that reads followup_message
HOST="${1:-}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/json.sh"
RAW_INPUT="$(LC_ALL=C tr '\n' ' ' || true)"
# shortcut: paths are not JSON-decoded, so a cwd containing a backslash or quote (Windows paths) will not resolve
HOOK_DIR="$(printf '%s' "$RAW_INPUT" | json_raw cwd)"
[[ -n "$HOOK_DIR" ]] || HOOK_DIR="$(printf '%s' "$RAW_INPUT" | json_raw workspace_roots)"
cd "${HOOK_DIR:-${CLAUDE_PROJECT_DIR:-.}}" 2>/dev/null || exit 0

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$PROJECT_ROOT"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"
PLAN_FILE="$STATE_DIR/fix_plan.md"

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

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
# Gated by the environment, not cli.pid: the agent can write files, so it could write its own PID there.
if [[ -n "${RALPH_CLI_AGENT:-}" ]]; then
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
SESSION_ID=""

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" == *=* ]] || continue
  key="${line%%=*}"
  val="${line#*=}"
  case "$key" in
    ITERATION) [[ "$val" =~ ^[0-9]+$ ]] && ITERATION="$val" ;;
    MAX_ITERATIONS) [[ "$val" =~ ^[0-9]+$ ]] && MAX_ITERATIONS="$val" ;;
    COMPLETION_PROMISE) COMPLETION_PROMISE="$val" ;;
    TEST_COMMAND) TEST_COMMAND="$val" ;;
    BASE_COMMIT) BASE_COMMIT="$val" ;;
    INITIAL_TASK_COUNT) [[ "$val" =~ ^[0-9]+$ ]] && INITIAL_TASK_COUNT="$val" ;;
    STARTED_AT) STARTED_AT="$val" ;;
    SESSION_ID) SESSION_ID="$val" ;;
  esac
done < "$STATE_FILE"

# Promises are matched on the raw JSON content, not a decoded copy: undo the escapes hosts apply to < > / and whitespace.
# Go-style JSON encoders emit \u003c and \u003e. Setup rejects promises whose raw form differs from their text.
LAST_MSG="$(printf '%s' "$RAW_INPUT" | json_raw last_assistant_message | LC_ALL=C sed 's/\\u003[cC]/</g;s/\\u003[eE]/>/g;s/\\\//\//g;s/\\[ntr]/ /g')"

# The loop belongs to the first session that stops in it. Payloads without session_id (headless CLI, other hosts) are not bound.
PAYLOAD_SESSION_ID="$(printf '%s' "$RAW_INPUT" | json_raw session_id)"
if [[ -n "$PAYLOAD_SESSION_ID" ]]; then
  if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="$PAYLOAD_SESSION_ID"
  elif [[ "$PAYLOAD_SESSION_ID" != "$SESSION_ID" ]]; then
    echo "Ralph loop: bound to session $SESSION_ID, ignoring this session. Run setup-ralph-loop.sh --force to rebind, or cancel-ralph.sh to end the loop." >&2
    exit 0
  fi
fi

# Cursor reports how the run ended; an aborted run neither verifies nor advances the loop
if [[ "$HOST" == cursor ]]; then
  RUN_STATUS="$(printf '%s' "$RAW_INPUT" | json_raw status)"
  if [[ -n "$RUN_STATUS" && "$RUN_STATUS" != completed ]]; then
    echo '{}'
    exit 0
  fi
fi

has_exact_promise() {
  local text="$1"
  local expected="$2"
  [[ -z "$expected" ]] && return 1

  printf "%s\n" "$text" | LC_ALL=C awk -v expected="$expected" '
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

# Final stdout when the loop ends: Cursor reads only followup_message, so it gets {}; other hosts show the notice to the user
end_output() {
  if [[ "$HOST" == cursor ]]; then echo '{}'; else printf '{"systemMessage":%s}\n' "$(printf '%s' "$MSG" | json_str)"; fi
}

# shortcut: state.env is writable by the agent, so TEST_COMMAND runs with whatever the agent wrote there. Full fix needs state outside the agent's writable scope (e.g. a sandbox deny rule on .ralph/state.env).
if [[ -n "$TEST_COMMAND" ]]; then
  TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
  set +e
  TEST_OUTPUT=$(${TIMEOUT_CMD:+"$TIMEOUT_CMD" 120} bash -c "$TEST_COMMAND" 2>&1)
  TEST_STATUS=$?
  set -e
  if [[ ${#TEST_OUTPUT} -gt 30000 ]]; then TEST_OUTPUT=${TEST_OUTPUT: -30000}; fi # keep the tail; failures print last

  if [[ "$TEST_STATUS" -ne 0 ]]; then
    TEST_FEEDBACK=$'\n\n'"[Automated Verification Failed for '$TEST_COMMAND']:"$'\n'"$TEST_OUTPUT"
  else
    TEST_FEEDBACK=$'\n\n'"[Automated Verification Passed for '$TEST_COMMAND' (Exit code: 0)]"
  fi
fi

TEST_PATH_RE='(^|/)(tests?|__tests__|specs?)/|(^|/)test_[^/]*\.py$|[._](test|spec)\.|(Test|Tests)\.(java|kt|cs)$'
# BASE_COMMIT is agent-writable state: a value like --output=FILE must never reach git as an option
if [[ ! "$BASE_COMMIT" =~ ^[0-9a-f]{7,64}$ ]] || ! DELETED_FILES="$(git -c core.quotePath=false diff --no-renames --name-only --diff-filter=D "$BASE_COMMIT" --)"; then
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
    MSG="Ralph loop: Verified${TEST_COMMAND:+ with test command '$TEST_COMMAND'} and all plan items complete!"
    echo "$MSG" >&2
    rm -rf "$STATE_DIR"
    end_output
    exit 0
  else
    TEST_FEEDBACK+=$'\n\n'"[Notice: Verification passed, but unchecked work items remain in fix_plan.md. Complete all tasks before exiting.]"
  fi
fi

if [[ "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
  MSG="Ralph loop: Max iterations ($MAX_ITERATIONS) reached without satisfying completion criteria."
  echo "$MSG" >&2
  rm -rf "$STATE_DIR"
  end_output
  exit 0
fi

NEXT_ITER=$((ITERATION + 1))

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

if [[ "$MAX_ITERATIONS" -gt 0 ]]; then
  SYS_MSG="Ralph loop iteration $NEXT_ITER of $MAX_ITERATIONS"
else
  SYS_MSG="Ralph loop iteration $NEXT_ITER"
fi

# Feedback goes through stdin: a command-line argument is capped by the OS (~128 KiB on Linux)
if [[ "$HOST" == cursor ]]; then
  RESULT="{\"followup_message\":$(printf '%s' "$FEEDBACK" | json_str)}"
else
  [[ -z "${RALPH_FEEDBACK_FILE:-}" ]] || printf '%s' "$FEEDBACK" > "$RALPH_FEEDBACK_FILE"
  RESULT="{\"decision\":\"block\",\"reason\":$(printf '%s' "$FEEDBACK" | json_str),\"systemMessage\":$(printf '%s' "$SYS_MSG" | json_str)}"
fi

# Advance only after the output is built, so a failed build cannot leave the loop advanced with no feedback
cat > "$STATE_FILE.tmp" <<EOF
ITERATION=$NEXT_ITER
MAX_ITERATIONS=$MAX_ITERATIONS
COMPLETION_PROMISE=$COMPLETION_PROMISE
TEST_COMMAND=$TEST_COMMAND
BASE_COMMIT=$BASE_COMMIT
INITIAL_TASK_COUNT=$INITIAL_TASK_COUNT
STARTED_AT=$STARTED_AT
SESSION_ID=$SESSION_ID
EOF
mv "$STATE_FILE.tmp" "$STATE_FILE"

printf '%s\n' "$RESULT"
