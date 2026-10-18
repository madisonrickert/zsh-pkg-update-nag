# Terminal UI: color-aware printers, summary formatter, and tiered prompt loop.

# Human-friendly labels for each supported manager.
typeset -gA _ZPUN_MANAGER_LABELS=(
  brew "Homebrew"
  npm  "npm (global)"
  pnpm "pnpm (global)"
  uv   "uv tools"
  gem  "RubyGems"
  cargo "cargo (Rust)"
)

_zpun_ui_color_enabled() {
  emulate -L zsh
  setopt local_options

  [[ -z ${NO_COLOR-} ]] || return 1
  [[ -t 1 ]] || return 1
  [[ $TERM != dumb ]] || return 1
  return 0
}

# _zpun_ui_say <style> <text…> — print with optional zsh prompt-escape styling.
# Styles: header, dim, pkg, cur, arrow, new, ok, err, prompt.
_zpun_ui_say() {
  emulate -L zsh
  setopt local_options

  local style=$1; shift
  local text=$*

  if ! _zpun_ui_color_enabled; then
    print -r -- "$text"
    return
  fi

  local open close='%f%b'
  case $style in
    header) open='%B%F{cyan}' ;;
    dim)    open='%F{244}' ;;
    pkg)    open='%F{default}' ;;
    cur)    open='%F{yellow}' ;;
    arrow)  open='%F{244}' ;;
    new)    open='%F{green}' ;;
    ok)     open='%F{green}' ;;
    err)    open='%B%F{red}' ;;
    prompt) open='%F{cyan}' ;;
    *)      open='' ; close='' ;;
  esac

  # Escape % in caller-supplied text so print -P doesn't expand it as a
  # prompt sequence (e.g. %n, %D{...}). Open/close are static and safe.
  print -P -r -- "${open}${text//\%/%%}${close}"
}

_zpun_ui_info()  { _zpun_ui_say dim "$*" ; }
_zpun_ui_ok()    { _zpun_ui_say ok  "$*" ; }
_zpun_ui_error() { _zpun_ui_say err "$*" >&2 ; }

# _zpun_ui_status <message> — overwrite the current status line on stderr.
# Used during provider scans to signal progress. Silent when stderr isn't a TTY
# (so captured output in tests and command substitution stays clean).
# Always returns 0 — callers use these at the end of functions and shouldn't
# inherit a "no TTY" as a failure.
_zpun_ui_status() {
  emulate -L zsh
  setopt local_options

  [[ -t 2 && $TERM != dumb ]] || return 0

  # Use $'...' quoting so CR and ESC[K are actual control bytes rather than
  # backslash-escape text. The `-r` flag on `print` would suppress backslash
  # interpretation, so pre-resolve the control sequence here instead.
  local reset=$'\r\033[K'
  if [[ -z ${NO_COLOR-} ]]; then
    local msg="$*"
    print -nP -- "${reset}  %F{244}…%f ${msg//\%/%%}" >&2
  else
    print -n -- "${reset}  ... $*" >&2
  fi
}

_zpun_ui_status_clear() {
  emulate -L zsh
  setopt local_options
  [[ -t 2 ]] || return 0
  print -n -- $'\r\033[K' >&2
  return 0
}

# _zpun_has_typed_input — returns 0 if stdin currently has unread bytes the
# user typed, 1 otherwise (or if the helper modules aren't available).
#
# Used by the deferred-mode precmd hook to defer the y/n/s prompt when the
# user is mid-typing the next command — popping a prompt at them in that
# moment is intrusive and risks consuming a pre-typed character as the
# answer. zsh/zselect polls fd 0 with no wait, but the descriptor only
# delivers bytes outside of canonical-mode line buffering, so we briefly
# switch to -icanon, poll, and undo that one change in `always`.
#
# Pattern lifted from dotfiler's _update_core_has_typed_input (which credits
# Philippe Troin: https://zsh.org/mla/users/2022/msg00062.html).
_zpun_has_typed_input() {
  emulate -L zsh
  setopt local_options
  [[ -t 0 ]] || return 1
  zmodload zsh/zselect 2>/dev/null || return 1
  local REPLY undo
  _zpun_tty_apply -icanon || return 1
  undo=$REPLY
  {
    zselect -t 0 -r 0
    return $?
  } always {
    _zpun_tty_undo "$undo"
  }
}

