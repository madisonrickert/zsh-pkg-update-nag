#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

@test "brew provider emits tsv for outdated formulae and casks" {
  run run_plugin_zsh "_zpun_provider_brew"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh	2.60.0	2.62.0"* ]]
  [[ "$output" == *"fd	10.1.0	10.2.0"* ]]
  [[ "$output" == *"claude-code@latest	0.9.0	0.9.1"* ]]
}

@test "brew provider is silent when nothing is outdated" {
  ZPUN_FIXTURE_BREW=empty run run_plugin_zsh "_zpun_provider_brew"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "npm provider tolerates exit 1 when any outdated" {
  run run_plugin_zsh "_zpun_provider_npm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pnpm	9.0.0	9.5.1"* ]]
  [[ "$output" == *"claude-code	1.4.2	1.5.0"* ]]
}

@test "uv provider parses 'latest: vX' lines" {
  run run_plugin_zsh "_zpun_provider_uv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruff	0.6.0	0.6.4"* ]]
}

@test "gem provider parses 'pkg (current < latest)' lines" {
  run run_plugin_zsh "zsh_pkg_update_nag_gem=all; _zpun_provider_gem"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rails	7.1.0	7.2.0"* ]]
  [[ "$output" == *"rspec	3.12.0	3.13.0"* ]]
}

@test "allowlist filters brew results" {
  run run_plugin_zsh "zsh_pkg_update_nag_brew=(gh); _zpun_config_load; _zpun_provider_brew"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh	"* ]]
  [[ "$output" != *"fd	"* ]]
}

@test "manager set to off is skipped" {
  run run_plugin_zsh "zsh_pkg_update_nag_brew=off; _zpun_manager_enabled brew && echo ENABLED || echo DISABLED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISABLED"* ]]
}
