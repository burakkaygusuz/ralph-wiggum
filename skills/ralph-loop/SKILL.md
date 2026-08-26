---
name: ralph-loop
description: Run an autonomous, iterative development loop using the Ralph Wiggum technique. Use this skill when the user wants continuous test-driven iteration, automated refactoring until tests pass, or execution bounded by a completion promise. DO NOT use for one-shot bug fixes, single-pass queries, or simple explanations.
---

# Ralph Loop (Iterative Autonomous Development)

## Parameters

- `PROMPT` (required): Task description, architecture requirements, and acceptance criteria.
- `--max-iterations <N>` (optional, default: 10): Safety ceiling on turns (0 for unbounded in CLI, host chat sessions cap at 5-10 turns).
- `--completion-promise '<TEXT>'` (optional): Exact string in `<promise>TEXT</promise>` required to stop.
- `--test-cmd '<CMD>'` (optional): Command executed deterministically by stop hook before accepting completion.
- `--force` (optional): Override an existing active Ralph loop state.

## Execution Workflow

1. **Initialize State & Living Scheduler:**
   Run the setup script:
   ```bash
   ./scripts/setup-ralph-loop.sh "$PROMPT" [--max-iterations N] [--completion-promise TEXT] [--test-cmd CMD] [--force]
   ```

2. **Iterate & Self-Correct (Huntley 1-Item Discipline):**
   On each turn:
   - Read `.ralph/fix_plan.md` and check `git status`.
   - Review `Working Memory & Cross-Turn Learnings` for findings from previous iterations.
   - Select exactly ONE highest-priority uncompleted work item from the queue.
   - Implement the changes and run verification tests (`npm test`, `pytest`, `cargo test`).
   - Update `Working Memory` with new insights and mark the item `[x]` with test evidence in `.ralph/fix_plan.md`.

3. **Terminate:**
   - Output `<promise>TEXT</promise>` in your response AND append it to `.ralph/fix_plan.md` **ONLY** when all work items and test criteria are completely verified.
   - Stop and summarize remaining blockers when max iterations is reached.

## Gotchas

- **Host Safety Limits:** In-session chat hosts (Claude Code, Cursor, Copilot) enforce internal runaway caps (typically 5-10 consecutive turns). For unbounded overnight iteration, use the standalone headless runner (`./scripts/ralph-cli.sh`).
- **Test Integrity:** NEVER alter, mock out, or delete existing test assertions to force a passing build. Fix application code.
- **Promise Integrity:** Never emit `<promise>...</promise>` early or to escape the loop. If `--test-cmd` fails, the stop hook will block exit.
