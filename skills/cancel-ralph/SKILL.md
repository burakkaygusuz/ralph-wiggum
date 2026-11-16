---
name: cancel-ralph
description: Cancel and clean up an active Ralph loop. Use this skill when the user asks to stop, abort, cancel, end, or terminate a running loop or Ralph session. DO NOT use when the user asks to start a loop or to get help for a loop.
---

# Cancel Ralph Loop

This skill stops any active Ralph loop and deletes its workspace state.

This skill requires bash.

## Steps

If `${CLAUDE_PLUGIN_ROOT}` has no value, or the text is still literal, replace this variable with an absolute path. Use the path of the folder two levels above this SKILL.md file. That folder contains `scripts/`. A relative path can resolve from the workspace, so do not use one. On Copilot CLI this folder is under `~/.copilot/installed-plugins/`.

Run the script that cancels the loop:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cancel-ralph.sh
```
