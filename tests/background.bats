#!/usr/bin/env bats
# Tests for the background scan path (_zpun_main_deferred + _zpun_precmd_nag).

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

# ---------------------------------------------------------------------------
# Helpers used only in this file
# ---------------------------------------------------------------------------

# _wait_pending — zsh snippet that polls until the pending file appears (up to
# 5 s). Paste inline inside run_plugin_zsh calls.
_WAIT_PENDING='
  local _p=$(_zpun_pending_path)
  integer _i=0
  while [[ ! -e $_p ]] && (( _i++ < 50 )); do sleep 0.1; done
'

# _wait_stamp — same but for the rate-limit stamp (written after the pending
# file, so useful when we need to verify the stamp was actually set).
_WAIT_STAMP='
  local _s=$(_zpun_rate_limit_stamp_path)
  integer _i=0
  while [[ ! -e $_s ]] && (( _i++ < 50 )); do sleep 0.1; done
'

# ---------------------------------------------------------------------------
# Background subshell: pending file content
# ---------------------------------------------------------------------------

@test "background scan writes 'ok' when no updates found" {
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_PNPM=empty ZPUN_FIXTURE_UV=empty ZPUN_FIXTURE_CARGO=empty \
    run run_plugin_zsh "
      _zpun_should_run() { return 0 }
      _zpun_main_deferred
      ${_WAIT_PENDING}
      cat \$(_zpun_pending_path)
    "
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "background scan writes TSV lines when updates are available" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    _zpun_main_deferred
    ${_WAIT_PENDING}
    cat \$(_zpun_pending_path)
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *$'brew\tgh\t2.60.0\t2.62.0'* ]]
  [[ "$output" == *$'npm\tpnpm\t9.0.0\t9.5.1'* ]]
}

# Regression: if the mv that finalizes the pending file fails silently (e.g.
# read-only XDG_STATE_HOME or ENOSPC), the EXIT trap must still write the 'err'
# sentinel so _zpun_precmd_nag has a "done" signal and can deregister itself.
# Pre-fix code cleared the trap before exit (`trap - INT TERM EXIT`), so a
# silent mv failure left no pending file and the precmd hook polled forever.
@test "background scan writes 'err' when mv fails silently (trap is the exit invariant)" {
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_PNPM=empty ZPUN_FIXTURE_UV=empty ZPUN_FIXTURE_CARGO=empty \
    run run_plugin_zsh "
      _zpun_should_run() { return 0 }
      # zsh subshells inherit function definitions, so this overrides the mv
      # call inside the background subshell launched by _zpun_main_deferred.
      mv() { return 1 }
      _zpun_main_deferred
      ${_WAIT_PENDING}
      cat \$(_zpun_pending_path)
    "
  [ "$status" -eq 0 ]
  [ "$output" = "err" ]
}

# ---------------------------------------------------------------------------
# Background subshell: rate-limit housekeeping
# ---------------------------------------------------------------------------

@test "background scan stamps the rate limit on completion" {
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_PNPM=empty ZPUN_FIXTURE_UV=empty ZPUN_FIXTURE_CARGO=empty \
    run run_plugin_zsh "
      _zpun_should_run() { return 0 }
      _zpun_main_deferred
      ${_WAIT_STAMP}
      _zpun_rate_limit_is_due && echo DUE || echo NOT_DUE
    "
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT_DUE"* ]]
}

@test "background scan releases the lock on completion" {
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_PNPM=empty ZPUN_FIXTURE_UV=empty ZPUN_FIXTURE_CARGO=empty \
    run run_plugin_zsh "
      _zpun_should_run() { return 0 }
      _zpun_main_deferred
      ${_WAIT_PENDING}
      _zpun_rate_limit_acquire_lock && echo LOCK_FREE || echo LOCK_HELD
    "
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOCK_FREE"* ]]
}

# ---------------------------------------------------------------------------
# _zpun_main_deferred: orphaned pending file from a previous shell
# ---------------------------------------------------------------------------

@test "_zpun_main_deferred registers hook when leftover pending files exist" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    # A dead shell's leftover — NOT our own pending.$$ — must be adopted.
    print -r -- 'ok' > \"\${pending:h}/pending.99999\"
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    print -r -- \${precmd_functions[(r)_zpun_precmd_nag]:-absent}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"_zpun_precmd_nag"* ]]
}

