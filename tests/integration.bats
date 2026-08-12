#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

@test "tier-1 'n' skips everything and prints 'Skipped'" {
  run run_plugin_zsh "
    NO_COLOR=1
    lines=( \$'brew\tgh\t2.60.0\t2.62.0' \$'npm\tpnpm\t9.0.0\t9.5.1' )
    _zpun_ui_prompt_and_upgrade \"\${lines[@]}\" <<< 'n'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 updates available"* ]]
  [[ "$output" == *"Update all?"* ]]
  [[ "$output" == *"Skipped."* ]]
  [[ "$output" != *"fixture upgraded"* ]]
  [[ "$output" != *"fixture installed"* ]]
}

@test "tier-1 'Y' upgrades all packages" {
  run run_plugin_zsh "
    NO_COLOR=1
    lines=( \$'brew\tgh\t2.60.0\t2.62.0' \$'npm\tpnpm\t9.0.0\t9.5.1' )
    _zpun_ui_prompt_and_upgrade \"\${lines[@]}\" <<< 'y'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew fixture upgraded: gh"* ]]
  [[ "$output" == *"npm fixture installed"* ]]
  [[ "$output" == *"Done."* ]]
}

@test "tier-2 's' then 'y','n' upgrades only the first" {
  run run_plugin_zsh "
    NO_COLOR=1
    lines=( \$'brew\tgh\t2.60.0\t2.62.0' \$'npm\tpnpm\t9.0.0\t9.5.1' )
    _zpun_ui_prompt_and_upgrade \"\${lines[@]}\" <<< 'syn'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew fixture upgraded: gh"* ]]
  [[ "$output" != *"npm fixture installed"* ]]
  [[ "$output" == *"Done."* ]]
}

@test "collect returns nothing when all managers report empty" {
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_PNPM=empty ZPUN_FIXTURE_UV=empty ZPUN_FIXTURE_CARGO=empty \
    run run_plugin_zsh "_zpun_collect_outdated"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "collect aggregates across multiple managers with manager-prefix" {
  # Export so the per-provider subshell inherits the override.
  run run_plugin_zsh "export zsh_pkg_update_nag_gem=all; _zpun_collect_outdated"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'brew\tgh\t2.60.0\t2.62.0'* ]]
  [[ "$output" == *$'npm\tpnpm\t9.0.0\t9.5.1'* ]]
  [[ "$output" == *$'uv\truff\t0.6.0\t0.6.4'* ]]
  [[ "$output" == *$'gem\trails\t7.1.0\t7.2.0'* ]]
  [[ "$output" == *$'cargo\tripgrep\t13.0.0\t14.1.0'* ]]
}

@test "collect emits only well-formed manager rows (regression for #4)" {
  # Regression for #4: `local pkg_current pkg_rest target rc` was re-declared
  # inside the per-manager loop. Once a second manager had updates, re-running
  # `local` on already-set names printed their leftover values
  # (pkg_current=…, rc=…) onto the collector's captured stdout. Those bogus
  # lines carry no tabs, so the renderer's ${(s:\t:)line}[N] char-indexed them
  # into single-character garbage ("p", "k", …) and the upgrade path reported
  # "unknown manager: p". Assert every emitted row is a real manager-prefixed
  # TSV line so any such stdout leak fails the suite.
  run run_plugin_zsh "export zsh_pkg_update_nag_gem=all; _zpun_collect_outdated"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  bogus="$(printf '%s\n' "$output" | grep -vE $'^(brew|npm|pnpm|uv|gem|cargo)\t' | grep -v '^$' || true)"
  [ -z "$bogus" ] || { echo "non-row output leaked into collector:"; echo "$bogus"; false; }
}

@test "min-age threshold drops fresh updates from the aggregated output" {
  # ZPUN_FIXTURE_NPM_AGE=fresh + ZPUN_FIXTURE_CURL=fresh make every age-lookup
  # return "now"; with global threshold = ~3 years (in days), every row should
  # be filtered out. Brew gets the threshold too but its lookup will fail-open
  # (no stubbed git repo), so we expect brew rows to still appear.
  ZPUN_FIXTURE_NPM_AGE=fresh ZPUN_FIXTURE_CURL=fresh \
    run run_plugin_zsh "
      export zsh_pkg_update_nag_gem=all
      zsh_pkg_update_nag_min_age_npm=999
      zsh_pkg_update_nag_min_age_uv=999
      zsh_pkg_update_nag_min_age_gem=999
      _zpun_collect_outdated
    "
  [ "$status" -eq 0 ]
  # Anchor on line-start: `npm\t` is also a substring of `pnpm\t`, so an
  # unanchored pattern would always match and never actually verify filtering.
  local re=$'(^|\n)npm\t'
  [[ ! "$output" =~ $re ]]
  re=$'(^|\n)uv\t'
  [[ ! "$output" =~ $re ]]
  re=$'(^|\n)gem\t'
  [[ ! "$output" =~ $re ]]
  [[ "$output" == *$'brew\tgh\t'* ]]   # brew is unfiltered (no min_age_brew set)
}

