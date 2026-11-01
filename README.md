# Ralph Wiggum

Keep your AI coding agent working until the tests pass.

Ralph Wiggum is a plugin that implements Geoffrey Huntley's [Ralph Technique](https://ghuntley.com/ralph/). A stop hook blocks the agent from ending its turn. The agent keeps working through a plan in `.ralph/fix_plan.md` until your tests pass and it states a completion promise, or until the iteration limit is reached. Cursor and Antigravity need no promise.

## Quickstart

```bash
/plugin marketplace add burakkaygusuz/ralph-wiggum
/plugin install ralph-wiggum
```

```bash
/ralph-loop "Implement JWT auth in src/auth/ and make all tests pass." --test-cmd "npm test" --completion-promise "AUTH_GREEN"
```

Stop at any time with `/cancel-ralph`. Other agents: see [Installation](#installation) and [Host Status](#host-status).

## Why Use?

- **Hard backpressure:** The hook runs `--test-cmd` after every turn. The hook accepts completion only when the tests pass and the work items are checked.
- **Safety cap:** At most 10 iterations by default (`--max-iterations`). A test integrity guard blocks completion when test files were deleted.
- **Zero dependencies:** Bash with POSIX `sed` and `awk`. No Python, Node.js or package installs.
- **Git-clean:** State lives in `.ralph/`, which setup adds to `.git/info/exclude`. Your `.gitignore` stays untouched.
- **Six agents:** Claude Code, Grok Build, Cursor, OpenAI Codex, Google Antigravity and GitHub Copilot. See [Host Status](#host-status) for what was verified.

---

## Installation

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

### OpenAI Codex & ChatGPT

```bash
codex plugin marketplace add burakkaygusuz/ralph-wiggum
codex plugin add ralph-wiggum@ralph-wiggum
```

Codex skips plugin hooks until you trust them. Run `/hooks` in an interactive session, or use `codex exec --dangerously-bypass-hook-trust` for a single headless run.

### Cursor & VS Code

Install via the Cursor / VS Code Agent Plugins interface. The plugin ships `.cursor-plugin/plugin.json`, with hooks from `hooks/cursor-hooks.json`.

### Google Antigravity

```bash
agy plugin install https://github.com/burakkaygusuz/ralph-wiggum
```

Headless `agy -p` cannot prompt, so it needs `--dangerously-skip-permissions` or an allow rule.

### Other Clients

No stop hook ships. Use `ralph-cli.sh` (see [Headless CLI](#headless-cli)).

---

## Host Status

| Host            | Run live                                           | Reads `<promise>` | Notes                                                                                                                         |
| :-------------- | :------------------------------------------------- | :---------------: | :---------------------------------------------------------------------------------------------------------------------------- |
| **Claude Code** | Install, loop, cancel                              |        Yes        | The only fully verified host.                                                                                                 |
| **Antigravity** | Install, full headless loop, cancel (`agy` 1.4.12) |        No         | Stop payloads carry no assistant text. The hook skips stops that carry an `error` or have `fullyIdle` false.                  |
| **Codex**       | Setup, cancel, stop hook in `codex exec` (0.166.0) |    Not tested     | The hook ran after trust. A `$schema` field in the root `plugin.json` makes Codex load no plugin hooks, so the file omits it. |
| **Cursor**      | No                                                 |        No         | Follows the Cursor plugin docs. Stop payloads carry no assistant text.                                                        |
| **Grok Build**  | No                                                 |  Yes (per docs)   | Follows the Grok hook docs; the hook reads `lastAssistantMessage`. Grok ends a turn after 8 continuations.                    |
| **Copilot**     | No                                                 |   No (per docs)   | Hooks live in `com.github.copilot/hooks/hooks.json`. The Stop payload has no `last_assistant_message`.                        |

Where no assistant text arrives (Cursor, Antigravity), the loop ends in one of two cases. First, `--test-cmd` passes, every plan item is checked and no test file was deleted. Second, the iteration limit is reached. Copilot sends no assistant text either, but the hook has no no-promise path for it, so its loop ends only at the iteration limit.

---

## Environment & Compatibility

| Environment |  Supported   | Notes                                                                                                            |
| :---------- | :----------: | :--------------------------------------------------------------------------------------------------------------- |
| **Linux**   |   **Yes**    | Bash and core tools (`git`, `awk`, `sed`, `grep`, `date`).                                                       |
| **macOS**   |   **Yes**    | Bash 3.2 works. `--test-cmd` has a time limit only if `timeout` or `gtimeout` exists (`brew install coreutils`). |
| **Windows** | _Unverified_ | Git Bash, or WSL with the repo under `~/` (not `/mnt/c`). PowerShell alone is not supported.                     |

---

## Parameters & Flags

Run `<plugin-dir>/scripts/setup-ralph-loop.sh --help` for the usage text and exit codes.

| Flag                          |  Required  | Description                                                                                                                                                             |
| :---------------------------- | :--------: | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PROMPT`                      |  **Yes**   | The task, constraints and goal.                                                                                                                                         |
| `--max-iterations <N>`        | _Optional_ | Iteration limit (default 10, 0 = unlimited).                                                                                                                            |
| `--completion-promise <TEXT>` | _Optional_ | Text the hook accepts in `<promise>TEXT</promise>`. Default: `COMPLETE` or `DONE`. No `<`, `\`, `"`, `&`, control characters or edge whitespace.                        |
| `--test-cmd <COMMAND>`        | _Optional_ | Runs from the repo root on every turn (120 s limit if `timeout` or `gtimeout` is installed). The hook accepts completion only when it exits 0.                          |
| `--prompt-file <PATH>`        | _Optional_ | Read the task from a file (relative to the current directory). Use it for quotes or shell syntax. Not with `PROMPT`. Setup script only; `/ralph-loop` does not take it. |
| `--force`                     | _Optional_ | Replace the state of an active loop.                                                                                                                                    |

---

## How to Use Across All Agents

Claude Code uses slash commands. Cursor, Antigravity, Codex and Copilot take natural language. Grok Build lists the skills as slash forms.

```bash
/ralph-loop "Implement JWT auth in src/auth/." --test-cmd "npm test" --completion-promise "AUTH_GREEN"
/ralph-loop "Refactor the database client to v2 and fix all deprecation warnings." --max-iterations 5
```

```text
Run a ralph-loop to implement JWT auth in src/auth/. Verify with 'npm test' and stop only when all tests pass with <promise>AUTH_GREEN</promise>.
```

### Headless CLI

For overnight runs beyond chat continuation limits (one clean process per iteration):

```bash
<plugin-dir>/scripts/setup-ralph-loop.sh "Fix all compiler errors in src/" --max-iterations 0 --test-cmd "cargo test"
<plugin-dir>/scripts/ralph-cli.sh
```

`ralph-cli.sh` runs `$AGENT_BIN -p <prompt>` each iteration. `AGENT_BIN` defaults to `claude`. Set another binary (for example `grok`) only if it accepts the same flags. Headless `grok` cancels tool calls that need permission, so set its permissions yourself. Do not run a plugin-enabled interactive session in the same repo meanwhile.

---

## How to Cancel an Active Loop

- **Claude Code, Grok Build, Cursor, Antigravity:** `/cancel-ralph`
- **Codex:** `$cancel-ralph`
- **Copilot (VS Code):** `/ralph-wiggum:cancel-ralph`
- **Any chat:** `Cancel active ralph loop`
- **Terminal:** `<plugin-dir>/scripts/cancel-ralph.sh`, or `Ctrl+C` while `ralph-cli.sh` runs

When the loop ends on its own, the hook deletes only `.ralph/state.env`. `.ralph/fix_plan.md` stays so you can see what was done and what is left. The next setup replaces it. Cancel deletes the whole `.ralph/` folder.

---

## Safety Notes

- **Session binding:** The loop binds to the first session that stops after setup. The hook ignores stops from other sessions and writes a notice to stderr, which the host can hide. Run `setup-ralph-loop.sh --force` or cancel to bind a new session. After `/clear` the host can issue a new session id, and the hook then ignores it (not verified).
- **Agent-writable state:** `.ralph/state.env` is a plain file the agent can edit. It can change `--test-cmd`, `BASE_COMMIT` and `INITIAL_TASK_COUNT`. Use your agent's permissions or sandbox to block writes to it. The agent must still write `.ralph/fix_plan.md` (each turn) and `.ralph/prompt.md` (written by `/ralph-loop`).

---

## License

Apache-2.0
