---
name: cancel-ralph
description: Cancel and clean up an active Ralph loop session. Use this skill when the user asks to stop, abort, cancel, or terminate a running loop. DO NOT use when starting or querying help for a loop.
---

# Cancel Ralph Loop

Aborts any active Ralph loop and cleans up workspace state.

## Execution

If `${CLAUDE_PLUGIN_ROOT}` has no value, or the text is still literal, use the absolute path of the folder two levels above this SKILL.md file instead. That folder contains `scripts/`. A relative path can resolve from the workspace, so do not use one. On Copilot CLI this folder is under `~/.copilot/installed-plugins/`.

Run the cancellation script:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cancel-ralph.sh
```
