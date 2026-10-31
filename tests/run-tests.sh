#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset CLAUDE_PROJECT_DIR RALPH_FEEDBACK_FILE
unset RALPH_CLI_AGENT # hermetic: an inherited value would silence the hook in every test
command -v jq >/dev/null || { echo "Error: the test suite needs jq to check hook output (the plugin itself does not)." >&2; exit 1; }

PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  printf "  - %-65s " "$name"
  local log_file
  log_file=$(mktemp)
  # errexit must be active inside the test; `if`/`||` contexts would disable it and only the last command would count
  set +e
  (
    set -e
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    cd "$dir"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q .
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
    "$@"
  ) >"$log_file" 2>&1
  local status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "[OK]"
    PASSED=$((PASSED + 1))
  else
    echo "[FAILED]"
    cat "$log_file"
    FAILED=$((FAILED + 1))
  fi
  rm -f "$log_file"
}

test_setup_and_defaults() {
  "$ROOT/scripts/setup-ralph-loop.sh" "CI test task" --completion-promise "CI_DONE"
  test -f .ralph/state.env
  test -f .ralph/fix_plan.md
  grep -q "ITERATION=1" .ralph/state.env
  grep -q "MAX_ITERATIONS=10" .ralph/state.env
  grep -q "COMPLETION_PROMISE=CI_DONE" .ralph/state.env
  grep -q "INITIAL_TASK_COUNT=3" .ralph/state.env
  test "$(ls -l .ralph/state.env | cut -c1-10)" = "-rw-------"
  grep -q "Ralph Implementation Plan & State Scheduler" .ralph/fix_plan.md
  grep -q "Working Memory & Cross-Turn Learnings" .ralph/fix_plan.md
}

test_completion_promise_in_agent_prompt() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Prompt promise task" --completion-promise "PROMPT_DONE"
  grep -qF "<promise>PROMPT_DONE</promise>" .ralph/fix_plan.md
}

test_marketplace_manifests() {
  test -f "$ROOT/.agents/plugins/marketplace.json"
  test -f "$ROOT/.claude-plugin/marketplace.json"
  test -f "$ROOT/.claude-plugin/plugin.json"
  test -f "$ROOT/.codex-plugin/plugin.json"
  jq -e '.name == "ralph-wiggum" and .plugins[0].name == "ralph-wiggum" and .plugins[0].source == "./"' "$ROOT/.agents/plugins/marketplace.json" >/dev/null
  jq -e '.name == "ralph-wiggum" and .plugins[0].name == "ralph-wiggum" and .plugins[0].source == "./"' "$ROOT/.claude-plugin/marketplace.json" >/dev/null
  jq -e '.owner.name != null' "$ROOT/.claude-plugin/marketplace.json" >/dev/null
}

test_manifest_versions_match() {
  local manifest
  for manifest in .claude-plugin/plugin.json .codex-plugin/plugin.json; do
    jq -e --slurpfile other "$ROOT/$manifest" '.version == $other[0].version and .description == $other[0].description' "$ROOT/plugin.json" >/dev/null
  done
}

test_double_init_guard() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Active task" --completion-promise "DONE"
  if "$ROOT/scripts/setup-ralph-loop.sh" "Second concurrent attempt" 2>/dev/null; then
    return 1
  fi
  "$ROOT/scripts/setup-ralph-loop.sh" "Forced reinited task" --completion-promise "DONE" --force
}

test_no_relative_script_paths() {
  if grep -rn '\./scripts/' "$ROOT/skills" "$ROOT/scripts" "$ROOT/hooks"; then
    return 1
  fi
}

test_cli_feedback_propagation() {
  local agent="$PWD/agent.sh"
  cat << 'EOF' > "$agent"
#!/usr/bin/env bash
PROMPT_ARG="$2"
if ! echo "$PROMPT_ARG" | grep -q "Automated Verification Failed"; then
  echo "Mock Agent Turn 1: Wrote code with failing test"
else
  echo "Mock Agent Turn 2: Received test failure feedback! Fixing..."
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo "All fixed! <promise>CLI_FEEDBACK_DONE</promise>"
fi
EOF
  chmod +x "$agent"

  "$ROOT/scripts/setup-ralph-loop.sh" "Test CLI feedback" --max-iterations 3 --completion-promise "CLI_FEEDBACK_DONE" --test-cmd "! grep -q '^- \[ \]' .ralph/fix_plan.md" --force
  AGENT_BIN="$agent" "$ROOT/scripts/ralph-cli.sh"
  test ! -d .ralph
}

test_cli_max_iterations_fails() {
  local agent="$PWD/agent.sh" out
  printf '#!/usr/bin/env bash\necho "Mock agent turn without a promise"\n' > "$agent"
  chmod +x "$agent"
  "$ROOT/scripts/setup-ralph-loop.sh" "CLI max task" --max-iterations 1 --completion-promise "NEVER_EMITTED"
  if out=$(AGENT_BIN="$agent" "$ROOT/scripts/ralph-cli.sh" 2>&1); then
    return 1
  fi
  grep -qF "Max iterations (1) reached" <<< "$out"
  if grep -q "finished successfully" <<< "$out"; then
    return 1
  fi
}

test_claude_stop_hook() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Claude task" --completion-promise "CLAUDE_DONE"
  local res
  res=$(echo '{"last_assistant_message": "Working on steps..."}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$res" >/dev/null
  grep -q "ITERATION=2" .ralph/state.env

  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  res=$(echo '{"last_assistant_message": "Finished! <promise>CLAUDE_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e 'has("decision") | not' <<< "$res" >/dev/null
  test ! -d .ralph
}

test_nested_cwd_independence() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Nested CWD task" --max-iterations 3 --completion-promise "NESTED_DONE"
  mkdir -p src/nested/dir
  (
    cd src/nested/dir
    local nested_out
    nested_out=$(echo '{"last_assistant_message": "Working in nested dir"}' | "$ROOT/scripts/stop-hook.sh")
    jq -e '.decision == "block"' <<< "$nested_out" >/dev/null
  )
  test -f .ralph/state.env
  grep -q "ITERATION=2" .ralph/state.env
  "$ROOT/scripts/cancel-ralph.sh"
  rm -rf src/nested
}

test_single_iteration_max_completion() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Single turn task" --max-iterations 1 --completion-promise "SINGLE_DONE" --test-cmd "true"
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo '{"last_assistant_message": "Done on turn 1! <promise>SINGLE_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh"
  test ! -d .ralph
}

test_anti_cheating_and_plan_integrity() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Integrity test task" --max-iterations 3 --completion-promise "INTEGRITY_DONE"
  cat <<EOF > .ralph/fix_plan.md
- [x] Only 1 task
EOF
  local ch_out
  ch_out=$(echo '{"last_assistant_message": "Done! <promise>INTEGRITY_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "Plan Integrity Guard Alert" <<< "$ch_out"
  test -d .ralph
  "$ROOT/scripts/cancel-ralph.sh"
}

