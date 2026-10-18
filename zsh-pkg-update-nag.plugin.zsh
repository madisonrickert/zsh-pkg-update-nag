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
# lib/min_age.zsh is sourced lazily by _zpun_collect_outdated (and by
# _zpun_ui_print_env for accurate diagnostics) only when the feature is
# enabled — it carries ~0.7 ms of source-time cost on a typical shell
# and the feature is off by default.
# Provider files (lib/providers/*.zsh) are intentionally NOT sourced here
# either. _zpun_collect_outdated re-sources the relevant one inside its
# per-manager timeout subshell, which is the only context that calls them.

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

# _zpun_min_age_active — 0 if min-age gating is enabled for at least one
# manager, 1 otherwise. Mirrors the inheritance rule of
# _zpun_min_age_threshold (per-manager override wins over the global,
# even when the override is 0) without needing lib/min_age.zsh loaded —
# the answer is what tells us whether sourcing it is worthwhile.
_zpun_min_age_active() {
  emulate -L zsh
  setopt local_options

  local m override_var t
  for m in brew npm pnpm uv gem cargo; do
    override_var="zsh_pkg_update_nag_min_age_${m}"
    # ${(P)+name}: "is the variable NAMED by override_var set" (indirect).
    # shuck: disable=C006
    if (( ${(P)+override_var} )); then
      t=${(P)override_var:-0}
    else
      t=${zsh_pkg_update_nag_min_age:-0}
    fi
    (( t > 0 )) && return 0
  done
  return 1
}

