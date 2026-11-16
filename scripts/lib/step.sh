# shellcheck shell=bash disable=SC2034 # the sourcing scripts use these variables
# Shared by stop-hook.sh and ralph-cli.sh. Callers set STATE_DIR, STATE_FILE and PLAN_FILE, run in the project root, and call lock_state first.
TEST_TIMEOUT=120
LOCK_WAIT=125

check_state_safe() {
  if [[ ! -O "$STATE_FILE" ]]; then
    echo "Ralph loop: refusing $STATE_FILE because it is not owned by the current user." >&2
    return 1
  fi

  if [[ -L "$STATE_FILE" || -L "$PLAN_FILE" ]]; then
    echo "Ralph loop: refusing $STATE_DIR because state or plan is a symlink." >&2
    return 1
  fi

  if [[ -n "$(git ls-files ':(icase).ralph')" ]]; then
    echo "Ralph loop: refusing $STATE_DIR because it is tracked by git." >&2
    return 1
  fi
}

# acquire_lock: returns 1 when the state dir vanished while waiting. Callers release with release_lock.
LOCK_HELD=""
acquire_lock() {
  local lock_dir="$STATE_DIR/.lock"
  local tries=0
  while :; do
    mkdir "$lock_dir" 2>/dev/null && break
    [[ -d "$STATE_DIR" ]] || return 1
    sleep 0.05
    tries=$((tries + 1))
    if [ "$tries" -ge $((LOCK_WAIT * 20)) ]; then # 20 tries per second
      rm -rf "$lock_dir" 2>/dev/null || true
      mkdir "$lock_dir" 2>/dev/null || true
      break
    fi
  done
  LOCK_HELD=1
}

release_lock() {
  [[ -z "$LOCK_HELD" ]] || rm -rf "$STATE_DIR/.lock" 2>/dev/null || true
  LOCK_HELD=""
}

# lock_state: take the lock, then load the state. Returns 1 when the state is gone; the lock stays held until release_lock.
lock_state() {
  acquire_lock || return 1
  [[ -f "$STATE_FILE" ]] || return 1
  read_state
}

