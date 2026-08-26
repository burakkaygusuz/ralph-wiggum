#!/usr/bin/env bash
set -euo pipefail

# Multi-Client Agent Skills Symlinker
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-all}"
SKILLS=("ralph-loop" "cancel-ralph" "ralph-loop-help")

link_skills() {
  local dir="$1"
  mkdir -p "$dir"
  for s in "${SKILLS[@]}"; do
    local target_path="$dir/$s"
    if [[ -d "$target_path" && ! -L "$target_path" ]]; then
      echo "Notice: Non-symlink directory exists at $target_path, backing up to $target_path.bak"
      mv "$target_path" "$target_path.bak"
    fi
    ln -sfn "$REPO_ROOT/skills/$s" "$target_path"
  done
  echo "Linked skills to $dir"
}

case "$TARGET" in
  antigravity|agy|gemini) link_skills "$HOME/.gemini/config/skills" ;;
  codex|openai)           link_skills "$HOME/.agents/skills" ;;
  cursor)                 link_skills "$HOME/.cursor/skills" ;;
  copilot|github)         link_skills "$HOME/.copilot/skills" ;;
  claude)                 link_skills "$HOME/.claude/skills" ;;
  all)
    for d in "$HOME/.gemini/config/skills" "$HOME/.agents/skills" "$HOME/.cursor/skills" "$HOME/.copilot/skills" "$HOME/.claude/skills"; do
      link_skills "$d"
    done
    ;;
  *) echo "Usage: $0 [antigravity|codex|cursor|copilot|claude|all]" >&2; exit 1 ;;
esac
