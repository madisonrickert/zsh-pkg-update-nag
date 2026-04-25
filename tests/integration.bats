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
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_UV=empty \
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
  [[ "$output" != *$'npm\t'* ]]
  [[ "$output" != *$'uv\t'* ]]
  [[ "$output" != *$'gem\t'* ]]
  [[ "$output" == *$'brew\tgh\t'* ]]   # brew is unfiltered (no min_age_brew set)
}

@test "min-age per-manager override of 0 disables filtering for that manager only" {
  ZPUN_FIXTURE_NPM_AGE=fresh \
    run run_plugin_zsh "
      zsh_pkg_update_nag_min_age_days=999
      zsh_pkg_update_nag_min_age_npm=0
      _zpun_collect_outdated
    "
  [ "$status" -eq 0 ]
  # npm rows survive because the per-manager override forces gating off.
  [[ "$output" == *$'npm\tpnpm'* ]]
}

@test "_zpun_run_upgrade builds correct command per manager" {
  run run_plugin_zsh "_zpun_run_upgrade brew pnpm; _zpun_run_upgrade npm typescript; _zpun_run_upgrade gem rails"
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew upgrade pnpm"* ]]
  [[ "$output" == *"npm install -g typescript@latest"* ]]
  [[ "$output" == *"gem update rails"* ]]
}
