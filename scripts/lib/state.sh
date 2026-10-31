# shellcheck shell=bash disable=SC2034 # the sourcing scripts use these variables
read_state() {
  ITERATION=1 MAX_ITERATIONS=10 COMPLETION_PROMISE="" TEST_COMMAND="" BASE_COMMIT="" INITIAL_TASK_COUNT=1 STARTED_AT="" SESSION_ID=""
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      ITERATION|MAX_ITERATIONS|INITIAL_TASK_COUNT) [[ "$val" =~ ^[0-9]+$ ]] && printf -v "$key" %s "$val" ;;
      COMPLETION_PROMISE|TEST_COMMAND|BASE_COMMIT|STARTED_AT|SESSION_ID) printf -v "$key" %s "$val" ;;
    esac
  done < "$STATE_FILE"
  return 0 # a skipped bad number must not leave status 1 for set -e callers
}
