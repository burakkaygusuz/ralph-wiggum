---
name: ralph-loop
description: Run an autonomous, iterative development loop using the Ralph Wiggum technique. Use this skill when the user wants continuous test-driven iteration, automated refactoring until tests pass, or execution bounded by a completion promise. DO NOT use for one-shot bug fixes, single-pass queries, or simple explanations.
---

# Ralph Loop (Iterative Autonomous Development)

> Per Geoffrey Huntley's original post (ghuntley.com/ralph), Ralph is best suited to greenfield work. The original loop has no completion signal by design; the `<promise>` token is an addition of this plugin. The tests and the plan of the operator decide when the work is done.

## Parameters

- `PROMPT` (required): Task description, architecture requirements, and acceptance criteria.
- `--max-iterations <N>` (optional, default: 10): Iteration limit (0 for unbounded).
- `--completion-promise '<TEXT>'` (optional): Exact string in `<promise>TEXT</promise>` that stops the loop. In Cursor, the stop hook does not read the promise, because Cursor does not send assistant text. Without this flag, the hook accepts `<promise>COMPLETE</promise>` or `<promise>DONE</promise>`. Setup rejects TEXT that contains `<`, `\`, `"`, `&` or control characters. Setup also rejects TEXT that starts or ends with whitespace. The stop hook cannot find such TEXT in the reply.
- `--test-cmd '<CMD>'` (optional): Command that the stop hook runs before it accepts completion.
- `--force` (optional): Replace the state of an active Ralph loop.

## Execution Workflow

If `${CLAUDE_PLUGIN_ROOT}` has no value, use the folder two levels above this SKILL.md file instead. That folder contains `scripts/`.

1. **Initialize State & Living Scheduler:**
   Write the task text verbatim to `.ralph/prompt.md`, then run the setup script. It reads that file without executing it, so quoting in the task text is never interpreted:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh --prompt-file .ralph/prompt.md [--max-iterations N] [--completion-promise TEXT] [--test-cmd CMD] [--force]
   ```
   Setup writes `.ralph/` to `.git/info/exclude` and does not touch `.gitignore`.
   The loop binds to the first session that stops after setup. The hook ignores stops from other sessions and writes a notice to stderr. The host can hide this notice. Run setup again with `--force`, or cancel the loop, to bind a new session. After `/clear`, the host can issue a new session id. The hook then ignores that session (not verified).

2. **Iterate & Self-Correct (Huntley 1-Item Discipline):**
   On each turn:
   - Read `.ralph/fix_plan.md` and check `git status`.
   - Review `Working Memory & Cross-Turn Learnings` for findings from previous iterations.
   - Select exactly ONE work item with the highest priority from the queue.
   - Implement the changes and run verification tests (`npm test`, `pytest`, `cargo test`).
   - Update `Working Memory` with new insights and mark the item `[x]` with test evidence in `.ralph/fix_plan.md`.

3. **Terminate:**
   - Output `<promise>TEXT</promise>` in your last reply **ONLY** when you verified all work items and test criteria.
   - Do not write the promise in `.ralph/fix_plan.md`. The stop hook reads only your last message.
   - When the iteration limit is reached, stop and summarize the remaining blockers.

## Gotchas

- **Headless Runner:** For long unattended runs, use `${CLAUDE_PLUGIN_ROOT}/scripts/ralph-cli.sh`. It exits non-zero when the iteration limit is reached without a verified promise. It runs `$AGENT_BIN --print -p` (default `AGENT_BIN=claude`). These flags are Claude Code syntax.
- **Test Integrity:** NEVER alter, mock out, or delete existing test assertions to force a passing build. Fix application code. The stop hook finds only deleted test files. It does not find changed assertions.
- **Promise Integrity:** Never emit `<promise>...</promise>` early or to escape the loop. If `--test-cmd` fails, the stop hook blocks the exit.
- **Trust Model:** The user writes the `--test-cmd` command. The stop hook runs this command after each turn. The hook does not ask for approval. Setup writes `.ralph/state.env` with owner-only permissions (umask 077). The hook rejects a state file that a different user owns or that git tracks. Use only commands that are safe for you to run.