test_exact_literal_promise_matching() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Exact promise task" --max-iterations 3 --completion-promise "AUTH_V1.0"
  echo '{"last_assistant_message": "False match <promise>AUTH_V100</promise>"}' | "$ROOT/scripts/stop-hook.sh" >/dev/null
  test -d .ralph
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo '{"last_assistant_message": "Exact match <promise>AUTH_V1.0</promise>"}' | "$ROOT/scripts/stop-hook.sh"
  test ! -d .ralph
}

test_continuous_backpressure() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Backpressure task" --test-cmd "echo SUITE_\$((6*7)); exit 1"
  local fail_out
  fail_out=$(echo '{"last_assistant_message": "Just wrote some code"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "Automated Verification Failed" <<< "$fail_out"
  grep -q "SUITE_42" <<< "$fail_out"
  test -d .ralph
  "$ROOT/scripts/cancel-ralph.sh"
}

# Cursor's loop_limit is a second cap; null (no limit) leaves --max-iterations as the only one
test_cursor_loop_limit_is_unlimited() {
  jq -e '.hooks.stop[0] | has("loop_limit") and .loop_limit == null' "$ROOT/hooks/cursor-hooks.json" >/dev/null
}


test_promise_only_in_plan_does_not_complete() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Plan promise task" --max-iterations 3 --completion-promise "PLAN_ONLY"
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo "<promise>PLAN_ONLY</promise>" >> .ralph/fix_plan.md
  echo '{"last_assistant_message": "Still working on it"}' | "$ROOT/scripts/stop-hook.sh" >/dev/null
  test -d .ralph
  "$ROOT/scripts/cancel-ralph.sh"
}

test_zero_checkbox_plan_integrity() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Empty plan task" --max-iterations 3 --completion-promise "EMPTY_PLAN"
  printf '# Plan\nNo checkboxes left\n' > .ralph/fix_plan.md
  sed -i.bak 's/^INITIAL_TASK_COUNT=.*/INITIAL_TASK_COUNT=1/' .ralph/state.env
  local err_file hook_out
  err_file=$(mktemp)
  hook_out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh" 2>"$err_file")
  grep -q "Plan Integrity Guard Alert" <<< "$hook_out"
  test ! -s "$err_file"
  rm -f "$err_file"
  "$ROOT/scripts/cancel-ralph.sh"
}

test_deleted_test_integrity_guard() {
  mkdir tests
  echo 'exit 0' > tests/foo.sh
  echo 'export const inspector = 1;' > inspector.ts
  git add . && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "tests"
  "$ROOT/scripts/setup-ralph-loop.sh" "Deleted test task" --max-iterations 3 --completion-promise "DEL_DONE" >/dev/null

  rm inspector.ts
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  if grep -q "Test Integrity Guard Alert" <<< "$out"; then
    return 1
  fi

  rm tests/foo.sh
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "Test Integrity Guard Alert" <<< "$out"
}

test_moved_test_file_is_not_a_deletion() {
  mkdir tests
  echo 'exit 0' > tests/a.test.js
  git add . && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "tests"
  "$ROOT/scripts/setup-ralph-loop.sh" "Move test task" --max-iterations 5 >/dev/null
  mkdir tests/unit
  git mv tests/a.test.js tests/unit/a.test.js
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  if grep -q "Test Integrity Guard Alert" <<< "$out"; then return 1; fi
  git mv tests/unit/a.test.js notes.txt
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "Test Integrity Guard Alert" <<< "$out"
  git mv notes.txt tests/unit/a.test.js
  mkdir tests/off
  git mv tests/unit/a.test.js tests/off/a.test.js.disabled
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "Test Integrity Guard Alert" <<< "$out"
}

test_concurrent_hooks_are_serialized() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Lock task" --max-iterations 9 --test-cmd "sleep 1" >/dev/null
  echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh" >/dev/null &
  echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh" >/dev/null &
  wait
  grep -qx 'ITERATION=3' .ralph/state.env
}

test_failed_test_reports_exit_code() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Exit task" --max-iterations 5 --test-cmd "exit 3" >/dev/null
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.reason | contains("exit code 3") and startswith("[Ralph loop iteration 2 of 5]")' <<< "$out" >/dev/null
}

test_security_and_injection_resistance() {
  local marker="$PWD/bad_marker"
  if "$ROOT/scripts/setup-ralph-loop.sh" task --max-iterations "\$(touch $marker)" 2>/dev/null; then
    return 1
  fi
  test ! -f "$marker"
}

test_prompt_file_preserves_text_literally() {
  local marker="$PWD/marker"
  printf '%s\n' "Fix the user's \"login\" \\ path" "Injected \$(touch $marker) \`touch $marker\`" "RALPH_ARGS_EOF" > PROMPT.md
  git add PROMPT.md && git commit -qm "prompt"
  "$ROOT/scripts/setup-ralph-loop.sh" --prompt-file PROMPT.md --max-iterations 3
  test -f PROMPT.md
  test -z "$(git status --porcelain)"
  test ! -e "$marker"
  grep -qF "Fix the user's \"login\" \\ path" .ralph/fix_plan.md
  grep -qF "Injected \$(touch $marker) \`touch $marker\`" .ralph/fix_plan.md
  grep -qx "RALPH_ARGS_EOF" .ralph/fix_plan.md
}

test_prompt_file_empty_is_rejected() {
  : > prompt.md
  if "$ROOT/scripts/setup-ralph-loop.sh" --prompt-file prompt.md; then
    return 1
  fi
  test ! -f .ralph/state.env
}

test_prompt_file_missing_is_rejected() {
  if "$ROOT/scripts/setup-ralph-loop.sh" --prompt-file missing.md; then
    return 1
  fi
}

test_prompt_and_prompt_file_are_exclusive() {
  echo "task" > prompt.md
  if "$ROOT/scripts/setup-ralph-loop.sh" "inline task" --prompt-file prompt.md; then
    return 1
  fi
  test -f prompt.md
}

test_complex_quotes_and_arg_unpacking() {
  "$ROOT/scripts/setup-ralph-loop.sh" --completion-promise 'AUTH_DONE' --test-cmd 'npm test' fix bug
  test -f .ralph/state.env
  grep -q "COMPLETION_PROMISE=AUTH_DONE" .ralph/state.env
  grep -q "TEST_COMMAND=npm test" .ralph/state.env
  grep -q "Specification & Objective" .ralph/fix_plan.md
  grep -q "^fix bug$" .ralph/fix_plan.md
  local cancel_out
  cancel_out=$("$ROOT/scripts/cancel-ralph.sh")
  grep -q "Ralph loop canceled at iteration 1" <<< "$cancel_out"
  test ! -d .ralph
}

test_setup_requires_git_commit() {
  local plain
  plain=$(mktemp -d)
  if (cd "$plain" && "$ROOT/scripts/setup-ralph-loop.sh" "Outside git" 2>/dev/null); then
    return 1
  fi
  git -C "$plain" init -q
  if (cd "$plain" && "$ROOT/scripts/setup-ralph-loop.sh" "No commit yet" 2>/dev/null); then
    return 1
  fi
  rm -rf "$plain"
}

