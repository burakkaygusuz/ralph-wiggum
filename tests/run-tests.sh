#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

chmod +x scripts/*.sh

PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  printf "  - %-65s " "$name"
  local log_file
  log_file=$(mktemp)
  if "$@" >"$log_file" 2>&1; then
    echo "[OK]"
    PASSED=$((PASSED + 1))
  else
    echo "[FAILED]"
    cat "$log_file"
    FAILED=$((FAILED + 1))
  fi
  rm -rf .ralph "$log_file"
}

test_setup_and_defaults() {
  ./scripts/setup-ralph-loop.sh "CI test task" --completion-promise "CI_DONE"
  test -f .ralph/state.env
  test -f .ralph/fix_plan.md
  grep -q "ITERATION=1" .ralph/state.env
  grep -q "MAX_ITERATIONS=10" .ralph/state.env
  grep -q "COMPLETION_PROMISE=CI_DONE" .ralph/state.env
  grep -q "INITIAL_TASK_COUNT=3" .ralph/state.env
  grep -q "Ralph Implementation Plan & State Scheduler" .ralph/fix_plan.md
  grep -q "Working Memory & Cross-Turn Learnings" .ralph/fix_plan.md
}

test_marketplace_manifests() {
  test -f .agents/plugins/marketplace.json
  test -f .claude-plugin/marketplace.json
  test -f .claude-plugin/plugin.json
  test -f .codex-plugin/plugin.json
  jq -e '.name == "ralph-wiggum" and .plugins[0].name == "ralph-wiggum" and .plugins[0].source == "./"' .agents/plugins/marketplace.json >/dev/null
  jq -e '.name == "ralph-wiggum" and .plugins[0].name == "ralph-wiggum" and .plugins[0].source == "./"' .claude-plugin/marketplace.json >/dev/null
}

test_double_init_guard() {
  ./scripts/setup-ralph-loop.sh "Active task" --completion-promise "DONE"
  set +e
  ./scripts/setup-ralph-loop.sh "Second concurrent attempt" 2>/dev/null
  local status=$?
  set -e
  test "$status" -ne 0
  ./scripts/setup-ralph-loop.sh "Forced reinited task" --completion-promise "DONE" --force
}

test_cli_feedback_propagation() {
  local tmp_agent
  tmp_agent=$(mktemp)
  cat << 'EOF' > "$tmp_agent"
#!/usr/bin/env bash
PROMPT_ARG="$3"
if ! echo "$PROMPT_ARG" | grep -q "Automated Verification Failed"; then
  echo "Mock Agent Turn 1: Wrote code with failing test"
else
  echo "Mock Agent Turn 2: Received test failure feedback! Fixing..."
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo "All fixed! <promise>CLI_FEEDBACK_DONE</promise>"
fi
EOF
  chmod +x "$tmp_agent"

  ./scripts/setup-ralph-loop.sh "Test CLI feedback" --max-iterations 3 --completion-promise "CLI_FEEDBACK_DONE" --test-cmd "grep -q '\[x\]' .ralph/fix_plan.md" --force
  AGENT_BIN="$tmp_agent" ./scripts/ralph-cli.sh .ralph/fix_plan.md
  test ! -d .ralph
  rm -f "$tmp_agent"
}

test_claude_stop_hook() {
  ./scripts/setup-ralph-loop.sh "Claude task" --completion-promise "CLAUDE_DONE"
  local res
  res=$(echo '{"last_assistant_message": "Working on steps..."}' | ./scripts/stop-hook.sh)
  echo "$res" | grep -q '"decision": "block"'
  grep -q "ITERATION=2" .ralph/state.env

  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo '{"last_assistant_message": "Finished! <promise>CLAUDE_DONE</promise>"}' | ./scripts/stop-hook.sh
  test ! -d .ralph
}

test_nested_cwd_independence() {
  ./scripts/setup-ralph-loop.sh "Nested CWD task" --max-iterations 3 --completion-promise "NESTED_DONE"
  mkdir -p src/nested/dir
  (
    cd src/nested/dir
    local nested_out
    nested_out=$(echo '{"last_assistant_message": "Working in nested dir"}' | "$SCRIPT_DIR/scripts/stop-hook.sh")
    echo "$nested_out" | grep -q '"decision": "block"'
  )
  test -f .ralph/state.env
  grep -q "ITERATION=2" .ralph/state.env
  ./scripts/cancel-ralph.sh
  rm -rf src/nested
}

test_single_iteration_max_completion() {
  ./scripts/setup-ralph-loop.sh "Single turn task" --max-iterations 1 --completion-promise "SINGLE_DONE" --test-cmd "true"
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo '{"last_assistant_message": "Done on turn 1! <promise>SINGLE_DONE</promise>"}' | ./scripts/stop-hook.sh
  test ! -d .ralph
}

test_anti_cheating_and_plan_integrity() {
  ./scripts/setup-ralph-loop.sh "Integrity test task" --max-iterations 3 --completion-promise "INTEGRITY_DONE"
  cat <<EOF > .ralph/fix_plan.md
# Plan
- [x] Only 1 task
EOF
  local ch_out
  ch_out=$(echo '{"last_assistant_message": "Done! <promise>INTEGRITY_DONE</promise>"}' | ./scripts/stop-hook.sh)
  echo "$ch_out" | grep -q "Plan Integrity Guard Alert"
  test -d .ralph
  ./scripts/cancel-ralph.sh
}

test_exact_literal_promise_matching() {
  ./scripts/setup-ralph-loop.sh "Exact promise task" --max-iterations 3 --completion-promise "AUTH_V1.0"
  echo '{"last_assistant_message": "False match <promise>AUTH_V100</promise>"}' | ./scripts/stop-hook.sh >/dev/null
  test -d .ralph
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo '{"last_assistant_message": "Exact match <promise>AUTH_V1.0</promise>"}' | ./scripts/stop-hook.sh
  test ! -d .ralph
}

test_continuous_backpressure() {
  ./scripts/setup-ralph-loop.sh "Backpressure task" --test-cmd "echo 'Running unit test suite'; exit 1"
  local fail_out
  fail_out=$(echo '{"last_assistant_message": "Just wrote some code"}' | ./scripts/stop-hook.sh)
  echo "$fail_out" | grep -q "Automated Verification Failed"
  test -d .ralph
  ./scripts/cancel-ralph.sh
}

test_copilot_stop_hook() {
  local tmp_copilot
  tmp_copilot=$(mktemp)
  echo '{"type":"message","text":"Completed in Copilot <promise>COPILOT_DONE</promise>"}' > "$tmp_copilot"
  ./scripts/setup-ralph-loop.sh "Copilot task" --max-iterations 3 --completion-promise "COPILOT_DONE"
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  local copilot_out
  copilot_out=$(echo "{\"TranscriptPath\": \"$tmp_copilot\", \"StopHookActive\": true}" | ./scripts/stop-hook.sh)
  echo "$copilot_out" | grep -q '"decision": "allow"'
  test ! -d .ralph
  rm -f "$tmp_copilot"
}

test_cursor_stop_hook() {
  ./scripts/setup-ralph-loop.sh "Cursor task" --max-iterations 3 --completion-promise "CURSOR_DONE"
  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo "## Completed Evidence: <promise>CURSOR_DONE</promise>" >> .ralph/fix_plan.md
  local cursor_out
  cursor_out=$(echo '{"status": "completed", "loop_count": 2}' | ./scripts/stop-hook.sh)
  echo "$cursor_out" | grep -q '"decision": "allow"'
  test ! -d .ralph
}

test_antigravity_lifecycle_contract() {
  local tmp_transcript
  tmp_transcript=$(mktemp)
  echo '{"type":"PLANNER_RESPONSE","content":"In progress"}' >> "$tmp_transcript"
  ./scripts/setup-ralph-loop.sh "Antigravity task" --max-iterations 3 --completion-promise "AGY_TEST_DONE"
  local agy_res
  agy_res=$(echo "{\"executionNum\": 1, \"transcriptPath\": \"$tmp_transcript\", \"terminationReason\": \"model_stop\"}" | ./scripts/stop-hook.sh)
  echo "$agy_res" | grep -q '"decision": "continue"'
  grep -q "ITERATION=2" .ralph/state.env

  perl -pi -e 's/- \[ \]/- \[x\]/g' .ralph/fix_plan.md
  echo '{"type":"PLANNER_RESPONSE","content":"All green! <promise>AGY_TEST_DONE</promise>"}' >> "$tmp_transcript"
  local agy_stop
  agy_stop=$(echo "{\"executionNum\": 2, \"transcriptPath\": \"$tmp_transcript\", \"terminationReason\": \"model_stop\"}" | ./scripts/stop-hook.sh)
  echo "$agy_stop" | grep -q '"decision": "stop"'
  test ! -d .ralph
  rm -f "$tmp_transcript"
}

test_security_and_injection_resistance() {
  set +e
  ./scripts/setup-ralph-loop.sh task --max-iterations '$(touch /tmp/bad_marker)' 2>/dev/null
  local inj_status=$?
  set -e
  test "$inj_status" -ne 0
  test ! -f /tmp/bad_marker
}

test_complex_quotes_and_arg_unpacking() {
  ./scripts/setup-ralph-loop.sh 'Implement feature and don'\''t break existing tests --max-iterations 5 --completion-promise "PROMISE_TEST"'
  test -f .ralph/state.env
  grep -q "MAX_ITERATIONS=5" .ralph/state.env
  local cancel_out
  cancel_out=$(./scripts/cancel-ralph.sh)
  echo "$cancel_out" | grep -q "Ralph loop canceled at iteration 1"
  test ! -d .ralph
}

echo "=== Running Ralph Wiggum Test Suite ==="
run_test "Setup & Default State Configuration" test_setup_and_defaults
run_test "Codex & Claude Marketplace Manifest Conformance" test_marketplace_manifests
run_test "Double Initialization Guard & --force Override" test_double_init_guard
run_test "Headless CLI Self-Correcting Feedback Propagation" test_cli_feedback_propagation
run_test "Claude Code Stop Hook Lifecycle & Iterations" test_claude_stop_hook
run_test "Nested CWD & Worktree Independence" test_nested_cwd_independence
run_test "Single-Iteration Max Completion Gate (Off-by-One Guard)" test_single_iteration_max_completion
run_test "Anti-Cheating & Plan Integrity Guard" test_anti_cheating_and_plan_integrity
run_test "Exact Literal Promise Matching (Awk Parser)" test_exact_literal_promise_matching
run_test "Continuous Per-Turn Hard Backpressure (--test-cmd)" test_continuous_backpressure
run_test "GitHub Copilot Stop Hook with TranscriptPath" test_copilot_stop_hook
run_test "Cursor Stop Hook with Living Fix Plan Resolution" test_cursor_stop_hook
run_test "Google Antigravity Native Lifecycle Hook Contract" test_antigravity_lifecycle_contract
run_test "Security & Shell Injection Resistance" test_security_and_injection_resistance
run_test "Complex Quotes, Contractions & Single-String Unpacking" test_complex_quotes_and_arg_unpacking

echo "---------------------------------------------------------------"
echo "Results: $PASSED passed, $FAILED failed."

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
