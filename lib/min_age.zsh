# Optional minimum-release-age gating for outdated packages.
#
# When zsh_pkg_update_nag_min_age > 0, _zpun_min_age_satisfied returns 1
# for any update whose latest version was published less than N days ago, and
# _zpun_collect_outdated drops the row before it reaches the user.
#
# Failure is always fail-open: if we can't determine an age (network down,
# missing curl/jq, third-party brew tap, malformed API response), we surface
# the update anyway and write a debug-log line. Hiding updates indefinitely
# because of a degraded environment would be strictly worse than current
# behavior.
#
# Publish dates are immutable, so a persistent TSV cache at
# $XDG_STATE_HOME/zsh-pkg-update-nag/age_cache.tsv eliminates repeat lookups.
#
# Per-manager publish-date lookups (`_zpun_min_age_lookup_<m>`) and any
# prefetch hooks (`_zpun_min_age_prefetch_<m>`) live in the corresponding
# `lib/providers/<m>.zsh`. This file keeps only the shared core: threshold
# inheritance, the satisfied/prefetch dispatchers, the ISO-8601 parser, and
# the cache.

# _zpun_min_age_threshold <manager> — print the configured threshold (in days)
# for a given manager. Per-manager overrides shadow the global setting:
#   zsh_pkg_update_nag_min_age_<manager>   if set (even to 0), wins
#   zsh_pkg_update_nag_min_age        otherwise
# Default 0 (off).
_zpun_min_age_threshold() {
  emulate -L zsh
  setopt local_options

  local manager=$1
  local override_var="zsh_pkg_update_nag_min_age_${manager}"
  # ${(P)override_var-fallback}: if the named variable is unset, use fallback.
  # An explicit empty/0 value wins over the global, by design.
  if (( ${(P)+override_var} )); then
    print -r -- "${(P)override_var:-0}"
  else
    print -r -- "${zsh_pkg_update_nag_min_age:-0}"
  fi
}

# _zpun_min_age_satisfied <manager> <name> <version> — 0 if old enough OR if
# we couldn't determine; 1 only when we positively know the update is too new.
_zpun_min_age_satisfied() {
  emulate -L zsh
  setopt local_options

  local manager=$1 name=$2 version=$3
  local threshold
  threshold=$(_zpun_min_age_threshold "$manager")

  (( threshold > 0 )) || return 0

  # The brew provider degrades to "?" for current/latest when jq is missing.
  # Without a real version string we can't ask any registry for an upload time.
  [[ -n $version && $version != '?' ]] || {
    _zpun_debug_log "min_age: ${manager}/${name} has no usable version, fail-open"
    return 0
  }

  local epoch
  epoch=$(_zpun_min_age_cache_get "$manager" "$name" "$version")
  if [[ -z $epoch ]]; then
    local lookup_fn="_zpun_min_age_lookup_${manager}"
    if (( ! $+functions[$lookup_fn] )); then
      _zpun_debug_log "min_age: no lookup for manager ${manager}, fail-open"
      return 0
    fi
    epoch=$( $lookup_fn "$name" "$version" 2>/dev/null )
    if [[ -z $epoch || $epoch != <-> ]]; then
      _zpun_debug_log "min_age: lookup failed for ${manager}/${name}@${version}, fail-open"
      return 0
    fi
    _zpun_min_age_cache_put "$manager" "$name" "$version" "$epoch"
  fi

  local now=$(date +%s)
  local age_seconds=$(( now - epoch ))
  local threshold_seconds=$(( threshold * 86400 ))
  (( age_seconds >= threshold_seconds ))
}

# _zpun_min_age_prefetch <manager> <name1> <version1> [<name2> <version2>...]
# Optional batch hook that a manager can implement to populate the cache for
# many (name, version) pairs in one go. The collector calls this once per
# manager before the per-row gating loop, so cache hits dominate. Managers
# without a hook are a no-op.
_zpun_min_age_prefetch() {
  emulate -L zsh
  setopt local_options

  local manager=$1; shift
  local hook="_zpun_min_age_prefetch_${manager}"
  (( $+functions[$hook] )) || return 0
  $hook "$@"
}

