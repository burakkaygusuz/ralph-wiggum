---
name: ralph-loop
description: Run an autonomous, iterative development loop that follows the Ralph Wiggum technique. Use this skill when the user wants continuous test-driven iteration, automated refactoring until tests pass, or a loop that ends when the tests pass and every plan item is checked. DO NOT use for one-shot bug fixes, single-pass queries, or simple explanations.
---

# Ralph Loop (Iterative Autonomous Development)

> According to Geoffrey Huntley's original post (ghuntley.com/ralph), Ralph is best for new projects that have no existing code. Huntley designed the original loop without a completion signal. Here, the tests and the plan decide when the work is done.

Requires bash and a git repository with at least one commit.

## Parameters

- `PROMPT` (required): Task description, architecture requirements, and acceptance criteria.
- `--max-iterations <N>` (optional, default: 10): Iteration limit (0 for no limit).
- `--test-cmd '<CMD>'` (strongly recommended): Command that the stop hook runs before it accepts completion. Without it, the loop ends as soon as every plan item is checked. If the user gave no test command, find the test command in the repository, or ask the user. Do not invent a test command.
- `--force` (optional): Replace the state of an active Ralph loop.

## Workflow

If `${CLAUDE_PLUGIN_ROOT}` has no value, or the text is still literal, replace this variable with an absolute path. Use the path of the folder two levels above this SKILL.md file. That folder contains `scripts/`. A relative path can resolve from the workspace, so do not use one.

1. **Set Up State and Scheduler:**
   Write the task text to `.ralph/prompt.md` without changes. Then run the setup script. The script reads that file but does not run it, so the script never interprets quote characters in the task text:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh --prompt-file .ralph/prompt.md [--max-iterations N] [--test-cmd CMD] [--force]
   ```
   Setup writes `.ralph/` to `.git/info/exclude` and does not touch `.gitignore`.
   The loop binds to the first session that stops after setup. The hook ignores stops from other sessions and writes a notice to stderr. The host can hide this notice. Run setup again with `--force`, or cancel the loop, to bind a new session. After `/clear`, the host can issue a new session id. The hook then ignores that session (not verified).

2. **Iterate & Self-Correct (Huntley One-Item Rule):**
   On each turn:
   - Read `.ralph/fix_plan.md` and check `git status`.
   - Review `Working Memory & Cross-Turn Learnings` for findings from previous iterations.
   - Select exactly one plan item with the highest priority from the Work Queue section.
   - Implement the changes. Then run the verification tests (`npm test`, `pytest`, `cargo test`).
   - Update `Working Memory` with new insights. Then mark the plan item `[x]` with test evidence in `.ralph/fix_plan.md`.

3. **End the Loop:**
   - The loop ends when every plan item is `[x]` and `--test-cmd` passes. The stop hook reads nothing from your reply.
   - Check a plan item only after you verified it. To continue the work, add or leave an unchecked plan item.
   - When the loop reaches the iteration limit, stop and summarize the blockers that are still open.

## Gotchas

- **Headless Runner:** For long runs without a person present, use `${CLAUDE_PLUGIN_ROOT}/scripts/ralph-cli.sh`. It exits non-zero when the iteration limit is reached without verified completion. It runs `$AGENT_BIN -p` (default `AGENT_BIN=claude`). Claude Code and Grok Build accept this flag.
- **Test Integrity:** NEVER change, mock out, or delete existing test assertions to make the build pass. Fix application code. The stop hook finds only deleted test files. It does not find changed assertions.
- **Completion Integrity:** Never check a plan item that you did not verify, not even to escape the loop. If `--test-cmd` fails, the stop hook blocks the exit.
- **Trust Model:** The `--test-cmd` command comes from the user or from the repository. The stop hook runs this command after each turn. The hook does not ask for approval. Setup writes `.ralph/state.env` with owner-only permissions (umask 077). The hook rejects a state file that a different user owns or that git tracks. Use only commands that are safe for you to run.
