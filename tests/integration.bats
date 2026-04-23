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

@test "_zpun_run_upgrade builds correct command per manager" {
  run run_plugin_zsh "_zpun_run_upgrade brew pnpm; _zpun_run_upgrade npm claude-code; _zpun_run_upgrade gem rails"
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew upgrade pnpm"* ]]
  [[ "$output" == *"npm install -g claude-code@latest"* ]]
  [[ "$output" == *"gem update rails"* ]]
}
