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
    _zpun_ui_read_choice "p" "yns" "y" < <(printf "s")
    print -r -- "[$REPLY]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[s]"* ]]
}

@test "read_choice: ESC maps to 'n' when n is in the valid set" {
  run run_plugin_zsh '
    _zpun_ui_read_choice "p" "yns" "y" < <(printf "\033")
    print -r -- "[$REPLY]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[n]"* ]]
}

@test "read_choice: ESC falls back to default when n is not valid" {
  run run_plugin_zsh '
    _zpun_ui_read_choice "p" "ya" "y" < <(printf "\033")
    print -r -- "[$REPLY]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[y]"* ]]
}

@test "read_choice: unrecognised key declines when n is in the valid set" {
  run run_plugin_zsh '
    _zpun_ui_read_choice "p" "yns" "y" < <(printf "w")
    print -r -- "[$REPLY]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[n]"* ]]
}

@test "read_choice: unrecognised key falls back to default when n is not valid" {
  run run_plugin_zsh '
    _zpun_ui_read_choice "p" "ya" "y" < <(printf "w")
    print -r -- "[$REPLY]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[y]"* ]]
}

@test "input_capture is a no-op when stdin isn't a TTY" {
  run run_plugin_zsh '
    _zpun_input_capture_begin
    print -r -- "saved=${_ZPUN_TTY_SAVED-unset}"
    print -r -- "buffer=${_ZPUN_INPUT_BUFFER-unset}"
    _zpun_input_capture_end
    print -r -- "OK"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"saved=unset"* ]]
  [[ "$output" == *"buffer=unset"* ]]
  [[ "$output" == *"OK"* ]]
}

@test "input_capture_end is idempotent" {
  run run_plugin_zsh '
    typeset -g _ZPUN_TTY_SAVED=""
    typeset -g _ZPUN_INPUT_BUFFER=""
    _zpun_input_capture_end
    _zpun_input_capture_end
    print -r -- "saved=${_ZPUN_TTY_SAVED-unset}"
    print -r -- "buffer=${_ZPUN_INPUT_BUFFER-unset}"
    print -r -- "OK"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"saved=unset"* ]]
  [[ "$output" == *"buffer=unset"* ]]
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

# ---------------------------------------------------------------------------
# tty handling. The capture's tty restore happens only at a prompt
# (_zpun_tty_restore_precmd): verbatim if nothing else touched the tty while
# we held it; otherwise only our own flags are flipped back, so another
# program's change is never clobbered by a stale snapshot.
# ---------------------------------------------------------------------------

@test "tty_apply: the undo list covers only the flags it actually changed" {
  run run_plugin_pty '
    stty echo icanon
    _zpun_tty_apply -icanon echo
    print -r -- "undo=[${${(@ps:\t:)REPLY}[3]}]"
    _zpun_tty_undo "$REPLY"
  '
  [ "$status" -eq 0 ]
  # echo was already on: unchanged, so it is not in the undo list.
  [[ "$output" == *"undo=[icanon]"* ]]
}

@test "input_capture: ending the capture does not touch the tty until a prompt" {
  run run_plugin_pty '
    stty echo icanon
    _zpun_input_capture_begin
    _zpun_input_capture_end
    print -r -- "ended: echo=$(tty_flag echo) icanon=$(tty_flag icanon)"
    print -r -- "hook=${precmd_functions[(r)_zpun_tty_restore_precmd]:-absent}"
    _zpun_tty_restore_precmd
    print -r -- "prompt: echo=$(tty_flag echo) icanon=$(tty_flag icanon)"
    print -r -- "after=${precmd_functions[(r)_zpun_tty_restore_precmd]:-absent}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ended: echo=off icanon=off"* ]]
  [[ "$output" == *"hook=_zpun_tty_restore_precmd"* ]]
  [[ "$output" == *"prompt: echo=on icanon=on"* ]]
  [[ "$output" == *"after=absent"* ]]
}

@test "input_capture: unchanged tty is restored verbatim (echo-off start stays off)" {
  run run_plugin_pty '
    stty -echo icanon
    _zpun_input_capture_begin
    _zpun_input_capture_end
    _zpun_tty_restore_precmd
    print -r -- "prompt: echo=$(tty_flag echo) icanon=$(tty_flag icanon)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt: echo=off icanon=on"* ]]
}

@test "input_capture: a concurrent tty change survives; only our flags flip back" {
  run run_plugin_pty '
    stty echo icanon ixon
    _zpun_input_capture_begin
    stty -ixon   # something else changes the tty while we hold it
    _zpun_input_capture_end
    _zpun_tty_restore_precmd
    print -r -- "prompt: echo=$(tty_flag echo) icanon=$(tty_flag icanon) ixon=$(tty_flag ixon)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt: echo=on icanon=on ixon=off"* ]]
}

@test "tty_release: hands upgraders echo+icanon before the prompt-time restore" {
  run run_plugin_pty '
    stty echo icanon
    _zpun_input_capture_begin
    _zpun_input_capture_end
    _zpun_tty_release
    print -r -- "released: echo=$(tty_flag echo) icanon=$(tty_flag icanon)"
    _zpun_tty_restore_precmd
    print -r -- "prompt: echo=$(tty_flag echo) icanon=$(tty_flag icanon)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"released: echo=on icanon=on"* ]]
  [[ "$output" == *"prompt: echo=on icanon=on"* ]]
}

@test "input_capture: begin while a restore is pending keeps the original snapshot" {
  run run_plugin_pty '
    stty echo icanon
    _zpun_input_capture_begin
    _zpun_input_capture_end
    _zpun_input_capture_begin   # tty is still in capture mode here
    _zpun_input_capture_end
    _zpun_tty_restore_precmd
    print -r -- "prompt: echo=$(tty_flag echo) icanon=$(tty_flag icanon)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt: echo=on icanon=on"* ]]
}

@test "has_typed_input: leaves the tty exactly as it found it" {
  run run_plugin_pty '
    stty echo icanon
    _zpun_has_typed_input
    print -r -- "after: echo=$(tty_flag echo) icanon=$(tty_flag icanon)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"after: echo=on icanon=on"* ]]
}

# read_choice runs in the calling shell (REPLY, not $(...)): type-ahead it
# drains before reading must survive in _ZPUN_INPUT_BUFFER to be replayed,
# rather than vanishing with a subshell's copy.
@test "read_choice: type-ahead drained during a capture survives for replay" {
  run run_plugin_pty '
    stty echo icanon
    _zpun_input_capture_begin
    print -r -- READY
    sleep 1      # "abc" is typed here, queued while captured
    _zpun_ui_read_choice "P?" yn y 2>/dev/null
    print -r -- "choice=[$REPLY] buffer=[$_ZPUN_INPUT_BUFFER]"
  ' abc y
  [ "$status" -eq 0 ]
  [[ "$output" == *"choice=[y] buffer=[abc]"* ]]
}