@test "_zpun_main_deferred does not launch a new scan when leftovers exist and not due" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \"\${pending:h}/pending.99999\"
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    # Lock should not be held — no new scan was started.
    _zpun_rate_limit_acquire_lock && echo LOCK_FREE || echo LOCK_HELD
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOCK_FREE"* ]]
}

# ---------------------------------------------------------------------------
# _zpun_precmd_nag: pending file absent (scan still in flight)
# ---------------------------------------------------------------------------

@test "_zpun_precmd_nag stays registered when pending file is absent" {
  run run_plugin_zsh "
    typeset -g _ZPUN_SCAN_IN_FLIGHT=1
    precmd_functions+=(_zpun_precmd_nag)
    _zpun_precmd_nag
    (( \${precmd_functions[(I)_zpun_precmd_nag]} )) && echo STILL_REGISTERED || echo REMOVED
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"STILL_REGISTERED"* ]]
}

@test "_zpun_precmd_nag deregisters when no scan is in flight (leftover-only)" {
  run run_plugin_zsh "
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    precmd_functions+=(_zpun_precmd_nag)
    _zpun_precmd_nag
    (( \${precmd_functions[(I)_zpun_precmd_nag]} )) && echo STILL_REGISTERED || echo REMOVED
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOVED"* ]]
}

@test "_zpun_precmd_nag prints checking notice on first call when scan is in flight" {
  run run_plugin_zsh "
    NO_COLOR=1
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    typeset -g _ZPUN_SCAN_IN_FLIGHT=1
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"checking for package updates"* ]]
}

@test "_zpun_precmd_nag prints no checking notice when no scan is in flight" {
  run run_plugin_zsh "
    NO_COLOR=1
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"checking for package updates"* ]]
}

@test "_zpun_precmd_nag clears the announced flag so subsequent calls are silent" {
  run run_plugin_zsh "
    NO_COLOR=1
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    _zpun_precmd_nag
    (( \${+_ZPUN_PRECMD_ANNOUNCED} )) && echo FLAG_SET || echo FLAG_CLEARED
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"FLAG_CLEARED"* ]]
}

# ---------------------------------------------------------------------------
# _zpun_precmd_nag: pending file present — ok sentinel
# ---------------------------------------------------------------------------

@test "_zpun_precmd_nag prints 'all up to date' for ok sentinel" {
  run run_plugin_zsh "
    NO_COLOR=1
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \$pending
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"All packages up to date"* ]]
}

@test "_zpun_precmd_nag removes itself from precmd_functions for ok sentinel" {
  run run_plugin_zsh "
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \$pending
    precmd_functions+=(_zpun_precmd_nag)
    _zpun_precmd_nag
    (( \${precmd_functions[(I)_zpun_precmd_nag]} == 0 )) && echo REMOVED || echo STILL_REGISTERED
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOVED"* ]]
}

@test "_zpun_precmd_nag removes the pending file after consuming it" {
  run run_plugin_zsh "
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \$pending
    _zpun_precmd_nag
    [[ -e \$pending ]] && echo FILE_EXISTS || echo FILE_GONE
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"FILE_GONE"* ]]
}

# ---------------------------------------------------------------------------
# _zpun_precmd_nag: pending file present — err sentinel
# ---------------------------------------------------------------------------

@test "_zpun_precmd_nag is silent to the user for err sentinel" {
  run run_plugin_zsh "
    NO_COLOR=1
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'err' > \$pending
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_zpun_precmd_nag removes itself for err sentinel" {
  run run_plugin_zsh "
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'err' > \$pending
    precmd_functions+=(_zpun_precmd_nag)
    _zpun_precmd_nag
    (( \${precmd_functions[(I)_zpun_precmd_nag]} == 0 )) && echo REMOVED || echo STILL_REGISTERED
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOVED"* ]]
}

# ---------------------------------------------------------------------------
# _zpun_precmd_nag: pending file present — TSV updates
# ---------------------------------------------------------------------------

