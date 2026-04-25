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

@test "summary preserves literal % in pkg/version under print -P" {
  # Force the color path so the print -P branch executes; without a TTY
  # _zpun_ui_color_enabled would otherwise short-circuit.
  run run_plugin_zsh "
    _zpun_ui_color_enabled() { return 0 }
    _zpun_ui_render_summary $'brew\t100%cool\t1.0%a\t2.0%b'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"100%cool"* ]]
  [[ "$output" == *"1.0%a"* ]]
  [[ "$output" == *"2.0%b"* ]]
}

@test "_zpun_ui_say preserves literal % in caller-supplied text" {
  run run_plugin_zsh '
    _zpun_ui_color_enabled() { return 0 }
    _zpun_ui_say err "upgrade failed for npm 100%-pkg"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"100%-pkg"* ]]
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

@test "read_choice: valid keypress passes through unchanged" {
  run run_plugin_zsh '
    choice=$(printf "s" | _zpun_ui_read_choice "p" "yns" "y")
    print -r -- "[$choice]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[s]"* ]]
}

@test "read_choice: ESC maps to 'n' when n is in the valid set" {
  run run_plugin_zsh '
    choice=$(printf "\033" | _zpun_ui_read_choice "p" "yns" "y")
    print -r -- "[$choice]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[n]"* ]]
}

@test "read_choice: ESC falls back to default when n is not valid" {
  run run_plugin_zsh '
    choice=$(printf "\033" | _zpun_ui_read_choice "p" "ya" "y")
    print -r -- "[$choice]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[y]"* ]]
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