@test "min-age per-manager override of 0 disables filtering for that manager only" {
  ZPUN_FIXTURE_NPM_AGE=fresh \
    run run_plugin_zsh "
      zsh_pkg_update_nag_min_age=999
      zsh_pkg_update_nag_min_age_npm=0
      _zpun_collect_outdated
    "
  [ "$status" -eq 0 ]
  # npm rows survive because the per-manager override forces gating off.
  [[ "$output" == *$'npm\tpnpm'* ]]
}

@test "upgrade_all bails out on Ctrl-C without running any upgrades" {
  run run_plugin_zsh "
    NO_COLOR=1
    _ZPUN_INTERRUPTED=1
    lines=( \$'brew\tgh\t2.60.0\t2.62.0' \$'npm\tpnpm\t9.0.0\t9.5.1' )
    _zpun_ui_upgrade_all \"\${lines[@]}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopped (Ctrl-C)."* ]]
  [[ "$output" != *"fixture upgraded"* ]]
  [[ "$output" != *"fixture installed"* ]]
  [[ "$output" != *"Done."* ]]
}

@test "upgrade_individually bails out on Ctrl-C without prompting" {
  run run_plugin_zsh "
    NO_COLOR=1
    _ZPUN_INTERRUPTED=1
    lines=( \$'brew\tgh\t2.60.0\t2.62.0' \$'npm\tpnpm\t9.0.0\t9.5.1' )
    _zpun_ui_upgrade_individually \"\${lines[@]}\" <<< 'yy'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopped (Ctrl-C)."* ]]
  [[ "$output" != *"fixture upgraded"* ]]
  [[ "$output" != *"fixture installed"* ]]
  [[ "$output" != *"update brew gh"* ]]
}

@test "_zpun_run_upgrade builds correct pinned command per manager" {
  run run_plugin_zsh "
    _zpun_run_upgrade brew pnpm
    _zpun_run_upgrade npm typescript 5.4.5
    _zpun_run_upgrade pnpm rollup 4.30.5
    _zpun_run_upgrade uv ruff 0.6.3
    _zpun_run_upgrade gem rails 7.1.5
    _zpun_run_upgrade cargo ripgrep 14.1.0
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew upgrade pnpm"* ]]
  [[ "$output" == *"npm install -g typescript@5.4.5"* ]]
  [[ "$output" == *"pnpm add -g rollup@4.30.5"* ]]
  [[ "$output" == *"uv tool install --force ruff==0.6.3"* ]]
  [[ "$output" == *"gem install rails -v 7.1.5"* ]]
  # cargo upgrades via cargo-update; with no min-age set it tracks latest and
  # adds no --cooldown. The version arg is ignored (cooldown is cargo's pin).
  [[ "$output" == *"cargo install-update ripgrep"* ]]
  [[ "$output" != *"--cooldown"* ]]
}

@test "_zpun_run_upgrade brew leaves Homebrew's own confirmation alone by default" {
  # Brew asks only when the plan exceeds the named package, so those prompts
  # carry information the nag summary can't — the default must not skip them.
  run run_plugin_zsh "_zpun_run_upgrade brew gh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--yes"* ]]
  [[ "$output" == *"brew fixture upgraded: gh"* ]]
}

@test "_zpun_run_upgrade brew passes --yes when brew_ask is off" {
  run run_plugin_zsh "zsh_pkg_update_nag_brew_ask=off; _zpun_run_upgrade brew gh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew upgrade --yes gh"* ]]
  # The flag must not displace the package name.
  [[ "$output" == *"brew fixture upgraded: gh"* ]]
}

@test "_zpun_run_upgrade cargo forwards --cooldown when min-age is set" {
  # Closes the upgrade-time gap: a configured cargo min-age must reach the
  # actual upgrade, so accepting it cannot install a version newer than the
  # cooldown the scan applied.
  run run_plugin_zsh "zsh_pkg_update_nag_min_age_cargo=7; _zpun_run_upgrade cargo ripgrep 14.1.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cargo install-update ripgrep --cooldown 7d"* ]]
}

@test "_zpun_run_upgrade without a version falls back to latest-tracking" {
  run run_plugin_zsh "_zpun_run_upgrade npm typescript; _zpun_run_upgrade gem rails"
  [ "$status" -eq 0 ]
  [[ "$output" == *"npm install -g typescript@latest"* ]]
  [[ "$output" == *"gem update rails"* ]]
}

@test "collect resolve-mode rewrites npm row to held-back target" {
  # npm --json fixture: typescript 5.5.0 is "now" (too new), 5.4.5 is 2020
  # (old enough), current is 5.4.0. With a large npm threshold the row should
  # be rewritten to the held-back 5.4.5 rather than hidden.
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_npm=999
    _zpun_collect_outdated
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *$'npm\ttypescript\t5.4.0\t5.4.5'* ]]
  # pnpm 9.5.1 is the only version above current 9.0.0 and it's too new → hidden.
  local re=$'(^|\n)npm\tpnpm\t'
  [[ ! "$output" =~ $re ]]
}

@test "collect gate-mode (brew) is unaffected by npm resolve threshold" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_npm=999
    _zpun_collect_outdated
  "
  [ "$status" -eq 0 ]
  # brew has no min_age set → its rows pass through unchanged (gate mode).
  [[ "$output" == *$'brew\tgh\t2.60.0\t2.62.0'* ]]
}
