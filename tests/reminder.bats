#!/usr/bin/env bats
# Tests for reminder mode (zsh_pkg_update_nag_mode=reminder): list + instruction,
# no interactive prompt.

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

@test "reminder mode renders the summary" {
  run run_plugin_zsh "
    NO_COLOR=1 zsh_pkg_update_nag_mode=reminder \
      _zpun_ui_present \$'brew\tgh\t2.60.0\t2.62.0' \$'npm\tpnpm\t9.0.0\t9.5.1'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 updates available"* ]]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"pnpm"* ]]
}

@test "reminder mode prints the upgrade instruction and no prompt" {
  run run_plugin_zsh "
    NO_COLOR=1 zsh_pkg_update_nag_mode=reminder \
      _zpun_ui_present \$'brew\tgh\t2.60.0\t2.62.0'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"zsh-pkg-update-nag --now"* ]]
  [[ "$output" != *"[Y/n/s]"* ]]
}

@test "reminder command is configurable" {
  run run_plugin_zsh "
    NO_COLOR=1 zsh_pkg_update_nag_mode=reminder \
      zsh_pkg_update_nag_reminder_command='update-nag' \
      _zpun_ui_present \$'brew\tgh\t2.60.0\t2.62.0'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run  update-nag  to upgrade."* ]]
  [[ "$output" != *"zsh-pkg-update-nag --now"* ]]
}

@test "prompt is the default mode (dispatches to the interactive path)" {
  # With no mode set, _zpun_ui_present must reach _zpun_ui_prompt_and_upgrade.
  # Stub the two downstream calls so we can assert which path ran without a tty.
  run run_plugin_zsh "
    NO_COLOR=1
    _zpun_ui_prompt_and_upgrade() { print 'PROMPT_PATH' }
    _zpun_ui_reminder()           { print 'REMINDER_PATH' }
    _zpun_ui_present \$'brew\tgh\t2.60.0\t2.62.0'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMPT_PATH"* ]]
  [[ "$output" != *"REMINDER_PATH"* ]]
}

@test "--now forces the prompt path even when reminder mode is set in the config file" {
  # Regression: reminder mode is enabled the documented way (config file), which
  # _zpun_main re-sources via _zpun_config_load. A `zsh_pkg_update_nag_mode=prompt`
  # override passed to _zpun_main would be clobbered by that reload, leaving the
  # `--now` escape hatch printing the reminder again. Dispatch keys off
  # ZSH_PKG_UPDATE_NAG_FORCE (set by the --now arm, untouched by config load), so
  # run the real zsh-pkg-update-nag --now against a real reminder config and
  # assert the prompt presenter fired.
  mkdir -p "$XDG_CONFIG_HOME/zsh-pkg-update-nag"
  echo 'zsh_pkg_update_nag_mode=reminder' > "$XDG_CONFIG_HOME/zsh-pkg-update-nag/config.zsh"
  run run_plugin_zsh "
    _zpun_collect_outdated()      { print \$'brew\tgh\t2.60.0\t2.62.0' }
    _zpun_ui_prompt_and_upgrade() { print 'PROMPT_PATH' }
    _zpun_ui_reminder()           { print 'REMINDER_PATH' }
    zsh-pkg-update-nag --now
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMPT_PATH"* ]]
  [[ "$output" != *"REMINDER_PATH"* ]]
}

@test "check-env reports reminder mode and its command" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_mode=reminder
    zsh_pkg_update_nag_reminder_command='my-upgrade'
    _zpun_ui_print_env
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode:"* ]]
  [[ "$output" == *"reminder"* ]]
  [[ "$output" == *"my-upgrade"* ]]
  # Guard the zsh local re-declaration pitfall: a `local mode=…` in
  # _zpun_ui_print_env would leak a bare `mode=<value>` line to stdout.
  [[ "$output" != *$'\nmode='* ]]
}

@test "check-env flags an unrecognized mode value instead of hiding it" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_mode=Reminder
    _zpun_ui_print_env
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode:"* ]]
  [[ "$output" == *"unrecognized value \"Reminder\""* ]]
}
