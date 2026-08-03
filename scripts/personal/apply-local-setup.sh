#!/bin/sh
# Installs this checkout as the active oh-my-claudecode plugin for the
# current user, so hand-patches on this fork (see PERSONAL_SETUP.md) survive
# `omc update` instead of being silently reverted the next time `omc setup`
# "repairs" the marketplace-installed plugin cache.
#
# Safe to re-run (idempotent): re-running after `omc-sync` picks up new
# upstream commits, or on a fresh machine after cloning this fork.
#
# What it does:
#   1. Adds/refreshes a marked block in ~/.zshrc: an `OMC_DEV_ROOT` export,
#      a `claude` alias that always passes --plugin-dir at this checkout,
#      and an `omc-sync` alias that replaces `omc update; omc setup`.
#   2. Merges `env.OMC_PLUGIN_ROOT` and `disabledMcpjsonServers: ["t"]` into
#      settings.json (additive merge — never overwrites unrelated keys).
#   3. Builds this checkout and runs `omc setup --plugin-dir-mode` against it.
#
# Does NOT affect the current Claude Code session — start a new session
# afterward (and `source ~/.zshrc`, or open a new shell) for it to take
# effect.

set -e

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ZSHRC="${OMC_PERSONAL_ZSHRC:-$HOME/.zshrc}"
MARKER_BEGIN="# >>> oh-my-claudecode personal fork setup >>>"
MARKER_END="# <<< oh-my-claudecode personal fork setup <<<"

echo "Repo:        $REPO_DIR"
echo "Config dir:  $CONFIG_DIR"
echo "Shell rc:    $ZSHRC"
echo

# 1. Shell alias block — idempotent: replace the marked block if present,
#    append it if not. Never touches anything outside the markers.
if [ -f "$ZSHRC" ] && grep -qF "$MARKER_BEGIN" "$ZSHRC"; then
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0 == b { skip = 1 }
    !skip { print }
    $0 == e { skip = 0 }
  ' "$ZSHRC" > "$ZSHRC.omc-tmp"
  mv "$ZSHRC.omc-tmp" "$ZSHRC"
  echo "Refreshing existing alias block in $ZSHRC"
else
  echo "Adding alias block to $ZSHRC"
fi

{
  echo ""
  echo "$MARKER_BEGIN"
  echo "# Managed by scripts/personal/apply-local-setup.sh in the fork — re-run"
  echo "# that script instead of hand-editing this block. See PERSONAL_SETUP.md."
  echo "export OMC_DEV_ROOT=\"$REPO_DIR\""
  echo "alias claude='claude --plugin-dir \"\$OMC_DEV_ROOT\"'"
  echo "alias omc-sync='(cd \"\$OMC_DEV_ROOT\" && git fetch upstream dev && git rebase upstream/dev && npm install && npm run build && OMC_PLUGIN_ROOT=\"\$OMC_DEV_ROOT\" omc setup --plugin-dir-mode)'"
  echo "$MARKER_END"
} >> "$ZSHRC"

# 2. settings.json — additive merge only.
if [ -f "$CONFIG_DIR/settings.json" ]; then
  python3 - "$CONFIG_DIR/settings.json" "$REPO_DIR" <<'PYEOF'
import json
import sys

path, repo_dir = sys.argv[1], sys.argv[2]
with open(path) as f:
    config = json.load(f)

config.setdefault("env", {})["OMC_PLUGIN_ROOT"] = repo_dir

servers = config.setdefault("disabledMcpjsonServers", [])
if "t" not in servers:
    servers.append("t")

with open(path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")

print(f"Updated {path}")
PYEOF
else
  echo "Warning: $CONFIG_DIR/settings.json not found, skipping settings merge" >&2
fi

# 3. Build and link as the active plugin.
cd "$REPO_DIR"
npm install
npm run build
OMC_PLUGIN_ROOT="$REPO_DIR" omc setup --plugin-dir-mode

echo
echo "Done. Restart your shell (or 'source $ZSHRC') and start a NEW Claude Code"
echo "session — this one will keep running the marketplace-installed version."
