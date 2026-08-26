#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"
PLAN_FILE="$STATE_DIR/fix_plan.md"

if [[ ! -f "$STATE_FILE" ]]; then
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

release_lock() {
  rm -rf "$STATE_DIR/.lock" 2>/dev/null || true
}

acquire_lock

if [[ ! -f "$STATE_FILE" ]]; then
  release_lock
  exit 0
fi

ITERATION=1
MAX_ITERATIONS=25
COMPLETION_PROMISE=""
TEST_COMMAND=""
INITIAL_TASK_COUNT=1
STARTED_AT=""

while IFS="=" read -r key val || [[ -n "$key" ]]; do
  case "$key" in
    ITERATION) [[ "$val" =~ ^[0-9]+$ ]] && ITERATION="$val" ;;
    MAX_ITERATIONS) [[ "$val" =~ ^[0-9]+$ ]] && MAX_ITERATIONS="$val" ;;
    COMPLETION_PROMISE) COMPLETION_PROMISE="$val" ;;
    TEST_COMMAND) TEST_COMMAND="$val" ;;
    INITIAL_TASK_COUNT) [[ "$val" =~ ^[0-9]+$ ]] && INITIAL_TASK_COUNT="$val" ;;
    STARTED_AT) STARTED_AT="$val" ;;
  esac
done < "$STATE_FILE"

RAW_INPUT="$(cat || true)"

IS_ANTIGRAVITY=false
if echo "$RAW_INPUT" | grep -Eq '"executionNum"|"fullyIdle"'; then
  IS_ANTIGRAVITY=true
fi

NORMALIZED_INPUT="$(printf "%s" "$RAW_INPUT" | sed 's/\\</</g; s/\\>/>/g; s/\\"/\"/g; s/\\n/ /g')"

TRANSCRIPT_PATH=$(echo "$RAW_INPUT" | sed -n -E 's/.*"(transcriptPath|transcript_path|TranscriptPath)":[[:space:]]*"([^"]*)".*/\2/p')
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
  TRANSCRIPT_TAIL=$(tail -n 50 "$TRANSCRIPT_PATH" 2>/dev/null || true)
  NORMALIZED_INPUT="$NORMALIZED_INPUT $(printf "%s" "$TRANSCRIPT_TAIL" | sed 's/\\</</g; s/\\>/>/g; s/\\"/\"/g; s/\\n/ /g')"
fi

PLAN_CONTENT=""
if [[ -f "$PLAN_FILE" ]]; then
  PLAN_CONTENT=$(cat "$PLAN_FILE")
  NORMALIZED_INPUT="$NORMALIZED_INPUT $(printf "%s" "$PLAN_CONTENT" | sed 's/\\</</g; s/\\>/>/g; s/\\"/\"/g; s/\\n/ /g')"
fi

LATEST_COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null || true)
if [[ -n "$LATEST_COMMIT_MSG" ]]; then
  NORMALIZED_INPUT="$NORMALIZED_INPUT $LATEST_COMMIT_MSG"
fi

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

# Execute hard backpressure on EVERY turn if TEST_COMMAND is provided
if [[ -n "$TEST_COMMAND" ]]; then
  set +e
  if command -v timeout >/dev/null 2>&1; then
    TEST_OUTPUT=$(timeout 120 bash -c "$TEST_COMMAND" 2>&1)
    TEST_STATUS=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    TEST_OUTPUT=$(gtimeout 120 bash -c "$TEST_COMMAND" 2>&1)
    TEST_STATUS=$?
  else
    TEST_OUTPUT=$(bash -c "$TEST_COMMAND" 2>&1)
    TEST_STATUS=$?
  fi
  set -e

  if [[ "$TEST_STATUS" -ne 0 ]]; then
    TEST_FEEDBACK=$'\n\n'"[Automated Verification Failed for '$TEST_COMMAND']:"$'\n'"$TEST_OUTPUT"
  else
    TEST_FEEDBACK=$'\n\n'"[Automated Verification Passed for '$TEST_COMMAND' (Exit code: 0)]"
  fi
fi

