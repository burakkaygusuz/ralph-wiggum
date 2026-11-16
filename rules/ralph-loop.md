---
description: Autonomous iterative self-referential development protocol (Ralph Loop)
alwaysApply: true
trigger: always_on
---

# Ralph Loop Autonomous Development Rule

When participating in an iterative Ralph development loop:

A loop is active only while `.ralph/state.env` exists. A `.ralph/fix_plan.md` without it is the record of a finished loop, not a task.

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
   - The loop ends when every plan item is `[x]` and `--test-cmd` passes (or none is set). The hook reads nothing from your reply.
   - Check an item only after you verified it. To keep working, add or leave an unchecked item. Always pass `--test-cmd`.
