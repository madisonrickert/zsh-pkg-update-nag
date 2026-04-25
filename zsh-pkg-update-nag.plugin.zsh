# zsh-pkg-update-nag — on-demand, rate-limited global-package update prompts.

# Resolve this file's directory whether we were sourced directly or through OMZ.
typeset -g _ZPUN_DIR="${${(%):-%x}:A:h}"

# Expose the shipped completion (_zsh-pkg-update-nag) to the completion system.
# oh-my-zsh usually does this automatically for its plugins, but adding it
# explicitly makes standalone `source`-based installs work too.
fpath=("$_ZPUN_DIR" $fpath)

source "$_ZPUN_DIR/lib/config.zsh"
source "$_ZPUN_DIR/lib/rate_limit.zsh"
source "$_ZPUN_DIR/lib/ui.zsh"
source "$_ZPUN_DIR/lib/min_age.zsh"
source "$_ZPUN_DIR/lib/providers/brew.zsh"
source "$_ZPUN_DIR/lib/providers/npm.zsh"
source "$_ZPUN_DIR/lib/providers/uv.zsh"
source "$_ZPUN_DIR/lib/providers/gem.zsh"

# _zpun_should_run — returns 0 if the current environment is a good place to nag.
# Honors ZSH_PKG_UPDATE_NAG_DISABLE unconditionally; skips environmental guards
# when ZSH_PKG_UPDATE_NAG_FORCE=1 so `zsh-pkg-update-nag --now` works from any
# context (pipes, scripts, etc.).
_zpun_should_run() {
  emulate -L zsh
  setopt local_options

  [[ ${ZSH_PKG_UPDATE_NAG_DISABLE:-0} != 1 ]] || return 1
  [[ ${ZSH_PKG_UPDATE_NAG_FORCE:-0} == 1 ]] && return 0

  [[ -o interactive ]] || return 1
  [[ $TERM != dumb ]] || return 1
  [[ -t 0 && -t 1 ]] || return 1
  [[ -z $CI ]] || return 1
  [[ -z $INSIDE_EMACS ]] || return 1
  if [[ -n $SSH_CONNECTION || -n $SSH_CLIENT ]]; then
    [[ ${ZSH_PKG_UPDATE_NAG_SSH:-0} == 1 ]] || return 1
  fi
  return 0
}

# _zpun_collect_outdated — runs each enabled provider with a timeout and
# aggregates their TSV output into an array. Lines: manager\tname\tcurrent\tlatest.
_zpun_collect_outdated() {
  emulate -L zsh
  setopt local_options

  local manager provider_fn result line pkg_name pkg_latest threshold
  local -a timeout_cmd outdated_rows prefetch_args
  timeout_cmd=( ${(z)"$(_zpun_timeout_prefix)"} )

  for manager in brew npm uv gem; do
    _zpun_manager_enabled "$manager" || continue
    provider_fn="_zpun_provider_${manager}"
    (( $+functions[$provider_fn] )) || continue

    _zpun_ui_status "Checking ${_ZPUN_MANAGER_LABELS[$manager]:-$manager}…"

    if result=$( "${timeout_cmd[@]}" zsh -c "source '$_ZPUN_DIR/lib/config.zsh'; _zpun_config_load; source '$_ZPUN_DIR/lib/providers/${manager}.zsh'; $provider_fn" 2>>"$(_zpun_debug_log_path)" ); then
      outdated_rows=()
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        outdated_rows+=( "$line" )
      done <<< "$result"

      (( ${#outdated_rows} )) || continue

      # Prefetch publish-date lookups in one batch when min-age is on for
      # this manager — the per-row _zpun_min_age_satisfied calls below then
      # see cache hits instead of going to brew/npm/curl one by one.
      threshold=$(_zpun_min_age_threshold "$manager")
      if (( threshold > 0 )); then
        prefetch_args=()
        for line in "${outdated_rows[@]}"; do
          prefetch_args+=( "${line%%$'\t'*}" "${line##*$'\t'}" )
        done
        _zpun_min_age_prefetch "$manager" "${prefetch_args[@]}"
      fi

      for line in "${outdated_rows[@]}"; do
        pkg_name=${line%%$'\t'*}
        pkg_latest=${line##*$'\t'}
        _zpun_min_age_satisfied "$manager" "$pkg_name" "$pkg_latest" || continue
        print -r -- "${manager}"$'\t'"${line}"
      done
    else
      _zpun_debug_log "provider $manager exited non-zero"
    fi
  done

  _zpun_ui_status_clear
}

# _zpun_timeout_prefix — print a command prefix like "timeout 10" if a timeout
# utility exists on PATH; otherwise print nothing. Consumers use `${(z)…}` to
# split safely into an argv array.
_zpun_timeout_prefix() {
  emulate -L zsh
  setopt local_options

  local secs=${ZSH_PKG_UPDATE_NAG_PROVIDER_TIMEOUT:-10}
  if (( $+commands[timeout] )); then
    print -r -- "timeout $secs"
  elif (( $+commands[gtimeout] )); then
    print -r -- "gtimeout $secs"
  fi
}

# _zpun_run_upgrade — execute a single upgrade command array-style.
# Arguments: <manager> <package>
_zpun_run_upgrade() {
  emulate -L zsh
  setopt local_options

  local manager=$1 pkg=$2
  local -a cmd
  case $manager in
    brew) cmd=(brew upgrade "$pkg") ;;
    npm)  cmd=(npm install -g "${pkg}@latest") ;;
    uv)   cmd=(uv tool upgrade "$pkg") ;;
    gem)  cmd=(gem update "$pkg") ;;
    *)    _zpun_ui_error "unknown manager: $manager"; return 2 ;;
  esac

  _zpun_ui_info "→ ${cmd[*]}"
  "${cmd[@]}"
}

