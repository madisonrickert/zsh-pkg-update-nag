# zsh-pkg-update-nag — on-demand, rate-limited global-package update prompts.

# Resolve this file's directory whether we were sourced directly or through OMZ.
typeset -g _ZPUN_DIR="${${(%):-%x}:A:h}"

source "$_ZPUN_DIR/lib/config.zsh"
source "$_ZPUN_DIR/lib/rate_limit.zsh"
source "$_ZPUN_DIR/lib/ui.zsh"
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

  local manager provider_fn result line
  local -a timeout_cmd
  timeout_cmd=( ${(z)"$(_zpun_timeout_prefix)"} )

  for manager in brew npm uv gem; do
    _zpun_manager_enabled "$manager" || continue
    provider_fn="_zpun_provider_${manager}"
    (( $+functions[$provider_fn] )) || continue

    if result=$( "${timeout_cmd[@]}" zsh -c "source '$_ZPUN_DIR/lib/config.zsh'; _zpun_config_load; source '$_ZPUN_DIR/lib/providers/${manager}.zsh'; $provider_fn" 2>>"$(_zpun_debug_log_path)" ); then
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        print -r -- "${manager}"$'\t'"${line}"
      done <<< "$result"
    else
      _zpun_debug_log "provider $manager exited non-zero"
    fi
  done
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

  _zpun_rate_limit_init_if_missing && return 0
  _zpun_rate_limit_is_due || return 0

  _zpun_rate_limit_acquire_lock || return 0
  # Safety net: if the user Ctrl-C's mid-prompt or the shell exits during the
  # check, still release the lock and refresh the stamp so we don't re-nag.
  trap '_zpun_rate_limit_release_lock; _zpun_rate_limit_stamp; trap - INT TERM EXIT' INT TERM EXIT

  local -a outdated
  outdated=( ${(f)"$(_zpun_collect_outdated)"} )

  if (( ${#outdated} )); then
    _zpun_ui_prompt_and_upgrade "${outdated[@]}"
  fi

  _zpun_rate_limit_stamp
  _zpun_rate_limit_release_lock
  trap - INT TERM EXIT
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
[[ ${ZSH_PKG_UPDATE_NAG_NO_AUTORUN:-0} == 1 ]] || _zpun_main