@test "_zpun_precmd_nag shows update prompt for TSV pending file" {
  run run_plugin_zsh "
    NO_COLOR=1
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- \$'brew\tgh\t2.60.0\t2.62.0' > \$pending
    _zpun_precmd_nag <<< 'n'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 update available"* ]]
  [[ "$output" == *"gh"* ]]
}

@test "_zpun_precmd_nag removes itself after showing update prompt" {
  run run_plugin_zsh "
    NO_COLOR=1
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- \$'brew\tgh\t2.60.0\t2.62.0' > \$pending
    precmd_functions+=(_zpun_precmd_nag)
    _zpun_precmd_nag <<< 'n'
    (( \${precmd_functions[(I)_zpun_precmd_nag]} == 0 )) && echo REMOVED || echo STILL_REGISTERED
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOVED"* ]]
}

# ---------------------------------------------------------------------------
# powerlevel10k instant-prompt compatibility
#
# When p10k instant-prompt is active, output during the first precmd can
# corrupt the pre-prompt buffer. _zpun_precmd_nag must:
#   - suppress the "(checking…)" notice (cosmetic loss),
#   - defer the first results-display call by one precmd so the print lands
#     after p10k finalizes regardless of hook registration order.
# ---------------------------------------------------------------------------

@test "_zpun_p10k_instant_prompt_active is false when var is unset" {
  run run_plugin_zsh "
    unset POWERLEVEL9K_INSTANT_PROMPT
    _zpun_p10k_instant_prompt_active && echo ACTIVE || echo INACTIVE
  "
  [[ "$output" == *"INACTIVE"* ]]
}

@test "_zpun_p10k_instant_prompt_active is false when var=off" {
  run run_plugin_zsh "
    POWERLEVEL9K_INSTANT_PROMPT=off
    _zpun_p10k_instant_prompt_active && echo ACTIVE || echo INACTIVE
  "
  [[ "$output" == *"INACTIVE"* ]]
}

@test "_zpun_p10k_instant_prompt_active is true for quiet" {
  run run_plugin_zsh "
    POWERLEVEL9K_INSTANT_PROMPT=quiet
    _zpun_p10k_instant_prompt_active && echo ACTIVE || echo INACTIVE
  "
  [[ "$output" == *"ACTIVE"* ]]
}

@test "_zpun_p10k_instant_prompt_active is true for verbose" {
  run run_plugin_zsh "
    POWERLEVEL9K_INSTANT_PROMPT=verbose
    _zpun_p10k_instant_prompt_active && echo ACTIVE || echo INACTIVE
  "
  [[ "$output" == *"ACTIVE"* ]]
}

@test "_zpun_precmd_nag suppresses checking notice under p10k instant-prompt" {
  run run_plugin_zsh "
    NO_COLOR=1
    POWERLEVEL9K_INSTANT_PROMPT=quiet
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"checking for package updates"* ]]
}

@test "_zpun_precmd_nag prints checking notice when POWERLEVEL9K_INSTANT_PROMPT=off" {
  run run_plugin_zsh "
    NO_COLOR=1
    POWERLEVEL9K_INSTANT_PROMPT=off
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    typeset -g _ZPUN_SCAN_IN_FLIGHT=1
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"checking for package updates"* ]]
}

@test "_zpun_precmd_nag mid-session arrival: notice, never the interactive prompt" {
  run run_plugin_zsh "
    NO_COLOR=1
    zsh_pkg_update_nag_mode=prompt
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    printf 'brew\tollama\t0.33.0\t0.40.0\n' > \$pending
    # first_call has passed: no _ZPUN_PRECMD_ANNOUNCED, no _ZPUN_SCAN_IN_FLIGHT
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ollama"* ]]
  [[ "$output" == *"to upgrade"* ]]
  [[ "$output" != *"Update all"* ]]
}

@test "_zpun_ui_read_choice: EOF (closed stdin) declines instead of defaulting" {
  run run_plugin_zsh "
    _zpun_ui_read_choice 'P?' 'yns' 'y' < /dev/null
    print -r -- \"[\$REPLY]\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[n]"* ]]
}