# ralph_step: decide one loop turn from what is on disk: the loop is done when the tests pass, no test file was deleted
# and every plan item is checked.
# Returns 0 verified (state removed), 4 iteration limit reached (state removed), 3 continue (call ralph_advance next).
# Sets MSG on 0 and 4, and FEEDBACK, SYS_MSG and NEXT_ITER on 3. MSG is also printed to stderr.
# Runs inside `||` at the callers, so set -e is off here: failures return 1 explicitly.
ralph_step() {
  local part out
  local TEST_FEEDBACK="" TEST_STATUS=0

  # shortcut: state.env is writable by the agent, so TEST_COMMAND runs with whatever the agent wrote there. Full fix needs state outside the agent's writable scope (e.g. a sandbox deny rule on .ralph/state.env).
  if [[ -n "$TEST_COMMAND" ]]; then
    TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
    TEST_OUTPUT=$(${TIMEOUT_CMD:+"$TIMEOUT_CMD" "$TEST_TIMEOUT"} bash -c "$TEST_COMMAND" </dev/null 2>&1 | tail -c 120000) # pipefail keeps the test status; bounds memory
    TEST_STATUS=$?
    if [[ ${#TEST_OUTPUT} -gt 30000 ]]; then TEST_OUTPUT=${TEST_OUTPUT: -30000}; fi # keep the tail; failures print last

    if [[ "$TEST_STATUS" -ne 0 ]]; then
      TEST_FEEDBACK=$'\n\n'"[Automated Verification Failed for '$TEST_COMMAND' (exit code $TEST_STATUS$([[ "$TEST_STATUS" -ne 124 ]] || echo ", timed out after $TEST_TIMEOUT s"))]:"$'\n'"$TEST_OUTPUT"
    else
      TEST_FEEDBACK=$'\n\n'"[Automated Verification Passed for '$TEST_COMMAND' (Exit code: 0)]"
    fi
  fi

  local TEST_PATH_RE='(^|/)(tests?|__tests__|specs?)/|(^|/)test_[^/]*\.py$|[._](test|spec)\.|(Test|Tests)\.(java|kt|cs)$'
  # BASE_COMMIT is agent-writable state: a value like --output=FILE must never reach git as an option
  if [[ ! "$BASE_COMMIT" =~ ^[0-9a-f]{7,64}$ ]] || ! DELETED_FILES="$(git -c core.quotePath=false diff -M --name-status --diff-filter=DR "$BASE_COMMIT" --)"; then
    DELETED_TESTS="unknown (git diff against $BASE_COMMIT failed)"
  else
    DELETED_TESTS=""
    while IFS=$'\t' read -r status old new; do
      [[ "$old" =~ $TEST_PATH_RE ]] || continue
      [[ "$status" == R* && "$new" =~ $TEST_PATH_RE && "${old##*/}" == "${new##*/}" ]] && continue
      DELETED_TESTS+="$old"$'\n'
    done <<< "$DELETED_FILES"
    DELETED_TESTS="${DELETED_TESTS%$'\n'}"
  fi
  if [[ -n "$DELETED_TESTS" ]]; then
    TEST_FEEDBACK+=$'\n\n'"[Test Integrity Guard Alert: Existing test files were deleted: $DELETED_TESTS. Revert deletions and fix application code.]"
  fi

  TOTAL_TASKS=$(grep -Ec "^[[:space:]]*- \[([ xX])\]" "$PLAN_FILE" 2>/dev/null || true)
  TOTAL_TASKS=${TOTAL_TASKS:-0}
  if [[ "$TOTAL_TASKS" -lt "$INITIAL_TASK_COUNT" ]]; then
    TEST_FEEDBACK+=$'\n\n'"[Plan Integrity Guard Alert: Work items were deleted from fix_plan.md ($TOTAL_TASKS < $INITIAL_TASK_COUNT). Restore required tasks.]"
  fi

  if [ "$TEST_STATUS" -eq 0 ] && [[ -z "$DELETED_TESTS" ]] && [[ "$TOTAL_TASKS" -ge "$INITIAL_TASK_COUNT" ]] && ! grep -Eq "^[[:space:]]*- \[ \]" "$PLAN_FILE" 2>/dev/null; then
    MSG="Ralph loop: Verified${TEST_COMMAND:+ with test command '$TEST_COMMAND'} and all plan items complete!"
    echo "$MSG" >&2
    rm -f "$STATE_FILE" || return 1 # keep the plan so the user can review it
    return 0
  fi

  if [[ "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
    MSG="Ralph loop: Max iterations ($MAX_ITERATIONS) reached without satisfying completion criteria."
    echo "$MSG" >&2
    rm -f "$STATE_FILE" || return 1
    return 4
  fi

  NEXT_ITER=$((ITERATION + 1))

  local GIT_PARTS=""
  for part in "Working Tree:status --short" "Unstaged Diff:diff --stat" "Staged Diff:diff --cached --stat"; do
    # shellcheck disable=SC2086 # the subcommand and its flags must split
    out="$(git ${part#*:} 2>/dev/null | head -n 200 || true)"
    [[ -z "$out" ]] || GIT_PARTS+="${part%%:*}:"$'\n'"$out"$'\n\n'
  done
  local GIT_CTX=""
  [[ -z "$GIT_PARTS" ]] || GIT_CTX=$'\n\n['"${GIT_PARTS%$'\n\n'}"$']'

  SYS_MSG="Ralph loop iteration $NEXT_ITER"
  if [[ "$MAX_ITERATIONS" -gt 0 ]]; then SYS_MSG+=" of $MAX_ITERATIONS"; fi

  FEEDBACK="[$SYS_MSG]"$'\n\n'"$(cat "$PLAN_FILE" 2>/dev/null || true)${GIT_CTX}${TEST_FEEDBACK}"

  return 3
}

# ralph_advance: write the next iteration to the state. Call it after the continue output is built, so a failed build cannot leave the loop advanced with no feedback.
ralph_advance() {
  local STATE_TMP
  STATE_TMP="$(mktemp "$STATE_DIR/state.XXXXXX")" || return 1
  cat > "$STATE_TMP" <<STATE || return 1
ITERATION=$NEXT_ITER
MAX_ITERATIONS=$MAX_ITERATIONS
TEST_COMMAND=$TEST_COMMAND
BASE_COMMIT=$BASE_COMMIT
INITIAL_TASK_COUNT=$INITIAL_TASK_COUNT
STARTED_AT=$STARTED_AT
SESSION_ID=$SESSION_ID
STATE
  mv "$STATE_TMP" "$STATE_FILE"
}
