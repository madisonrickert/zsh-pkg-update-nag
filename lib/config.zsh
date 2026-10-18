# Config defaults, user-config loading, and per-manager enablement checks.

# _zpun_config_load — set defaults, then source the user's config if present.
# Idempotent; safe to call multiple times.
_zpun_config_load() {
  emulate -L zsh
  setopt local_options

  : ${zsh_pkg_update_nag_interval_hours:=4}
  : ${zsh_pkg_update_nag_brew:=all}
  : ${zsh_pkg_update_nag_npm:=all}
  : ${zsh_pkg_update_nag_pnpm:=all}
  : ${zsh_pkg_update_nag_uv:=all}
  : ${zsh_pkg_update_nag_gem:=off}
  : ${zsh_pkg_update_nag_cargo:=all}
  : ${zsh_pkg_update_nag_min_age:=0}

  # Whether Homebrew runs its own confirmation prompt during an upgrade.
  # Homebrew defaults to ask-mode: `brew upgrade` prints the plan and prompts
  # whenever it pulls in dependencies, dependents, or packages beyond the named
  # one. We invoke brew once per package, so that asks once per such package,
  # after the user already answered the nag prompt.
  #
  # On (the default) leaves brew alone. Deliberately not suppressed by default:
  # brew asks only when the plan exceeds the named package, so those prompts are
  # the only place dependent upgrades surface — the nag summary lists just the
  # named packages and can't show them. Set to "off" to pass `--yes` and accept
  # the plan unseen, matching the other five managers, which never re-confirm.
  : ${zsh_pkg_update_nag_brew_ask:=on}

  # Presentation mode at the session-start nag:
  #   prompt   — render the summary and block on the [Y/n/s] upgrade prompt (default).
  #   reminder — render the summary and print a one-line instruction to upgrade
  #              on demand; never prompt. Nothing is read from the terminal.
  : ${zsh_pkg_update_nag_mode:=prompt}
  # Command suggested by reminder mode. Point it at whatever entry point you use
  # to run the upgrade interactively (an alias, a wrapper function, etc.).
  : ${zsh_pkg_update_nag_reminder_command:="zsh-pkg-update-nag --now"}

  local config_path=${ZSH_PKG_UPDATE_NAG_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh-pkg-update-nag/config.zsh}
  if [[ -r $config_path ]]; then
    source "$config_path"
  fi
}

