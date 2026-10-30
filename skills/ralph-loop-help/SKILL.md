---
name: ralph-loop-help
description: Explain the Ralph Wiggum iterative loop methodology, configuration flags, prompt writing patterns, and available commands. Use this skill when the user asks how Ralph loop works, asks for parameter explanations, or needs help structuring a loop prompt. DO NOT use when the user asks to start or cancel an active loop.
---

# Ralph Loop Help & Guidance

The Ralph loop executes continuous, test-driven iterations over a living implementation plan until deterministic verification criteria pass.

## Core Mechanics

- **State & Fix Plan:** State is tracked in `.ralph/state.env` and the persistent backlog in `.ralph/fix_plan.md`.
- **Completion Promise:** Stopping token wrapped in `<promise>TEXT</promise>`, emitted only when criteria pass.
- **Max Iterations:** Bounded turn limit (default: 10, 0 for unbounded). For unattended runs, use `${CLAUDE_PLUGIN_ROOT}/scripts/ralph-cli.sh`.
- **Hard Backpressure:** Automated execution of `--test-cmd` on every turn before completion is accepted.

## Prompt Guidelines

1. **Include Verifiable Tests:** Pass `--test-cmd "npm test"` or `--test-cmd "pytest"`.
2. **Define a Clear Promise:** Use specific tokens like `--completion-promise "AUTH_READY"`.
3. **Bound Total Turns:** Specify `--max-iterations 10` (the default) or a smaller value.

## Commands & Scripts

- `/ralph-loop [PROMPT] [FLAGS]` or `${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh`
- `/cancel-ralph` or `${CLAUDE_PLUGIN_ROOT}/scripts/cancel-ralph.sh`
- `${CLAUDE_PLUGIN_ROOT}/scripts/ralph-cli.sh` for headless out-of-process execution.
