# Notes

Known issues and follow-ups that aren't urgent enough to fix inline.

## `print -P` with provider-sourced strings

`_zpun_ui_render_summary` (lib/ui.zsh) uses `print -P` to apply prompt-color
escapes, and interpolates `$pkg`, `$cur`, `$lat` directly into the format
string. `print -P` expands `%n`, `%m`, `%d`, `%D{…}`, and other prompt
sequences — so any `%` in a package name or version string gets interpreted.

Current data sources (brew/npm/uv/gem) don't produce `%` in names in practice,
but the background-mode pending file (`$XDG_STATE_HOME/zsh-pkg-update-nag/pending_updates`)
is a new data path that also flows through this renderer. If a future provider
or a corrupt pending file ever carried `%`, the output would be mangled.

Fix: escape `%` → `%%` on fields before handing them to `print -P`, or keep
color writes and content writes separate.

## Powerlevel10k instant-prompt compatibility (background mode)

`_zpun_precmd_nag` prints `(checking for package updates in the background…)`
to stdout during the first `precmd`. Users with powerlevel10k instant-prompt
enabled (`POWERLEVEL9K_INSTANT_PROMPT=quiet` or `verbose`) will see p10k
complain about "Console output during zsh initialization detected" at every
shell startup where background mode is active.

The final results display (update prompt or "all up to date") is also emitted
from `precmd`, so the same concern applies when the scan completes fast
enough to print before p10k finalizes the instant prompt.

Fix: detect `POWERLEVEL9K_INSTANT_PROMPT` and either suppress the "checking…"
notice (cosmetic loss only) or defer output until after the instant-prompt
buffer has been swapped in. OMZ's `tools/check_for_upgrade.sh` handles this
by checking `$POWERLEVEL9K_INSTANT_PROMPT` and going silent / deferring.

## ESC to dismiss the update prompt

Tier-1 prompt (`Update all? [Y/n/s]`) currently only accepts `y`/`n`/`s`/Enter.
ESC would be a more discoverable "skip everything" key — particularly for
users who expect the same behavior as a typical TUI. ESC arrives as a single
byte (`\033`) in `read -k 1`, so the plumbing is straightforward; treat it as
synonymous with `n`.

## Stray control characters during the spinner

If the user presses arrow keys (or any other escape-sequence-emitting key)
while `_zpun_ui_status` is updating its single-line spinner, the bytes echo
to the terminal and corrupt the display. Cosmetic but reads as broken UI.

Fix options: disable terminal echo during scan with `stty -echo` (and restore
on cleanup), or use `read -t 0` to drain stdin into `/dev/null` while the
spinner ticks. EXIT trap already exists in `_zpun_main`; the stty restore
needs to be wired into it alongside the existing cleanup.

## Auto-run `brew update`?

The plugin reports outdated packages but doesn't refresh the local index
first. For brew specifically, `brew outdated` only sees what's in the local
formula cache as of the last `brew update` — so a user who hasn't run
`brew update` recently sees stale results.

Open questions before implementing: do we run it every time (slow,
network-dependent) or only when the rate-limit window elapses? Do we honor
`HOMEBREW_NO_AUTO_UPDATE=1`? Brew already auto-updates on `brew install` /
`brew upgrade` by default, so once the user accepts the prompt, the index
gets refreshed downstream — running it ourselves first is redundant unless
they typically dismiss the prompt.

## Make background mode the default

`ZSH_PKG_UPDATE_NAG_BACKGROUND=1` is opt-in but is the right default for
most users — it keeps shell startup snappy and the scan still surfaces at
the first prompt. The synchronous mode is mainly useful when actively
debugging the plugin. Switching the default would mean making
`ZSH_PKG_UPDATE_NAG_FOREGROUND=1` (or `BACKGROUND=0`) the opt-out and
flipping the auto-run branch in `zsh-pkg-update-nag.plugin.zsh`.

Worth bundling with the p10k instant-prompt fix above — background mode
amplifies that issue.

## Add a CLAUDE.md spelling out priorities

The plugin runs on every shell startup, so two non-negotiables for any
contributor (or AI assistant) editing this codebase:

- **Code quality**: this is shareable open-source; favor explicit, tested,
  portable zsh over clever shortcuts. Watch for known zsh pitfalls
  (`local path=` shadowing `$PATH`, `local foo` re-declaring and printing
  existing values inside loops — both have bitten this codebase already).
- **Performance**: every millisecond at plugin-load time is felt at every
  shell open. Lookups that hit the network belong behind the cache and the
  background-mode path. Pre-cache. Batch. Avoid sourcing or computation at
  load time that isn't needed for the auto-run path.

A CLAUDE.md at repo root would put these in front of any AI agent (Claude
Code, Copilot CLI, Cursor) editing the project.

## Auto-update the plugin itself

`README.md`'s Limitations section currently says "No self-update. To update
the plugin itself, `git pull` inside its install directory." That's
friction users won't bother with. Options:

- A periodic `git -C $_ZPUN_DIR pull --ff-only` gated by its own (longer)
  rate-limit window — say every 7 days.
- Or piggyback on the existing rate-limit window and pull during the same
  scan that checks packages.
- Either way: only do it when `$_ZPUN_DIR` is a git repo (skip for users
  installed via `gem`/`brew`/`apt` style packaging where the dir is
  immutable).
- Notify the user when an update was pulled, so the change isn't silent.

## README polish pass

Whole-document readability sweep — the doc has grown organically as
features land and could benefit from a fresh read for ordering, redundancy,
and tone. No specific fix; flagged for a deliberate revision.

## Drop non-global package managers from the roadmap

The "Limitations / roadmap" section in `README.md` mentions Bun/Deno
globals as a future direction, but those tools' `outdated` commands only
operate on project deps — outside this plugin's "global tools at shell
startup" scope by design. Remove the entry rather than carry it as a
phantom roadmap item.

## Lazy-source provider files

`zsh-pkg-update-nag.plugin.zsh` sources `lib/providers/{brew,npm,uv,gem}.zsh`
at plugin load time, but `_zpun_collect_outdated` re-sources each one inside
its own `zsh -c` subshell when it runs. The top-level sources exist so that
`(( $+functions[_zpun_provider_$manager] ))` returns true in the parent — but
that guard is redundant given the subshell re-source.

Dropping the four top-level sources saves a couple of ms at plugin load and
the single source-of-truth lives inside `_zpun_collect_outdated`. Low
priority, but a free win in background mode where every millisecond at load
is more visible.
