#!/usr/bin/env bash
# Install `/caffeinate` and `/decaffeinate` as user-level commands, so they work
# without the plugin's `claude-caffeinate:` prefix (plugin commands always carry it).
#
#   bash scripts/install-commands.sh              install
#   bash scripts/install-commands.sh --uninstall  remove
set -eu

cc="$(cd "$(dirname "$0")" && pwd)/caffeinate.sh"
dest="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/commands"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$dest/caffeinate.md" "$dest/decaffeinate.md"
  echo "Removed /caffeinate and /decaffeinate from $dest"
  exit 0
fi

mkdir -p "$dest"
write() { # $1 file, $2 description, $3 subcommand
  cat > "$dest/$1" <<MD
---
description: $2
allowed-tools: Bash(bash:*)
---

!\`bash "$cc" $3\`

Report the line above to the user, nothing more.
MD
}
write caffeinate.md   "Hold the Mac awake until decaffeinated" on
write decaffeinate.md "Let the Mac sleep again — release this session's locks, hooks off" off
echo "Installed /caffeinate and /decaffeinate in $dest (they call $cc)"