# Anti-Cheating & Integrity Guard: Detect deleted/tampered test files
DELETED_TESTS=$(git status --short 2>/dev/null | grep -E "^[[:space:]]*D[[:space:]]+.*(test|spec).*" || true)
if [[ -n "$DELETED_TESTS" ]]; then
  TEST_FEEDBACK+=$'\n\n'"[Test Integrity Guard Alert: Existing test files were deleted: $DELETED_TESTS. Revert deletions and fix application code.]"
fi

# Plan Integrity Guard: Count total and completed items
TOTAL_TASKS=$(grep -Ec "^[[:space:]]*- \[([ xX])\]" "$PLAN_FILE" 2>/dev/null || echo "0")
if [[ "$TOTAL_TASKS" -lt "$INITIAL_TASK_COUNT" ]]; then
  TEST_FEEDBACK+=$'\n\n'"[Plan Integrity Guard Alert: Work items were deleted from fix_plan.md ($TOTAL_TASKS < $INITIAL_TASK_COUNT). Restore required tasks.]"
fi

PROMISE_MATCHED=false
if [[ -n "$COMPLETION_PROMISE" ]]; then
  if has_exact_promise "$NORMALIZED_INPUT" "$COMPLETION_PROMISE"; then
    PROMISE_MATCHED=true
  fi
else
  if has_exact_promise "$NORMALIZED_INPUT" "COMPLETE" || has_exact_promise "$NORMALIZED_INPUT" "DONE"; then
    PROMISE_MATCHED=true
  fi
fi

# 1. First: Evaluate completion criteria for the current turn
if [ "$PROMISE_MATCHED" = true ] && [ "$TEST_STATUS" -eq 0 ] && [[ -z "$DELETED_TESTS" ]] && [[ "$TOTAL_TASKS" -ge "$INITIAL_TASK_COUNT" ]]; then
  if ! has_unchecked_items "$PLAN_FILE"; then
    echo "Ralph loop: Verified with test command '$TEST_COMMAND' and all plan items complete!" >&2
    release_lock
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

# 2. Second: If not completed, evaluate if max iterations has been reached
if [[ "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
  echo "Ralph loop: Max iterations ($MAX_ITERATIONS) reached without satisfying completion criteria." >&2
  release_lock
  rm -rf "$STATE_DIR"
  if [ "$IS_ANTIGRAVITY" = true ]; then
    echo '{"decision": "stop"}'
  else
    echo '{"decision": "allow"}'
  fi
  exit 0
fi

# 3. Third: Advance iteration and feed back
NEXT_ITER=$((ITERATION + 1))

cat <<EOF > "$STATE_FILE.tmp"
ITERATION=$NEXT_ITER
MAX_ITERATIONS=$MAX_ITERATIONS
COMPLETION_PROMISE=$COMPLETION_PROMISE
TEST_COMMAND=$TEST_COMMAND
INITIAL_TASK_COUNT=$INITIAL_TASK_COUNT
STARTED_AT=$STARTED_AT
EOF
mv "$STATE_FILE.tmp" "$STATE_FILE"

release_lock

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

json_escape() {
  awk '
    BEGIN { first = 1 }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\r/, "")
      gsub(/\t/, "\\t")
      if (!first) {
        printf "\\n"
      }
      printf "%s", $0
      first = 0
    }
  '
}

ESC_FEEDBACK="$(printf "%s" "$FEEDBACK" | json_escape)"

if [ "$IS_ANTIGRAVITY" = true ]; then
  cat <<EOF
{
  "decision": "continue",
  "reason": "$ESC_FEEDBACK"
}
EOF
else
  if [[ "$MAX_ITERATIONS" -gt 0 ]]; then
    SYS_MSG="Ralph loop iteration $NEXT_ITER of $MAX_ITERATIONS"
  else
    SYS_MSG="Ralph loop iteration $NEXT_ITER"
  fi

  cat <<EOF
{
  "decision": "block",
  "reason": "$ESC_FEEDBACK",
  "followup_message": "$ESC_FEEDBACK",
  "systemMessage": "$SYS_MSG"
}
EOF
fi
