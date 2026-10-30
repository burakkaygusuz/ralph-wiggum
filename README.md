# Ralph Wiggum

Ralph Wiggum is an autonomous development loop plugin for AI coding assistants, implementing Geoffrey Huntley's [Ralph Technique](https://ghuntley.com/ralph/). Instead of stopping after one turn or guessing if the code works, it keeps your agent iterating over a living implementation plan, inspecting test outputs, and self-correcting until objective criteria (compiler, linter, tests) confirm complete success.

---

## Why Use?

- **Zero-Babysitting Autonomy:** The agent picks the next priority from the implementation plan, writes code, runs tests, and self-corrects without requiring manual intervention every turn.
- **Minimal Dependencies:** Bash scripts plus `jq` for hook JSON. No Python, Node.js, Ruby, or pip/npm packages required.
- **Living Backlog & Persistent Scheduler:** Tracks work items, acceptance criteria, and verified progress in `.ralph/fix_plan.md`.
- **No More Half-Done Code:** Strictly terminates only when your success promise (`<promise>COMPLETE</promise>`) is genuinely verified and all work items are complete.
- **Test Integrity Guard:** Deterministically verifies that existing test files are not deleted to bypass test backpressure.
- **Git-Clean State:** Setup writes `.ralph/` to `.git/info/exclude` and does not touch `.gitignore`.
- **Works Across All Agents:** Compatible with **Claude Code**, **Cursor**, **OpenAI Codex**, **Google Antigravity**, and **GitHub Copilot**. The `<promise>` is read only from the agent's final reply; this is verified on Claude Code only. Codex and Cursor use schema-compatible output but are unverified, and Antigravity and Copilot are unverified. This repo ships no Antigravity hook config, so the loop does not auto-continue there; use `ralph-cli.sh` for unattended runs.
- **Safety First:** Safe default iteration cap (`--max-iterations 10`), continuous per-turn test verification (`--test-cmd`), and instant cancellation (`/cancel-ralph` or `Ctrl+C`).

---

## Environment & Compatibility Matrix

| Environment | Supported | Requirements / Notes |
| :--- | :---: | :--- |
| **Linux** | **Yes** | Bash (no bash-4 features used), `jq`, and core tools (`git`, `awk`, `sed`, `grep`, `date`). |
| **macOS** | **Yes** | Bash 3.2 (`/bin/bash`) works. `jq` is preinstalled on macOS 15+ (_unverified_); on earlier versions run `brew install jq`. `--test-cmd` is time-limited only when `timeout` or `gtimeout` is installed (`brew install coreutils`). |
| **Windows (Git Bash)** | _Unverified_ | Git for Windows is required for the hooks. `jq` is not bundled with Git for Windows; install it separately. |
| **Windows (WSL)** | _Unverified_ | Keep the repo in the Linux filesystem (for example `~/`), not under `/mnt/c`. Install `jq` inside the distro. |
| **Windows (PowerShell only)** | **No** | Not supported. Use Git Bash or WSL. |

---

## Installation

