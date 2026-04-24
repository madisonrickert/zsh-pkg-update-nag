# zsh-pkg-update-nag

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell: zsh](https://img.shields.io/badge/shell-zsh%205%2B-green)](https://www.zsh.org/)
[![Platforms: macOS | Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)]()

A zsh plugin that nags you — gently, and no more than once every 4 hours — about outdated global packages when you open a new terminal, and offers to update them behind a single `Y/n/s` confirmation.

```
▲ 3 updates available

  Homebrew
    gh      2.60.0 → 2.62.0
    fd      10.1.0 → 10.2.0
  npm (global)
    pnpm    9.0.0  → 9.5.1

  Update all? [Y/n/s] ›
```

- **`Y`** (or Enter) — run every upgrade in sequence, grouped by manager.
- **`n`** — skip everything; no re-nag until the next interval.
- **`s`** — drop into per-package `Y/n` across all managers.

Supports **Homebrew** (formulae *and* casks), **npm (global)**, **uv tools**, and **RubyGems**. Managers are enabled independently, each with a choice of `all` (scan everything), `off`, or an explicit allowlist.

### Why?

You already have `brew outdated`, `npm outdated -g`, `uv tool list --outdated`. Running them by hand is friction nobody actually keeps up with. A session-start nag surfaces updates at a moment you're already at the keyboard and ready to decide — without turning into `topgrade` (which upgrades everything) or an auto-updater (which decides for you).

## Install

Pick whichever matches your setup. Each path is ~30 seconds.

### oh-my-zsh

**1.** Clone into the custom-plugins directory:

```sh
git clone https://github.com/madisonrickert/zsh-pkg-update-nag \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-pkg-update-nag"
```

**2.** Add `zsh-pkg-update-nag` to the `plugins=(...)` array in your `~/.zshrc` — typically near the top, alongside `git`, `brew`, etc.:

```zsh
plugins=(
  git
  # ...your existing plugins...
  zsh-pkg-update-nag
)
```

**3.** Reload: `exec zsh` (or open a new terminal).

### zinit

```zsh
# in ~/.zshrc
zinit light madisonrickert/zsh-pkg-update-nag
```

### antidote

```sh
# in ~/.zsh_plugins.txt
madisonrickert/zsh-pkg-update-nag
```

### Standalone (plain zsh, no framework)

```sh
git clone https://github.com/madisonrickert/zsh-pkg-update-nag ~/.zsh-pkg-update-nag

# Append the source line — run this once
echo 'source ~/.zsh-pkg-update-nag/zsh-pkg-update-nag.plugin.zsh' >> ~/.zshrc

exec zsh
```

### Verify it worked

Open a fresh terminal. In the default (synchronous) mode the check runs before your first prompt — if anything is outdated you'll see the update prompt; if nothing's outdated the shell is silent. In background mode (`ZSH_PKG_UPDATE_NAG_BACKGROUND=1`) a dim `(checking…)` notice appears at the first prompt and results follow once the scan finishes.

Confirm detected managers and the computed config any time with:

```sh
zsh-pkg-update-nag --check-env
```

Subsequent shells within the 4-hour rate-limit window stay silent. Run `zsh-pkg-update-nag --now` to force a check on demand.

## Configuration

All options are optional. Defaults are sensible.

File location: `${XDG_CONFIG_HOME:-$HOME/.config}/zsh-pkg-update-nag/config.zsh` (override with `$ZSH_PKG_UPDATE_NAG_CONFIG`).

```zsh
# ~/.config/zsh-pkg-update-nag/config.zsh

# How often to check (hours). Default: 4.
zsh_pkg_update_nag_interval_hours=4

# Per-manager: "off", "all", or a zsh array / whitespace-separated string of
# package names to watch. Default shown.
zsh_pkg_update_nag_brew=all
zsh_pkg_update_nag_npm=all
zsh_pkg_update_nag_uv=all
zsh_pkg_update_nag_gem=off

# Example: watch only two npm globals.
# zsh_pkg_update_nag_npm=(typescript prettier)
```

### Environment variables

| Variable | Purpose |
|---|---|
| `ZSH_PKG_UPDATE_NAG_DISABLE=1` | Disable the plugin entirely (no check on shell start). |
| `ZSH_PKG_UPDATE_NAG_BACKGROUND=1` | Run the scan in the background so plugin load returns instantly (see below). |
| `ZSH_PKG_UPDATE_NAG_FORCE=1` | Ignore the rate-limit for this shell. |
| `ZSH_PKG_UPDATE_NAG_SSH=1` | Opt in under SSH sessions (default: skipped). |
| `ZSH_PKG_UPDATE_NAG_DEBUG=1` | Append diagnostics to `$XDG_STATE_HOME/zsh-pkg-update-nag/debug.log`. |
| `ZSH_PKG_UPDATE_NAG_PROVIDER_TIMEOUT` | Per-provider timeout in seconds (default `10`). |
| `ZSH_PKG_UPDATE_NAG_CONFIG` | Override config file path. |
| `NO_COLOR=1` | Disable color output (respected per the [NO_COLOR](https://no-color.org) spec). |

#### Background mode (`ZSH_PKG_UPDATE_NAG_BACKGROUND=1`)

By default the plugin scans synchronously at shell startup and blocks until all providers have responded. Setting this variable makes the scan run in a background process instead, so your shell prompt appears immediately.

```zsh
# ~/.zshrc (before the plugin loads)
export ZSH_PKG_UPDATE_NAG_BACKGROUND=1
```

What you'll see:

- **First prompt** — a dim notice `(checking for package updates in the background…)` appears once while the scan is in flight.
- **When the scan finishes** (before your next prompt) — either the normal update prompt, or `All packages up to date.` if nothing needs upgrading.
- **`--now`** always runs synchronously regardless of this setting, so progress output remains visible.

Results are written atomically to `$XDG_STATE_HOME/zsh-pkg-update-nag/pending_updates` and consumed once displayed. If you open several shells at once, the rate-limit lock ensures only one background scan runs; subsequent shells will pick up the same results when their first prompt fires.

## Subcommands

```sh
zsh-pkg-update-nag --now         # run the check immediately
zsh-pkg-update-nag --check-env   # show detected managers, config, and next-check time
zsh-pkg-update-nag --help
```

Tab-completion for these flags is shipped as `_zsh-pkg-update-nag`. oh-my-zsh picks it up automatically; standalone users may need to run `compinit` (or open a fresh shell) once after installing.

## When the plugin does nothing

By design, the check is skipped in any of these cases:

- Non-interactive shells (scripts, here-docs).
- Dumb terminals (`TERM=dumb`), non-TTY stdin/stdout, `INSIDE_EMACS` set.
- `CI` environment variable set.
- SSH sessions, unless you opt in with `ZSH_PKG_UPDATE_NAG_SSH=1`.
- Within the rate-limit window.
- Another shell is mid-check (file-lock held).

## Uninstall

```sh
# oh-my-zsh
rm -rf "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-pkg-update-nag"
# remove the entry from your plugins=(...) in ~/.zshrc

# standalone
rm -rf ~/.zsh-pkg-update-nag
# remove the `source` line from ~/.zshrc

# optional: wipe state + config
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/zsh-pkg-update-nag"
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/zsh-pkg-update-nag"
```

## Troubleshooting

Nothing happens on shell start?

1. `ZSH_PKG_UPDATE_NAG_FORCE=1 zsh-pkg-update-nag --now` to bypass the rate-limit.
2. `zsh-pkg-update-nag --check-env` to confirm managers are detected and configured.
3. `ZSH_PKG_UPDATE_NAG_DEBUG=1 zsh-pkg-update-nag --now` and then `cat ~/.local/state/zsh-pkg-update-nag/debug.log`.

## Requirements

- **zsh** 5.0 or newer.
- **Optional:** `jq` (improves Homebrew version-delta display — without it, brew versions show as `?`), `timeout` / `gtimeout` (wraps provider calls with a 10s timeout). On macOS, `gtimeout` is part of `coreutils`: `brew install coreutils`.

## Limitations / roadmap

- **Bun and Deno globals aren't supported yet.** Both `bun outdated` and `deno outdated` currently only operate on project dependencies, not globally-installed tools. Will add once upstream supports global mode.
- **No self-update.** To update the plugin itself, `git pull` inside its install directory.

## Contributing

Issues and PRs welcome. Tests use [bats-core](https://github.com/bats-core/bats-core):

```sh
brew install bats-core
bats tests/
```

The codebase is zsh-specific (not bash-portable). A few conventions worth knowing before submitting a PR:

- Every function begins with `emulate -L zsh` + `setopt local_options` so user shell options can't alter behavior.
- Commands are invoked array-style (`local cmd=(brew upgrade "$pkg"); "${cmd[@]}"`) — never `eval` on user-or-network-derived strings.
- Internal symbols are prefixed `_zpun_`; public env vars are `ZSH_PKG_UPDATE_NAG_*`.
- `shellcheck` output is noisy for zsh syntax (`${(f)…}`, `$+functions[…]`, etc.); `zsh -n` is the authoritative parse check.

## License

MIT — see [LICENSE](LICENSE).