# _zpun_min_age_parse_iso8601 <iso_timestamp> — print the timestamp's epoch
# seconds in UTC. Accepts the variants we see in practice:
#   2024-01-15T12:34:56Z
#   2024-01-15T12:34:56.789Z
#   2024-01-15T12:34:56+00:00
# Falls back across BSD date / GNU date / perl Time::Piece. Same shape as
# _zpun_mtime in lib/rate_limit.zsh.
_zpun_min_age_parse_iso8601() {
  emulate -L zsh
  setopt local_options

  local iso=$1
  iso=${iso%%.*}                                 # drop fractional seconds
  iso=${iso%Z}                                   # drop trailing Z
  iso=${iso%%[+-][0-9][0-9]:[0-9][0-9]}          # drop +HH:MM offset
  iso=${iso%%[+-][0-9][0-9][0-9][0-9]}           # drop +HHMM offset
  [[ -n $iso ]] || return 1

  local epoch
  if epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$iso" +%s 2>/dev/null) && [[ -n $epoch ]]; then
    print -r -- "$epoch"; return 0
  fi
  if epoch=$(TZ=UTC date -d "$iso" +%s 2>/dev/null) && [[ -n $epoch ]]; then
    print -r -- "$epoch"; return 0
  fi
  if (( $+commands[perl] )); then
    epoch=$(perl -MTime::Piece -e 'print Time::Piece->strptime(shift, "%Y-%m-%dT%H:%M:%S")->epoch' "$iso" 2>/dev/null)
    [[ -n $epoch ]] && { print -r -- "$epoch"; return 0 }
  fi
  return 1
}

# _zpun_min_age_cache_get <manager> <name> <version> — print epoch on hit;
# return 1 on miss. Walks the file linearly; with the 500-row cap that's
# instant in practice.
_zpun_min_age_cache_get() {
  emulate -L zsh
  setopt local_options

  local manager=$1 name=$2 version=$3
  local cache=$(_zpun_age_cache_path)
  [[ -f $cache ]] || return 1

  local key="${manager}"$'\t'"${name}"$'\t'"${version}"$'\t'
  local line found=""
  while IFS= read -r line; do
    [[ $line == "${key}"* ]] && found=${line##*$'\t'}
  done < "$cache"

  [[ -n $found && $found == <-> ]] || return 1
  print -r -- "$found"
}

# _zpun_min_age_cache_put <manager> <name> <version> <epoch> — append a row
# and trim if we're over the cap.
_zpun_min_age_cache_put() {
  emulate -L zsh
  setopt local_options

  local manager=$1 name=$2 version=$3 epoch=$4
  local cache=$(_zpun_age_cache_path)
  local dir=${cache:h}
  [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null
  print -r -- "${manager}"$'\t'"${name}"$'\t'"${version}"$'\t'"${epoch}" >> "$cache" 2>/dev/null
  _zpun_min_age_cache_trim
}

# _zpun_min_age_cache_trim — keep only the last 500 lines. Newest entries win
# on cache_get conflicts, so trimming oldest is the right policy.
_zpun_min_age_cache_trim() {
  emulate -L zsh
  setopt local_options

  local cache=$(_zpun_age_cache_path)
  [[ -f $cache ]] || return 0

  local count
  count=$(wc -l < "$cache" 2>/dev/null)
  count=${count// /}
  (( ${count:-0} > 500 )) || return 0

  local tmp="${cache}.tmp"
  if tail -n 500 "$cache" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$cache" 2>/dev/null
  fi
  rm -f "$tmp" 2>/dev/null
}

# _zpun_min_age_cache_count — number of entries currently in the cache. Used
# by --check-env. Prints "0" if the cache file doesn't exist.
_zpun_min_age_cache_count() {
  emulate -L zsh
  setopt local_options

  local cache=$(_zpun_age_cache_path)
  [[ -f $cache ]] || { print -r -- 0; return 0 }
  local count
  count=$(wc -l < "$cache" 2>/dev/null)
  count=${count// /}
  print -r -- "${count:-0}"
}
