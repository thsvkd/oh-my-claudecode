#!/bin/sh
# One-shot bootstrap: makes this checkout the active oh-my-claudecode install
# for the current user, so hand-patches on this fork (see PERSONAL_SETUP.md)
# survive `omc update` instead of being silently reverted the next time
# `omc setup` "repairs" the marketplace-installed plugin cache.
#
# Run it once on a fresh machine right after cloning the fork, and re-run it
# any time afterwards — the result is the same either way, whether or not OMC
# was already installed here by npm or the plugin marketplace.
#
# What it does:
#   0. Checks the tools it needs, and fails with a usable message if one is
#      missing rather than dying inside npm.
#   1. Ensures the `upstream` remote exists, so omc-sync has something to
#      fetch. A fresh clone of the fork only has `origin`.
#   2. Adds/refreshes a marked block in the shell rc: an `OMC_DEV_ROOT`
#      export, a `claude` alias that always passes --plugin-dir at this
#      checkout, and an `omc-sync` alias.
#   3. Builds this checkout and links it via `setup --plugin-dir-mode`.
#   4. Merges `env.OMC_PLUGIN_ROOT` + `disabledMcpjsonServers: ["t"]` into
#      settings.json — AFTER step 3, because on a fresh machine settings.json
#      does not exist until setup creates it.
#   5. Verifies every one of those landed, and exits non-zero if any did not.
#
# Does NOT affect the current Claude Code session — start a new session
# afterward (and `source` your shell rc, or open a new shell).

set -e

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
SHELL_RC="${OMC_PERSONAL_ZSHRC:-$HOME/.zshrc}"
UPSTREAM_URL="https://github.com/Yeachan-Heo/oh-my-claudecode.git"
MARKER_BEGIN="# >>> oh-my-claudecode personal fork setup >>>"
MARKER_END="# <<< oh-my-claudecode personal fork setup <<<"

echo "Repo:        $REPO_DIR"
echo "Config dir:  $CONFIG_DIR"
echo "Shell rc:    $SHELL_RC"
echo

# 0. Preflight. Everything below needs these; checking up front turns a
#    confusing mid-run failure into one actionable line.
missing=""
for tool in git node npm; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  echo "Missing required tool(s):$missing" >&2
  echo "Install them and re-run this script." >&2
  exit 1
fi

# 1. upstream remote — a fresh clone of the fork only has origin, and
#    omc-sync fetches upstream/dev. Idempotent: adds it only when absent and
#    never rewrites a URL the user set deliberately.
if git -C "$REPO_DIR" remote get-url upstream >/dev/null 2>&1; then
  echo "Upstream remote already configured: $(git -C "$REPO_DIR" remote get-url upstream)"
else
  git -C "$REPO_DIR" remote add upstream "$UPSTREAM_URL"
  echo "Added upstream remote: $UPSTREAM_URL"
fi

# 2. Shell alias block — idempotent: replace the marked block if present,
#    append it if not. Never touches anything outside the markers.
if [ -f "$SHELL_RC" ] && grep -qF "$MARKER_BEGIN" "$SHELL_RC"; then
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0 == b { skip = 1 }
    !skip { print }
    $0 == e { skip = 0 }
  ' "$SHELL_RC" > "$SHELL_RC.omc-tmp"
  mv "$SHELL_RC.omc-tmp" "$SHELL_RC"
  echo "Refreshing existing alias block in $SHELL_RC"
else
  echo "Adding alias block to $SHELL_RC"
fi

{
  echo ""
  echo "$MARKER_BEGIN"
  echo "# Managed by scripts/personal/apply-local-setup.sh in the fork — re-run"
  echo "# that script instead of hand-editing this block. See PERSONAL_SETUP.md."
  echo "export OMC_DEV_ROOT=\"$REPO_DIR\""
  echo "alias claude='claude --plugin-dir \"\$OMC_DEV_ROOT\"'"
  # The sync steps live in scripts/personal/sync.sh: a rebase cannot run
  # with a dirty worktree, and dist/ + bridge/ are tracked yet rebuilt on
  # every build, so the sequence needs conditionals an alias cannot hold.
  echo "alias omc-sync='sh \"\$OMC_DEV_ROOT/scripts/personal/sync.sh\"'"
  echo "$MARKER_END"
} >> "$SHELL_RC"

# 3. Build and link as the active plugin. Must run through this checkout's
#    OWN bridge/cli.cjs, not whatever `omc` resolves to on PATH: omc's
#    installer copies file-based templates (e.g. the HUD cache wrapper) via
#    getPackageDir(), which resolves from the __dirname of the CLI binary
#    actually running and does NOT consult OMC_PLUGIN_ROOT. A globally
#    installed `omc` would silently re-copy the unpatched marketplace
#    version of that wrapper even with OMC_PLUGIN_ROOT set correctly.
#
#    Deliberately NOT passing CLAUDE_PLUGIN_ROOT here. It would make the
#    installer treat itself as already running as the plugin and skip writing
#    ~/.claude/CLAUDE.md entirely — measured, and caught by the verify step
#    below. The hook-duplication question it would have settled is handled as
#    a warning at the end instead.
cd "$REPO_DIR"
npm install
npm run build
OMC_PLUGIN_ROOT="$REPO_DIR" node "$REPO_DIR/bridge/cli.cjs" setup --plugin-dir-mode

