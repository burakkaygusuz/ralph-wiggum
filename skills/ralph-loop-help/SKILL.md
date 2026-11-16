---
name: ralph-loop-help
description: Explain the Ralph Wiggum iterative loop methodology, configuration flags, prompt writing patterns, and available commands. Use this skill when the user asks how the Ralph loop works, asks about a parameter, or needs help with a loop prompt. DO NOT use when the user asks to start or cancel an active loop.
---

# Ralph Loop Help & Guidance

The Ralph loop runs continuous, test-driven iterations over a plan that the agent updates. The loop continues until the checks of the stop hook pass.

## Core Mechanics

- **State & Fix Plan:** `.ralph/state.env` holds the state. `.ralph/fix_plan.md` holds the persistent plan.
- **Completion:** The loop ends when every plan item is checked and `--test-cmd` passes. The hook reads nothing from the agent's reply. To continue the work, the agent adds or leaves an unchecked plan item. This plugin removed the `--completion-promise` flag.
- **Max Iterations:** Limit on iterations (default: 10, 0 for no limit). For runs without a person present, use `${CLAUDE_PLUGIN_ROOT}/scripts/ralph-cli.sh`.
- **Hard Backpressure:** The hook runs `--test-cmd` on every turn. It accepts completion only after the command passes.

## Prompt Guidelines

1. **Include Verifiable Tests:** Pass `--test-cmd "npm test"` or `--test-cmd "pytest"`.
2. **Write Checkable Plan Items:** The plan decides completion. Write acceptance criteria that the agent can verify before it checks a plan item.
3. **Limit Total Iterations:** Set `--max-iterations 10` (the default) or a smaller value that is not 0.

## Commands & Scripts

If `${CLAUDE_PLUGIN_ROOT}` has no value, or the text is still literal, replace this variable with an absolute path. Use the path of the folder two levels above this SKILL.md file. That folder contains `scripts/`. A relative path can resolve from the workspace, so do not use one.

- The slash form to start or cancel a loop differs by host. See `README.md` in that folder, sections "How to Use Across All Agents" and "How to Cancel an Active Loop". The scripts are `${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop.sh` and `${CLAUDE_PLUGIN_ROOT}/scripts/cancel-ralph.sh`.
- `${CLAUDE_PLUGIN_ROOT}/scripts/ralph-cli.sh` runs the loop headless, without a plugin host.
