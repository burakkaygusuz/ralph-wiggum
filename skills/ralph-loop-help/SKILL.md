---
name: ralph-loop-help
description: Explain the Ralph Wiggum iterative loop methodology, configuration flags, prompt writing patterns, and available commands. Use this skill when the user asks how Ralph loop works, asks for parameter explanations, or needs help structuring a loop prompt. DO NOT use when the user asks to start or cancel an active loop.
---

# Ralph Loop Help & Guidance

The Ralph loop executes continuous, test-driven iterations over a living implementation plan until deterministic verification criteria pass.

## Core Mechanics

- **State & Fix Plan:** State is tracked in `.ralph/state.env` and the persistent backlog in `.ralph/fix_plan.md`.
- **Completion Promise:** Stopping token wrapped in `<promise>TEXT</promise>`, emitted only when criteria pass.
- **Max Iterations:** Bounded turn limit (default: 10). Note that interactive chat hosts enforce a 5-10 turn runaway guard; use `./scripts/ralph-cli.sh` for unbounded execution.
- **Hard Backpressure:** Automated execution of `--test-cmd` on every turn before completion is accepted.

## Prompt Guidelines

1. **Include Verifiable Tests:** Pass `--test-cmd "npm test"` or `--test-cmd "pytest"`.
2. **Define a Clear Promise:** Use specific tokens like `--completion-promise "AUTH_READY"`.
3. **Bound Total Turns:** Specify `--max-iterations 10`.

## Commands & Scripts

- `/ralph-loop [PROMPT] [FLAGS]` or `./scripts/setup-ralph-loop.sh`
- `/cancel-ralph` or `./scripts/cancel-ralph.sh`
- `./scripts/ralph-cli.sh` for headless out-of-process execution.
