# zsh-pkg-update-nag

[![CI](https://github.com/madisonrickert/zsh-pkg-update-nag/actions/workflows/ci.yml/badge.svg)](https://github.com/madisonrickert/zsh-pkg-update-nag/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell: zsh](https://img.shields.io/badge/shell-zsh%205%2B-green)](https://www.zsh.org/)
[![Platforms: macOS | Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)]()

A zsh plugin that surfaces outdated global packages at the start of a shell session and offers a one-keystroke `Y/n/s` upgrade. Rate-limited to once every four hours, skipped in SSH and scripts, and never blocks shell startup.

```
▲ 4 updates available

  Homebrew
    gh           2.60.0 → 2.62.0
    fd           10.1.0 → 10.2.0
  npm (global)
    pnpm         9.0.0  → 9.5.1
    claude-code  2.1.0  → 2.1.1

  Update all? [Y/n/s] ›
```

- **`Y`** (or Enter): run every upgrade in sequence, grouped by manager.
- **`n`** (or Esc): skip everything; no re-nag until the next interval.
- **`s`**: step through per-package `Y/n` across all managers.

Supports **Homebrew** (formulae and casks), **npm (global)**, **pnpm (global)**, **uv tools**, and **RubyGems**. Each manager is independently configurable as `all`, `off`, or an explicit allowlist.

### Why?

You already have `brew outdated`, `npm outdated -g`, `uv tool list --outdated`. Running them by hand is friction nobody keeps up with. A session-start nag catches updates at a moment you're at the keyboard and ready to decide, without becoming `topgrade` (which upgrades everything) or an auto-updater (which decides for you).

## Install

Pick whichever matches your setup.

### oh-my-zsh

Clone into the custom-plugins directory:

```sh
git clone https://github.com/madisonrickert/zsh-pkg-update-nag \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-pkg-update-nag"
```

Add `zsh-pkg-update-nag` to the `plugins=(...)` array in your `~/.zshrc`, then `exec zsh`.

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

### zdot

[zdot](https://github.com/georgeharker/zdot) ships a built-in [`update-nag` module](https://github.com/georgeharker/zdot/tree/main/modules/update-nag) that wraps this plugin:

```zsh
# in your .zshrc, alongside other zdot_load_module calls
zdot_load_module update-nag
```

### Standalone (plain zsh)

```sh
git clone https://github.com/madisonrickert/zsh-pkg-update-nag ~/.zsh-pkg-update-nag
echo 'source ~/.zsh-pkg-update-nag/zsh-pkg-update-nag.plugin.zsh' >> ~/.zshrc
exec zsh
```

### Verify it worked

Open a fresh terminal. The scan runs in the background, so your prompt appears immediately. A dim `(checking…)` notice flashes while the scan is in flight, then results land in place (either the update prompt or `All packages up to date.`) before your next prompt.

Confirm detected managers and the computed config any time:

```sh
zsh-pkg-update-nag --check-env
```

Subsequent shells within the four-hour rate-limit window stay silent. Run `zsh-pkg-update-nag --now` to force a check on demand.

### Keeping the plugin updated

The plugin doesn't self-update. Your install path already has that covered:

- **oh-my-zsh**: `omz update` pulls every custom plugin under `$ZSH_CUSTOM/plugins/`. For periodic auto-updates of OMZ and every plugin, see [Pilaton/OhMyZsh-full-autoupdate](https://github.com/Pilaton/OhMyZsh-full-autoupdate).
- **zinit**: `zinit update`.
- **antidote**: `antidote update`.
- **Standalone**: `git -C ~/.zsh-pkg-update-nag pull`.

## Configuration

All options are optional. Defaults are sensible.

Config file location: `${XDG_CONFIG_HOME:-$HOME/.config}/zsh-pkg-update-nag/config.zsh` (override with `$ZSH_PKG_UPDATE_NAG_CONFIG`).

```zsh
# ~/.config/zsh-pkg-update-nag/config.zsh

# How often to check (hours). Default: 4.
zsh_pkg_update_nag_interval_hours=4

# Per-manager: "off", "all", or a zsh array / whitespace-separated list of
# package names to watch. Default shown.
zsh_pkg_update_nag_brew=all
zsh_pkg_update_nag_npm=all
zsh_pkg_update_nag_pnpm=all
zsh_pkg_update_nag_uv=all
zsh_pkg_update_nag_gem=off

# Example: watch only two npm globals.
# zsh_pkg_update_nag_npm=(typescript prettier)

# Minimum release age in days (0 = off, the default). See the section below.
zsh_pkg_update_nag_min_age=0
# zsh_pkg_update_nag_min_age_npm=14   # per-manager override; wins over the global
```

### Environment variables

| Variable | Purpose |
|---|---|
| `ZSH_PKG_UPDATE_NAG_DISABLE=1` | Disable the plugin entirely. |
| `ZSH_PKG_UPDATE_NAG_FORCE=1` | Ignore the rate-limit for this shell. |
| `ZSH_PKG_UPDATE_NAG_SSH=1` | Opt in under SSH (default: skipped). |
| `ZSH_PKG_UPDATE_NAG_BACKGROUND=0` | Run the scan synchronously at shell load (default: background). |
| `ZSH_PKG_UPDATE_NAG_DEBUG=1` | Append diagnostics to `$XDG_STATE_HOME/zsh-pkg-update-nag/debug.log`. |
| `ZSH_PKG_UPDATE_NAG_PROVIDER_TIMEOUT` | Per-provider timeout in seconds (default `10`). |
| `ZSH_PKG_UPDATE_NAG_CONFIG` | Override config file path. |
| `GITHUB_TOKEN` | Used by the brew min-age GraphQL fast path when `gh` isn't available (5000 req/hr). |
| `ZSH_PKG_UPDATE_NAG_MIN_AGE_LOOKUP_PARALLELISM` | Concurrency for the brew min-age REST fallback (default `6`). Only applies when neither `gh` nor `$GITHUB_TOKEN` is set. |
| `NO_COLOR=1` | Disable color output (per the [NO_COLOR](https://no-color.org) spec). |

## Background mode

Scans run in a background subshell, so plugin load returns immediately and shell startup stays snappy.

- A dim `(checking for package updates in the background…)` notice appears at your first prompt while the scan is in flight.
- When the scan finishes, the update prompt or `All packages up to date.` lands in place before your next prompt.
- `--now` always runs synchronously, so progress output stays visible while you wait.
- If multiple shells open at once, only one runs the scan; the others pick up its result.

To run synchronously instead (mainly useful when debugging), set `ZSH_PKG_UPDATE_NAG_BACKGROUND=0` before the plugin loads.

### powerlevel10k instant-prompt

If you use [powerlevel10k](https://github.com/romkatv/powerlevel10k) with instant-prompt enabled, the plugin auto-adapts: the dim "(checking…)" notice is suppressed (cosmetic only), and the results display is deferred one prompt so it lands after p10k finalizes. No action needed.

## Minimum release age

Optional supply-chain safety net. When `zsh_pkg_update_nag_min_age` is set to N > 0 days, an update is only surfaced once the new version has been published for at least N days. Fresh releases get a quarantine window during which yanked or compromised versions usually surface.

```zsh
# ~/.config/zsh-pkg-update-nag/config.zsh
zsh_pkg_update_nag_min_age=7           # global baseline
zsh_pkg_update_nag_min_age_npm=14      # stricter for npm
zsh_pkg_update_nag_min_age_brew=0      # off for brew
```

Per-manager overrides (`zsh_pkg_update_nag_min_age_<manager>`) win over the global, even when set to `0`. Leave a per-manager variable unset to inherit the global.

### Prefer the upstream feature when one exists

If your package manager has minimum-release-age built in, use **that** for those packages. It acts at install time (so it also protects ad-hoc installs) and avoids the per-package lookup this plugin does.

| Manager | Native minimum-age support | Recommendation |
|---|---|---|
| brew | None (homebrew/core is human-curated) | Use this plugin's setting |
| npm | [`min-release-age`](https://docs.npmjs.com/cli/v11/using-npm/config#min-release-age) (npm 11+) | Prefer npm's; this plugin's setting is the fallback when you can't change `.npmrc` |
| pnpm | [`minimumReleaseAge`](https://pnpm.io/settings#minimumreleaseage) in `.npmrc` | Prefer pnpm's; this plugin's setting is the fallback |
| uv | [`--exclude-newer DATE`](https://docs.astral.sh/uv/reference/cli/#uv-pip-install--exclude-newer) (per-invocation) | This plugin's setting is easier for ongoing use |
| gem | None | Use this plugin's setting |
| _(out of scope)_ cargo | [`--minimum-release-age`](https://doc.rust-lang.org/cargo/commands/cargo-install.html) | Prefer cargo's |

### Performance

Each outdated package needs one publish-date lookup the first time it's seen. Lookups are cached forever in `$XDG_STATE_HOME/zsh-pkg-update-nag/age_cache.tsv` (publish dates don't change), so steady-state cost is near-zero. Most users see ~95% cache hits after a day or two.

| Manager | Lookup source | Cold-cache cost |
|---|---|---|
| brew | `brew info --json=v2` (~1.2 s fixed) plus a single GitHub GraphQL query covering every package via `gh api graphql` or `curl` with `$GITHUB_TOKEN`. Falls back to per-package serial REST when neither is available. | ~3 s for any number of packages on the fast path; ~N seconds on the unauth REST fallback |
| npm | `npm view <pkg> time --json` + `jq` | ~350–650 ms (network) per package |
| pnpm | `https://registry.npmjs.org/<pkg>` via `curl` + `jq` | ~100–300 ms per package |
| uv | `https://pypi.org/pypi/<pkg>/json` via `curl` + `jq` | ~100–300 ms per package |
| gem | `https://rubygems.org/api/v1/versions/<pkg>.json` via `curl` + `jq` | ~100–300 ms per package |

Real-world: cold cache, 35 outdated brew packages with `gh` authenticated → about 7 s total. Steady state with cache populated: ~3–4 s regardless of N. Background mode keeps that latency entirely off the startup path. Each provider call is wrapped by `ZSH_PKG_UPDATE_NAG_PROVIDER_TIMEOUT` (default 10 s) so a hung HTTP request can never extend the scan past that cap. If a single manager is too slow even in the background, set its per-manager override to `0` to disable the lookup for it.

### GitHub auth (brew only)

The brew lookup hits the GitHub API. In order of preference:

1. **`gh` CLI installed and authenticated** (`gh auth login`): single batched GraphQL call per scan; 5000 req/hr quota. Strongly recommended if you're enabling brew min-age.
2. **`$GITHUB_TOKEN` set**: same GraphQL fast path via `curl`; same 5000 req/hr quota.
3. **No auth**: per-package REST against the 60 req/hr public cap. Enough for ~30–60 unique brew packages per hour; the lookup fails-open once exhausted.

### Edge cases

- **Fail-open.** If the age can't be determined (network down, missing `curl`/`jq`, third-party brew tap, malformed registry response), the update is shown anyway and a line lands in the debug log.
- **Brew signal.** The brew "publish date" is the formula file's commit time in `Homebrew/homebrew-core` or `homebrew-cask`, not the upstream project's release time. For homebrew-core that's typically within hours of upstream; for third-party taps the lookup fails-open.

## Subcommands

```sh
zsh-pkg-update-nag --now         # run the check immediately
zsh-pkg-update-nag --check-env   # show detected managers, config, and next-check time
zsh-pkg-update-nag --help
```

Tab-completion ships as `_zsh-pkg-update-nag`. oh-my-zsh picks it up automatically; standalone users may need to run `compinit` (or open a fresh shell) once after installing.

## Troubleshooting

The check is skipped on purpose in any of these cases:

- Non-interactive shells (scripts, here-docs).
- Dumb terminals (`TERM=dumb`), non-TTY stdin/stdout, `INSIDE_EMACS` set.
- `CI` environment variable set.
- SSH sessions, unless `ZSH_PKG_UPDATE_NAG_SSH=1`.
- Within the rate-limit window.
- Another shell is mid-check (file-lock held).

If you expect a check and it's not running:

```sh
ZSH_PKG_UPDATE_NAG_FORCE=1 zsh-pkg-update-nag --now    # bypass the rate-limit
zsh-pkg-update-nag --check-env                         # confirm detection
ZSH_PKG_UPDATE_NAG_DEBUG=1 zsh-pkg-update-nag --now    # write diagnostics
cat "${XDG_STATE_HOME:-$HOME/.local/state}/zsh-pkg-update-nag/debug.log"
```

## Uninstall

Remove the plugin from your manager, then optionally wipe its state and config:

```sh
# oh-my-zsh
rm -rf "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-pkg-update-nag"
# remove `zsh-pkg-update-nag` from the plugins=(...) array in ~/.zshrc

# zinit
# remove `zinit light madisonrickert/zsh-pkg-update-nag` from ~/.zshrc

# antidote
# remove `madisonrickert/zsh-pkg-update-nag` from ~/.zsh_plugins.txt

# zdot
# remove `zdot_load_module update-nag` from your .zshrc

# standalone
rm -rf ~/.zsh-pkg-update-nag
# remove the `source` line from ~/.zshrc

# optional: wipe state + config
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/zsh-pkg-update-nag"
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/zsh-pkg-update-nag"
```

## Requirements

- **zsh 5.0 or newer.**
- **Optional, only as needed:**
  - `jq`: improves Homebrew version-delta display (without it, brew versions show as `?`); also required for any `min_age > 0` lookup.
  - `curl`: required for `min_age > 0` on brew/uv/gem. Ships at `/usr/bin/curl` on macOS and most Linux distros.
  - [`gh`](https://cli.github.com/): enables the GraphQL fast path for brew min-age (one API call covering every package). Strongly recommended if you set `min_age > 0` for brew. Alternatively, set `$GITHUB_TOKEN` and the same path runs via `curl`.
  - `timeout` / `gtimeout`: wraps each provider call with a 10-second timeout. On macOS, `gtimeout` ships in `coreutils` (`brew install coreutils`).

## Caveats

- **Brew results reflect your last `brew update`.** The plugin doesn't refresh brew's local index. Running `brew update` from a shell hook would add 5–30 s of network I/O to startup. Brew already auto-updates the index on `brew install` / `brew upgrade` (every `HOMEBREW_AUTO_UPDATE_SECS`, default 24 h), so the list catches up the next time you upgrade anything. Run `brew update` manually if you suspect the cache is stale.

## Contributing

Issues and PRs welcome. Tests use [bats-core](https://github.com/bats-core/bats-core):

```sh
brew install bats-core
bats tests/
```

The codebase is zsh-specific (not bash-portable). Conventions:

- Every function begins with `emulate -L zsh; setopt local_options` so user shell options can't alter behavior.
- Commands are invoked array-style (`local cmd=(brew upgrade "$pkg"); "${cmd[@]}"`), never `eval` on user-or-network-derived strings.
- Internal symbols are prefixed `_zpun_`; public env vars are `ZSH_PKG_UPDATE_NAG_*`.
- `shellcheck` output is noisy on zsh-specific syntax (`${(f)…}`, `$+functions[…]`); `zsh -n` is the authoritative parse check.

## License

MIT. See [LICENSE](LICENSE).