test_tracked_state_refused() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Tracked task" --completion-promise "TRACKED"
  git add -f .ralph
  git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "track state"
  if "$ROOT/scripts/setup-ralph-loop.sh" "Replacement" --completion-promise "TRACKED" --force 2>/dev/null; then
    return 1
  fi
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  test -z "$out"
  grep -q "ITERATION=1" .ralph/state.env
}

test_multiline_flags_rejected() {
  if "$ROOT/scripts/setup-ralph-loop.sh" "Multiline task" --test-cmd $'true\nfalse' 2>/dev/null; then
    return 1
  fi
  if "$ROOT/scripts/setup-ralph-loop.sh" "Multiline task" --completion-promise $'DONE\nX' 2>/dev/null; then
    return 1
  fi
  test ! -f .ralph/state.env
}

test_leading_zero_max_iterations_is_decimal() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Zero task" --max-iterations 09
  grep -q "^MAX_ITERATIONS=9$" .ralph/state.env
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh" 2>&1)
  jq -e '.decision == "block"' <<< "$out" >/dev/null
}

test_unlimited_and_untested_messages_are_clean() {
  local setup_out hook_out
  setup_out=$("$ROOT/scripts/setup-ralph-loop.sh" "Unlimited task" --max-iterations 0 --completion-promise "CLEAN_DONE")
  grep -qF "Max: unlimited" <<< "$setup_out"
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  hook_out=$(echo '{"last_assistant_message": "<promise>CLEAN_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh" 2>&1)
  grep -qF "Verified and all plan items" <<< "$hook_out"
  if grep -qF "''" <<< "$hook_out"; then
    return 1
  fi
}

test_baseline_commit_recorded() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Baseline task"
  grep -qF "BASE_COMMIT=$(git rev-parse HEAD)" .ralph/state.env
}

test_missing_plan_alert() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Missing plan task" --completion-promise "GONE"
  rm .ralph/fix_plan.md
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "Plan Integrity Guard Alert" <<< "$out"
}

test_promise_only_from_last_message() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Field task" --max-iterations 3 --completion-promise "FIELD_DONE"
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  local out
  out=$(echo '{"transcript": "<promise>FIELD_DONE</promise>", "last_assistant_message": "still going"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  test -d .ralph
}

test_grok_payload() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Grok task" --max-iterations 5 --completion-promise "GROK_DONE"
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  local out
  out=$(echo '{"reason": "shutdown", "lastAssistantMessage": "<promise>GROK_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh")
  test -z "$out"
  grep -q "^ITERATION=1$" .ralph/state.env
  out=$(echo '{"reason": "end_turn", "lastAssistantMessage": "working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  echo '{"sessionId": "grok-a", "reason": "end_turn", "lastAssistantMessage": "working"}' | "$ROOT/scripts/stop-hook.sh" >/dev/null
  grep -q "^SESSION_ID=.*grok-a" .ralph/state.env
  out=$(echo '{"sessionId": "grok-b", "reason": "end_turn", "lastAssistantMessage": "<promise>GROK_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh" 2>/dev/null)
  test -z "$out"
  test -d .ralph
  echo '{"reason": "end_turn", "lastAssistantMessage": "<promise>GROK_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh"
  test ! -d .ralph
}

test_antigravity_payload() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Agy task" --max-iterations 5
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  local repo="$PWD" elsewhere out
  elsewhere="$(mktemp -d)"
  out=$(cd "$elsewhere" && echo "{\"terminationReason\": \"error\", \"fullyIdle\": true, \"conversationId\": \"c1\", \"workspacePaths\": [\"$repo\"]}" | "$ROOT/scripts/stop-hook.sh" antigravity)
  test -z "$out"
  out=$(cd "$elsewhere" && echo "{\"terminationReason\": \"model_stop\", \"fullyIdle\": false, \"conversationId\": \"c1\", \"workspacePaths\": [\"$repo\"]}" | "$ROOT/scripts/stop-hook.sh" antigravity)
  test -z "$out"
  grep -q "^ITERATION=1$" .ralph/state.env
  echo '- [ ] open item' >> .ralph/fix_plan.md
  out=$(cd "$elsewhere" && echo "{\"terminationReason\": \"model_stop\", \"fullyIdle\": true, \"conversationId\": \"c1\", \"workspacePaths\": [\"$repo\"]}" | "$ROOT/scripts/stop-hook.sh" antigravity)
  jq -e '.decision == "continue" and (.reason | length > 0) and (has("followup_message") | not)' <<< "$out" >/dev/null
  grep -q "^SESSION_ID=.*c1" .ralph/state.env
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  out=$(cd "$elsewhere" && echo "{\"terminationReason\": \"model_stop\", \"fullyIdle\": true, \"conversationId\": \"c1\", \"workspacePaths\": [\"$repo\"]}" | "$ROOT/scripts/stop-hook.sh" antigravity)
  rm -rf "$elsewhere"
  jq -e '. == {}' <<< "$out" >/dev/null
  test ! -d .ralph
}

test_host_specific_block_schema() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Schema task" --max-iterations 3
  local claude_out cursor_out
  claude_out=$(echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block" and (has("followup_message") | not)' <<< "$claude_out" >/dev/null
  cursor_out=$(echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh" cursor)
  jq -e 'has("followup_message") and (has("decision") | not)' <<< "$cursor_out" >/dev/null
}

test_workspace_roots_locates_project() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Roots task" --max-iterations 3
  local repo="$PWD" elsewhere out
  elsewhere="$(mktemp -d)"
  out=$(cd "$elsewhere" && echo "{\"workspace_roots\": [\"$repo\"], \"last_assistant_message\": \"working\"}" | "$ROOT/scripts/stop-hook.sh" cursor)
  rm -rf "$elsewhere"
  jq -e 'has("followup_message")' <<< "$out" >/dev/null
}

test_large_test_output_is_fed_back() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Big output task" --max-iterations 3 --test-cmd "head -c 1200000 /dev/zero | tr '\0' x; exit 1"
  local out
  out=$(echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block" and (.reason | contains("Automated Verification Failed"))' <<< "$out" >/dev/null
  grep -q "^ITERATION=2$" .ralph/state.env
}

test_cli_large_agent_output_is_fed_back() {
  local agent="$PWD/agent.sh"
  cat > "$agent" <<'EOF'
#!/usr/bin/env bash
perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
head -c 1200000 /dev/zero | tr '\0' x
echo
echo "<promise>BIG_DONE</promise>"
EOF
  chmod +x "$agent"
  "$ROOT/scripts/setup-ralph-loop.sh" "CLI big task" --max-iterations 3 --completion-promise "BIG_DONE" >/dev/null
  AGENT_BIN="$agent" "$ROOT/scripts/ralph-cli.sh" >/dev/null 2>&1
  test ! -d .ralph
}

test_feedback_with_control_characters_is_valid_json() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Escape task" --max-iterations 3 --test-cmd "printf '\033[31mred\033[0m \"q\"\n'; exit 1"
  local out
  out=$(echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block" and (.reason | contains("red") and contains("\"q\""))' <<< "$out" >/dev/null
}