# 4. settings.json — additive merge, and it must run AFTER setup: on a fresh
#    machine the file does not exist beforehand, and merging first meant the
#    keys were silently dropped while the script still exited 0.
mkdir -p "$CONFIG_DIR"
node - "$SETTINGS" "$REPO_DIR" <<'NODE'
const fs = require('node:fs');
const [path, repoDir] = process.argv.slice(2);

let config = {};
if (fs.existsSync(path)) {
  const raw = fs.readFileSync(path, 'utf8').trim();
  if (raw) {
    try {
      config = JSON.parse(raw);
    } catch (error) {
      console.error(`Refusing to merge: ${path} is not valid JSON (${error.message})`);
      process.exit(1);
    }
  }
}

config.env = config.env && typeof config.env === 'object' ? config.env : {};
config.env.OMC_PLUGIN_ROOT = repoDir;

if (!Array.isArray(config.disabledMcpjsonServers)) config.disabledMcpjsonServers = [];
if (!config.disabledMcpjsonServers.includes('t')) config.disabledMcpjsonServers.push('t');

fs.writeFileSync(path, `${JSON.stringify(config, null, 2)}\n`);
console.log(`Updated ${path}`);
NODE

# 5. Prune the standalone hook copies so hooks come from exactly one place —
#    this checkout's plugin manifest. See the script header for why.
echo
echo "Reconciling hooks..."
node "$REPO_DIR/scripts/personal/prune-standalone-hooks.mjs" "$CONFIG_DIR" "$REPO_DIR" "$SETTINGS"

# 6. Verify. Without this the script could report success while leaving the
#    checkout unlinked — exactly the failure this step exists to catch.
echo
echo "Verifying setup..."
node - "$SETTINGS" "$REPO_DIR" "$SHELL_RC" "$CONFIG_DIR" <<'NODE'
const fs = require('node:fs');
const [settingsPath, repoDir, shellRc, configDir] = process.argv.slice(2);
const failures = [];

const read = path => (fs.existsSync(path) ? fs.readFileSync(path, 'utf8') : null);

const settingsRaw = read(settingsPath);
if (settingsRaw === null) {
  failures.push(`settings.json missing at ${settingsPath}`);
} else {
  const settings = JSON.parse(settingsRaw);
  if (settings?.env?.OMC_PLUGIN_ROOT !== repoDir) {
    failures.push(`env.OMC_PLUGIN_ROOT is ${JSON.stringify(settings?.env?.OMC_PLUGIN_ROOT)}, expected ${repoDir}`);
  }
  if (!settings?.disabledMcpjsonServers?.includes('t')) {
    failures.push('disabledMcpjsonServers does not contain "t"');
  }
}

const rc = read(shellRc);
if (rc === null) failures.push(`shell rc missing at ${shellRc}`);
else {
  for (const needle of [`export OMC_DEV_ROOT="${repoDir}"`, '--plugin-dir', 'alias omc-sync=']) {
    if (!rc.includes(needle)) failures.push(`shell rc is missing ${needle}`);
  }
  const blocks = rc.split('# >>> oh-my-claudecode personal fork setup >>>').length - 1;
  if (blocks !== 1) failures.push(`shell rc has ${blocks} setup blocks, expected exactly 1`);
}

if (!read(`${configDir}/CLAUDE.md`)) failures.push(`CLAUDE.md missing at ${configDir}/CLAUDE.md`);
if (!fs.existsSync(`${repoDir}/dist/cli/index.js`)) failures.push('build output missing at dist/cli/index.js');

// Hooks reach Claude Code through this checkout's own plugin manifest, which
// --plugin-dir loads. That path must exist; whether the installer ALSO wrote
// standalone copies into ~/.claude depends on what it found in settings.json,
// so report which arrangement this machine ended up with instead of guessing.
if (!fs.existsSync(`${repoDir}/hooks/hooks.json`)) {
  failures.push('plugin hook manifest missing at hooks/hooks.json');
}
// Step 5 pruned these, so anything left means hooks would fire twice.
const leftovers = fs.existsSync(`${repoDir}/templates/hooks`)
  ? fs.readdirSync(`${repoDir}/templates/hooks`)
      .filter(name => fs.existsSync(`${configDir}/hooks/${name}`))
  : [];
if (leftovers.length) {
  failures.push(`standalone hook copies still in ${configDir}/hooks: ${leftovers.join(', ')}`);
}

if (failures.length) {
  console.error('Setup verification FAILED:');
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log('  settings.json  OMC_PLUGIN_ROOT + disabledMcpjsonServers ok');
console.log('  shell rc       exactly one setup block, aliases present');
console.log('  CLAUDE.md      installed');
console.log('  build output   present');
console.log('  hooks          this checkout\'s plugin manifest only');
NODE

echo
command -v claude >/dev/null 2>&1 \
  || echo "Note: the 'claude' CLI is not on PATH yet. Install Claude Code; the alias is already in place for when it is."
echo "Done. Restart your shell (or 'source $SHELL_RC') and start a NEW Claude Code"
echo "session — this one keeps running whatever it started with."