# _zpun_collect_outdated — runs each enabled provider with a timeout and
# aggregates their TSV output into an array. Lines: manager\tname\tcurrent\tlatest.
_zpun_collect_outdated() {
  emulate -L zsh
  setopt local_options

  local manager provider_fn result line pkg_name pkg_latest threshold
  # Declared here, not inside the per-manager loop below: re-running `local`
  # on an already-set name inside a loop prints "name=value" to stdout (the
  # zsh pitfall noted in CLAUDE.md), which would land in the collector's
  # captured output as bogus package rows.
  local pkg_current pkg_rest target rc
  local -a timeout_cmd outdated_rows prefetch_args
  timeout_cmd=( ${(z)"$(_zpun_timeout_prefix)"} )

  # Source min-age helpers on demand. When the feature is fully off (the
  # default), we skip the whole file and the per-row gating below.
  #
  # Each provider's per-manager publish-date lookup
  # (_zpun_min_age_lookup_<m>) and any prefetch hook
  # (_zpun_min_age_prefetch_<m>) live in lib/providers/<m>.zsh, alongside
  # _zpun_provider_<m>. The provider files are also sourced inside the
  # per-manager timeout subshell below for the scan; that's a separate
  # process so the lookups defined there aren't visible to the parent.
  # When min-age is active we additionally source each enabled provider
  # in the parent so _zpun_min_age_satisfied / the prefetch dispatcher
  # can resolve the per-manager hooks. Sub-ms each on a 1µs/line basis;
  # gated on the same _zpun_min_age_active check so off-by-default users
  # pay nothing.
  local _have_min_age=0
  if _zpun_min_age_active; then
    source "$_ZPUN_DIR/lib/min_age.zsh"
    _have_min_age=1
    for manager in brew npm pnpm uv gem cargo; do
      _zpun_manager_enabled "$manager" || continue
      source "$_ZPUN_DIR/lib/providers/${manager}.zsh"
    done
  fi

  for manager in brew npm pnpm uv gem cargo; do
    _zpun_manager_enabled "$manager" || continue
    provider_fn="_zpun_provider_${manager}"

    _zpun_progress_emit "Checking ${_ZPUN_MANAGER_LABELS[$manager]:-$manager}…"

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
      if (( _have_min_age )); then
        threshold=$(_zpun_min_age_threshold "$manager")
        if (( threshold > 0 )); then
          prefetch_args=()
          for line in "${outdated_rows[@]}"; do
            prefetch_args+=( "${line%%$'\t'*}" "${line##*$'\t'}" )
          done
          _zpun_min_age_prefetch "$manager" "${prefetch_args[@]}"
        fi
      fi

      for line in "${outdated_rows[@]}"; do
        pkg_name=${line%%$'\t'*}
        pkg_latest=${line##*$'\t'}
        pkg_rest=${line#*$'\t'}
        pkg_current=${pkg_rest%%$'\t'*}
        if (( _have_min_age )); then
          if (( $+functions[_zpun_min_age_versions_${manager}] )); then
            # Resolve mode: rewrite latest to the newest old-enough version,
            # hide when nothing qualifies, fail-open on lookup failure.
            target=$(_zpun_min_age_resolve_target "$manager" "$pkg_name" "$pkg_current" "$pkg_latest")
            rc=$?
            case $rc in
              0) line="${pkg_name}"$'\t'"${pkg_current}"$'\t'"${target}" ;;
              1) continue ;;
              *) : ;;   # fail-open: leave the row as the provider reported it
            esac
          else
            # Gate mode (brew): hide when the latest is positively too new.
            _zpun_min_age_satisfied "$manager" "$pkg_name" "$pkg_latest" || continue
          fi
        fi
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
# Arguments: <manager> <package> [<version>]
# When version is provided, npm/pnpm/uv/gem pin to that exact version.
# When omitted, those fall back to latest-tracking commands.
# brew always uses `brew upgrade <pkg>` (version arg is ignored), adding
# `--yes` to skip Homebrew's own confirmation only when brew_ask is off.
# cargo upgrades via cargo-update and forwards the configured min-age to its
# native `--cooldown` (the version arg is ignored) so the upgrade installs the
# same cooldown-resolved version the scan showed, not the true latest.
_zpun_run_upgrade() {
  emulate -L zsh
  setopt local_options

  local manager=$1 pkg=$2 version=${3:-}
  local -a cmd
  case $manager in
    brew)
      # Homebrew defaults to ask-mode: `brew upgrade` prints the plan and
      # prompts whenever it pulls in dependencies, dependents, or packages
      # beyond the named one. We run brew once per package, so that re-prompts
      # once per such package after the nag prompt was already answered.
      # Opting out with brew_ask=off passes `--yes` (alias `--no-ask`) to skip
      # it; the default leaves brew alone, because those prompts are the only
      # place dependent upgrades surface. Resolved inline (not via config load)
      # so the function stays correct when called directly, as the cargo
      # min-age block below also does.
      if [[ ${zsh_pkg_update_nag_brew_ask:-on} == off ]]; then
        cmd=(brew upgrade --yes "$pkg")
      else
        cmd=(brew upgrade "$pkg")
      fi
      ;;
    npm)  cmd=(npm install -g "${pkg}@${version:-latest}") ;;
    pnpm) cmd=(pnpm add -g "${pkg}@${version:-latest}") ;;
    uv)   if [[ -n $version ]]; then cmd=(uv tool install --force "${pkg}==${version}")
          else cmd=(uv tool upgrade "$pkg"); fi ;;
    gem)  if [[ -n $version ]]; then cmd=(gem install "$pkg" -v "$version")
          else cmd=(gem update "$pkg"); fi ;;
    cargo)
      # Resolve the cargo min-age threshold inline (per-manager override wins
      # over the global, even at 0), mirroring lib/providers/cargo.zsh. When
      # set, forward it to cargo-update's --cooldown so accepting the upgrade
      # cannot install a version newer than the cooldown the scan applied.
      local cargo_threshold
      if (( ${+zsh_pkg_update_nag_min_age_cargo} )); then
        cargo_threshold=${zsh_pkg_update_nag_min_age_cargo:-0}
      else
        cargo_threshold=${zsh_pkg_update_nag_min_age:-0}
      fi
      if (( cargo_threshold > 0 )); then
        cmd=(cargo install-update "$pkg" --cooldown "${cargo_threshold}d")
      else
        cmd=(cargo install-update "$pkg")
      fi
      ;;
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
  # _ZPUN_INTERRUPTED is the trap → upgrade-loop signal: a Ctrl-C that hits
  # mid-upgrade fires the trap (which cleans up state and disarms itself),
  # but control returns to the next loop iteration unless we explicitly
  # check. The upgrade loops in lib/ui.zsh test this flag at the top of each
  # iteration and bail out instead of charging ahead with the next package.
  typeset -g _ZPUN_INTERRUPTED=0
  # Safety net: if the user Ctrl-C's mid-scan or the shell exits during the
  # check, end the capture (replays any buffered keystrokes and schedules the
  # tty restore for the next prompt), clear the status line, release the
  # lock, and refresh the stamp so we don't re-nag.
  trap '_ZPUN_INTERRUPTED=1; _zpun_input_capture_end; _zpun_ui_status_clear; _zpun_rate_limit_release_lock; _zpun_rate_limit_stamp; trap - INT TERM EXIT' INT TERM EXIT

  # Capture spans the scan, so keys typed mid-scan neither echo over the
  # spinner nor get taken as the y/n/s answer. The long hold is safe: the
  # tty is only restored at the next prompt, and only verbatim if nothing
  # else changed it meanwhile (_zpun_tty_restore_precmd / _zpun_tty_undo).
  _zpun_input_capture_begin

  local -a outdated
  outdated=( ${(f)"$(_zpun_collect_outdated)"} )

  if (( ${#outdated} )); then
    # _zpun_ui_present owns the teardown: it ends the capture after its mode
    # handler returns, replaying type-ahead onto the next prompt.
    _zpun_ui_present "${outdated[@]}"
  else
    _zpun_input_capture_end
  fi

  _zpun_rate_limit_stamp
  _zpun_rate_limit_release_lock
  trap - INT TERM EXIT
  unset _ZPUN_INTERRUPTED
}

# _zpun_p10k_instant_prompt_active — 0 if powerlevel10k instant-prompt is
# enabled in any non-"off" mode (quiet | verbose). Output during the
# instant-prompt phase corrupts p10k's pre-prompt buffer (the "Console
# output during zsh initialization detected" warning), so callers must
# either suppress that output (cosmetic notices) or defer it past p10k's
# first precmd, which finalizes the buffer.
_zpun_p10k_instant_prompt_active() {
  emulate -L zsh
  setopt local_options
  case ${POWERLEVEL9K_INSTANT_PROMPT:-} in
    ''|off) return 1 ;;
    *)      return 0 ;;
  esac
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
#
# _ZPUN_PRECMD_ANNOUNCED is set by _zpun_main_deferred when this hook is
# registered, and we capture-and-clear it here as a "first call" sentinel.
# It drives the one-shot "(checking…)" notice, leftover delivery, and the
# p10k deferral below, all of which matter only on the first invocation.
#
# session_start is narrower: "the user has not run a command yet", the one
# moment a blocking prompt is acceptable. Any later arrival may come the
# instant the user returns from a foreground app, when a single-key read
# would steal the leading ESC byte of their key sequences, so it gets a
# non-blocking notice instead.
_zpun_precmd_nag() {
  emulate -L zsh
  setopt local_options

  local pending=$(_zpun_pending_path)

  # Defer one precmd under p10k instant-prompt: the first precmd may run
  # BEFORE p10k finalizes its pre-prompt buffer (depends on hook registration
  # order; our hook can be registered before p10k's, since users commonly
  # source ~/.p10k.zsh after loading plugins). By the second call p10k has
  # finalized regardless of order. The first-call sentinel survives the
  # deferral so leftovers and our own results are still delivered on the
  # second call. That call follows the user's first command line, though,
  # so it only counts as session start if that line added no history event
  # (a bare Enter); _ZPUN_P10K_DEFERRED records $HISTCMD to tell.
  if (( ${+_ZPUN_PRECMD_ANNOUNCED} && ! ${+_ZPUN_P10K_DEFERRED} )) \
      && _zpun_p10k_instant_prompt_active; then
    typeset -g _ZPUN_P10K_DEFERRED=$HISTCMD
    return 0
  fi

  local first_call=0 session_start=0
  if (( ${+_ZPUN_PRECMD_ANNOUNCED} )); then
    first_call=1
    if (( ! ${+_ZPUN_P10K_DEFERRED} )) || [[ $_ZPUN_P10K_DEFERRED == "$HISTCMD" ]]; then
      session_start=1
    fi
    unset _ZPUN_PRECMD_ANNOUNCED _ZPUN_P10K_DEFERRED
  fi

  # Leftover pending files from shells that died before consuming their
  # scan: deliver as a non-blocking notice on the first call. Superseded
  # (dropped quietly) when this shell's own results already landed before
  # the prompt — a fresh present beats a dead shell's rows; hour-old
  # leftovers were already deleted by _zpun_pending_leftovers.
  if (( first_call )) && (( ${+_ZPUN_LEFTOVER_PENDING} )); then
    local leftover lcontent lfirst
    local -a lrows
    for leftover in "${_ZPUN_LEFTOVER_PENDING[@]}"; do
      lcontent=$(<"$leftover") 2>/dev/null
      rm -f "$leftover" 2>/dev/null
      lfirst=${lcontent%%$'\n'*}
      if [[ $lfirst == ok || -z $lcontent ]]; then
        continue
      fi
      if [[ $lfirst == err ]]; then
        _zpun_debug_log "leftover scan from a dead shell failed"
        continue
      fi
      lrows=( ${(f)lcontent} )
      lrows=( ${lrows:#} )
      [[ -e $pending ]] && continue
      (( ${#lrows} )) && _zpun_ui_notice "${lrows[@]}"
    done
  fi
  unset _ZPUN_LEFTOVER_PENDING

  if [[ ! -e $pending ]]; then
    if (( ! ${+_ZPUN_SCAN_IN_FLIGHT} )); then
      # Registered only to deliver leftovers; nothing more will arrive, so
      # stop paying for this hook on every prompt.
      precmd_functions=( ${precmd_functions:#_zpun_precmd_nag} )
      return 0
    fi
    # Scan still running. Print a one-shot notice on the first prompt so the
    # user knows something is happening, then wait silently. Suppress under
    # p10k instant-prompt — by the time we get here the user has already
    # seen a prompt, so the notice would be stale. Cosmetic loss only.
    if (( first_call )) && ! _zpun_p10k_instant_prompt_active; then
      _zpun_ui_info "(checking for package updates in the background…)"
    fi
    return 0
  fi

  precmd_functions=( ${precmd_functions:#_zpun_precmd_nag} )
  unset _ZPUN_SCAN_IN_FLIGHT

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
      (( ${#outdated} )) || return 0
      if (( session_start )); then
        # Results were waiting before the user ran anything: the one moment
        # a blocking prompt is by design.
        _zpun_ui_present "${outdated[@]}"
      else
        # Mid-session arrival: never block. Render the summary and point at
        # --now; stdin untouched.
        _zpun_ui_notice "${outdated[@]}"
      fi
      ;;
  esac
}

# _zpun_main_deferred — background variant of _zpun_main. Launches the scan in
# a background subshell (so plugin load does not block shell startup) and
# registers _zpun_precmd_nag to display results before the first prompt.
# This is the default auto-run path; opt into the synchronous _zpun_main by
# setting ZSH_PKG_UPDATE_NAG_BACKGROUND=0.
_zpun_main_deferred() {
  emulate -L zsh
  setopt local_options

  _zpun_should_run || return 0
  _zpun_config_load
  # Pending is per-shell (pending.$$): scan results belong to the shell that
  # spawned them, so no other window's precmd can consume them there — the
  # old shared "pending_updates" file is what let a presentation (and its
  # blocking prompt) pop in a window the user wasn't watching. Files of other
  # LIVE shells are theirs to consume; files of dead shells are leftovers,
  # adopted for a non-blocking first-prompt notice (or deleted if hour-old).
  #
  # This shell has only just started, so a pending.$$ already on disk was
  # written by a dead shell whose PID we reused (or by the shell this one
  # `exec`ed over). Left alone, the first precmd would present it as our
  # own fresh scan, and our real result would never be consumed.
  local pending=$(_zpun_pending_path)
  [[ -e $pending ]] && rm -f "$pending" 2>/dev/null
  local -a reply
  _zpun_pending_leftovers "$pending"
  typeset -ga _ZPUN_LEFTOVER_PENDING
  _ZPUN_LEFTOVER_PENDING=( "${reply[@]}" )

  if ! _zpun_rate_limit_is_due || ! _zpun_rate_limit_acquire_lock; then
    if (( ${#_ZPUN_LEFTOVER_PENDING} )); then
      typeset -g _ZPUN_PRECMD_ANNOUNCED=1
      precmd_functions=( ${precmd_functions:#_zpun_precmd_nag} _zpun_precmd_nag )
    fi
    return 0
  fi

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
    #
    # zsh signal traps resume execution after they run, so INT/TERM must
    # `exit` explicitly; that in turn fires the EXIT trap. HUP is ignored:
    # if the terminal closes mid-scan, the scan finishes, and its result
    # becomes a leftover the next shell adopts.
    trap '_zpun_rate_limit_release_lock; [[ -e "$_pending" ]] || print -r -- "err" > "$_pending"; rm -f "$_tmp"' EXIT
    trap 'exit 1' INT TERM
    trap '' HUP

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
  typeset -g _ZPUN_SCAN_IN_FLIGHT=1
  precmd_functions=( ${precmd_functions:#_zpun_precmd_nag} _zpun_precmd_nag )
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
      # On-demand invocation is an explicit request to act: always take the
      # interactive prompt path even under `reminder` mode. Signal that with
      # ZSH_PKG_UPDATE_NAG_FORCE rather than a mode override (which the config
      # reload in _zpun_main would clobber); see _zpun_ui_present for why the
      # dispatch keys off FORCE.
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

# _zpun_dispatch — pick foreground vs background based on env. Background is
# the default; set ZSH_PKG_UPDATE_NAG_BACKGROUND=0 to opt into the synchronous
# path, which is mainly useful when actively debugging the plugin.
_zpun_dispatch() {
  emulate -L zsh
  setopt local_options
  if [[ ${ZSH_PKG_UPDATE_NAG_BACKGROUND:-1} == 0 ]]; then
    _zpun_main
  else
    _zpun_main_deferred
  fi
}

# Source-time entry: run the dispatch once per shell startup. Tests that want
# to source the plugin without triggering it set ZSH_PKG_UPDATE_NAG_NO_AUTORUN=1.
if [[ ${ZSH_PKG_UPDATE_NAG_NO_AUTORUN:-0} != 1 ]]; then
  _zpun_dispatch
fi