test_malformed_stdin_does_not_crash() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Malformed task" --max-iterations 3
  local out
  out=$(echo 'not json' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
}

test_cli_agent_deleting_state_is_not_success() {
  local agent="$PWD/agent.sh" out
  printf '#!/usr/bin/env bash\nrm -rf .ralph\necho "Mock agent removed state"\n' > "$agent"
  chmod +x "$agent"
  "$ROOT/scripts/setup-ralph-loop.sh" "CLI delete task" --max-iterations 3 --completion-promise "NEVER_EMITTED"
  if out=$(AGENT_BIN="$agent" "$ROOT/scripts/ralph-cli.sh" 2>&1); then
    return 1
  fi
  grep -qF "state removed without verification" <<< "$out"
  if grep -q "finished successfully" <<< "$out"; then
    return 1
  fi
}

test_cli_no_advance_stops_after_one_agent_call() {
  local agent="$PWD/agent.sh" calls="$PWD/calls" out="$PWD/cli.log" pid watchdog status=0
  printf '#!/usr/bin/env bash\necho x >> "%s"\necho "Mock agent turn"\n' "$calls" > "$agent"
  chmod +x "$agent"
  "$ROOT/scripts/setup-ralph-loop.sh" "CLI refused task" --max-iterations 3 --completion-promise "NEVER_EMITTED"
  git add -f .ralph/state.env && git commit -q -m "track state"
  # own process group: bash defers the CLI's TERM trap until the hung agent exits, so the agent must die too
  set -m
  AGENT_BIN="$agent" "$ROOT/scripts/ralph-cli.sh" >"$out" 2>&1 &
  pid=$!
  set +m
  (sleep 30; kill -- -"$pid" 2>/dev/null) &
  watchdog=$!
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  test "$status" -ne 0
  grep -qF "did not advance" "$out"
  test "$(wc -l < "$calls")" -le 2
  test ! -e .ralph/cli.pid
}

test_plugin_hook_gated_while_cli_runs() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Gated task" --max-iterations 3
  local out
  out=$(echo '{"last_assistant_message": "working"}' | RALPH_CLI_AGENT=1 "$ROOT/scripts/stop-hook.sh")
  test -z "$out"
  grep -q "^ITERATION=1$" .ralph/state.env
}

test_cli_agent_hook_calls_are_silent_and_advance_once() {
  local agent="$PWD/agent.sh" calls="$PWD/calls" out="$PWD/hook.out" status=0
  cat > "$agent" <<EOF
#!/usr/bin/env bash
grep '^ITERATION=' .ralph/state.env >> "$calls"
echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh" >> "$out"
echo "Mock agent turn"
EOF
  chmod +x "$agent"
  "$ROOT/scripts/setup-ralph-loop.sh" "Gate task" --max-iterations 3 >/dev/null
  AGENT_BIN="$agent" "$ROOT/scripts/ralph-cli.sh" >/dev/null 2>&1 || status=$?
  test "$status" -ne 0
  test ! -s "$out"
  test "$(cat "$calls")" = "$(printf 'ITERATION=1\nITERATION=2\nITERATION=3')"
}

test_cli_clears_inherited_agent_env() {
  local agent="$PWD/agent.sh"
  printf '#!/usr/bin/env bash\nperl -pi -e "s/- \\[ \\]/- [x]/g" .ralph/fix_plan.md\necho "<promise>INHERITED_DONE</promise>"\n' > "$agent"
  chmod +x "$agent"
  "$ROOT/scripts/setup-ralph-loop.sh" "Inherited env task" --max-iterations 3 --completion-promise "INHERITED_DONE" >/dev/null
  RALPH_CLI_AGENT=1 AGENT_BIN="$agent" "$ROOT/scripts/ralph-cli.sh" >/dev/null 2>&1
  test ! -d .ralph
}

test_agent_written_cli_pid_does_not_gate_hook() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Pid task" --max-iterations 3
  echo "$$" > .ralph/cli.pid
  local out
  out=$(echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  grep -q "^ITERATION=2$" .ralph/state.env
}

test_state_dir_is_excluded_from_git() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Excluded task" --max-iterations 3 --completion-promise "EXCL_DONE"
  echo code > app.txt
  git add -A && git commit -qm "work"
  test -z "$(git ls-files .ralph)"
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  grep -q "^ITERATION=2$" .ralph/state.env
}

test_hook_is_silent_outside_git() {
  local plain err out
  plain="$(mktemp -d)"
  err="$(mktemp)"
  out=$(echo "{\"cwd\": \"$plain\"}" | "$ROOT/scripts/stop-hook.sh" 2>"$err")
  out+=$(echo '{"cwd": "/nonexistent-ralph-dir"}' | "$ROOT/scripts/stop-hook.sh" 2>>"$err")
  rm -rf "$plain" "$err"
  test -z "$out"
  test ! -s "$err"
}

test_committed_test_deletion_is_caught() {
  mkdir tests
  echo 'exit 0' > tests/foo.sh
  git add . && git commit -qm "tests"
  "$ROOT/scripts/setup-ralph-loop.sh" "Committed deletion" --max-iterations 3 >/dev/null
  git rm -q tests/foo.sh && git commit -qm "delete test"
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "Test Integrity Guard Alert" <<< "$out"
}

test_test_directory_variants_are_guarded() {
  mkdir __tests__
  echo 'x' > __tests__/a.js
  echo 'def test_x(): pass' > test_x.py
  git add . && git commit -qm "tests"
  "$ROOT/scripts/setup-ralph-loop.sh" "Variant task" --max-iterations 3 >/dev/null
  rm -r __tests__ test_x.py
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "Test Integrity Guard Alert" <<< "$out"
}

test_bare_state_line_is_ignored() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Bare line task" --max-iterations 3 >/dev/null
  echo "TEST_COMMAND" >> .ralph/state.env
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  if grep -q "Automated Verification" <<< "$out"; then
    return 1
  fi
}

test_setup_excludes_state_before_requiring_commit() {
  rm -rf .git && git init -q .
  local out
  if out=$("$ROOT/scripts/setup-ralph-loop.sh" "No commit task" 2>&1); then
    return 1
  fi
  grep -qF "needs a commit" <<< "$out"
  mkdir .ralph && echo x > .ralph/fix_plan.md
  test -z "$(git status --porcelain)"
}

test_exclude_append_handles_missing_trailing_newline() {
  printf 'node_modules' > .git/info/exclude
  "$ROOT/scripts/setup-ralph-loop.sh" "Newline task" --max-iterations 3 >/dev/null
  "$ROOT/scripts/setup-ralph-loop.sh" "Newline task" --max-iterations 3 --force >/dev/null
  grep -qxF 'node_modules' .git/info/exclude
  test "$(grep -cxF '.ralph/' .git/info/exclude)" -eq 1
}

