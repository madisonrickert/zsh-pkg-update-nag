# Terminal UI: color-aware printers, summary formatter, and tiered prompt loop.

# Human-friendly labels for each supported manager.
typeset -gA _ZPUN_MANAGER_LABELS=(
  brew "Homebrew"
  npm  "npm (global)"
  uv   "uv tools"
  gem  "RubyGems"
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

  print -P -r -- "${open}${text}${close}"
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
    print -nP -- "${reset}  %F{244}…%f $*" >&2
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

    if [[ $manager != $prev_manager ]]; then
      label=${_ZPUN_MANAGER_LABELS[$manager]:-$manager}
      _zpun_ui_say header "  $label"
      prev_manager=$manager
    fi

    pad=$(( max_name - ${#pkg} ))
    (( pad < 0 )) && pad=0
    spaces=${(l:$pad:: :)}
    if _zpun_ui_color_enabled; then
      print -P -r -- "    %F{default}${pkg}%f${spaces}  %F{yellow}${cur}%f %F{244}→%f %F{green}${lat}%f"
    else
      print -r -- "    ${pkg}${spaces}  ${cur} → ${lat}"
    fi
  done
  print
}

# _zpun_ui_read_choice <prompt> <valid_chars> <default_char>
# Displays the prompt on stderr so callers can safely $(...)-capture stdout.
# Emits exactly one character (the chosen key, lowercased) on stdout.
_zpun_ui_read_choice() {
  emulate -L zsh
  setopt local_options

  local prompt=$1 valid=$2 default=$3
  local key

  if _zpun_ui_color_enabled; then
    print -nP -r -- "  %F{cyan}${prompt}%f " >&2
  else
    print -n -r -- "  ${prompt} " >&2
  fi

  # read -k 1 reads a single keypress; -u 0 forces stdin (important for subshells).
  if ! read -k 1 -u 0 key; then
    print >&2
    print -r -- "$default"
    return
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
    key=$default
  fi
  print -r -- "$key"
}

# _zpun_ui_prompt_and_upgrade <lines…> — tier-1 prompt, then run upgrades.
_zpun_ui_prompt_and_upgrade() {
  emulate -L zsh
  setopt local_options

  local -a lines
  lines=( "$@" )

  _zpun_ui_render_summary "${lines[@]}"

  local choice=$(_zpun_ui_read_choice "Update all? [Y/n/s] ›" "yns" "y")

  case $choice in
    y) _zpun_ui_upgrade_all "${lines[@]}" ;;
    n) _zpun_ui_info "Skipped. Next check in ${zsh_pkg_update_nag_interval_hours}h." ;;
    s) _zpun_ui_upgrade_individually "${lines[@]}" ;;
  esac
}

_zpun_ui_upgrade_all() {
  emulate -L zsh
  setopt local_options

  local line manager pkg
  for line in "$@"; do
    manager=${${(s:	:)line}[1]}
    pkg=${${(s:	:)line}[2]}
    _zpun_run_upgrade "$manager" "$pkg" || _zpun_ui_error "  upgrade failed for ${manager} ${pkg}"
  done
  _zpun_ui_ok "Done."
}

_zpun_ui_upgrade_individually() {
  emulate -L zsh
  setopt local_options

  local line manager pkg cur lat choice
  for line in "$@"; do
    manager=${${(s:	:)line}[1]}
    pkg=${${(s:	:)line}[2]}
    cur=${${(s:	:)line}[3]}
    lat=${${(s:	:)line}[4]}

    choice=$(_zpun_ui_read_choice "update ${manager} ${pkg} ${cur} → ${lat}? [Y/n]" "yn" "y")
    if [[ $choice == y ]]; then
      _zpun_run_upgrade "$manager" "$pkg" || _zpun_ui_error "  upgrade failed for ${manager} ${pkg}"
    fi
  done
  _zpun_ui_ok "Done."
}

# _zpun_ui_print_env — diagnostic output for the --check-env subcommand.
_zpun_ui_print_env() {
  emulate -L zsh
  setopt local_options

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
  print -r -- "  version:       $(_zpun_version 2>/dev/null || print 0.1.0)"
  print -r -- "  plugin dir:    $_ZPUN_DIR"
  print -r -- "  state dir:     $(_zpun_state_dir)"
  print -r -- "  interval:      ${zsh_pkg_update_nag_interval_hours}h"
  local global_age=${zsh_pkg_update_nag_min_age_days:-0}
  local cached_count=0
  (( $+functions[_zpun_min_age_cache_count] )) && cached_count=$(_zpun_min_age_cache_count)
  if (( global_age > 0 )); then
    print -r -- "  min age:       ${global_age}d global (${cached_count} cached)"
  else
    print -r -- "  min age:       off (global; ${cached_count} cached)"
  fi
  print -r -- "  stamp:         $stamp_status"
  print -r -- "  managers:"
  local m mode allow available age_label age_threshold
  for m in brew npm uv gem; do
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
    print -r -- "    $m: $mode ($available)$age_label"
  done
}

_zpun_version() { print -r -- "0.1.0" }
