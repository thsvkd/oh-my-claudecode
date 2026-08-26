// Drop the standalone hook copies the installer writes into ~/.claude.
//
// This checkout is always loaded through --plugin-dir, so its hooks/hooks.json
// already supplies every hook. The installer ALSO writes ~/.claude copies
// whenever settings.json has no marketplace OMC entry, and those then fire
// alongside the plugin ones (upstream #2252). Pruning them is what makes a
// fresh machine end up in the same state as one that already had OMC
// installed — the whole point of running one bootstrap script everywhere.
//
// Only files this fork itself ships as hook templates are touched, so
// third-party hooks living in the same directory are left alone.
//
// Usage: node prune-standalone-hooks.mjs <configDir> <repoDir> <settingsPath>

import fs from 'node:fs';
import path from 'node:path';

const [configDir, repoDir, settingsPath] = process.argv.slice(2);
if (!configDir || !repoDir || !settingsPath) {
  console.error('Usage: prune-standalone-hooks.mjs <configDir> <repoDir> <settingsPath>');
  process.exit(2);
}

// find-node.sh and lib/config-dir.sh are installed from scripts/, not
// templates/hooks/, so they are named explicitly.
const owned = new Set(['find-node.sh', 'lib/config-dir.sh']);
const collect = (dir, prefix = '') => {
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) collect(path.join(dir, entry.name), rel);
    else owned.add(rel);
  }
};
collect(path.join(repoDir, 'templates', 'hooks'));

const hooksDir = path.join(configDir, 'hooks');
const removedFiles = [];
for (const rel of owned) {
  const target = path.join(hooksDir, ...rel.split('/'));
  if (fs.existsSync(target)) {
    fs.rmSync(target);
    removedFiles.push(rel);
  }
}
for (const dir of [path.join(hooksDir, 'lib'), hooksDir]) {
  if (fs.existsSync(dir) && fs.readdirSync(dir).length === 0) fs.rmdirSync(dir);
}

// A settings.json hook entry naming a script that no longer exists is a
// runtime error rather than a no-op, so the matching entries go with the
// files. Entries for anything else are left untouched.
let droppedEntries = 0;
if (fs.existsSync(settingsPath)) {
  const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  const isOwnedCommand = command =>
    typeof command === 'string'
    && [...owned].some(name => command.includes(`/hooks/${name}`));

  if (settings.hooks && typeof settings.hooks === 'object') {
    for (const [event, matchers] of Object.entries(settings.hooks)) {
      if (!Array.isArray(matchers)) continue;
      const kept = [];
      for (const matcher of matchers) {
        if (!Array.isArray(matcher?.hooks)) {
          kept.push(matcher);
          continue;
        }
        const inner = matcher.hooks.filter(hook => {
          const isOurs = isOwnedCommand(hook?.command);
          if (isOurs) droppedEntries += 1;
          return !isOurs;
        });
        if (inner.length) kept.push({ ...matcher, hooks: inner });
      }
      if (kept.length) settings.hooks[event] = kept;
      else delete settings.hooks[event];
    }
    if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
    fs.writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);
  }
}

console.log(
  removedFiles.length || droppedEntries
    ? `  Pruned ${removedFiles.length} standalone hook file(s), ${droppedEntries} settings.json entr(y/ies)`
    : '  No standalone hook copies present'
);
