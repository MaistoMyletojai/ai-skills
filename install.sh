#!/bin/bash
# Install AI skills to ~/.claude/skills/
# Usage: ./install.sh [skill-name]  — install one skill
#        ./install.sh               — install all skills

DEST="$HOME/.claude/skills"
mkdir -p "$DEST"

install_skill() {
  local skill_name="$1"
  local src="skills/$skill_name"
  if [ ! -d "$src" ]; then
    echo "✗ Skill not found: $skill_name"
    exit 1
  fi
  rm -rf "$DEST/$skill_name"
  cp -r "$src" "$DEST/$skill_name"
  echo "✓ $skill_name"
}

if [ -n "$1" ]; then
  install_skill "$1"
else
  for skill_dir in skills/*/; do
    install_skill "$(basename "$skill_dir")"
  done
fi

echo "Done. Skills installed to $DEST"
