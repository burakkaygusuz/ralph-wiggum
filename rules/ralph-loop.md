---
description: Autonomous iterative self-referential development protocol (Ralph Loop)
alwaysApply: true
trigger: always_on
---

# Ralph Loop Autonomous Development Rule

When participating in an iterative Ralph development loop:

1. **Plan & Backlog Inspection:**
   - Read `.ralph/fix_plan.md` and check `git status` at the start of your turn.
   - Consult the `Working Memory & Cross-Turn Learnings` section for architectural context discovered in prior turns.
   - Select the single highest-priority uncompleted work item from the work queue.

2. **Codebase Exploration:**
   - Search the repository before implementing. Never assume functionality is missing without checking.

3. **Complete Implementation (No Stubs / No Placeholders):**
   - Implement complete, production-ready code. Never leave stub functions, TODO placeholders, or mock implementations.

4. **Test Integrity Guard (Zero Cheating):**
   - NEVER modify, delete, or comment out existing test suites or assertions to force a passing build.
   - Fix the actual application code to satisfy test criteria.

5. **Automated Verification (Backpressure):**
   - Always run the relevant test suite or compiler (e.g., `npm test`, `pytest`, `cargo test`) after changes.
   - Fix any compiler or test errors before concluding the turn.

6. **Scheduler, Learnings & Plan Update:**
   - Record newly discovered architectural insights and quirks in `Working Memory & Cross-Turn Learnings`.
   - Mark the completed work item as `[x]` and document verification evidence in `.ralph/fix_plan.md`.
   - If `--completion-promise` is set, output `<promise>TEXT</promise>` in your last reply **ONLY** when you verified all work items and test criteria.
   - Do not write the promise in `.ralph/fix_plan.md`. The stop hook reads it only from your last reply (`last_assistant_message`, or `lastAssistantMessage` on Grok).
   - Cursor sends no assistant text, so the hook reads no promise there. The loop ends when `--test-cmd` passes and every plan item is `[x]`.
   - In Cursor, check an item only after you verify it. Always pass `--test-cmd`.
