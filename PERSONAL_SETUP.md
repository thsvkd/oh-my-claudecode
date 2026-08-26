# Personal fork setup

This is a personal fork of [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode),
used as the actual OMC install on this machine — not just a staging area for
upstream PRs.

## Why this exists

Two HUD fixes (reasoning-effort display, and a `/model`-switch staleness bug
in the statusLine cache wrapper) were submitted upstream as
[PR #3626](https://github.com/Yeachan-Heo/oh-my-claudecode/pull/3626), closed
by the maintainer as needing an owner decision (not merged).

The marketplace-installed plugin has no supported way to keep a local patch
across `omc update` — confirmed the hard way: hand-patching the plugin cache
directly (`~/.claude/plugins/cache/omc/oh-my-claudecode/<version>/`) survives
until the next `omc setup`, which detected the drift and silently "repaired"
those files back to the unpatched marketplace version.

The supported alternative (`docs/REFERENCE.md#plugin-directory-flags`, Flow A
in `CONTRIBUTING.md`) is to run Claude Code against a local checkout via
`--plugin-dir`, so our commits are always present in the checkout Claude Code
actually loads. `git rebase upstream/dev` keeps pulling in new upstream
commits with our commits staying on top.

## What `apply-local-setup.sh` does

See the header comment in `scripts/personal/apply-local-setup.sh` for the
exact steps. Summary: adds a marked, idempotent block to `~/.zshrc` (an
`OMC_DEV_ROOT` export, a `claude` alias that always passes `--plugin-dir` at
this checkout, and an `omc-sync` alias that runs `scripts/personal/sync.sh`), merges `env.OMC_PLUGIN_ROOT` +
`disabledMcpjsonServers: ["t"]` into `~/.claude/settings.json`, then builds
and links this checkout via `omc setup --plugin-dir-mode`.

Run it once to set up a machine:

```bash
sh scripts/personal/apply-local-setup.sh
```

Then start a **new** Claude Code session (or a new shell) — the current one
keeps running whatever it started with.

## Day-to-day workflow

| Instead of...          | Run...       |
| ----------------------- | ------------ |
| `omc update; omc setup` | `omc-sync`   |
| `claude`                | `claude` (unchanged — the alias makes this transparent) |

`omc-sync` runs `scripts/personal/sync.sh`, which discards stale build
output in `dist/` and `bridge/`, fetches `upstream/dev`, rebases this branch
onto it (our commits stay on top), reinstalls deps, rebuilds, and re-links
via this checkout's own CLI in `--plugin-dir-mode`. If the rebase hits a
conflict, resolve it manually (`git status` will show the conflicted files),
then re-run `omc-sync` — it's a normal `git rebase`, nothing special.

It refuses to start when anything outside `dist/` and `bridge/` is dirty, so
in-progress work is never discarded on your behalf.

### ⚠️ Don't `git restore dist/ bridge/` after building for personal use

`omc-hud.mjs` imports `dist/hud/index.js` directly from this checkout at
*every* statusline call — it's a live import, not a one-time copy. If you
run `npm run build` and then `git restore dist/ bridge/` (e.g. while
preparing a clean diff for an upstream PR — `dist/`/`bridge/` are tracked
but their compiled content shouldn't appear in PR diffs, per
`CONTRIBUTING.md`), that restore **reverts the compiled output your running
HUD is actually reading**, silently regressing patched features back to
whatever was last committed — with no error, just missing behavior. Hit
this exact issue once: effort-level display vanished after a commit-prep
`git restore`, even though `dist/` had it working moments before.

If you ever need to `git restore dist/ bridge/` on this checkout, run
`npm run build` again immediately after (or just `omc-sync`).

This is also why `omc-sync` may discard those two paths on its own: it
always rebuilds them before finishing, so the running HUD never ends up
reading reverted output.

## Re-running the setup script

Safe to re-run any time (e.g. after `omc-sync`, or on a new machine after
cloning this fork). It detects and replaces its own marked block in
`~/.zshrc` rather than duplicating it, and only merges (never overwrites)
into `settings.json`.

## If this needs to be undone

- Remove the marked block between `# >>> oh-my-claudecode personal fork
  setup >>>` and `# <<< ... <<<` in `~/.zshrc`.
- Remove `env.OMC_PLUGIN_ROOT` from `~/.claude/settings.json` (leave
  `disabledMcpjsonServers` — it's a no-op once plugin-dir mode is off).
- Run `omc setup` (without `--plugin-dir-mode`) once to re-sync the
  marketplace-installed plugin's agents/skills/HUD.
