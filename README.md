# Ralph Wiggum

Ralph Wiggum is an autonomous development loop plugin for AI coding assistants, implementing Geoffrey Huntley's [Ralph Technique](https://ghuntley.com/ralph/). The agent does not stop after one turn and does not guess if the code works. It iterates over a living implementation plan and reads the test output. It corrects itself until objective criteria (compiler, linter, tests) confirm success.

---

## Why Use?

- **Zero-Babysitting Autonomy:** The agent picks the next item from the plan, writes code, runs tests, and corrects itself. It needs no manual action in each turn.
- **Minimal Dependencies:** Bash scripts with POSIX `sed` and `awk` for hook JSON. No Python, Node.js, Ruby, or pip/npm packages required.
- **Living Backlog & Persistent Scheduler:** Tracks work items, acceptance criteria, and verified progress in `.ralph/fix_plan.md`.
- **No More Half-Done Code:** The loop ends only when the agent outputs your completion promise (`<promise>COMPLETE</promise>`), the tests pass, and all work items are complete. (Cursor and Antigravity send no assistant text, so there the tests, plan and guards decide.)
- **Test Integrity Guard:** Deterministically verifies that existing test files are not deleted to bypass test backpressure.
- **Git-Clean State:** Setup writes `.ralph/` to `.git/info/exclude` and does not touch `.gitignore`.
- **Works Across All Agents:** Compatible with **Claude Code**, **Grok Build**, **Cursor**, **OpenAI Codex**, **Google Antigravity**, and **GitHub Copilot**. The `<promise>` is read only from the agent's last reply; this is verified on Claude Code only. Codex, Cursor, Grok Build and Antigravity use schema-compatible output but are unverified, and Copilot is unverified.
- **Safety First:** The default iteration limit (`--max-iterations 10`), continuous per-turn test verification (`--test-cmd`), and cancellation at any time (`/cancel-ralph` or `Ctrl+C`).

---

## Environment & Compatibility Matrix

| Environment                   |  Supported   | Requirements / Notes                                                                                                                  |
| :---------------------------- | :----------: | :------------------------------------------------------------------------------------------------------------------------------------ |
| **Linux**                     |   **Yes**    | Bash (no bash-4 features used) and core tools (`git`, `awk`, `sed`, `grep`, `date`).                                                  |
| **macOS**                     |   **Yes**    | Bash 3.2 (`/bin/bash`) works. `--test-cmd` is time-limited only when `timeout` or `gtimeout` is installed (`brew install coreutils`). |
| **Windows (Git Bash)**        | _Unverified_ | Git for Windows is required for the hooks.                                                                                            |
| **Windows (WSL)**             | _Unverified_ | Keep the repo in the Linux filesystem (for example `~/`), not under `/mnt/c`.                                                         |
| **Windows (PowerShell only)** |    **No**    | Not supported. Use Git Bash or WSL.                                                                                                   |

---

## Installation

