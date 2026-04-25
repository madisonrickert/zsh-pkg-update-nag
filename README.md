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

Open a fresh terminal. The scan runs in the background (default), so your prompt appears immediately; a dim `(checking…)` notice flashes at the first prompt while the scan is in flight, then results land in place — either the update prompt or `All packages up to date.` — before your next prompt. Set `ZSH_PKG_UPDATE_NAG_BACKGROUND=0` to run synchronously instead (mainly useful when debugging).

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

# Minimum release age (days). Hides updates younger than this — gives
# fresh releases time to be yanked or flagged before you adopt them.
# Default 0 (off). 7 is a sensible baseline; see the section below.
zsh_pkg_update_nag_min_age=0

# Per-manager overrides (optional). When set — even to 0 — these win over
# the global. Useful to disable the gate for managers whose lookup is the
# slowest (npm) or where you trust the curation (brew/homebrew-core).
# zsh_pkg_update_nag_min_age_brew=0
# zsh_pkg_update_nag_min_age_npm=14
# zsh_pkg_update_nag_min_age_uv=7
# zsh_pkg_update_nag_min_age_gem=7
```

### Environment variables

| Variable | Purpose |
|---|---|
| `ZSH_PKG_UPDATE_NAG_DISABLE=1` | Disable the plugin entirely (no check on shell start). |
| `ZSH_PKG_UPDATE_NAG_BACKGROUND` | `1` (default) runs the scan in the background so plugin load returns instantly; `0` runs it synchronously at shell load (mainly useful when debugging). See below. |
| `ZSH_PKG_UPDATE_NAG_FORCE=1` | Ignore the rate-limit for this shell. |
| `ZSH_PKG_UPDATE_NAG_SSH=1` | Opt in under SSH sessions (default: skipped). |
| `ZSH_PKG_UPDATE_NAG_DEBUG=1` | Append diagnostics to `$XDG_STATE_HOME/zsh-pkg-update-nag/debug.log`. |
| `ZSH_PKG_UPDATE_NAG_PROVIDER_TIMEOUT` | Per-provider timeout in seconds (default `10`). |
| `ZSH_PKG_UPDATE_NAG_MIN_AGE_LOOKUP_PARALLELISM` | Concurrency for the brew min-age REST fallback (default `6`). Only applies when neither `gh` nor `$GITHUB_TOKEN` is available — otherwise the GraphQL fast path is one round trip regardless. |
| `GITHUB_TOKEN` | If set, the brew min-age prefetch uses GraphQL via `curl` with this token (5000/hr). Picked up automatically when `gh` isn't installed. |
| `ZSH_PKG_UPDATE_NAG_CONFIG` | Override config file path. |
| `NO_COLOR=1` | Disable color output (respected per the [NO_COLOR](https://no-color.org) spec). |

#### Background mode (default)

The scan runs in a background subshell so plugin load returns immediately and shell startup stays snappy. What you'll see at the next interactive shell:

- **First prompt** — a dim notice `(checking for package updates in the background…)` appears once while the scan is in flight.
- **When the scan finishes** (before your next prompt) — either the normal update prompt, or `All packages up to date.` if nothing needs upgrading.
- **`--now`** always runs synchronously regardless of this setting, so progress output remains visible.

To opt into the synchronous path (mainly useful when debugging), set:

```zsh
# ~/.zshrc (before the plugin loads)
export ZSH_PKG_UPDATE_NAG_BACKGROUND=0
```

Results are written atomically to `$XDG_STATE_HOME/zsh-pkg-update-nag/pending_updates` and consumed once displayed. If you open several shells at once, the rate-limit lock ensures only one background scan runs; subsequent shells will pick up the same results when their first prompt fires.

##### powerlevel10k instant-prompt

If you use [powerlevel10k](https://github.com/romkatv/powerlevel10k) with instant-prompt enabled (`POWERLEVEL9K_INSTANT_PROMPT=quiet|verbose`), the plugin auto-adapts:

- The dim "(checking…)" notice is **suppressed** to avoid p10k's "Console output during zsh initialization detected" warning. (Cosmetic loss only — results still appear once the scan finishes.)
- The results display is **deferred by one prompt** so it lands after p10k finalizes its instant-prompt buffer, regardless of whether our precmd hook is registered before or after p10k's.

No action needed — set `POWERLEVEL9K_INSTANT_PROMPT=off` (or leave it unset) to opt out.

#### Minimum release age (`zsh_pkg_update_nag_min_age`)

Optional supply-chain safety net. When set to N > 0, an update is only surfaced once its `latest` version has been published for at least N days — fresh releases get a quarantine window during which yanked or compromised versions usually surface and get pulled. Off by default (`0`).

```zsh
# ~/.config/zsh-pkg-update-nag/config.zsh
zsh_pkg_update_nag_min_age=7           # global baseline
zsh_pkg_update_nag_min_age_npm=14      # stricter for npm specifically
zsh_pkg_update_nag_min_age_brew=0      # off for brew
```

Per-manager overrides (`zsh_pkg_update_nag_min_age_<manager>`) win over the global, even when set to `0`. Leave a per-manager variable unset to inherit the global.

##### Prefer the upstream feature when one exists

If your package manager has minimum-release-age built in, use **that** for those packages — it acts at install time (so it also protects ad-hoc installs) and avoids the per-package lookup this plugin does. This plugin's setting is the gap-filler for managers without native support.

| Manager | Native minimum-age support | Recommendation |
|---|---|---|
| brew | None (homebrew/core is human-curated) | Use this plugin's setting |
| npm | None | Use this plugin's setting |
| uv | [`--exclude-newer DATE`](https://docs.astral.sh/uv/reference/cli/#uv-pip-install--exclude-newer) (per-invocation; no persistent config) | This plugin's setting is easier for ongoing use |
| gem | None | Use this plugin's setting |
| _(out of scope)_ pnpm | [`minimumReleaseAge`](https://pnpm.io/settings#minimumreleaseage) in `.npmrc` | Prefer pnpm's native setting |
| _(out of scope)_ cargo | [`--minimum-release-age`](https://doc.rust-lang.org/cargo/commands/cargo-install.html) | Prefer cargo's native flag |

##### Performance

Each outdated package needs one publish-date lookup the first time it's seen. Lookups are cached forever in `$XDG_STATE_HOME/zsh-pkg-update-nag/age_cache.tsv` (publish dates don't change), so steady-state cost is near-zero — most users see ~95% cache hits after a day or two of use.

| Manager | Lookup source | Cold-cache cost |
|---|---|---|
| brew | One batched `brew info --json=v2` for the file paths (~1.2 s fixed), then a single GitHub GraphQL query covering every package via `gh api graphql` (uses your `gh` token, 5000/hr quota) or `curl` with `$GITHUB_TOKEN`. Falls back to per-package serial REST when neither is available (60/hr unauth quota). | ~3 s for any number of packages on the fast path; ~N seconds on the unauth REST fallback |
| npm | `npm view <pkg> time --json` + `jq` | ~350–650 ms (network) per package |
| uv | `https://pypi.org/pypi/<pkg>/json` via `curl` + `jq` | ~100–300 ms (network) per package |
| gem | `https://rubygems.org/api/v1/versions/<pkg>.json` via `curl` + `jq` | ~100–300 ms (network) per package |