test_diff_failure_blocks_verification() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Diff failure task" --max-iterations 3 --completion-promise "DIFF_DONE" >/dev/null
  sed 's/^BASE_COMMIT=.*/BASE_COMMIT=deadbeef/' .ralph/state.env > state.tmp && mv state.tmp .ralph/state.env
  sed 's/- \[ \]/- [x]/' .ralph/fix_plan.md > plan.tmp && mv plan.tmp .ralph/fix_plan.md
  local out
  out=$(echo '{"last_assistant_message": "<promise>DIFF_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh" 2>err)
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  if grep -q "Ralph loop: Verified" err; then
    return 1
  fi
}

test_cancel_refuses_tracked_state() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Cancel tracked task" --completion-promise "CANCEL" >/dev/null
  git add -f .ralph
  git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "track state"
  local out
  if out=$("$ROOT/scripts/cancel-ralph.sh" 2>&1); then
    return 1
  fi
  grep -q "tracked by git" <<< "$out"
  test -f .ralph/state.env
}

test_state_values_keep_trailing_equals() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Equals task" --completion-promise "DONE=" --test-cmd "echo ARG=" >/dev/null
  local out
  out=$(echo '{"last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "Automated Verification Passed for 'echo ARG='" <<< "$out"
  grep -q "^TEST_COMMAND=echo ARG=$" .ralph/state.env
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  echo '{"last_assistant_message": "<promise>DONE=</promise>"}' | "$ROOT/scripts/stop-hook.sh" >/dev/null
  test ! -d .ralph
}

# Runs "$@" with a PATH holding only symlinks to the tools the scripts need, so jq is provably not found
without_jq() {
  local bin="$PWD/nojq-bin" t
  if [[ ! -d "$bin" ]]; then
    mkdir "$bin"
    for t in awk bash cat cut date dirname env git grep head ls mkdir mktemp mv perl rm sed sleep sort tail tr wc yes timeout gtimeout uname; do
      command -v "$t" >/dev/null && ln -s "$(command -v "$t")" "$bin/$t"
    done
  fi
  # a fresh shell: this shell caches the path of jq, and `!` would skip errexit
  if PATH="$bin" bash -c "command -v jq" >/dev/null; then return 1; fi
  PATH="$bin" "$@"
}

test_hook_and_cli_run_without_jq() {
  "$ROOT/scripts/setup-ralph-loop.sh" "No jq task" --max-iterations 3 --completion-promise NOJQ_DONE >/dev/null
  local out
  out=$(echo '{"last_assistant_message": "working"}' | without_jq "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block" and .systemMessage == "Ralph loop iteration 2 of 3"' <<< "$out" >/dev/null
  out=$(echo '{"last_assistant_message": "x"}' | without_jq "$ROOT/scripts/stop-hook.sh" cursor)
  jq -e 'has("followup_message")' <<< "$out" >/dev/null
  printf '#!/usr/bin/env bash\necho "<promise>NOJQ_DONE</promise>"\n' > agent.sh
  chmod +x agent.sh
  "$ROOT/scripts/setup-ralph-loop.sh" "No jq cli task" --max-iterations 3 --completion-promise NOJQ_DONE --force >/dev/null
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  out=$(AGENT_BIN="$PWD/agent.sh" without_jq "$ROOT/scripts/ralph-cli.sh" 2>&1)
  grep -qF "Ralph loop finished successfully." <<< "$out"
  test ! -d .ralph
}

test_json_str_escapes_exactly() {
  source "$ROOT/scripts/lib/json.sh"
  local cases=(
    'plain'
    'say "hi" and \back\slash\ \\ \n literal'
    $'tab\there\nnewline\r\n crlf'
    $'ctl \001 \037 \b \f \033[31m'
    'unicode: é 日本 😀'
    ''
  )
  local c out
  for c in "${cases[@]}"; do
    out="$(printf '%s' "$c" | json_str)"
    jq -e --arg c "$c" '. == $c' <<< "$out" >/dev/null
  done
  for c in $'a\n' 'a' $'a\n\n' $'\n'; do
    printf '%s' "$c" | json_str > got.json
    printf '%s' "$c" > want.txt
    jq -j . got.json | cmp - want.txt
  done
  head -c 900000 /dev/urandom | base64 | tr 'AB' '"\\' > big.txt
  json_str < big.txt > got.json
  jq -j . got.json | cmp - big.txt
  awk 'BEGIN { for (i = 0; i < 1200000; i++) print "" }' > blank.txt # 1.2 M empty lines took 6.5 s without the awk fast path
  SECONDS=0
  json_str < blank.txt > got.json
  test "$SECONDS" -lt 4
  jq -j . got.json | cmp - blank.txt
  tr 'C' '\n' < big.txt | json_str > got.json
  jq -j . got.json | tr 'C' '\n' | cmp - <(tr 'C' '\n' < big.txt)
}

test_json_raw_ignores_escaped_decoys() {
  source "$ROOT/scripts/lib/json.sh"
  local p='{"last_assistant_message":"say \"session_id\":\"evil\" \"cwd\":\"/evil\" ok","session_id":"real","cwd":"/real","workspace_roots": [ "/w0","/w1"],"num":5,"nul":null,"o":{"k":1}}'
  test "$(json_raw session_id <<< "$p")" = real
  test "$(json_raw cwd <<< "$p")" = /real
  test "$(json_raw workspace_roots <<< "$p")" = /w0
  test "$(json_raw last_assistant_message <<< "$p")" = 'say \"session_id\":\"evil\" \"cwd\":\"/evil\" ok'
  local key
  for key in missing num nul o; do
    test -z "$(json_raw "$key" <<< "$p")"
  done
  # decoy only inside an escaped string: no real key exists
  test -z "$(json_raw session_id <<< '{"m":"x \"session_id\":\"evil\" y"}')"
  head -c 900000 /dev/urandom | base64 | tr 'AB' '"\\' | tr -d '\n' > big.txt
  jq -c -n --rawfile m big.txt '{last_assistant_message:$m,session_id:"s"}' > big.json
  test "$(json_raw session_id < big.json)" = s
  test "$(json_raw last_assistant_message < big.json | wc -c)" -gt 1200000
}