# _zpun_manager_enabled <manager> — 0 if this manager should be scanned, 1 if skipped.
# A manager is enabled if its config variable is "all" or a non-empty array.
_zpun_manager_enabled() {
  emulate -L zsh
  setopt local_options

  local manager=$1
  local varname="zsh_pkg_update_nag_${manager}"
  local -a as_array
  local as_string

  # Capture both scalar and array forms.
  if [[ ${(t)${(P)varname}} == *array* ]]; then
    as_array=( "${(@P)varname}" )
    (( ${#as_array} )) || return 1
    return 0
  fi

  as_string=${(P)varname}
  [[ $as_string == off || -z $as_string ]] && return 1
  return 0
}

# _zpun_manager_allowlist <manager> — echo the allowlist for this manager.
# Empty output means "accept everything".
_zpun_manager_allowlist() {
  emulate -L zsh
  setopt local_options

  local manager=$1
  local varname="zsh_pkg_update_nag_${manager}"
  local -a as_array
  local as_string

  if [[ ${(t)${(P)varname}} == *array* ]]; then
    as_array=( "${(@P)varname}" )
    print -r -- "${(F)as_array}"
    return 0
  fi

  as_string=${(P)varname}
  if [[ $as_string == all ]]; then
    return 0
  fi
  # A scalar that isn't "all" or "off" is treated as a whitespace-separated list.
  print -r -- "${as_string//[[:space:]]/$'\n'}"
}

# _zpun_filter_by_allowlist <manager> — read TSV from stdin, drop rows whose
# first field isn't in the manager's allowlist (empty allowlist = pass-through).
_zpun_filter_by_allowlist() {
  emulate -L zsh
  setopt local_options

  local manager=$1
  local -a allow
  allow=( ${(f)"$(_zpun_manager_allowlist "$manager")"} )
  allow=( ${allow:#} )

  if (( ${#allow} == 0 )); then
    cat
    return
  fi

  local line name
  while IFS= read -r line; do
    name=${line%%$'\t'*}
    if (( ${allow[(Ie)$name]} )); then
      print -r -- "$line"
    fi
  done
}

_zpun_state_dir() {
  emulate -L zsh
  setopt local_options
  print -r -- "${XDG_STATE_HOME:-$HOME/.local/state}/zsh-pkg-update-nag"
}

# _zpun_pending_path — per-shell pending file, keyed by PID. Scan results
# belong to the shell that spawned them, so a cross-shell precmd can no
# longer consume another window's scan and pop a presentation (with its
# blocking prompt) there. zsh keeps $$ as the parent shell's PID inside
# subshells, so the parent, the deferred subshell it forks, and the precmd
# hook all agree on the name. (The legacy shared name was "pending_updates";
# a stale legacy file is harmless and simply never gets consumed — the rate
# limit gates the next real scan.)
_zpun_pending_path() {
  emulate -L zsh
  setopt local_options
  print -r -- "$(_zpun_state_dir)/pending.$$"
}

# _zpun_pending_owner_alive <pending-file> — 0 when the shell that owns the
# file (PID suffix) is still running. Such a file is NOT a leftover: its
# owner is merely busy in a foreground command and will consume it at its
# next prompt. `kill -0` is a builtin, so this costs no fork. A PID reused by
# an unrelated process reads as alive, which errs on the side of leaving
# the file alone.
_zpun_pending_owner_alive() {
  emulate -L zsh
  setopt local_options
  local pid=${1##*/pending.}
  [[ $pid == <-> ]] || return 1
  kill -0 $pid 2>/dev/null
}

# _zpun_pending_leftovers <own-pending> — set reply to the pending files in
# <own-pending>'s directory left by shells that have died, excluding
# <own-pending> itself and in-progress `.tmp` writes. Files of shells that
# died over an hour ago are deleted instead of returned: stale enough to let
# the rate limit govern the next real scan. Runs on the startup path, so it
# is fork-free: the directory comes from the argument rather than a
# $(_zpun_state_dir) subshell, and the glob qualifier `mh+1` does the age
# test without `date`/`stat`.
_zpun_pending_leftovers() {
  emulate -L zsh
  setopt local_options extended_glob
  # Used via ${(b)exclude} below, which the linter does not see.
  # shuck: disable=C001
  local exclude=$1
  local dir=${exclude:h}
  local -a candidates stale
  candidates=( $dir/pending.<->(N) )
  stale=( $dir/pending.<->(Nmh+1) )
  candidates=( ${candidates:#${(b)exclude}} )
  stale=( ${stale:#${(b)exclude}} )
  local f
  reply=()
  for f in "${candidates[@]}"; do
    if ! _zpun_pending_owner_alive "$f"; then
      reply+=( "$f" )
    fi
  done
  for f in "${stale[@]}"; do
    (( ${reply[(Ie)$f]} )) || continue
    rm -f "$f" 2>/dev/null
    reply=( ${reply:#${(b)f}} )
  done
  return 0
}

_zpun_age_cache_path() {
  emulate -L zsh
  setopt local_options
  print -r -- "$(_zpun_state_dir)/age_cache.tsv"
}

_zpun_debug_log_path() {
  emulate -L zsh
  setopt local_options
  local dir=$(_zpun_state_dir)
  [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null
  print -r -- "$dir/debug.log"
}

# _zpun_debug_log <message…> — append a line to the debug log if enabled.
_zpun_debug_log() {
  emulate -L zsh
  setopt local_options

  [[ ${ZSH_PKG_UPDATE_NAG_DEBUG:-0} == 1 ]] || return 0
  local ts=$(date +%Y-%m-%dT%H:%M:%S)
  print -r -- "[$ts] $*" >> "$(_zpun_debug_log_path)" 2>/dev/null
}
