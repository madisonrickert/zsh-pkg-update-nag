#!/usr/bin/env bats
# Regression test: _zpun_collect_outdated spawns an inner subshell per provider
# and must re-read the user's config file inside that subshell, not just rely
# on the parent shell's variables (which aren't exported).

load helpers

setup() {
  setup_env
  mkdir -p "$XDG_CONFIG_HOME/zsh-pkg-update-nag"
  cat > "$XDG_CONFIG_HOME/zsh-pkg-update-nag/config.zsh" <<'ZSH'
zsh_pkg_update_nag_brew=(gh)
zsh_pkg_update_nag_npm=off
zsh_pkg_update_nag_pnpm=off
zsh_pkg_update_nag_uv=off
zsh_pkg_update_nag_gem=off
ZSH
}
teardown() { teardown_env ; }

@test "user config allowlist applies inside provider subshells" {
  run run_plugin_zsh "_zpun_collect_outdated"
  [ "$status" -eq 0 ]
  # Only brew/gh should pass the allowlist; fd and the cask are filtered out.
  [[ "$output" == *$'brew\tgh\t2.60.0\t2.62.0'* ]]
  [[ "$output" != *"fd"* ]]
  [[ "$output" != *"example-app@latest"* ]]
  [[ "$output" != *"pnpm"* ]]
  [[ "$output" != *"rollup"* ]]
  [[ "$output" != *"ruff"* ]]
}