test_hook_reads_pretty_payload_and_project_dir() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Pretty task" --max-iterations 9 >/dev/null
  local out here="$PWD"
  cd /
  out=$(printf '{\n  "session_id": "s1",\n  "workspace_roots": [\n    "%s"\n  ],\n  "last_assistant_message": "w"\n}\n' "$here" | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  grep -q '^SESSION_ID=s1$' "$here/.ralph/state.env"
  # payload cwd wins over CLAUDE_PROJECT_DIR; CLAUDE_PROJECT_DIR is the fallback
  out=$(echo "{\"cwd\": \"$here\"}" | CLAUDE_PROJECT_DIR=/nonexistent "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  out=$(echo '{"last_assistant_message": "w"}' | CLAUDE_PROJECT_DIR="$here" "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  grep -q '^ITERATION=4$' "$here/.ralph/state.env"
  # an escaped decoy session_id in the message must not rebind or mismatch the loop
  out=$(echo '{"session_id":"s1","last_assistant_message":"\"session_id\":\"other\""}' | CLAUDE_PROJECT_DIR="$here" "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
}

test_escaped_promise_forms_match() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Escaped promise task" --max-iterations 9 --completion-promise 'ESC DONE/1' >/dev/null
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  cp -R .ralph saved
  local msg out
  for msg in 'done <promise>ESC DONE/1</promise>' 'done <promise>ESC DONE\/1<\/promise>' 'x <promise>\n ESC DONE/1\t</promise>' \
    'a <promise>ESC DONE/1</promise>' 'a <promise>ESC DONE\/1<\/promise>' \
    '\u003cpromise\u003eESC DONE/1\u003c/promise\u003e' '\u003Cpromise\u003EESC DONE\/1\u003C\/promise\u003E'; do
    rm -rf .ralph; cp -R saved .ralph
    out=$(printf '{"last_assistant_message":"%s"}\n' "$msg" | "$ROOT/scripts/stop-hook.sh" 2>/dev/null)
    jq -e '.systemMessage | contains("Verified")' <<< "$out" >/dev/null
    test ! -d .ralph
  done
  for msg in '<promise>ESC DONE/1X</promise>' '<promise>ESC DONE</promise>' '<promise>esc done/1</promise>' '<promise>ESC DONE/1 X</promise>'; do
    rm -rf .ralph; cp -R saved .ralph
    out=$(printf '{"last_assistant_message":"%s"}\n' "$msg" | "$ROOT/scripts/stop-hook.sh" 2>/dev/null)
    jq -e '.decision == "block"' <<< "$out" >/dev/null
    test -d .ralph
  done
}

test_invalid_utf8_does_not_break_promise() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Latin1 task" --max-iterations 3 --completion-promise LATIN_DONE >/dev/null
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  local out
  out=$(printf '{"session_id":"s","cwd":"%s","last_assistant_message":"caf\351 <promise>LATIN_DONE</promise>"}' "$PWD" | LC_ALL=en_US.UTF-8 "$ROOT/scripts/stop-hook.sh" 2>/dev/null)
  jq -e '.systemMessage | contains("Verified")' <<< "$out" >/dev/null
  test ! -d .ralph
  "$ROOT/scripts/setup-ralph-loop.sh" "Latin1 cli task" --max-iterations 3 --completion-promise LATIN_DONE >/dev/null
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  printf '#!/usr/bin/env bash\nprintf "caf\\351 <promise>LATIN_DONE</promise>\\n"\n' > agent.sh
  chmod +x agent.sh
  out=$(LC_ALL=en_US.UTF-8 AGENT_BIN="$PWD/agent.sh" "$ROOT/scripts/ralph-cli.sh" 2>&1)
  grep -qF "Ralph loop finished successfully." <<< "$out"
}

test_hook_output_is_valid_json_for_tricky_feedback() {
  local msg=$'q"uote back\\slash tab\t ctl\001\037\033 uni é日本😀 end\\'
  "$ROOT/scripts/setup-ralph-loop.sh" "Tricky task" --max-iterations 5 --test-cmd "printf '%s' \"\$TRICKY\"; exit 1" >/dev/null
  local out
  out=$(echo '{"last_assistant_message": "w"}' | TRICKY="$msg" "$ROOT/scripts/stop-hook.sh")
  jq -e --arg m "$msg" '.decision == "block" and (.reason | contains($m)) and .systemMessage == "Ralph loop iteration 2 of 5"' <<< "$out" >/dev/null
  out=$(echo '{"last_assistant_message": "w"}' | TRICKY="$msg" "$ROOT/scripts/stop-hook.sh" cursor)
  jq -e --arg m "$msg" '.followup_message | contains($m)' <<< "$out" >/dev/null
}

test_bad_last_state_number_does_not_stop_hook() {
  "$ROOT/scripts/setup-ralph-loop.sh" task
  printf 'MAX_ITERATIONS=3\nITERATION=abc\n' > .ralph/state.env
  echo '{}' | "$ROOT/scripts/stop-hook.sh" | grep -q '"decision":"block"'
}

test_cursor_without_text_ends_on_tests_and_plan() {
  "$ROOT/scripts/setup-ralph-loop.sh" task --completion-promise DONE_X --test-cmd true
  local out
  out=$(echo '{"conversation_id": "c1"}' | "$ROOT/scripts/stop-hook.sh" cursor)
  jq -e 'has("followup_message")' <<< "$out" >/dev/null
  sed -i.bak 's/\[ \]/[x]/' .ralph/fix_plan.md; rm -f .ralph/fix_plan.md.bak
  out=$(echo '{"conversation_id": "c1"}' | "$ROOT/scripts/stop-hook.sh" cursor 2>/dev/null)
  test "$out" = '{}'
  test ! -d .ralph
}

test_cursor_conversation_id_binds_loop() {
  "$ROOT/scripts/setup-ralph-loop.sh" task
  echo '{"conversation_id": "c1", "last_assistant_message": "x"}' | "$ROOT/scripts/stop-hook.sh" cursor >/dev/null
  grep -q '^SESSION_ID=c1$' .ralph/state.env
  echo '{"conversation_id": "c2", "last_assistant_message": "x"}' | "$ROOT/scripts/stop-hook.sh" cursor 2>/dev/null
  grep -q '^ITERATION=2$' .ralph/state.env
}

test_state_symlinks_are_refused() {
  "$ROOT/scripts/setup-ralph-loop.sh" task
  echo "TEST_COMMAND=touch PWNED" > notes.txt
  mv .ralph/state.env .ralph/real.env
  ln -s ../notes.txt .ralph/state.env
  echo '{}' | "$ROOT/scripts/stop-hook.sh" 2>&1 | grep -q "symlink"
  test ! -e PWNED
  rm .ralph/state.env; mv .ralph/real.env .ralph/state.env
  mv .ralph/fix_plan.md .ralph/real.md; ln -s ../notes.txt .ralph/fix_plan.md
  echo '{}' | "$ROOT/scripts/stop-hook.sh" 2>&1 | grep -q "symlink"
}

test_setup_replaces_planted_state_tmp_symlink() {
  mkdir .ralph
  echo keep > notes.txt
  ln -s ../notes.txt .ralph/state.env.tmp
  ln -s ../notes.txt .ralph/fix_plan.md
  "$ROOT/scripts/setup-ralph-loop.sh" task
  test "$(cat notes.txt)" = keep
}

test_prompt_file_resolves_from_caller_dir() {
  mkdir sub
  echo "from sub" > sub/prompt.md
  (cd sub && "$ROOT/scripts/setup-ralph-loop.sh" --prompt-file prompt.md)
  grep -q "from sub" .ralph/fix_plan.md
}

test_unknown_option_is_rejected() {
  if "$ROOT/scripts/setup-ralph-loop.sh" task --max-iteration 3 2>/dev/null; then return 1; fi
  test ! -f .ralph/state.env
}

