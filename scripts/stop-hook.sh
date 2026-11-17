#!/usr/bin/env bash
set -euo pipefail
umask 077

HOST="${1:-}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/json.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/step.sh"

RAW_INPUT="$(LC_ALL=C tr '\n' ' ' || true)"
# shortcut: paths are not JSON-decoded, so a cwd containing a backslash or quote (Windows paths) will not resolve
HOOK_DIR="$(printf '%s' "$RAW_INPUT" | json_raw cwd)"
[[ -n "$HOOK_DIR" ]] || HOOK_DIR="$(printf '%s' "$RAW_INPUT" | json_raw workspace_roots)"
[[ -n "$HOOK_DIR" ]] || HOOK_DIR="$(printf '%s' "$RAW_INPUT" | json_raw workspacePaths)"
cd "${HOOK_DIR:-${CLAUDE_PROJECT_DIR:-.}}" 2>/dev/null || exit 0

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$PROJECT_ROOT"
STATE_DIR="$PROJECT_ROOT/.ralph"
STATE_FILE="$STATE_DIR/state.env"
PLAN_FILE="$STATE_DIR/fix_plan.md"

[[ -f "$STATE_FILE" ]] || exit 0

check_state_safe || exit 0

# The headless CLI advances the loop itself; the plugin hook must not run during its agent calls.
# Gated by the environment, not cli.pid: the agent can write files, so it could write its own PID there.
[[ -z "${RALPH_CLI_AGENT:-}" ]] || exit 0

trap release_lock EXIT
lock_state || exit 0

# Grok also fires Stop at session end (reason channel_closed or shutdown); no turn is left to continue.
STOP_REASON="$(printf '%s' "$RAW_INPUT" | json_raw reason)"
[[ -z "$STOP_REASON" || "$STOP_REASON" == "end_turn" ]] || exit 0

# Antigravity also stops on a system error, and while background tasks still run (fullyIdle false). Its terminationReason values are not documented reliably (live: NO_TOOL_CALL), so it is not used.
[[ -z "$(printf '%s' "$RAW_INPUT" | json_raw error)" ]] || exit 0
[[ ! "$RAW_INPUT" =~ \"fullyIdle\"[[:space:]]*:[[:space:]]*false ]] || exit 0

# The loop belongs to the first session that stops in it. Cursor sends conversation_id, Grok sends sessionId and Antigravity sends conversationId instead; payloads with neither are not bound.
PAYLOAD_SESSION_ID="$(printf '%s' "$RAW_INPUT" | json_raw session_id)"
[[ -n "$PAYLOAD_SESSION_ID" ]] || PAYLOAD_SESSION_ID="$(printf '%s' "$RAW_INPUT" | json_raw conversation_id)"
[[ -n "$PAYLOAD_SESSION_ID" ]] || PAYLOAD_SESSION_ID="$(printf '%s' "$RAW_INPUT" | json_raw sessionId)"
[[ -n "$PAYLOAD_SESSION_ID" ]] || PAYLOAD_SESSION_ID="$(printf '%s' "$RAW_INPUT" | json_raw conversationId)"
if [[ -n "$PAYLOAD_SESSION_ID" ]]; then
  if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="$PAYLOAD_SESSION_ID"
  elif [[ "$PAYLOAD_SESSION_ID" != "$SESSION_ID" ]]; then
    echo "Ralph loop: bound to session $SESSION_ID, ignoring this session. Run setup-ralph-loop.sh --force to rebind, or cancel-ralph.sh to end the loop." >&2
    exit 0
  fi
fi

if [[ "$HOST" == cursor ]]; then
  RUN_STATUS="$(printf '%s' "$RAW_INPUT" | json_raw status)"
  if [[ -n "$RUN_STATUS" && "$RUN_STATUS" != completed ]]; then
    echo '{}'
    exit 0
  fi
fi

end_output() {
  if [[ "$HOST" == cursor || "$HOST" == antigravity ]]; then echo '{}'; else printf '{"systemMessage":%s}\n' "$(printf '%s' "$MSG" | json_str)"; fi
}

STEP_STATUS=0
ralph_step || STEP_STATUS=$?
case "$STEP_STATUS" in
  0|4) end_output; exit 0 ;;
  3) ;;
  *) exit 1 ;;
esac

# Feedback goes through stdin: a command-line argument is capped by the OS (~128 KiB on Linux)
if [[ "$HOST" == antigravity ]]; then
  RESULT="{\"decision\":\"continue\",\"reason\":$(printf '%s' "$FEEDBACK" | json_str)}"
elif [[ "$HOST" == cursor ]]; then
  RESULT="{\"followup_message\":$(printf '%s' "$FEEDBACK" | json_str)}"
else
  RESULT="{\"decision\":\"block\",\"reason\":$(printf '%s' "$FEEDBACK" | json_str),\"systemMessage\":$(printf '%s' "$SYS_MSG" | json_str)}"
fi

# Advance only after the output is built, so a failed build cannot leave the loop advanced with no feedback
ralph_advance || exit 1

printf '%s\n' "$RESULT"