@test "_zpun_precmd_nag defers first call under p10k when pending exists" {
  run run_plugin_zsh "
    NO_COLOR=1
    POWERLEVEL9K_INSTANT_PROMPT=quiet
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \$pending
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    precmd_functions+=(_zpun_precmd_nag)
    _zpun_precmd_nag
    [[ -e \$pending ]] && echo PENDING_KEPT || echo PENDING_GONE
    (( \${precmd_functions[(I)_zpun_precmd_nag]} )) && echo HOOK_KEPT || echo HOOK_REMOVED
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"All packages up to date"* ]]
  [[ "$output" == *"PENDING_KEPT"* ]]
  [[ "$output" == *"HOOK_KEPT"* ]]
}

@test "_zpun_precmd_nag processes pending on second call after p10k defer" {
  run run_plugin_zsh "
    NO_COLOR=1
    POWERLEVEL9K_INSTANT_PROMPT=quiet
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \$pending
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    precmd_functions+=(_zpun_precmd_nag)
    _zpun_precmd_nag
    _zpun_precmd_nag
    [[ -e \$pending ]] && echo PENDING_KEPT || echo PENDING_GONE
    (( \${precmd_functions[(I)_zpun_precmd_nag]} )) && echo HOOK_KEPT || echo HOOK_REMOVED
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"All packages up to date"* ]]
  [[ "$output" == *"PENDING_GONE"* ]]
  [[ "$output" == *"HOOK_REMOVED"* ]]
}

@test "_zpun_precmd_nag does not defer when POWERLEVEL9K_INSTANT_PROMPT=off" {
  run run_plugin_zsh "
    NO_COLOR=1
    POWERLEVEL9K_INSTANT_PROMPT=off
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \$pending
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"All packages up to date"* ]]
}

@test "_zpun_main_deferred sets ANNOUNCED on the leftover branch" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \"\${pending:h}/pending.99999\"
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    (( \${+_ZPUN_PRECMD_ANNOUNCED} )) && echo ANNOUNCED_SET || echo ANNOUNCED_UNSET
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANNOUNCED_SET"* ]]
}

# A pending.$$ present at startup was left by a dead shell whose PID we
# reused: it must not be presented as this shell's own fresh scan.
@test "_zpun_main_deferred discards a stale pending file at its own PID" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- \$'brew\tgh\t2.60.0\t2.62.0' > \$pending
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    [[ -e \$pending ]] && echo PENDING_KEPT || echo PENDING_GONE
    (( \${+_ZPUN_PRECMD_ANNOUNCED} )) && echo ANNOUNCED_SET || echo ANNOUNCED_UNSET
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PENDING_GONE"* ]]
  [[ "$output" == *"ANNOUNCED_UNSET"* ]]
}

# ---------------------------------------------------------------------------
# Leftover adoption: only DEAD shells' files are leftovers.
# ---------------------------------------------------------------------------

# _DEAD_PID — zsh snippet: set dead_pid to a PID no process holds.
_DEAD_PID='
  integer dead_pid=99000
  while kill -0 $dead_pid 2>/dev/null; do (( dead_pid++ )); done
'

@test "leftovers: a live shell's pending file is neither adopted nor deleted" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    local dir=\$(_zpun_state_dir)
    mkdir -p \$dir
    sleep 30 &
    local live=\$!
    print -r -- \$'brew\tgh\t2.60.0\t2.62.0' > \$dir/pending.\$live
    touch -t 202001010000 \$dir/pending.\$live   # old, too: still not gc'd
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    print -r -- \"leftovers=\${#_ZPUN_LEFTOVER_PENDING}\"
    [[ -e \$dir/pending.\$live ]] && echo FILE_KEPT || echo FILE_GONE
    kill \$live
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"leftovers=0"* ]]
  [[ "$output" == *"FILE_KEPT"* ]]
}

@test "leftovers: a dead shell's hour-old pending file is deleted, not adopted" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    ${_DEAD_PID}
    local dir=\$(_zpun_state_dir)
    mkdir -p \$dir
    print -r -- \$'brew\tgh\t2.60.0\t2.62.0' > \$dir/pending.\$dead_pid
    touch -t 202001010000 \$dir/pending.\$dead_pid
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    print -r -- \"leftovers=\${#_ZPUN_LEFTOVER_PENDING}\"
    [[ -e \$dir/pending.\$dead_pid ]] && echo FILE_KEPT || echo FILE_GONE
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"leftovers=0"* ]]
  [[ "$output" == *"FILE_GONE"* ]]
}

