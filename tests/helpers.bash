#!/usr/bin/env bash
# Shared bats helpers: isolated state/config dirs, fixture-PATH setup, and a
# convenience function to run zsh with the plugin sourced.

setup_env() {
  TMP_DIR="$(mktemp -d -t zpun.XXXXXX)"
  export XDG_STATE_HOME="$TMP_DIR/state"
  export XDG_CONFIG_HOME="$TMP_DIR/config"
  mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"

  # Stub PATH: only our fixtures + coreutils-ish essentials.
  local plugin_root
  plugin_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export ZPUN_PLUGIN_ROOT="$plugin_root"
  export PATH="$plugin_root/tests/fixtures:/usr/bin:/bin:/usr/sbin:/sbin"

  unset ZSH_PKG_UPDATE_NAG_DISABLE
  unset ZSH_PKG_UPDATE_NAG_FORCE
  unset ZSH_PKG_UPDATE_NAG_SSH
  unset ZSH_PKG_UPDATE_NAG_DEBUG
  unset NO_COLOR
}

teardown_env() {
  rm -rf "$TMP_DIR"
}

# run_plugin_zsh <zsh -c args…> — invoke zsh in a way that sources the plugin.
# We bypass interactive guards by sourcing the library files directly and
# calling functions rather than relying on the source-time auto-run.
run_plugin_zsh() {
  env -i HOME="$HOME" PATH="$PATH" TERM=xterm-256color \
    ZDOTDIR="$TMP_DIR" \
    XDG_STATE_HOME="$XDG_STATE_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    ZPUN_FIXTURE_BREW="${ZPUN_FIXTURE_BREW:-}" \
    ZPUN_FIXTURE_NPM="${ZPUN_FIXTURE_NPM:-}" \
    ZPUN_FIXTURE_NPM_AGE="${ZPUN_FIXTURE_NPM_AGE:-}" \
    ZPUN_FIXTURE_NPM_VERSIONS="${ZPUN_FIXTURE_NPM_VERSIONS:-}" \
    ZPUN_FIXTURE_PNPM="${ZPUN_FIXTURE_PNPM:-}" \
    ZPUN_FIXTURE_UV="${ZPUN_FIXTURE_UV:-}" \
    ZPUN_FIXTURE_GEM="${ZPUN_FIXTURE_GEM:-}" \
    ZPUN_FIXTURE_CARGO="${ZPUN_FIXTURE_CARGO:-}" \
    CARGO_HOME="${CARGO_HOME:-}" \
    ZPUN_FIXTURE_CURL="${ZPUN_FIXTURE_CURL:-}" \
    ZSH_PKG_UPDATE_NAG_FORCE="${ZSH_PKG_UPDATE_NAG_FORCE:-}" \
    ZSH_PKG_UPDATE_NAG_DEBUG="${ZSH_PKG_UPDATE_NAG_DEBUG:-}" \
    ZSH_PKG_UPDATE_NAG_MIN_AGE_LOOKUP_PARALLELISM="${ZSH_PKG_UPDATE_NAG_MIN_AGE_LOOKUP_PARALLELISM:-}" \
    ZSH_PKG_UPDATE_NAG_MIN_AGE_LIST_TTL="${ZSH_PKG_UPDATE_NAG_MIN_AGE_LIST_TTL:-}" \
    ZSH_PKG_UPDATE_NAG_NO_AUTORUN=1 \
    zsh -c "
      source '$ZPUN_PLUGIN_ROOT/zsh-pkg-update-nag.plugin.zsh'
      # The plugin no longer sources providers or min_age at load — they're
      # loaded on demand by _zpun_collect_outdated. Tests that call
      # _zpun_provider_<m> or _zpun_min_age_* directly need them present in
      # the current shell, so we source them eagerly here.
      for _zpun_test_provider in '$ZPUN_PLUGIN_ROOT'/lib/providers/*.zsh; do
        source \"\$_zpun_test_provider\"
      done
      source '$ZPUN_PLUGIN_ROOT/lib/min_age.zsh'
      _zpun_config_load
      $1
    "
}

# run_plugin_pty <zsh script> [typeahead answer] — like run_plugin_zsh, but
# the script runs with a pseudo-terminal on stdin (via zsh/zpty), so tty-mode
# code paths execute for real. The script's output is printed with CRs
# stripped. A helper `tty_flag <flag>` (prints on/off from `stty -a`) is
# predefined. With [typeahead answer]: once the script prints READY, type
# <typeahead>, then after 1.5 s type <answer> (pair with a `sleep 1` after
# READY so the typeahead is queued before the code under test reads).
run_plugin_pty() {
  cat > "$TMP_DIR/pty.zsh" <<EOF
source '$ZPUN_PLUGIN_ROOT/zsh-pkg-update-nag.plugin.zsh'
_zpun_config_load
tty_flag() {
  local cur=" \${\$(stty -a)//[;\$'\n'\$'\t']/ } "
  [[ \$cur == *" \$1 "* ]] && print on || print off
}
$1
print -r -- PTY_DONE
EOF
  run_plugin_zsh "
    zmodload zsh/zpty
    zpty _t 'zsh -f $TMP_DIR/pty.zsh'
    local out= line
    if [[ -n '${2:-}' ]]; then
      zpty -r _t line '*READY*'
      zpty -w -n _t '${2:-}'
      sleep 1.5
      zpty -w -n _t '${3:-}'
    fi
    while zpty -r _t line; do
      out+=\$line
      [[ \$line == *PTY_DONE* ]] && break
    done
    zpty -d _t
    print -r -- \"\${out//\$'\\r'/}\"
  "
}
