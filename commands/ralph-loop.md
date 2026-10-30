---
description: "Start Ralph Wiggum loop in current session"
argument-hint: "PROMPT [--max-iterations N] [--completion-promise TEXT] [--test-cmd CMD] [--force]"
allowed-tools: ["Edit(./.ralph/prompt.md)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh:*)"]
---

# Ralph Loop Command

Initialize the Ralph loop.

1. Write the task text from `$ARGUMENTS` (everything except `--max-iterations`, `--completion-promise`, `--test-cmd` and `--force` with their values) verbatim to `.ralph/prompt.md`.
2. Run `"${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh" --prompt-file .ralph/prompt.md` followed by any `--max-iterations`, `--completion-promise`, `--test-cmd` and `--force` flags from `$ARGUMENTS`.
Read `.ralph/fix_plan.md` and begin executing Step 1 from the Work Queue.

When you finish each turn, the Ralph stop hook will evaluate your verification status and feed progress or test feedback back to you for the next iteration until completion or max iterations.

CRITICAL RULE: If a completion promise is set, you may ONLY output `<promise>TEXT</promise>` when the statement is completely and unequivocally true.
