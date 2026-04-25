#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

@test "fresh install with no stampfile is immediately due for a check" {
  run run_plugin_zsh "_zpun_rate_limit_is_due && echo DUE || echo NOT_DUE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DUE"* ]]
}

@test "rate-limit blocks within interval" {
  run_plugin_zsh "_zpun_rate_limit_stamp"
  run run_plugin_zsh "_zpun_rate_limit_is_due && echo DUE || echo NOT_DUE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT_DUE"* ]]
}

@test "FORCE overrides rate-limit" {
  run_plugin_zsh "_zpun_rate_limit_stamp"
  ZSH_PKG_UPDATE_NAG_FORCE=1 run run_plugin_zsh "_zpun_rate_limit_is_due && echo DUE || echo NOT_DUE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DUE"* ]]
}

@test "stamp refresh updates mtime" {
  run_plugin_zsh "_zpun_rate_limit_stamp"
  local stamp="$XDG_STATE_HOME/zsh-pkg-update-nag/last_check"
  touch -t 202001010000 "$stamp"
  # GNU stat (Linux) doesn't error on `-f %m`; it interprets `-f` as
  # "filesystem info" and prints a multi-line dump, so the OR never triggers.
  # Use the GNU form first and let BSD stat (macOS) be the fallback.
  local before=$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp")
  run_plugin_zsh "_zpun_rate_limit_stamp"
  local after=$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp")
  [ "$after" -gt "$before" ]
}

@test "lock prevents concurrent runs" {
  run_plugin_zsh "_zpun_rate_limit_acquire_lock && echo ONE"
  run run_plugin_zsh "_zpun_rate_limit_acquire_lock && echo TWO || echo LOCKED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOCKED"* ]]
  run_plugin_zsh "_zpun_rate_limit_release_lock"
  run run_plugin_zsh "_zpun_rate_limit_acquire_lock && echo FREE"
  [[ "$output" == *"FREE"* ]]
}