Measured: cold cache, 35 outdated brew packages, with `gh` authenticated → **~7 s** total cold-cache cost for the whole scan (down from ~77 s before the prefetch + GraphQL changes). Steady state with cache populated: ~3–4 s regardless of N. Background mode (the default) keeps that latency entirely off the startup path, so you only feel it as a delay before results appear at the prompt. Each provider call is also wrapped by the existing `ZSH_PKG_UPDATE_NAG_PROVIDER_TIMEOUT` (default 10 s) so a hung HTTP request can never extend the scan beyond that cap. If a single manager is too slow even in the background, set its per-manager override to `0` to disable the lookup for it specifically.

###### GitHub rate limit (brew only)

The brew lookup hits the GitHub API. There are three auth paths, in order of preference:

1. **`gh` CLI installed and authenticated** (`gh auth login`) — uses GitHub's GraphQL API in a single batched call per scan; 5000/hour quota. **Strongly recommended** if you're enabling brew min-age.
2. **`$GITHUB_TOKEN` set in the environment** — same GraphQL fast path via `curl`; same 5000/hour quota. Useful when you don't use `gh` but already have a token (CI, scripts, etc.).
3. **No auth** — falls back to per-package REST calls against the public 60/hour cap. Enough for ~30–60 unique brew packages per hour; the lookup fails-open once exhausted (the update gets shown anyway and a debug-log line records why).

##### Failure mode: fail-open

If we can't determine an age (network down, missing `curl`/`jq`, third-party brew tap, malformed registry response), the update is **shown anyway** and a line is written to the debug log. Hiding updates indefinitely because the network's down would be strictly worse than current behavior.

##### Brew caveat

The brew signal is the formula file's commit time in `Homebrew/homebrew-core` (or `homebrew-cask`), not the upstream project's release time. For homebrew-core that's usually within hours of upstream; for third-party taps the lookup falls back to fail-open since we don't enumerate every tap path. The lookup goes through the GitHub commits API rather than `git log` because Homebrew 4.0+ no longer clones the tap locally by default.

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
- **Optional:** `jq` (improves Homebrew version-delta display — without it, brew versions show as `?`; also required for any `min_age > 0` lookup), `curl` (required for `min_age > 0` on brew/uv/gem; ships in `/usr/bin/curl` on macOS and most Linuxes), [`gh`](https://cli.github.com/) (enables the GraphQL fast path for brew min-age, batching all packages into a single API call; strongly recommended if you set `min_age > 0` for brew — alternatively set `$GITHUB_TOKEN` and the same path runs via `curl`), `timeout` / `gtimeout` (wraps provider calls with a 10s timeout). On macOS, `gtimeout` is part of `coreutils`: `brew install coreutils`.

## Limitations / roadmap

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
