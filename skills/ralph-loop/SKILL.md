---
name: ralph-loop
description: Run an autonomous, iterative development loop using the Ralph Wiggum technique. Use this skill when the user wants continuous test-driven iteration, automated refactoring until tests pass, or execution bounded by a completion promise. DO NOT use for one-shot bug fixes, single-pass queries, or simple explanations.
---

# Ralph Loop (Iterative Autonomous Development)

> Per Geoffrey Huntley's original post (ghuntley.com/ralph), Ralph is best suited to greenfield work. The original loop has no completion signal by design; the `<promise>` token is this plugin's addition, so the operator's tests and plan are what really decide when work is done.

## Parameters

- `PROMPT` (required): Task description, architecture requirements, and acceptance criteria.
- `--max-iterations <N>` (optional, default: 10): Safety ceiling on turns (0 for unbounded).
- `--completion-promise '<TEXT>'` (optional): Exact string in `<promise>TEXT</promise>` required to stop.
- `--test-cmd '<CMD>'` (optional): Command executed deterministically by stop hook before accepting completion.
- `--force` (optional): Override an existing active Ralph loop state.

## Execution Workflow

1. **Initialize State & Living Scheduler:**
   Write the task text verbatim to `.ralph/prompt.md`, then run the setup script. It reads that file without executing it, so quoting in the task text is never interpreted:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh --prompt-file .ralph/prompt.md [--max-iterations N] [--completion-promise TEXT] [--test-cmd CMD] [--force]
   ```
   Setup writes `.ralph/` to `.git/info/exclude` and does not touch `.gitignore`.

2. **Iterate & Self-Correct (Huntley 1-Item Discipline):**
   On each turn:
   - Read `.ralph/fix_plan.md` and check `git status`.
   - Review `Working Memory & Cross-Turn Learnings` for findings from previous iterations.
   - Select exactly ONE highest-priority uncompleted work item from the queue.
   - Implement the changes and run verification tests (`npm test`, `pytest`, `cargo test`).
   - Update `Working Memory` with new insights and mark the item `[x]` with test evidence in `.ralph/fix_plan.md`.

3. **Terminate:**
   - Output `<promise>TEXT</promise>` in your final reply **ONLY** when all work items and test criteria are completely verified. Do not write it to `.ralph/fix_plan.md`: the stop hook reads only your last message.
   - Stop and summarize remaining blockers when max iterations is reached.

## Gotchas

- **Headless Runner:** For long unattended runs, use `${CLAUDE_PLUGIN_ROOT}/scripts/ralph-cli.sh`. It exits non-zero when max iterations is reached without a verified promise.
- **Test Integrity:** NEVER alter, mock out, or delete existing test assertions to force a passing build. Fix application code. The stop hook detects deleted test files only; weakened assertions are not detected, so a passing `--test-cmd` is the backstop.
- **Promise Integrity:** Never emit `<promise>...</promise>` early or to escape the loop. If `--test-cmd` fails, the stop hook will block exit.
- **Trust Model:** `--test-cmd` is user-authored and the stop hook executes it unprompted on every stop. `.ralph/state.env` is written with owner-only permissions (umask 077), and the hook refuses a state file not owned by the current user or tracked by git. Only pass commands you would run yourself.
