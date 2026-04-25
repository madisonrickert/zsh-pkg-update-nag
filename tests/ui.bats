#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

@test "summary renders all groups" {
  run run_plugin_zsh "NO_COLOR=1 _zpun_ui_render_summary $'brew\tgh\t2.60.0\t2.62.0' $'brew\tfd\t10.1.0\t10.2.0' $'npm\tpnpm\t9.0.0\t9.5.1'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 updates available"* ]]
  [[ "$output" == *"Homebrew"* ]]
  [[ "$output" == *"npm (global)"* ]]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"pnpm"* ]]
}

@test "summary pluralizes correctly for single update" {
  run run_plugin_zsh "NO_COLOR=1 _zpun_ui_render_summary $'brew\tgh\t2.60.0\t2.62.0'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 update available"* ]]
  [[ "$output" != *"1 updates"* ]]
}

@test "NO_COLOR disables escape sequences" {
  NO_COLOR=1 run run_plugin_zsh "_zpun_ui_render_summary $'brew\tgh\t2.60.0\t2.62.0'"
  [ "$status" -eq 0 ]
  # No ANSI CSI anywhere.
  [[ "$output" != *$'\x1b['* ]]
}

@test "progress dispatcher fans out to every registered hook" {
  run run_plugin_zsh '
    typeset -ga seen=()
    _hook_a() { seen+=( "a:$*" ) }
    _hook_b() { seen+=( "b:$*" ) }
    _zpun_progress_hooks=( _hook_a _hook_b )
    _zpun_progress_emit "checking foo"
    _zpun_progress_emit "querying bar"
    print -l -- "${seen[@]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"a:checking foo"* ]]
  [[ "$output" == *"b:checking foo"* ]]
  [[ "$output" == *"a:querying bar"* ]]
  [[ "$output" == *"b:querying bar"* ]]
}

@test "progress hooks default to forwarding to the spinner status" {
  run run_plugin_zsh '
    print -r -- "${_zpun_progress_hooks[@]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"_zpun_progress_to_status"* ]]
}

@test "progress emit is a no-op when no hooks are registered" {
  run run_plugin_zsh '
    _zpun_progress_hooks=()
    _zpun_progress_emit "should reach nobody" && echo OK
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "check-env reports manager status" {
  run run_plugin_zsh "_zpun_ui_print_env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zsh-pkg-update-nag"* ]]
  [[ "$output" == *"managers:"* ]]
  [[ "$output" == *"brew:"* ]]
  [[ "$output" == *"npm:"* ]]
  [[ "$output" == *"uv:"* ]]
  [[ "$output" == *"gem:"* ]]
}
