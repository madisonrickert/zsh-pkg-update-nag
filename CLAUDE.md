# CLAUDE.md

## 1. Shell startup is the critical path

This plugin is sourced from `~/.zshrc`. Every millisecond it spends at
plugin-load time is paid by the user **at every new shell** — every new tab,
every `tmux` split, every `exec zsh`. There is no budget for "it's only N ms".

- **Do nothing at load that isn't required for the auto-run path.** Sourcing
  files, defining functions, reading env vars — all of it counts. If a
  helper is only needed when a feature is enabled, source it lazily from
  the caller. `lib/min_age.zsh` and `lib/providers/*.zsh` are deliberately
  *not* sourced from `zsh-pkg-update-nag.plugin.zsh`; providers are
  re-sourced inside the per-manager timeout subshell in
  `_zpun_collect_outdated`, and each emits TSV
  (`name<TAB>current<TAB>latest`) on stdout.
- **Background by default.** `_zpun_main_deferred` runs the package scan
  in a background subshell and reports results at the next prompt via a
  `precmd` hook. The synchronous `_zpun_main` exists for debugging. New
  work that touches the network or spawns subprocesses belongs on the
  deferred path — not at load, not at first prompt.
- **Cache anything that hits the network.** Publish-date lookups for
  `min-age` are batched (`_zpun_min_age_prefetch`) and cached so per-row
  checks become local reads. Apply the same pattern to any new network
  feature: prefetch, batch, cache; never one-call-per-package.
- **Bail out fast.** `_zpun_should_run` gates on cheap checks (interactive,
  not CI, not SSH unless opted-in, etc.) before doing anything else. New
  gating should land here, ahead of any heavier work.
- **Verify perf claims by measuring.** Don't quote estimates. Time changes
  on a real shell with `time ( source zsh-pkg-update-nag.plugin.zsh )` (or
  the equivalent for the path you touched) before claiming a change is
  "negligible".
- **Per-component config when costs differ.** If a new feature is
  materially more expensive for one manager than the others, expose a
  per-manager override alongside the global setting (see `min_age` for the
  pattern).

## 2. Code quality: this is shareable open source

- **Explicit, portable zsh.** No bashisms; no relying on options that
  aren't set inside `emulate -L zsh; setopt local_options`. Functions that
  touch globals or change shell state should establish that emulation
  block at the top, like the existing helpers do.
- **Tests are not optional.** New behavior gets a `bats` test under
  `tests/`. Run the suite with `bats tests/`. The existing files
  (`background.bats`, `providers.bats`, `rate_limit.bats`, etc.) are the
  templates — match the style.
- **README and docs stay in sync.** When you add a feature with measurable
  cost or that overlaps with a manager-native command, document the cost
  and recommend the native path where one exists.

### Known zsh pitfalls — these have bitten this codebase

- **`local path=...` shadows `$PATH`.** zsh's `path` is tied to `PATH` via
  `typeset -T`. Use a different name (`pkg_path`, `state_path`, etc.).
- **`local foo` inside a loop re-declares `foo` each iteration AND prints
  the previous value to stdout** under certain option combinations.
  Declare loop-locals once before the loop, or use `local foo=` (with the
  empty assignment) to suppress the print.
- **No output during powerlevel10k instant-prompt.** Printing during the
  instant-prompt phase corrupts p10k's pre-prompt buffer (the "Console
  output during zsh initialization detected" warning). Gate prompt-time
  output on `_zpun_p10k_instant_prompt_active` — suppress cosmetic notices
  outright, or defer one `precmd` so p10k has finalized. See
  `_zpun_precmd_nag` for the deferral pattern.
