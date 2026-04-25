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
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_PNPM=empty ZPUN_FIXTURE_UV=empty \
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
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_PNPM=empty ZPUN_FIXTURE_UV=empty \
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
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_PNPM=empty ZPUN_FIXTURE_UV=empty \
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
  ZPUN_FIXTURE_BREW=empty ZPUN_FIXTURE_NPM=empty ZPUN_FIXTURE_PNPM=empty ZPUN_FIXTURE_UV=empty \
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

@test "_zpun_main_deferred registers hook when orphaned pending file exists" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \$pending
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    print -r -- \${precmd_functions[(r)_zpun_precmd_nag]:-absent}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"_zpun_precmd_nag"* ]]
}

@test "_zpun_main_deferred does not launch a new scan when orphaned file exists" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \$pending
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
    precmd_functions+=(_zpun_precmd_nag)
    _zpun_precmd_nag
    (( \${precmd_functions[(I)_zpun_precmd_nag]} )) && echo STILL_REGISTERED || echo REMOVED
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"STILL_REGISTERED"* ]]
}

@test "_zpun_precmd_nag prints checking notice on first call when scan is in flight" {
  run run_plugin_zsh "
    NO_COLOR=1
    typeset -g _ZPUN_PRECMD_ANNOUNCED=1
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"checking for package updates"* ]]
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
    _zpun_precmd_nag
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"checking for package updates"* ]]
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

@test "_zpun_main_deferred sets ANNOUNCED on orphaned-pending branch" {
  run run_plugin_zsh "
    _zpun_should_run() { return 0 }
    local pending=\$(_zpun_pending_path)
    mkdir -p \${pending:h}
    print -r -- 'ok' > \$pending
    _zpun_rate_limit_stamp
    _zpun_main_deferred
    (( \${+_ZPUN_PRECMD_ANNOUNCED} )) && echo SET || echo UNSET
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SET"* ]]
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