@test "leftovers: delivered as a notice, then the hook deregisters" {
  run run_plugin_zsh "
    NO_COLOR=1
    _zpun_should_run() { return 0 }
    ${_DEAD_PID}
    local dir=\$(_zpun_state_dir)
    mkdir -p \$dir
    print -r -- \$'brew\tgh\t2.60.0\t2.62.0' > \$dir/pending.\$dead_pid
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    _zpun_precmd_nag
    [[ -e \$dir/pending.\$dead_pid ]] && echo FILE_KEPT || echo FILE_GONE
    (( \${precmd_functions[(I)_zpun_precmd_nag]} )) && echo HOOK_KEPT || echo HOOK_REMOVED
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"to upgrade"* ]]
  [[ "$output" != *"Update all"* ]]
  [[ "$output" == *"FILE_GONE"* ]]
  [[ "$output" == *"HOOK_REMOVED"* ]]
}

@test "leftovers: survive the p10k deferral and are delivered on the second call" {
  run run_plugin_zsh "
    NO_COLOR=1
    POWERLEVEL9K_INSTANT_PROMPT=quiet
    _zpun_should_run() { return 0 }
    ${_DEAD_PID}
    local dir=\$(_zpun_state_dir)
    mkdir -p \$dir
    print -r -- \$'brew\tgh\t2.60.0\t2.62.0' > \$dir/pending.\$dead_pid
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    _zpun_precmd_nag
    print -r -- '--- second precmd'
    _zpun_precmd_nag
    [[ -e \$dir/pending.\$dead_pid ]] && echo FILE_KEPT || echo FILE_GONE
    (( \${precmd_functions[(I)_zpun_precmd_nag]} )) && echo HOOK_KEPT || echo HOOK_REMOVED
  "
  [ "$status" -eq 0 ]
  # Nothing before the deferral; the notice after it.
  [[ "${output%%--- second precmd*}" != *"gh"* ]]
  [[ "${output#*--- second precmd}" == *"gh"* ]]
  [[ "$output" == *"FILE_GONE"* ]]
  [[ "$output" == *"HOOK_REMOVED"* ]]
}

# ---------------------------------------------------------------------------
# Session start vs. mid-session: only results waiting before the user has run
# anything may block on the interactive prompt.
# ---------------------------------------------------------------------------

@test "p10k: deferred call is session start when no command ran (bare Enter)" {
  run run_plugin_zsh "
    NO_COLOR=1
    zsh_pkg_update_nag_mode=prompt
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- \$'brew\tgh\t2.60.0\t2.62.0' > \$pending
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    typeset -g _ZPUN_P10K_DEFERRED=\$HISTCMD
    POWERLEVEL9K_INSTANT_PROMPT=quiet
    _zpun_precmd_nag <<< 'n'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Update all"* ]]
}

@test "p10k: deferred call after a command ran is a non-blocking notice" {
  run run_plugin_zsh "
    NO_COLOR=1
    zsh_pkg_update_nag_mode=prompt
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- \$'brew\tgh\t2.60.0\t2.62.0' > \$pending
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    typeset -g _ZPUN_P10K_DEFERRED=\$(( HISTCMD - 1 ))
    POWERLEVEL9K_INSTANT_PROMPT=quiet
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"to upgrade"* ]]
  [[ "$output" != *"Update all"* ]]
}

# ---------------------------------------------------------------------------
# Background subshell signal handling
# ---------------------------------------------------------------------------

# zsh signal traps resume execution after running, so the subshell must exit
# explicitly on TERM rather than carry on scanning after writing 'err'.
@test "background scan exits on TERM, writing 'err' and releasing the lock" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    local dir=\$(_zpun_state_dir)
    _zpun_collect_outdated() {
      zmodload zsh/system
      print -r -- \$sysparams[ppid] > \$dir/scan.pid
      sleep 3
      print -r -- \$'brew\tgh\t2.60.0\t2.62.0'
    }
    _zpun_main_deferred
    integer i=0
    while [[ ! -s \$dir/scan.pid ]] && (( i++ < 50 )); do sleep 0.1; done
    local scan=\$(<\$dir/scan.pid)
    kill -TERM \$scan
    ${_WAIT_PENDING}
    cat \$(_zpun_pending_path)
    i=0
    while kill -0 \$scan 2>/dev/null && (( i++ < 20 )); do sleep 0.1; done
    kill -0 \$scan 2>/dev/null && echo SCAN_ALIVE || echo SCAN_EXITED
    _zpun_rate_limit_acquire_lock && echo LOCK_FREE || echo LOCK_HELD
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"err"* ]]
  [[ "$output" == *"SCAN_EXITED"* ]]
  [[ "$output" == *"LOCK_FREE"* ]]
}

