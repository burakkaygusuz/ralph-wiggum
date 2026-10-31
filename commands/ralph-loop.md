---
description: "Start Ralph Wiggum loop in current session"
argument-hint: "PROMPT [--max-iterations N] [--completion-promise TEXT] [--test-cmd CMD] [--force]"
allowed-tools: ["Edit(./.ralph/prompt.md)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh:*)"]
---

# Ralph Loop Command

Initialize the Ralph loop.

1. Write the task text from `$ARGUMENTS` (everything except `--max-iterations`, `--completion-promise`, `--test-cmd` and `--force` with their values) verbatim to `.ralph/prompt.md`.
2. Run `"${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh" --prompt-file .ralph/prompt.md` followed by any `--max-iterations`, `--completion-promise`, `--test-cmd` and `--force` flags from `$ARGUMENTS`.
3. Read `.ralph/fix_plan.md`.
4. Start item 1 in the work queue.

When you finish a turn, the stop hook checks your work. It sends you the plan and test feedback for the next iteration. This repeats until the work is complete or the iteration limit is reached.

VERY IMPORTANT: Write `<promise>TEXT</promise>` only when all work items are completed and the tests pass. TEXT is the completion promise. If the user did not set it, use `COMPLETE`.
