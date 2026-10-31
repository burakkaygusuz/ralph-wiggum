---
name: ralph-loop-help
description: Explain the Ralph Wiggum iterative loop methodology, configuration flags, prompt writing patterns, and available commands. Use this skill when the user asks how the Ralph loop works, asks about a parameter, or needs help with a loop prompt. DO NOT use when the user asks to start or cancel an active loop.
---

# Ralph Loop Help & Guidance

The Ralph loop executes continuous, test-driven iterations over a living implementation plan until deterministic verification criteria pass.

## Core Mechanics

- **State & Fix Plan:** `.ralph/state.env` holds the state. `.ralph/fix_plan.md` holds the persistent backlog.
- **Completion Promise:** The text in the form `<promise>TEXT</promise>`. The agent outputs it only when all criteria pass.
- **Max Iterations:** Limit on turns (default: 10, 0 for no limit). For unattended runs, use `${CLAUDE_PLUGIN_ROOT}/scripts/ralph-cli.sh`.
- **Hard Backpressure:** The hook runs `--test-cmd` on every turn. It accepts completion only after the command passes.

## Prompt Guidelines

1. **Include Verifiable Tests:** Pass `--test-cmd "npm test"` or `--test-cmd "pytest"`.
2. **Define a Clear Promise:** Use specific tokens like `--completion-promise "AUTH_READY"`.
3. **Bound Total Turns:** Specify `--max-iterations 10` (the default) or a smaller value.

## Commands & Scripts

If `${CLAUDE_PLUGIN_ROOT}` has no value, or the text is still literal, use the absolute path of the folder two levels above this SKILL.md file instead. That folder contains `scripts/`. A relative path can resolve from the workspace, so do not use one.

- Start and cancel: the slash form differs per host. See `README.md` in that folder, sections "How to Use Across All Agents" and "How to Cancel an Active Loop". Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh` and `${CLAUDE_PLUGIN_ROOT}/scripts/cancel-ralph.sh`.
- `${CLAUDE_PLUGIN_ROOT}/scripts/ralph-cli.sh` for headless out-of-process execution.
