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
  : ${zsh_pkg_update_nag_min_age:=0}

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

_zpun_pending_path() {
  emulate -L zsh
  setopt local_options
  print -r -- "$(_zpun_state_dir)/pending_updates"
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