# ---------------------------------------------------------------------------
# Auto-run dispatch (_zpun_dispatch)
#
# Background mode is the default; ZSH_PKG_UPDATE_NAG_BACKGROUND=0 opts out.
# ---------------------------------------------------------------------------

@test "_zpun_dispatch picks _zpun_main_deferred by default" {
  run run_plugin_zsh "
    _zpun_main()          { print -r -- CALLED_MAIN }
    _zpun_main_deferred() { print -r -- CALLED_DEFERRED }
    unset ZSH_PKG_UPDATE_NAG_BACKGROUND
    _zpun_dispatch
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED_DEFERRED"* ]]
  [[ "$output" != *"CALLED_MAIN"* ]]
}

@test "_zpun_dispatch picks _zpun_main_deferred when BACKGROUND=1" {
  run run_plugin_zsh "
    _zpun_main()          { print -r -- CALLED_MAIN }
    _zpun_main_deferred() { print -r -- CALLED_DEFERRED }
    ZSH_PKG_UPDATE_NAG_BACKGROUND=1 _zpun_dispatch
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED_DEFERRED"* ]]
  [[ "$output" != *"CALLED_MAIN"* ]]
}

@test "_zpun_dispatch picks _zpun_main when BACKGROUND=0" {
  run run_plugin_zsh "
    _zpun_main()          { print -r -- CALLED_MAIN }
    _zpun_main_deferred() { print -r -- CALLED_DEFERRED }
    ZSH_PKG_UPDATE_NAG_BACKGROUND=0 _zpun_dispatch
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED_MAIN"* ]]
  [[ "$output" != *"CALLED_DEFERRED"* ]]
}

# ---------------------------------------------------------------------------
# Typed-input guard: render summary, render the prompt line as auto-skipped
# with an 'n' result rather than reading a possibly-pre-typed character.
# ---------------------------------------------------------------------------

@test "_zpun_has_typed_input returns 1 when stdin isn't a TTY" {
  run run_plugin_zsh "_zpun_has_typed_input && echo HAS || echo CLEAR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEAR"* ]]
}

@test "prompt_and_upgrade auto-skips with 'n' when user has typed input" {
  run run_plugin_zsh "
    NO_COLOR=1
    _zpun_has_typed_input() { return 0 }   # mock: user is typing
    lines=( \$'brew\tgh\t2.60.0\t2.62.0' \$'npm\tpnpm\t9.0.0\t9.5.1' )
    _zpun_ui_prompt_and_upgrade \"\${lines[@]}\"
  "
  [ "$status" -eq 0 ]
  # Summary still rendered so the user sees what was found.
  [[ "$output" == *"2 updates available"* ]]
  [[ "$output" == *"gh"* ]]
  # Prompt line shown as auto-dismissed.
  [[ "$output" == *"Update all? [Y/n/s]"* ]]
  [[ "$output" == *"typed input detected"* ]]
  # 'n' branch reached: skip notice, no upgrades.
  [[ "$output" == *"Skipped."* ]]
  [[ "$output" != *"fixture upgraded"* ]]
  [[ "$output" != *"fixture installed"* ]]
}

@test "prompt_and_upgrade reads normally when stdin has no typed input" {
  # _zpun_has_typed_input returns 1 (no TTY in bats), so the auto-skip
  # branch isn't taken — we fall through to the standard read.
  run run_plugin_zsh "
    NO_COLOR=1
    lines=( \$'brew\tgh\t2.60.0\t2.62.0' )
    _zpun_ui_prompt_and_upgrade \"\${lines[@]}\" <<< 'n'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 update available"* ]]
  [[ "$output" != *"typed input detected"* ]]
  [[ "$output" == *"Skipped."* ]]
}