test_git_context_is_capped() {
  "$ROOT/scripts/setup-ralph-loop.sh" task
  local i
  for i in $(seq 1 600); do : > "f$i.txt"; done
  echo '{}' | "$ROOT/scripts/stop-hook.sh" | jq -e '.reason | split("\n") | length < 300' >/dev/null
}

test_unmatchable_promise_is_rejected() {
  local promise
  for promise in 'A<B' 'A\B' ' LEAD' 'TRAIL ' 'A"B' 'A&B' $'A\tB' $'A\001B'; do
    if "$ROOT/scripts/setup-ralph-loop.sh" "Promise task" --completion-promise "$promise" 2>/dev/null; then
      return 1
    fi
    test ! -f .ralph/state.env
  done
}

test_success_requires_passing_tests() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Failing gate task" --max-iterations 3 --completion-promise "GATE_FAIL" --test-cmd "exit 1" >/dev/null
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  local out
  out=$(echo '{"last_assistant_message": "<promise>GATE_FAIL</promise>"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  test -d .ralph
  "$ROOT/scripts/cancel-ralph.sh"
}

test_success_requires_checked_plan() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Open item task" --max-iterations 3 --completion-promise "PLAN_OPEN" >/dev/null
  printf '# Plan\n- [x] 1. done\n- [x] 2. done\n- [ ] 3. open\n' > .ralph/fix_plan.md
  local out
  out=$(echo '{"last_assistant_message": "<promise>PLAN_OPEN</promise>"}' | "$ROOT/scripts/stop-hook.sh")
  grep -q "unchecked work items remain" <<< "$out"
  test -d .ralph
  "$ROOT/scripts/cancel-ralph.sh"
}

test_base_commit_option_is_not_passed_to_git() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Option task" --max-iterations 3 --completion-promise "BASE_DONE" >/dev/null
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  sed 's/^BASE_COMMIT=.*/BASE_COMMIT=--output=FILE/' .ralph/state.env > state.tmp && mv state.tmp .ralph/state.env
  local out
  out=$(echo '{"last_assistant_message": "<promise>BASE_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh")
  test ! -e FILE
  jq -e '.decision == "block"' <<< "$out" >/dev/null
  test -d .ralph
}

