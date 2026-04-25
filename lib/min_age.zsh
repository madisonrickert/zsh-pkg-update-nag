# Optional minimum-release-age gating for outdated packages.
#
# When zsh_pkg_update_nag_min_age_days > 0, _zpun_min_age_satisfied returns 1
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

# _zpun_min_age_threshold <manager> — print the configured threshold (in days)
# for a given manager. Per-manager overrides shadow the global setting:
#   zsh_pkg_update_nag_min_age_<manager>   if set (even to 0), wins
#   zsh_pkg_update_nag_min_age_days        otherwise
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
    print -r -- "${zsh_pkg_update_nag_min_age_days:-0}"
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

# _zpun_min_age_brew_github_lookup <repo> <file_path> — print epoch seconds
# of the latest commit touching <file_path> in <repo>. Used by both the
# per-row lookup and the batch prefetch.
#
# Note: `path` cannot be a local var name in this file — zsh ties scalar
# $path to the $PATH array, so shadowing it would break every external
# command call. (Same gotcha as _zpun_mtime in lib/rate_limit.zsh.)
_zpun_min_age_brew_github_lookup() {
  emulate -L zsh
  setopt local_options

  local repo=$1 file_path=$2 json commit_date
  if (( $+commands[gh] )); then
    json=$(gh api "repos/${repo}/commits?path=${file_path}&per_page=1" 2>/dev/null) || json=""
  fi
  if [[ -z $json ]]; then
    (( $+commands[curl] )) || return 1
    json=$(curl -fsSL --max-time 5 \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/${repo}/commits?path=${file_path}&per_page=1" 2>/dev/null) || return 1
  fi
  [[ -n $json ]] || return 1
  commit_date=$(print -r -- "$json" | jq -r '.[0].commit.committer.date // empty' 2>/dev/null)
  [[ -n $commit_date && $commit_date != null ]] || return 1
  _zpun_min_age_parse_iso8601 "$commit_date"
}

# _zpun_min_age_brew_repo_for <source_path> — print the GitHub repo that
# hosts a given ruby_source_path. Returns 1 if the path doesn't match a
# known tap layout.
_zpun_min_age_brew_repo_for() {
  emulate -L zsh
  setopt local_options

  case $1 in
    Formula/*) print -r -- "Homebrew/homebrew-core" ;;
    Casks/*)   print -r -- "Homebrew/homebrew-cask" ;;
    *)         return 1 ;;
  esac
}

# _zpun_min_age_lookup_brew <name> <version> — date of the latest commit that
# touched the formula (or cask) file in its tap repo. Modern Homebrew (4.0+,
# default since 2023) doesn't clone homebrew-core locally — it uses an API,
# so we go through the GitHub commits API instead of `git log`.
#
# Slow path: a single `brew info` call (~1 s of brew CLI startup) then the
# GitHub API call. The collector calls _zpun_min_age_prefetch_brew first
# whenever there's more than one outdated brew package, which batches the
# brew info call across all of them — making this per-row lookup mostly a
# fallback for cache-misses outside the prefetched set.
_zpun_min_age_lookup_brew() {
  emulate -L zsh
  setopt local_options

  local name=$1
  (( $+commands[brew] && $+commands[jq] )) || return 1

  local info source_path repo
  info=$(brew info --json=v2 "$name" 2>/dev/null) || return 1
  [[ -n $info ]] || return 1
  source_path=$(print -r -- "$info" | jq -r \
    '(.formulae[0]?.ruby_source_path // .casks[0]?.ruby_source_path) // empty' 2>/dev/null)
  [[ -n $source_path ]] || return 1

  repo=$(_zpun_min_age_brew_repo_for "$source_path") || return 1
  _zpun_min_age_brew_github_lookup "$repo" "$source_path"
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

# _zpun_min_age_prefetch_brew <name1> <version1> [<name2> <version2>...]
# Single batched `brew info --json=v2` covering every uncached name, then a
# GitHub API call per package, then a single cache write per package. ~30×
# faster than calling _zpun_min_age_lookup_brew once per package.
_zpun_min_age_prefetch_brew() {
  emulate -L zsh
  setopt local_options

  (( $+commands[brew] && $+commands[jq] )) || return 0

  local -a uncached_names uncached_versions
  local i name version
  for (( i=1; i+1 <= $#; i+=2 )); do
    name=$argv[$i]
    version=$argv[$i+1]
    [[ -n $version && $version != '?' ]] || continue
    _zpun_min_age_cache_get brew "$name" "$version" >/dev/null && continue
    uncached_names+=( "$name" )
    uncached_versions+=( "$version" )
  done

  (( ${#uncached_names} )) || return 0

  local info
  info=$(brew info --json=v2 "${uncached_names[@]}" 2>/dev/null) || return 0
  [[ -n $info ]] || return 0

  # Build the name → ruby_source_path map by streaming through jq once.
  local -A path_map
  local jq_line jq_name jq_path
  while IFS=$'\t' read -r jq_name jq_path; do
    [[ -n $jq_name && -n $jq_path ]] || continue
    path_map[$jq_name]=$jq_path
  done < <(print -r -- "$info" | jq -r '
    ((.formulae // [])[] | "\(.name)\t\(.ruby_source_path)"),
    ((.casks    // [])[] | "\(.name)\t\(.ruby_source_path)")
  ' 2>/dev/null)

  local source_path repo epoch
  for (( i=1; i <= ${#uncached_names}; i+=1 )); do
    name=$uncached_names[$i]
    version=$uncached_versions[$i]
    source_path=${path_map[$name]:-}
    [[ -n $source_path ]] || continue
    repo=$(_zpun_min_age_brew_repo_for "$source_path") || continue
    epoch=$(_zpun_min_age_brew_github_lookup "$repo" "$source_path") || continue
    [[ -n $epoch && $epoch == <-> ]] || continue
    _zpun_min_age_cache_put brew "$name" "$version" "$epoch"
  done

  return 0
}

# _zpun_min_age_lookup_npm <name> <version> — query the npm registry through
# the npm CLI (which respects user proxy / auth config). We fetch the full
# `time` map as JSON and pick the version key with jq, because npm's
# property-accessor syntax (`time.<version>`) treats dots as path separators
# and silently returns nothing on real semver versions.
_zpun_min_age_lookup_npm() {
  emulate -L zsh
  setopt local_options

  local name=$1 version=$2
  (( $+commands[npm] && $+commands[jq] )) || return 1

  local map iso
  map=$(npm view "$name" time --json 2>/dev/null) || return 1
  [[ -n $map ]] || return 1
  iso=$(print -r -- "$map" | jq -r --arg v "$version" '.[$v] // empty' 2>/dev/null)
  [[ -n $iso && $iso != null ]] || return 1
  _zpun_min_age_parse_iso8601 "$iso"
}

# _zpun_min_age_lookup_uv <name> <version> — PyPI's JSON API. uv has no flag
# for this; we hit pypi.org directly.
_zpun_min_age_lookup_uv() {
  emulate -L zsh
  setopt local_options

  local name=$1 version=$2
  (( $+commands[curl] && $+commands[jq] )) || return 1

  local json
  json=$(curl -fsSL --max-time 5 "https://pypi.org/pypi/${name}/json" 2>/dev/null) || return 1
  [[ -n $json ]] || return 1

  local iso
  iso=$(print -r -- "$json" | jq -r --arg v "$version" '.releases[$v][0].upload_time // empty' 2>/dev/null)
  [[ -n $iso ]] || return 1
  _zpun_min_age_parse_iso8601 "$iso"
}

# _zpun_min_age_lookup_gem <name> <version> — RubyGems JSON API.
_zpun_min_age_lookup_gem() {
  emulate -L zsh
  setopt local_options

  local name=$1 version=$2
  (( $+commands[curl] && $+commands[jq] )) || return 1

  local json
  json=$(curl -fsSL --max-time 5 "https://rubygems.org/api/v1/versions/${name}.json" 2>/dev/null) || return 1
  [[ -n $json ]] || return 1

  local iso
  iso=$(print -r -- "$json" | jq -r --arg v "$version" '.[] | select(.number==$v) | .created_at' 2>/dev/null | head -n 1)
  [[ -n $iso ]] || return 1
  _zpun_min_age_parse_iso8601 "$iso"
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