Ralph Wiggum conforms to the [Agent Plugins Specification (v1.0.0)](https://agent-plugins.org). You can install it across compatible AI agent clients and harnesses:

### Claude Code

```bash
/plugin marketplace add burakkaygusuz/ralph-wiggum
/plugin install ralph-wiggum
```

### OpenAI Codex & ChatGPT

```bash
codex plugin marketplace add burakkaygusuz/ralph-wiggum
codex plugin add ralph-wiggum@ralph-wiggum
```

### Universal 1-Liner (Any Agent via `npx skills`)

```bash
npx skills@latest add burakkaygusuz/ralph-wiggum
```

### Cursor & VS Code

Install via Cursor / VS Code Agent Plugins interface, or link directly:

```bash
./scripts/install-client.sh cursor
```

### Google Antigravity & GitHub Copilot

```bash
./scripts/install-client.sh antigravity  # ~/.gemini/config/skills
./scripts/install-client.sh copilot      # ~/.copilot/skills
```

### Open-Source Agents & CLI Harnesses (Hermes, OpenClaw, Kiro, NanoClaw)

Conformant clients discover `skills/` and `plugin.json` automatically:

```bash
# Universal installer for all local client environments
./scripts/install-client.sh all
```

---

## Parameters & Flags

| Flag                          |  Required  | Description                                                                                                                                                                          |
| :---------------------------- | :--------: | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PROMPT`                      |  **Yes**   | The task description, constraints, and goal for the agent.                                                                                                                           |
| `--max-iterations <N>`        | _Optional_ | Safety ceiling on turns (default: 10). Use `<plugin-dir>/scripts/ralph-cli.sh` for unattended runs; it exits non-zero when the ceiling is reached (0 = unlimited).                         |
| `--completion-promise <TEXT>` | _Optional_ | Stops the loop early the moment the agent verifies and outputs `<promise>TEXT</promise>`. Without it, `<promise>COMPLETE</promise>` or `<promise>DONE</promise>` is accepted. Setup rejects TEXT containing `<` or `\`, or with leading/trailing whitespace, because the stop hook could never match it. |
| `--test-cmd <COMMAND>`        | _Optional_ | Hard backpressure: Executes test command (`exit code 0`) on every turn before promise is accepted.                                                                                   |
| `--prompt-file <PATH>`        | _Optional_ | Read the task text from a file instead of arguments (use it for prompts with quotes or shell syntax). Relative paths resolve from the repository root. Cannot be combined with `PROMPT`. |
| `--force`                     | _Optional_ | Replace an existing active loop's state. Without it, setup refuses while `.ralph/state.env` exists.                                                                                 |

---

## How to Use Across All Agents

Ralph Loop can be invoked via **Slash Commands** (Claude Code), **Natural Language Prompts** (Cursor, Antigravity, Codex, Copilot), or **Headless CLI**.

### Scenario 1: Test-Driven Development (TDD with Hard Backpressure)

- **Claude Code:**

  ```bash
  /ralph-loop "Implement JWT auth with refresh tokens in src/auth/ and make all tests pass." --test-cmd "npm test" --completion-promise "AUTH_GREEN"
  ```

- **Cursor / Antigravity / Codex / Copilot (Chat):**

  ```text
  Run a ralph-loop to implement JWT auth with refresh tokens in src/auth/. Verify changes with 'npm test' and stop only when all tests pass with <promise>AUTH_GREEN</promise>.
  ```

---

### Scenario 2: Autonomous Refactoring (Refactoring with Safety Cap)

- **Claude Code:**

  ```bash
  /ralph-loop "Refactor database client to v2 and fix all deprecation warnings." --max-iterations 8
  ```

- **Cursor / Antigravity / Codex / Copilot (Chat):**

  ```text
  Start a ralph-loop with max 8 iterations to refactor the database client to v2 and eliminate all deprecation warnings.
  ```

---

### Scenario 3: End-to-End Feature Development (Feature Development & Verification)

- **Claude Code:**

  ```bash
  /ralph-loop "Implement rate limiting middleware with Redis store and unit tests." --completion-promise "RATE_LIMIT_READY" --max-iterations 10
  ```

- **Cursor / Antigravity / Codex / Copilot (Chat):**

  ```text
  Execute a ralph-loop to create rate limiting middleware with Redis store. Iterate until complete and verified, then output <promise>RATE_LIMIT_READY</promise>. Max 10 iterations.
  ```

---

### Scenario 4: Pure CLI (Headless Terminal Loop — 1 Clean Process Per Iteration)

For unbounded overnight tasks beyond chat host continuation limits:

```bash
# 1. Initialize loop state
<plugin-dir>/scripts/setup-ralph-loop.sh "Fix all compiler errors in src/" --max-iterations 0 --test-cmd "cargo test"

# 2. Start process loop
<plugin-dir>/scripts/ralph-cli.sh .ralph/fix_plan.md
```

`ralph-cli.sh` runs `$AGENT_BIN --print -p <prompt>` each iteration. `AGENT_BIN` defaults to `claude`, so `--print -p` is Claude Code syntax; set `AGENT_BIN` to another binary only if it accepts the same flags. Do not run a plugin-enabled interactive session in the same repo while `ralph-cli.sh` runs.

---

### How to Cancel an Active Loop

- **Claude Code:** `/cancel-ralph`
- **Cursor / Antigravity / Codex / Copilot (Chat):** `Cancel active ralph loop` or `Stop ralph loop`
- **Terminal / CLI:** `<plugin-dir>/scripts/cancel-ralph.sh` or `Ctrl+C`

---

## Safety & Controls

1. **Deterministic Exit & Continuous Backpressure:** `--test-cmd` is executed on every iteration to guarantee immediate error feedback and verify all tests pass before accepting `<promise>TEXT</promise>`.
2. **Test Integrity Guard:** Blocks completion if existing test files are deleted to bypass test backpressure.
3. **Clean Cancellation & Signal Trapping:** Handles `SIGINT` (`Ctrl+C`) and `SIGTERM` in CLI runner to clean up `.ralph` state instantly.
4. **Safety Ceiling:** Built-in default `--max-iterations 10` to prevent unexpected token spend on impossible tasks.
5. **Session Binding:** The loop binds to the first session that stops after setup. Stops from other sessions are ignored, with a stderr notice (logged by the hook; the host may not show it in the chat), until you re-run `setup-ralph-loop.sh --force` or cancel. A new session after `/clear` may be ignored the same way if the host issues a new session id (not verified).
6. **Known Limit (Agent-Writable State):** `.ralph/state.env` is plain files the agent can edit, so `--test-cmd`, `BASE_COMMIT` and `INITIAL_TASK_COUNT` are only as trusted as the agent's file access. Deny writes to `.ralph/state.env` in your agent's permissions or sandbox to close this; the agent still needs to edit `.ralph/fix_plan.md`, and `/ralph-loop` writes `.ralph/prompt.md`.

---

## License

Apache-2.0