test_cursor_aborted_run_does_not_advance() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Aborted task" --max-iterations 3 >/dev/null
  local out
  out=$(echo '{"status": "aborted", "last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh" cursor)
  test "$out" = "{}"
  grep -q "^ITERATION=1$" .ralph/state.env
  out=$(echo '{"status": "completed", "last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh" cursor)
  jq -e 'has("followup_message")' <<< "$out" >/dev/null
  grep -q "^ITERATION=2$" .ralph/state.env
}

test_test_output_is_capped_to_tail() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Cap task" --max-iterations 3 --test-cmd 'yes x | head -c 120000; echo; echo TAIL_$((6*7)); exit 1' >/dev/null
  local out
  out=$(echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.decision == "block" and (.reason | length < 40000 and contains("TAIL_42") and contains("Automated Verification Failed"))' <<< "$out" >/dev/null
  "$ROOT/scripts/cancel-ralph.sh" >/dev/null
  "$ROOT/scripts/setup-ralph-loop.sh" "Short task" --max-iterations 3 --test-cmd 'echo SHORT_$((6*7)); exit 1' >/dev/null
  out=$(echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh")
  jq -e '.reason | contains("SHORT_42")' <<< "$out" >/dev/null
}

test_loop_end_shows_system_message() {
  "$ROOT/scripts/setup-ralph-loop.sh" "End task" --max-iterations 1 --completion-promise "END_DONE" >/dev/null
  local out
  out=$(echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh" 2>/dev/null)
  jq -e '.systemMessage | contains("Max iterations (1)")' <<< "$out" >/dev/null
  "$ROOT/scripts/setup-ralph-loop.sh" "End task" --max-iterations 1 --completion-promise "END_DONE" >/dev/null
  out=$(echo '{"last_assistant_message": "working"}' | "$ROOT/scripts/stop-hook.sh" cursor 2>/dev/null)
  test "$out" = "{}"
  "$ROOT/scripts/setup-ralph-loop.sh" "End task" --max-iterations 3 --completion-promise "END_DONE" >/dev/null
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  out=$(echo '{"last_assistant_message": "<promise>END_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh" 2>/dev/null)
  jq -e '.systemMessage | contains("Verified")' <<< "$out" >/dev/null
}

test_loop_binds_to_first_stopping_session() {
  "$ROOT/scripts/setup-ralph-loop.sh" "Session task" --max-iterations 5 --completion-promise "SESSION_DONE" >/dev/null
  echo '{"session_id": "sess-a", "last_assistant_message": "Working"}' | "$ROOT/scripts/stop-hook.sh" >/dev/null
  grep -q "^SESSION_ID=sess-a$" .ralph/state.env
  grep -q "^ITERATION=2$" .ralph/state.env
  perl -pi -e 's/- \[ \]/- [x]/g' .ralph/fix_plan.md
  local out
  out=$(echo '{"session_id": "sess-b", "last_assistant_message": "<promise>SESSION_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh" 2>"$PWD/err.txt")
  test -z "$out"
  grep -q "bound to session sess-a" "$PWD/err.txt"
  grep -q "setup-ralph-loop.sh --force" "$PWD/err.txt"
  grep -q "^ITERATION=2$" .ralph/state.env
  test -d .ralph
  echo '{"session_id": "sess-a", "last_assistant_message": "<promise>SESSION_DONE</promise>"}' | "$ROOT/scripts/stop-hook.sh" >/dev/null
  test ! -d .ralph
}

echo "=== Running Ralph Wiggum Test Suite ==="
run_test "Setup & Default State Configuration" test_setup_and_defaults
run_test "Completion Promise Is Written Into Agent Prompt" test_completion_promise_in_agent_prompt
run_test "Codex & Claude Marketplace Manifest Conformance" test_marketplace_manifests
run_test "Plugin Manifest Versions & Descriptions Match" test_manifest_versions_match
run_test "No Relative ./scripts/ Paths in Skills, Scripts or Hooks" test_no_relative_script_paths
run_test "Double Initialization Guard & --force Override" test_double_init_guard
run_test "Headless CLI Self-Correcting Feedback Propagation" test_cli_feedback_propagation
run_test "Headless CLI Max Iterations Exits Non-Zero" test_cli_max_iterations_fails
run_test "Claude Code Stop Hook Lifecycle & Iterations" test_claude_stop_hook
run_test "Nested CWD & Worktree Independence" test_nested_cwd_independence
run_test "Single-Iteration Max Completion Gate (Off-by-One Guard)" test_single_iteration_max_completion
run_test "Anti-Cheating & Plan Integrity Guard" test_anti_cheating_and_plan_integrity
run_test "Zero-Checkbox Plan Integrity Guard (No Bash Error)" test_zero_checkbox_plan_integrity
run_test "Deleted Test File Guard Ignores Non-Test Names" test_deleted_test_integrity_guard
run_test "Promise Only In Plan Does Not Complete" test_promise_only_in_plan_does_not_complete
run_test "Exact Literal Promise Matching (Awk Parser)" test_exact_literal_promise_matching
run_test "Moved Test File Is Not A Deletion" test_moved_test_file_is_not_a_deletion
run_test "Concurrent Hooks Are Serialized" test_concurrent_hooks_are_serialized
run_test "Failed Test Reports Exit Code And Iteration" test_failed_test_reports_exit_code
run_test "Continuous Per-Turn Hard Backpressure (--test-cmd)" test_continuous_backpressure
run_test "Cursor loop_limit Is Unlimited (Plugin Cap Governs)" test_cursor_loop_limit_is_unlimited
run_test "Security & Shell Injection Resistance" test_security_and_injection_resistance
run_test "Complex Quotes & Flag Argument Unpacking" test_complex_quotes_and_arg_unpacking
run_test "Prompt File Preserves Text Literally" test_prompt_file_preserves_text_literally
run_test "Empty Prompt File Is Rejected" test_prompt_file_empty_is_rejected
run_test "Missing Prompt File Is Rejected" test_prompt_file_missing_is_rejected
run_test "Prompt And Prompt File Are Exclusive" test_prompt_and_prompt_file_are_exclusive
run_test "Setup Requires A Git Commit" test_setup_requires_git_commit
run_test "Tracked .ralph State Is Refused" test_tracked_state_refused
run_test "Multi-Line Flag Values Are Rejected" test_multiline_flags_rejected
run_test "Leading-Zero --max-iterations Is Decimal" test_leading_zero_max_iterations_is_decimal
run_test "Unlimited & Untested Messages Are Clean" test_unlimited_and_untested_messages_are_clean
run_test "Baseline Commit Recorded In State" test_baseline_commit_recorded
run_test "Promise Outside Last Message Does Not Complete" test_promise_only_from_last_message
run_test "Feedback With Control Characters Is Valid JSON" test_feedback_with_control_characters_is_valid_json
run_test "Grok Payload Uses camelCase Message And Skips Session End" test_grok_payload
run_test "Antigravity Payload Uses continue And Skips Unfinished Stops" test_antigravity_payload
run_test "Host-Specific Block Schema (Cursor vs Others)" test_host_specific_block_schema
run_test "workspace_roots Locates Project" test_workspace_roots_locates_project
run_test "Large Test Output Is Fed Back (>1MB)" test_large_test_output_is_fed_back
run_test "CLI Large Agent Output Completes (>1MB)" test_cli_large_agent_output_is_fed_back
run_test "Malformed Stdin Does Not Crash Hook" test_malformed_stdin_does_not_crash
run_test "CLI Agent Deleting State Is Not Success" test_cli_agent_deleting_state_is_not_success
run_test "CLI Stops When Hook Does Not Advance" test_cli_no_advance_stops_after_one_agent_call
run_test "Plugin Hook Gated While CLI Runs" test_plugin_hook_gated_while_cli_runs
run_test "CLI Agent Hook Calls Are Silent And Advance Once" test_cli_agent_hook_calls_are_silent_and_advance_once
run_test "CLI Clears Inherited RALPH_CLI_AGENT For Its Hook" test_cli_clears_inherited_agent_env
run_test "Agent-Written cli.pid Does Not Gate Hook" test_agent_written_cli_pid_does_not_gate_hook
run_test "Missing Plan File Raises Integrity Alert" test_missing_plan_alert
run_test "State Dir Excluded From git add -A" test_state_dir_is_excluded_from_git
run_test "Stop Hook Silent Outside Git Or Bad cwd" test_hook_is_silent_outside_git
run_test "Committed Test Deletion Is Caught" test_committed_test_deletion_is_caught
run_test "Test Directory Variants Are Guarded" test_test_directory_variants_are_guarded
run_test "Bare State Line Without '=' Is Ignored" test_bare_state_line_is_ignored
run_test "Setup Excludes State Before Requiring A Commit" test_setup_excludes_state_before_requiring_commit
run_test "Exclude Append Handles Missing Trailing Newline" test_exclude_append_handles_missing_trailing_newline
run_test "Baseline Diff Failure Blocks Verification" test_diff_failure_blocks_verification
run_test "Cancel Refuses Tracked .ralph State" test_cancel_refuses_tracked_state
run_test "State Values Keep Trailing '=' (Bash 3.2 IFS Fix)" test_state_values_keep_trailing_equals
run_test "Hook And CLI Run With jq Absent From PATH" test_hook_and_cli_run_without_jq
run_test "json_str Escapes Exactly (Incl. 1.2 MB)" test_json_str_escapes_exactly
run_test "json_raw Ignores Escaped Decoys (Incl. 1.2 MB)" test_json_raw_ignores_escaped_decoys
run_test "Hook Reads Pretty Payload And Project Dir Order" test_hook_reads_pretty_payload_and_project_dir
run_test "JSON-Escaped Promise Forms Match Exactly" test_escaped_promise_forms_match
run_test "Invalid UTF-8 Does Not Break Promise (UTF-8 Locale)" test_invalid_utf8_does_not_break_promise
run_test "Hook Output Is Valid JSON For Tricky Feedback" test_hook_output_is_valid_json_for_tricky_feedback
run_test "Bad Number On Last State Line Still Blocks" test_bad_last_state_number_does_not_stop_hook
run_test "Cursor Without Assistant Text Ends On Tests And Plan" test_cursor_without_text_ends_on_tests_and_plan
run_test "Cursor conversation_id Binds The Loop" test_cursor_conversation_id_binds_loop
run_test "State And Plan Symlinks Are Refused" test_state_symlinks_are_refused
run_test "Setup Replaces Planted Symlinks" test_setup_replaces_planted_state_tmp_symlink
run_test "Prompt File Resolves From Caller Dir" test_prompt_file_resolves_from_caller_dir
run_test "Unknown Option Is Rejected" test_unknown_option_is_rejected
run_test "Git Context Is Capped" test_git_context_is_capped
run_test "Unmatchable Completion Promise Is Rejected" test_unmatchable_promise_is_rejected
run_test "Success Gate Requires Passing Tests" test_success_requires_passing_tests
run_test "Success Gate Requires Checked Plan" test_success_requires_checked_plan
run_test "BASE_COMMIT Option Never Reaches git" test_base_commit_option_is_not_passed_to_git
run_test "Cursor Aborted Run Does Not Advance" test_cursor_aborted_run_does_not_advance
run_test "Loop Binds To First Stopping Session" test_loop_binds_to_first_stopping_session
run_test "Test Output Is Capped To Its Tail" test_test_output_is_capped_to_tail
run_test "Loop End Shows systemMessage (Cursor Keeps {})" test_loop_end_shows_system_message

echo "---------------------------------------------------------------"
echo "Results: $PASSED passed, $FAILED failed."

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