# _zpun_main — orchestrate guard → rate-limit → collect → prompt → stamp.
_zpun_main() {
  emulate -L zsh
  setopt local_options

  _zpun_should_run || return 0
  _zpun_config_load

  _zpun_rate_limit_is_due || return 0

  _zpun_rate_limit_acquire_lock || return 0
  # Safety net: if the user Ctrl-C's mid-scan or the shell exits during the
  # check, clear any lingering status line, release the lock, and refresh the
  # stamp so we don't re-nag.
  trap '_zpun_ui_status_clear; _zpun_rate_limit_release_lock; _zpun_rate_limit_stamp; trap - INT TERM EXIT' INT TERM EXIT

  local -a outdated
  outdated=( ${(f)"$(_zpun_collect_outdated)"} )

  if (( ${#outdated} )); then
    _zpun_ui_prompt_and_upgrade "${outdated[@]}"
  fi

  _zpun_rate_limit_stamp
  _zpun_rate_limit_release_lock
  trap - INT TERM EXIT
}

# _zpun_precmd_nag — one-shot precmd hook registered by _zpun_main_deferred.
#
# Pending file format (written atomically by the background subshell):
#   "ok"          — scan completed, no updates available
#   "err"         — scan failed or was interrupted
#   <TSV lines>   — scan completed, updates available (manager\tname\tcurrent\tlatest)
#
# The hook prints a one-shot "checking…" notice at the first prompt while the
# scan is still running, then waits silently. When the pending file appears it
# acts on its content and removes itself.
_zpun_precmd_nag() {
  emulate -L zsh
  setopt local_options

  local pending=$(_zpun_pending_path)

  if [[ ! -e $pending ]]; then
    # Scan still running. Print a one-shot notice at the very first prompt so
    # the user knows something is happening, then wait silently.
    if (( ${+_ZPUN_PRECMD_ANNOUNCED} )); then
      unset _ZPUN_PRECMD_ANNOUNCED
      _zpun_ui_info "(checking for package updates in the background…)"
    fi
    return 0
  fi

  precmd_functions=( ${precmd_functions:#_zpun_precmd_nag} )
  unset _ZPUN_PRECMD_ANNOUNCED

  local content
  content=$(<"$pending")
  rm -f "$pending"

  case ${content%%$'\n'*} in
    ok)
      _zpun_ui_info "All packages up to date."
      ;;
    err)
      _zpun_debug_log "background scan failed or was interrupted"
      ;;
    *)
      local -a outdated
      outdated=( ${(f)content} )
      outdated=( ${outdated:#} )
      (( ${#outdated} )) && _zpun_ui_prompt_and_upgrade "${outdated[@]}"
      ;;
  esac
}

# _zpun_main_deferred — background variant of _zpun_main. Launches the scan in
# a background subshell (so plugin load does not block shell startup) and
# registers _zpun_precmd_nag to display results before the first prompt.
# Activated by setting ZSH_PKG_UPDATE_NAG_BACKGROUND=1.
_zpun_main_deferred() {
  emulate -L zsh
  setopt local_options

  _zpun_should_run || return 0
  _zpun_config_load

  # If a previous shell's background scan left results waiting, register the
  # hook to display them even if the rate limit isn't due for a new scan.
  local pending=$(_zpun_pending_path)
  if [[ -e $pending ]]; then
    precmd_functions+=(_zpun_precmd_nag)
    return 0
  fi

  _zpun_rate_limit_is_due || return 0
  _zpun_rate_limit_acquire_lock || return 0

  # Stderr is redirected to the debug log; _zpun_ui_status already guards on
  # [[ -t 2 ]], so progress messages go silent without any code changes there.
  (
    local _pending=$(_zpun_pending_path)
    local _tmp="${_pending}.tmp"
    local _state_dir=$(_zpun_state_dir)
    [[ -d $_state_dir ]] || mkdir -p "$_state_dir" 2>/dev/null

    # Invariant: the pending file MUST exist when this subshell exits, so
    # _zpun_precmd_nag has a reliable "done" signal. The trap enforces that on
    # every exit path — signal, mid-scan crash, or silent failure of the mv
    # below (e.g. read-only XDG_STATE_HOME, ENOSPC). The `[[ -e ]]` guard makes
    # it a no-op when the happy path already wrote pending; that's why we
    # don't clear the trap before exit.
    trap '_zpun_rate_limit_release_lock; [[ -e "$_pending" ]] || print -r -- "err" > "$_pending"; rm -f "$_tmp"' INT TERM EXIT

    local results
    results=$(_zpun_collect_outdated)
    if [[ -n $results ]]; then
      printf '%s' "$results" > "$_tmp"
    else
      print -r -- "ok" > "$_tmp"
    fi
    mv "$_tmp" "$_pending"

    _zpun_rate_limit_stamp
    _zpun_rate_limit_release_lock
  ) 2>>"$(_zpun_debug_log_path)" &!

  typeset -g _ZPUN_PRECMD_ANNOUNCED=1
  precmd_functions+=(_zpun_precmd_nag)
}

# Public subcommand: `zsh-pkg-update-nag --check-env` for diagnostics; `--now` to force.
zsh-pkg-update-nag() {
  emulate -L zsh
  setopt local_options

  case ${1:-} in
    --check-env|check-env)
      _zpun_config_load
      _zpun_ui_print_env
      ;;
    --now|now|--force|force)
      _zpun_config_load
      ZSH_PKG_UPDATE_NAG_FORCE=1 _zpun_main
      ;;
    --help|-h|help|'')
      print -r -- "Usage: zsh-pkg-update-nag [--now | --check-env | --help]"
      print -r -- "  --now         Run the update check immediately, ignoring rate-limit."
      print -r -- "  --check-env   Print detected managers, config, and next-check time."
      print -r -- "  --help        Show this help."
      ;;
    *)
      print -u2 -r -- "zsh-pkg-update-nag: unknown option '$1' (try --help)"
      return 2
      ;;
  esac
}

# Source-time entry: run the main flow once per shell startup. Tests that want
# to source the plugin without triggering the auto-run set ZSH_PKG_UPDATE_NAG_NO_AUTORUN=1.
# Set ZSH_PKG_UPDATE_NAG_BACKGROUND=1 to scan in the background and display results
# before the first prompt instead of blocking shell startup.
if [[ ${ZSH_PKG_UPDATE_NAG_NO_AUTORUN:-0} != 1 ]]; then
  if [[ ${ZSH_PKG_UPDATE_NAG_BACKGROUND:-0} == 1 ]]; then
    _zpun_main_deferred
  else
    _zpun_main
  fi
fi