# _zpun_tty_apply <mode…> — switch the tty flags named by <mode…> (each
# `echo`/`-echo`/`icanon`/`-icanon`; `-icanon` also forces `min 1 time 0` so
# a blocking `read -k` returns on the first byte) and set REPLY to an opaque
# token for _zpun_tty_undo. The token records the tty before (`stty -g`), the
# tty as we left it, and the minimal flag list that reverses only what we
# changed; flags already in the requested state are neither touched nor
# undone. Returns 1 with the tty untouched when stdin isn't a TTY or its modes
# can't be read.
_zpun_tty_apply() {
  emulate -L zsh
  setopt local_options
  REPLY=
  [[ -t 0 ]] || return 1
  local raw
  raw=$(stty -a 2>/dev/null) || return 1
  # Normalise both BSD ("lflags: icanon … echo …") and GNU ("… icanon …;")
  # layouts into space-delimited tokens so " echo " can't match "echoe".
  local cur=" ${raw//[;$'\n'$'\t']/ } "
  local m flag cbreak=0
  local -a apply undo
  for m in "$@"; do
    flag=${m#-}
    [[ $m == -icanon ]] && cbreak=1
    if [[ $m == -* ]]; then
      [[ $cur == *" $flag "* ]] || continue
      apply+=( -$flag ); undo+=( $flag )
    else
      [[ $cur == *" -$flag "* ]] || continue
      apply+=( $flag ); undo+=( -$flag )
    fi
  done
  (( cbreak )) && apply+=( min 1 time 0 )
  local before after
  before=$(stty -g 2>/dev/null) || return 1
  stty "${apply[@]}" 2>/dev/null
  after=$(stty -g 2>/dev/null)
  REPLY="${before}"$'\t'"${after}"$'\t'"${undo[*]}"
  return 0
}

# _zpun_tty_undo <token> — reverse a _zpun_tty_apply using the REPLY it
# returned. If the tty is exactly as we left it, nothing else touched it
# while we held it, so the saved snapshot is restored verbatim. If it
# differs, something else changed it in the meantime (a child process,
# another program sharing the pty, a terminal reset). Replaying the snapshot
# then would silently revert that change and could leave the terminal in a
# mode the shell no longer expects, so only the flags we changed are flipped
# back and everything else is left as it is now.
_zpun_tty_undo() {
  emulate -L zsh
  setopt local_options
  [[ -n $1 && -t 0 ]] || return 0
  local -a parts
  parts=( "${(@ps:\t:)1}" )
  local before=$parts[1] after=$parts[2] undo=$parts[3] now
  now=$(stty -g 2>/dev/null) || return 0
  if [[ -n $before && $now == "$after" ]]; then
    stty "$before" 2>/dev/null
  elif [[ -n $undo ]]; then
    stty ${=undo} 2>/dev/null
  fi
  return 0
}

# _zpun_input_capture_begin — silently absorb keystrokes during the foreground
# scan so they don't echo over the spinner, and so a key typed mid-scan is
# never taken as the y/n/s answer (_zpun_has_typed_input sees it queued and
# auto-skips). Switches the terminal to -echo -icanon and stays that way
# through the prompt; the prompt's read enables echo just for the answer key,
# then `_zpun_input_capture_end` replays buffered bytes onto the next ZLE
# prompt via `print -z` and schedules the tty restore for that prompt. No-op
# when stdin isn't a TTY (background mode, scripts, captured tests).
#
# _ZPUN_TTY_SAVED doubles as the "session active" flag: it is set for the
# session's lifetime and holds the _zpun_tty_apply token.
#
# Caller MUST ensure _zpun_input_capture_end runs on every exit path —
# typically via the existing INT/TERM/EXIT trap in _zpun_main.
_zpun_input_capture_begin() {
  emulate -L zsh
  setopt local_options
  (( ${+_ZPUN_TTY_SAVED} )) && return 0
  if (( ${+_ZPUN_TTY_RESTORE} )); then
    # A previous capture's restore is still waiting for its prompt: the tty
    # is not in its original state, so snapshotting it now would record our
    # own capture mode as "original". Resume that session instead, keeping
    # its token (re-apply our flags in case _zpun_tty_release flipped them).
    typeset -g _ZPUN_TTY_SAVED=$_ZPUN_TTY_RESTORE
    unset _ZPUN_TTY_RESTORE
    precmd_functions=( ${precmd_functions:#_zpun_tty_restore_precmd} )
    stty -echo -icanon min 1 time 0 2>/dev/null
  else
    local REPLY
    _zpun_tty_apply -echo -icanon || return 0
    typeset -g _ZPUN_TTY_SAVED=$REPLY
  fi
  typeset -g _ZPUN_INPUT_BUFFER=
}

# _zpun_input_capture_drain — append any currently-queued tty bytes to the
# capture buffer. Called between the scan and any prompt's read so type-ahead
# the user kept producing after the scan ended doesn't accidentally answer
# the prompt. Safe to call repeatedly. No-op when no capture session active.
_zpun_input_capture_drain() {
  emulate -L zsh
  setopt local_options
  (( ${+_ZPUN_TTY_SAVED} )) || return 0
  local key
  while read -k 1 -t 0 -u 0 key 2>/dev/null; do
    _ZPUN_INPUT_BUFFER+=$key
  done
  return 0
}

# _zpun_input_capture_end — final drain, push the captured bytes onto ZLE's
# editor buffer with `print -z` so the user's typed-ahead input lands on the
# next interactive prompt, and hand the tty restore to
# _zpun_tty_restore_precmd. Idempotent — safe to call from a trap that may
# also fire on the normal exit path.
#
# The restore is deferred because the tty is only ever restored at a prompt:
# there the shell is in the foreground by definition and nothing else is
# running, so it cannot clobber another program's mode. Ending the capture
# from a trap, mid-function, or with a child still holding the terminal
# never writes the tty. The one exception is _zpun_tty_release, called
# right before upgraders run.
_zpun_input_capture_end() {
  emulate -L zsh
  setopt local_options
  (( ${+_ZPUN_TTY_SAVED} )) || return 0
  _zpun_input_capture_drain
  [[ -n $_ZPUN_INPUT_BUFFER ]] && print -z -- "$_ZPUN_INPUT_BUFFER"
  typeset -g _ZPUN_TTY_RESTORE=$_ZPUN_TTY_SAVED
  precmd_functions=( _zpun_tty_restore_precmd ${precmd_functions:#_zpun_tty_restore_precmd} )
  unset _ZPUN_TTY_SAVED _ZPUN_INPUT_BUFFER
}

# _zpun_tty_restore_precmd — one-shot precmd hook: restore the tty a capture
# session left behind (compare-then-restore, see _zpun_tty_undo), then
# deregister. Registered first in precmd_functions so later hooks (and any
# prompt we present from _zpun_precmd_nag) start from the user's tty mode.
_zpun_tty_restore_precmd() {
  emulate -L zsh
  setopt local_options
  precmd_functions=( ${precmd_functions:#_zpun_tty_restore_precmd} )
  (( ${+_ZPUN_TTY_RESTORE} )) || return 0
  _zpun_tty_undo "$_ZPUN_TTY_RESTORE"
  unset _ZPUN_TTY_RESTORE
}

# _zpun_tty_release — hand the terminal to child processes (upgraders: brew,
# npm, …, whose own confirmation prompts need echo and line editing) by
# flipping back only the flags the capture changed. The full restore still
# happens at the next prompt. No-op when no capture restore is pending.
_zpun_tty_release() {
  emulate -L zsh
  setopt local_options
  (( ${+_ZPUN_TTY_RESTORE} )) || return 0
  [[ -t 0 ]] || return 0
  local undo=${${(@ps:\t:)_ZPUN_TTY_RESTORE}[3]}
  [[ -n $undo ]] && stty ${=undo} 2>/dev/null
  return 0
}

# _zpun_progress_emit <message…> — fan a progress event out to every hook
# in $_zpun_progress_hooks. Long-running phases call this so a downstream
# listener (the spinner today; potentially debug log, telemetry, IDE
# integration tomorrow) can react without modifying call sites.
#
# Replace or extend the listener set with array assignment / append:
#   _zpun_progress_hooks=( my_listener )
#   _zpun_progress_hooks+=( another_listener )
_zpun_progress_emit() {
  emulate -L zsh
  setopt local_options
  local fn
  for fn in $_zpun_progress_hooks; do
    "$fn" "$@"
  done
}

# Default hook: forward to the existing single-line spinner.
_zpun_progress_to_status() { _zpun_ui_status "$@" }

typeset -ga _zpun_progress_hooks=( _zpun_progress_to_status )

# _zpun_ui_render_summary <lines…> — print the grouped tier-1 summary.
# Each input line is manager\tname\tcurrent\tlatest.
_zpun_ui_render_summary() {
  emulate -L zsh
  setopt local_options

  local -a lines
  lines=( "$@" )

  # Compute max name width for per-manager column alignment.
  local max_name=0
  local line name
  for line in "${lines[@]}"; do
    name=${${(s:	:)line}[2]}
    (( ${#name} > max_name )) && max_name=${#name}
  done
  (( max_name = max_name < 8 ? 8 : max_name ))

  _zpun_ui_say header "▲ ${#lines} update$( (( ${#lines} == 1 )) || print s ) available"
  print

  local manager prev_manager=""
  local pkg cur lat label pad spaces
  for line in "${lines[@]}"; do
    manager=${${(s:	:)line}[1]}
    pkg=${${(s:	:)line}[2]}
    cur=${${(s:	:)line}[3]}
    lat=${${(s:	:)line}[4]}

    if [[ $manager != "$prev_manager" ]]; then
      label=${_ZPUN_MANAGER_LABELS[$manager]:-$manager}
      _zpun_ui_say header "  $label"
      prev_manager=$manager
    fi

    pad=$(( max_name - ${#pkg} ))
    (( pad < 0 )) && pad=0
    spaces=${(l:$pad:: :)}
    if _zpun_ui_color_enabled; then
      # Escape % in provider-sourced fields so print -P doesn't interpret
      # them as prompt sequences. Width math above used the unescaped pkg.
      print -P -r -- "    %F{default}${pkg//\%/%%}%f${spaces}  %F{yellow}${cur//\%/%%}%f %F{244}→%f %F{green}${lat//\%/%%}%f"
    else
      print -r -- "    ${pkg}${spaces}  ${cur} → ${lat}"
    fi
  done
  print
}

# _zpun_ui_read_choice <prompt> <valid_chars> <default_char>
# Displays the prompt on stderr and sets REPLY to exactly one character (the
# chosen key, lowercased). Call it directly, never as $(...): it must run in
# the calling shell so that type-ahead drained into _ZPUN_INPUT_BUFFER
# survives to be replayed, and so the EXIT-trap gate below sees an outer
# trap end the capture session. A subshell would get copies of both.
_zpun_ui_read_choice() {
  emulate -L zsh
  setopt local_options

  local prompt=$1 valid=$2 default=$3
  local key token
  REPLY=

  if _zpun_ui_color_enabled; then
    print -nP -r -- "  %F{cyan}${prompt//\%/%%}%f " >&2
  else
    print -n -r -- "  ${prompt} " >&2
  fi

  # The terminal must be in non-canonical mode for `read -k 1` to return on
  # a single keypress (cooked mode buffers input until Enter). Two cases:
  #
  # 1. We're inside a capture session (_ZPUN_TTY_SAVED set): the terminal is
  #    already in -echo -icanon. Drain any queued type-ahead into the shared
  #    buffer so it doesn't get consumed as the answer, then briefly enable
  #    echo so the user sees their keypress. Function-local EXIT trap puts
  #    echo back off; the session's prompt-time restore handles the rest.
  #
  # 2. Standalone (per-package prompt during upgrades, or background-mode
  #    precmd path): no capture session active, terminal is whatever the
  #    user's shell left it. Switch to cbreak with echo for the duration of
  #    this read, which the user is actively answering, and undo it on exit
  #    via function-local EXIT trap (compare-then-restore, _zpun_tty_undo).
  #
  # Function-local traps work here because `emulate -L zsh` enables
  # LOCAL_TRAPS, so they fire on every return path including signal unwinds.
  if [[ -t 0 ]]; then
    if (( ${+_ZPUN_TTY_SAVED} )); then
      _zpun_input_capture_drain
      stty echo 2>/dev/null
      # If a signal-driven outer trap ends the session mid-read (clearing
      # _ZPUN_TTY_SAVED), our cleanup must NOT then turn echo back off on a
      # terminal that is about to be handed back — the gate guards that.
      trap '(( ${+_ZPUN_TTY_SAVED} )) && stty -echo 2>/dev/null' EXIT
    elif _zpun_tty_apply -icanon echo; then
      token=$REPLY
      # The token is `stty -g` strings, flags, and tabs — never a single
      # quote — so it is safe to embed (expanding it now is the point).
      # shuck: disable=C008
      trap "_zpun_tty_undo '$token'" EXIT
    fi
  fi

  # read -k 1 reads a single keypress; -u 0 forces stdin.
  if ! read -k 1 -u 0 key; then
    # EOF (Ctrl-D, closed stdin) or an interrupted read must DECLINE, not
    # accept: only an explicit valid key — or the [Y/n] Enter default —
    # accepts. Mirrors the update-impl pattern `read ... || _ans=n`.
    print >&2
    if [[ $valid == *n* ]]; then
      REPLY=n
    else
      REPLY=$default
    fi
    return 0
  fi
  print >&2

  if [[ -z $key || $key == $'\n' || $key == $'\r' ]]; then
    key=$default
  elif [[ $key == $'\033' ]]; then
    # ESC = "skip everything" — synonymous with 'n' when n is a valid choice,
    # otherwise fall back to the caller's default.
    [[ $valid == *n* ]] && key=n || key=$default
  fi

  key=${key:l}
  if [[ $valid != *$key* ]]; then
    # Unrecognised key: treat as decline if 'n' is valid, otherwise fall
    # back to the caller's default. Only Enter (handled above) and an
    # explicit valid key should accept a [Y/n…] prompt — a stray 'w' or
    # 'q' must not silently confirm.
    [[ $valid == *n* ]] && key=n || key=$default
  fi
  REPLY=$key
}

# _zpun_ui_prompt_and_upgrade <lines…> — tier-1 prompt, then run upgrades.
_zpun_ui_prompt_and_upgrade() {
  emulate -L zsh
  setopt local_options

  local -a lines
  lines=( "$@" )

  _zpun_ui_render_summary "${lines[@]}"

  local choice REPLY
  if _zpun_has_typed_input; then
    # User is mid-typing the next command — don't pop a blocking prompt
    # at them and risk consuming a pre-typed key as the answer. Render
    # the prompt line as auto-dismissed so they see what happened, then
    # treat as 'n': skip everything and rely on the rate-limit interval
    # before we nag again.
    if _zpun_ui_color_enabled; then
      print -P -r -- "  %F{cyan}Update all? [Y/n/s] ›%f n  %F{244}(skipped — typed input detected)%f"
    else
      print -r -- "  Update all? [Y/n/s] › n  (skipped — typed input detected)"
    fi
    choice=n
  else
    _zpun_ui_read_choice "Update all? [Y/n/s] ›" "yns" "y"
    choice=$REPLY
  fi

  # End any active capture session: replay captured type-ahead onto the next
  # ZLE prompt and schedule the tty restore for it. Upgraders (`brew
  # upgrade`, `npm install -g`, …) run before that prompt, so hand them a
  # cooked+echo terminal by flipping back the capture's own flags. Both are
  # no-ops when no session is active (background-mode precmd).
  _zpun_input_capture_end
  [[ $choice == [ys] ]] && _zpun_tty_release

  case $choice in
    y) _zpun_ui_upgrade_all "${lines[@]}" ;;
    # Config global, set by _zpun_config_load.
    # shuck: disable=C006
    n) _zpun_ui_info "Skipped. Next check in ${zsh_pkg_update_nag_interval_hours}h." ;;
    s) _zpun_ui_upgrade_individually "${lines[@]}" ;;
  esac
}

# _zpun_ui_reminder <lines…> — reminder-mode presentation: render the tier-1
# summary and print a one-line instruction to run the upgrade on demand. No
# prompt, no terminal read.
_zpun_ui_reminder() {
  emulate -L zsh
  setopt local_options

  local -a lines
  lines=( "$@" )

  _zpun_ui_render_summary "${lines[@]}"

  # Indent to line up with the two-space summary block above, so the
  # instruction reads as part of the notice rather than a detached trailer.
  # Config global, set by _zpun_config_load.
  # shuck: disable=C006
  local cmd=${zsh_pkg_update_nag_reminder_command}
  _zpun_ui_say prompt "  Run  ${cmd}  to upgrade."
}

# _zpun_ui_notice <lines…> — non-blocking mid-session presentation: render
# the tier-1 summary and point at the on-demand upgrade command. NEVER reads
# the terminal. Used by the deferred precmd when results arrive after the
# session's first prompt — i.e. potentially the instant the user returned
# from a foreground application, which is exactly when a blocking single-key
# read would steal their leading ESC bytes and mangle their typing.
_zpun_ui_notice() {
  emulate -L zsh
  setopt local_options

  _zpun_ui_render_summary "$@"
  _zpun_ui_say prompt "  Run  ${zsh_pkg_update_nag_reminder_command:-zsh-pkg-update-nag --now}  to upgrade."
}

# _zpun_ui_mode — single source of truth for the recognized presentation modes.
# Sets REPLY to the canonical mode (prompt|reminder) and returns 0 when
# $zsh_pkg_update_nag_mode was a recognized value, 1 when it was unrecognized
# and coerced to prompt. Both the dispatcher (_zpun_ui_present) and the
# diagnostic (_zpun_ui_print_env) classify through here so they can't drift on
# what counts as a valid mode. Sets REPLY in the caller's scope (zsh dynamic
# scoping) — callers should `local REPLY` before invoking. No fork: this runs on
# the nag path, so it stays a plain case with no command substitution.
_zpun_ui_mode() {
  emulate -L zsh
  setopt local_options
  case ${zsh_pkg_update_nag_mode:-prompt} in
    reminder) REPLY=reminder ; return 0 ;;
    prompt)   REPLY=prompt   ; return 0 ;;
    *)        REPLY=prompt   ; return 1 ;;
  esac
}

# _zpun_ui_present <lines…> — dispatch to the configured presentation mode.
# reminder: list + instruction; prompt (default): the interactive [Y/n/s] flow.
# An explicit `--now` invocation sets ZSH_PKG_UPDATE_NAG_FORCE=1, which config
# load never touches, so it reliably forces the prompt path regardless of the
# ambient mode (whose whole purpose is to defer the upgrade to a command like
# `--now`). Dispatching on FORCE here rather than on a var passed to _zpun_main
# survives the config reload _zpun_main performs.
_zpun_ui_present() {
  emulate -L zsh
  setopt local_options

  local REPLY
  _zpun_ui_mode

  {
    if [[ ${ZSH_PKG_UPDATE_NAG_FORCE:-0} != 1 && $REPLY == reminder ]]; then
      _zpun_ui_reminder "$@"
    else
      _zpun_ui_prompt_and_upgrade "$@"
    fi
  } always {
    # Single teardown owner: whatever mode handler ran, restore the tty and
    # replay captured type-ahead once it returns. Idempotent — the prompt path
    # necessarily ends the session itself before running upgrades, and on the
    # deferred precmd path no session exists at all.
    _zpun_input_capture_end
  }
}

_zpun_ui_upgrade_all() {
  emulate -L zsh
  setopt local_options

  local line manager pkg ver
  for line in "$@"; do
    (( ${_ZPUN_INTERRUPTED:-0} )) && { _zpun_ui_info "Stopped (Ctrl-C)."; return; }
    manager=${${(s:	:)line}[1]}
    pkg=${${(s:	:)line}[2]}
    ver=${${(s:	:)line}[4]}
    _zpun_run_upgrade "$manager" "$pkg" "$ver" || _zpun_ui_error "  upgrade failed for ${manager} ${pkg}"
  done
  _zpun_ui_ok "Done."
}

_zpun_ui_upgrade_individually() {
  emulate -L zsh
  setopt local_options

  local line manager pkg cur lat choice REPLY
  for line in "$@"; do
    (( ${_ZPUN_INTERRUPTED:-0} )) && { _zpun_ui_info "Stopped (Ctrl-C)."; return; }
    manager=${${(s:	:)line}[1]}
    pkg=${${(s:	:)line}[2]}
    cur=${${(s:	:)line}[3]}
    lat=${${(s:	:)line}[4]}

    _zpun_ui_read_choice "update ${manager} ${pkg} ${cur} → ${lat}? [Y/n]" "yn" "y"
    choice=$REPLY
    if [[ $choice == y ]]; then
      _zpun_run_upgrade "$manager" "$pkg" "$lat" || _zpun_ui_error "  upgrade failed for ${manager} ${pkg}"
    fi
  done
  _zpun_ui_ok "Done."
}

# _zpun_ui_print_env — diagnostic output for the --check-env subcommand.
_zpun_ui_print_env() {
  emulate -L zsh
  setopt local_options

  # min-age helpers are normally lazy-loaded only when the feature is on,
  # but --check-env should report cache state accurately even when min-age
  # is currently disabled (the cache file may persist from prior config).
  # Latency doesn't matter here — this is a manual diagnostic command.
  (( $+functions[_zpun_min_age_threshold] )) || source "$_ZPUN_DIR/lib/min_age.zsh"

  local stamp=$(_zpun_rate_limit_stamp_path)
  local stamp_status="absent (will init on next shell)"
  if [[ -e $stamp ]]; then
    local mtime=$(_zpun_mtime "$stamp")
    local now=$(date +%s)
    local age_min=$(( (now - mtime) / 60 ))
    local interval_min=$(( zsh_pkg_update_nag_interval_hours * 60 ))
    local remaining=$(( interval_min - age_min ))
    (( remaining < 0 )) && remaining=0
    stamp_status="last check ${age_min}m ago; next check in ${remaining}m"
  fi

  print -r -- "zsh-pkg-update-nag"
  print -r -- "  version:       $(_zpun_version 2>/dev/null || print 0.6.0)"
  print -r -- "  plugin dir:    $_ZPUN_DIR"
  print -r -- "  state dir:     $(_zpun_state_dir)"
  print -r -- "  interval:      ${zsh_pkg_update_nag_interval_hours}h"
  local REPLY
  if _zpun_ui_mode; then
    case $REPLY in
      reminder)
        print -r -- "  mode:          reminder (\"${zsh_pkg_update_nag_reminder_command}\")" ;;
      prompt)
        print -r -- "  mode:          prompt" ;;
    esac
  else
    print -r -- "  mode:          prompt (unrecognized value \"${zsh_pkg_update_nag_mode}\")"
  fi
  local global_age=${zsh_pkg_update_nag_min_age:-0}
  local cached_count=0
  (( $+functions[_zpun_min_age_cache_count] )) && cached_count=$(_zpun_min_age_cache_count)
  if (( global_age > 0 )); then
    print -r -- "  min age:       ${global_age}d global (${cached_count} cached)"
  else
    print -r -- "  min age:       off (global; ${cached_count} cached)"
  fi
  print -r -- "  stamp:         $stamp_status"
  print -r -- "  managers:"
  local m mode allow available age_label age_threshold ask_label
  for m in brew npm pnpm uv gem cargo; do
    mode="off"
    if _zpun_manager_enabled "$m"; then
      allow=$(_zpun_manager_allowlist "$m" | tr '\n' ' ')
      if [[ -z ${allow// } ]]; then
        mode="all"
      else
        mode="allowlist: $allow"
      fi
    fi
    available="missing"
    (( $+commands[$m] )) && available="available"
    age_threshold=0
    (( $+functions[_zpun_min_age_threshold] )) && age_threshold=$(_zpun_min_age_threshold "$m")
    age_label=""
    (( age_threshold > 0 )) && age_label=" min-age=${age_threshold}d"
    # brew is the only manager that confirms on its own; surface the setting so
    # "why does brew prompt for every package?" is answerable from here.
    ask_label=""
    [[ $m == brew ]] && ask_label=" ask=${zsh_pkg_update_nag_brew_ask:-on}"
    print -r -- "    $m: $mode ($available)$age_label$ask_label"
  done
}

_zpun_version() { print -r -- "0.6.0" }
