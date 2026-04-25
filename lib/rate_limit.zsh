# Stampfile + atomic lock to keep the nag rate-limited across shells.

_zpun_rate_limit_stamp_path() {
  emulate -L zsh
  setopt local_options
  print -r -- "$(_zpun_state_dir)/last_check"
}

_zpun_rate_limit_lock_path() {
  emulate -L zsh
  setopt local_options
  print -r -- "$(_zpun_state_dir)/lock.d"
}

# Returns 0 if enough time has passed since the last check OR force is set OR
# there's no stampfile yet (fresh install — check immediately, don't defer).
_zpun_rate_limit_is_due() {
  emulate -L zsh
  setopt local_options

  [[ ${ZSH_PKG_UPDATE_NAG_FORCE:-0} == 1 ]] && return 0

  local stamp=$(_zpun_rate_limit_stamp_path)
  [[ -e $stamp ]] || return 0

  local interval_seconds=$(( zsh_pkg_update_nag_interval_hours * 3600 ))
  local now=$(date +%s)
  local mtime=$(_zpun_mtime "$stamp")
  (( now - mtime >= interval_seconds ))
}

# Refresh the stampfile's mtime to now. Errors are swallowed.
_zpun_rate_limit_stamp() {
  emulate -L zsh
  setopt local_options

  local stamp=$(_zpun_rate_limit_stamp_path)
  local dir=${stamp:h}
  [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null
  : > "$stamp" 2>/dev/null
}

# Atomic lock using mkdir (portable, unlike flock(1) on macOS).
_zpun_rate_limit_acquire_lock() {
  emulate -L zsh
  setopt local_options

  local lock=$(_zpun_rate_limit_lock_path)
  local dir=${lock:h}
  [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null

  # If a stale lock exists (older than 5 minutes), clean it up.
  if [[ -d $lock ]]; then
    local lock_mtime=$(_zpun_mtime "$lock")
    local now=$(date +%s)
    if (( now - lock_mtime > 300 )); then
      rmdir "$lock" 2>/dev/null
    fi
  fi

  mkdir "$lock" 2>/dev/null
}

_zpun_rate_limit_release_lock() {
  emulate -L zsh
  setopt local_options
  rmdir "$(_zpun_rate_limit_lock_path)" 2>/dev/null
}

# _zpun_mtime <path> — portable mtime-in-seconds lookup. BSD stat (macOS) uses
# `-f %m`; GNU stat (Linux) uses `-c %Y`. We validate the result is purely
# numeric before accepting it: GNU stat treats `-f` as "filesystem info mode"
# and emits multi-line garbage on stdout, which would otherwise be returned as
# a bogus mtime. Fall back to perl.
#
# NB: do NOT name the local variable `path`. zsh ties scalar `$path` to the
# `$PATH` array, so shadowing it inside a function breaks every subsequent
# external command lookup in that function body.
_zpun_mtime() {
  emulate -L zsh
  setopt local_options

  local target=$1
  local result

  if result=$(stat -f %m "$target" 2>/dev/null) && [[ $result == <-> ]]; then
    print -r -- "$result"
    return
  fi
  if result=$(stat -c %Y "$target" 2>/dev/null) && [[ $result == <-> ]]; then
    print -r -- "$result"
    return
  fi
  if (( $+commands[perl] )); then
    perl -e 'print ((stat shift)[9])' "$target" 2>/dev/null && return
  fi
  print -r -- 0
}
