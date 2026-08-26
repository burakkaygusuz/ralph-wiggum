# Ralph Wiggum

Ralph Wiggum is an autonomous development loop plugin for AI coding assistants, implementing Geoffrey Huntley's [Ralph Technique](https://ghuntley.com/ralph/). Instead of stopping after one turn or guessing if the code works, it keeps your agent iterating over a living implementation plan, inspecting test outputs, and self-correcting until objective criteria (compiler, linter, tests) confirm complete success.

---

## Why Use?

- **Zero-Babysitting Autonomy:** The agent picks the next priority from the implementation plan, writes code, runs tests, and self-corrects without requiring manual intervention every turn.
- **Zero Runtime Dependencies:** Pure Bash script engine. No Python, Node.js, Ruby, or external pip/npm packages required.
- **Living Backlog & Persistent Scheduler:** Tracks work items, acceptance criteria, and verified progress in `.ralph/fix_plan.md`.
- **No More Half-Done Code:** Strictly terminates only when your success promise (`<promise>COMPLETE</promise>`) is genuinely verified and all work items are complete.
- **Test Integrity Guard:** Deterministically verifies that test files are not deleted or tampered with to bypass test backpressure.
- **Works Across All Agents:** Compatible with **Claude Code**, **Cursor**, **OpenAI Codex**, **Google Antigravity**, and **GitHub Copilot**.
- **Safety First:** Safe default iteration cap (`--max-iterations 10`), continuous per-turn test verification (`--test-cmd`), and instant cancellation (`/cancel-ralph` or `Ctrl+C`).

---

## Environment & Compatibility Matrix

| Environment | Supported | Requirements / Notes |
| :--- | :---: | :--- |
| **Linux** | **Yes** | Bash 4.0+ and core tools (`git`, `awk`, `sed`, `grep`, `date`). |
| **macOS** | **Yes** | Native Terminal / zsh / bash with standard CLI utilities. |
| **Windows (Git Bash)** | **Yes** | Git Bash (bundled with Git for Windows). |
| **Windows (WSL)** | **Yes** | WSL (Ubuntu, Debian, or any Linux distro). |
| **Windows (CMD / PowerShell)** | _Via Git Bash / WSL_ | Requires Git Bash or WSL terminal environment. |

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
| `--max-iterations <N>`        | _Optional_ | Safety ceiling on turns (default: 10). Note: interactive chat hosts enforce a 5-10 turn runaway guard; use `./scripts/ralph-cli.sh` for unbounded loops (0 = unlimited).             |
| `--completion-promise <TEXT>` | _Optional_ | Stops the loop early the moment the agent verifies and outputs `<promise>TEXT</promise>`.                                                                                            |
| `--test-cmd <COMMAND>`        | _Optional_ | Hard backpressure: Executes test command (`exit code 0`) on every turn before promise is accepted.                                                                                   |

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
./scripts/setup-ralph-loop.sh "Fix all compiler errors in src/" --max-iterations 0 --test-cmd "cargo test"

# 2. Start process loop
./scripts/ralph-cli.sh .ralph/fix_plan.md
```

---

### How to Cancel an Active Loop

- **Claude Code:** `/cancel-ralph`
- **Cursor / Antigravity / Codex / Copilot (Chat):** `Cancel active ralph loop` or `Stop ralph loop`
- **Terminal / CLI:** `./scripts/cancel-ralph.sh` or `Ctrl+C`

---

## Safety & Controls

1. **Deterministic Exit & Continuous Backpressure:** `--test-cmd` is executed on every iteration to guarantee immediate error feedback and verify all tests pass before accepting `<promise>TEXT</promise>`.
2. **Test Integrity Guard:** Blocks completion if existing test files are deleted or tampered with to bypass test backpressure.
3. **Clean Cancellation & Signal Trapping:** Handles `SIGINT` (`Ctrl+C`) and `SIGTERM` in CLI runner to clean up `.ralph` state instantly.
4. **Safety Ceiling:** Built-in default `--max-iterations 10` aligned with host continuation limits to prevent unexpected token spend on impossible tasks.

---

## License

Apache-2.0