Ralph Wiggum conforms to the [Agent Plugins Specification (v1.0.0)](https://agent-plugins.org). You can install it across compatible AI agent clients and harnesses:

### Claude Code

```bash
/plugin marketplace add burakkaygusuz/ralph-wiggum
/plugin install ralph-wiggum
```

### Grok Build

```bash
grok plugin marketplace add burakkaygusuz/ralph-wiggum
grok plugin install ralph-wiggum --trust
```

This follows the official Grok Build hook documentation; it was not run on a live `grok`. Grok sends the last reply as `lastAssistantMessage`, and the stop hook reads that key. Grok ends a turn after 8 continuations. Send a new prompt to continue the loop. No stop hook is documented for other Grok products (grok.com, X, the xAI API).

### OpenAI Codex & ChatGPT

```bash
codex plugin marketplace add burakkaygusuz/ralph-wiggum
codex plugin add ralph-wiggum@ralph-wiggum
```

### Cursor & VS Code

Install via the Cursor / VS Code Agent Plugins interface. Cursor stop payloads carry no assistant text, so no `<promise>` can be read there. The loop ends in one of two cases. First, `--test-cmd` passes, every plan item is checked, and no test file was deleted. Second, the iteration limit is reached.

The plugin ships `.cursor-plugin/plugin.json` (hooks from `hooks/cursor-hooks.json`, rules and skills from their default folders). It follows the official Cursor plugin docs; it was not run on a live Cursor.

### Google Antigravity

```bash
agy plugin install https://github.com/burakkaygusuz/ralph-wiggum
```

This follows the official Antigravity hook documentation; it was not run on a live `agy`. The root `hooks.json` runs the stop hook, and the hook answers `{"decision":"continue"}`. The Antigravity docs also show `"block"` for plugin hooks; if the loop does not continue, change `continue` in `scripts/stop-hook.sh`. Stop payloads carry no assistant text, so no `<promise>` can be read. The loop ends in the same two cases as on Cursor. The hook skips stops that carry an `error` or that have `fullyIdle` false.

### Other Clients

No stop hook ships for other clients. Use `ralph-cli.sh` for unattended runs (see Scenario 4).

---

## Parameters & Flags

| Flag                          |  Required  | Description                                                                                                                                                                                                                                                                                                                              |
| :---------------------------- | :--------: | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PROMPT`                      |  **Yes**   | The task description, constraints, and goal for the agent.                                                                                                                                                                                                                                                                               |
| `--max-iterations <N>`        | _Optional_ | Iteration limit (default: 10). Use `<plugin-dir>/scripts/ralph-cli.sh` for unattended runs; it exits non-zero when the limit is reached (0 = unlimited).                                                                                                                                                                                 |
| `--completion-promise <TEXT>` | _Optional_ | Stops the loop when the agent verifies the work and outputs `<promise>TEXT</promise>`. Without it, the hook accepts `<promise>COMPLETE</promise>` or `<promise>DONE</promise>`. Setup rejects TEXT that contains `<`, `\`, `"`, `&` or control characters, or that has leading or trailing whitespace. The stop hook cannot match these. |
| `--test-cmd <COMMAND>`        | _Optional_ | Hard backpressure: Executes test command (`exit code 0`) from the repo root on every turn, limited to 120 s, before promise is accepted.                                                                                                                                                                                                 |
| `--prompt-file <PATH>`        | _Optional_ | Read the task text from a file instead of arguments (use it for prompts with quotes or shell syntax). Relative paths resolve from the current directory. Do not combine it with `PROMPT`.                                                                                                                                                |
| `--force`                     | _Optional_ | Replace an existing active loop's state. Without it, setup rejects the command while `.ralph/state.env` exists.                                                                                                                                                                                                                          |

---

## How to Use Across All Agents

Ralph Loop can be invoked via **Slash Commands** (Claude Code; other hosts list the skills as slash forms, see "How to Cancel an Active Loop"), **Natural Language Prompts** (Cursor, Antigravity, Codex, Copilot), or **Headless CLI**.

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
<plugin-dir>/scripts/ralph-cli.sh
```

`ralph-cli.sh` runs `$AGENT_BIN -p <prompt>` each iteration. `AGENT_BIN` defaults to `claude`; set it to another binary (for example `grok`) only if it accepts the same flags. In headless mode, `grok` cancels tool calls that need permission, so set its permissions yourself. Do not run a plugin-enabled interactive session in the same repo while `ralph-cli.sh` runs.

---

### How to Cancel an Active Loop

- **Claude Code, Grok Build, Cursor, Antigravity:** `/cancel-ralph`
- **Codex:** `$cancel-ralph`
- **Copilot (VS Code):** `/ralph-wiggum:cancel-ralph`
- **Any chat:** `Cancel active ralph loop` or `Stop ralph loop`. The `cancel-ralph` skill runs the script.
- **Terminal / CLI:** `<plugin-dir>/scripts/cancel-ralph.sh` or `Ctrl+C`

Only Claude Code is verified. The other forms follow the host docs and were not run live.

---

## Safety & Controls

1. **Deterministic Exit & Continuous Backpressure:** The hook runs `--test-cmd` on every iteration. The agent gets error feedback at once. The hook accepts `<promise>TEXT</promise>` only after all tests pass.
2. **Test Integrity Guard:** Blocks completion if existing test files are deleted to bypass test backpressure.
3. **Clean Cancellation & Signal Trapping:** Handles `SIGINT` (`Ctrl+C`) and `SIGTERM` in the CLI runner to clean up `.ralph` state.
4. **Safety Ceiling:** Built-in default `--max-iterations 10` to prevent unexpected token spend on impossible tasks.
5. **Session Binding:** The loop binds to the first session that stops after setup. The hook ignores stops from other sessions and writes a notice to stderr. The host can hide this notice. Run `setup-ralph-loop.sh --force` or cancel the loop to bind a new session. After `/clear`, the host can issue a new session id, and the hook then ignores that session (not verified).
6. **Known Limit (Agent-Writable State):** `.ralph/state.env` is a plain file that the agent can edit. The agent can therefore change `--test-cmd`, `BASE_COMMIT` and `INITIAL_TASK_COUNT`. To prevent this problem, use the permissions or the sandbox of your agent. Do not let the agent write to `.ralph/state.env`. Let the agent write to `.ralph/fix_plan.md`, because the agent changes this file in each turn. Also let the agent write to `.ralph/prompt.md`, because the `/ralph-loop` command writes this file.

---

## License

Apache-2.0
