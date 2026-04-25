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

# _zpun_min_age_brew_graphql_prefetch <names_var> <versions_var> <repos_var> <paths_var>
#
# Args are the *names* of four parallel arrays in the caller's scope (we use
# ${(P)name} indirection to read them) — passing thousands of values flat
# would also work but indirection keeps the call site readable.
#
# Builds one GitHub GraphQL query with synthetic aliases (p1..pN for
# homebrew-core, c1..cN for homebrew-cask) covering every package, sends it
# in one HTTP round trip, then writes every resolved (name, version, epoch)
# triple to the cache.
#
# Auth path:
#   - If `gh` is installed AND `gh auth status` succeeds → run via `gh api
#     graphql`. Uses the user's gh token (5000/hr GraphQL pool, separate
#     from the REST 60/hr unauth pool).
#   - Else if `$GITHUB_TOKEN` is set AND `curl` + `jq` are available → POST
#     directly to https://api.github.com/graphql with bearer auth.
#   - Else → return 1 so the caller can fall back to the per-package REST
#     path. (GitHub's GraphQL endpoint requires authentication; there is no
#     unauthenticated GraphQL quota.)
_zpun_min_age_brew_graphql_prefetch() {
  emulate -L zsh
  setopt local_options

  (( $+commands[jq] )) || return 1

  local auth_method=""
  if (( $+commands[gh] )) && gh auth status >/dev/null 2>&1; then
    auth_method=gh
  elif [[ -n ${GITHUB_TOKEN:-} ]] && (( $+commands[curl] )); then
    auth_method=token
  else
    return 1
  fi

  # Use _-prefixed local names so they don't shadow whatever array name the
  # caller used (otherwise ${(P)names_var} would dereference our own empty
  # local instead of the caller's array).
  local names_var=$1 versions_var=$2 repos_var=$3 paths_var=$4
  local -a _names _versions _repos _paths
  _names=(    "${(@P)names_var}" )
  _versions=( "${(@P)versions_var}" )
  _repos=(    "${(@P)repos_var}" )
  _paths=(    "${(@P)paths_var}" )

  local total=${#_names}
  (( total > 0 )) || return 0

  # Build the GraphQL body — one alias per package, partitioned by repo.
  # Brew names can include `-`, `@`, etc. which aren't valid in GraphQL
  # aliases, so we use synthetic p<N>/c<N> and a parallel name→pkg map.
  local -A alias_to_pkg
  local query_core="" query_cask=""
  local n_core=0 n_cask=0
  local i alias field
  for (( i=1; i <= total; i+=1 )); do
    field='object(expression: "HEAD") { ... on Commit { history(path: "'${_paths[i]}'", first: 1) { nodes { committedDate } } } }'
    case ${_repos[i]} in
      Homebrew/homebrew-core)
        n_core=$(( n_core + 1 ))
        alias="p${n_core}"
        query_core+="    ${alias}: ${field}"$'\n'
        ;;
      Homebrew/homebrew-cask)
        n_cask=$(( n_cask + 1 ))
        alias="c${n_cask}"
        query_cask+="    ${alias}: ${field}"$'\n'
        ;;
      *) continue ;;
    esac
    alias_to_pkg[$alias]="${_names[i]}"$'\t'"${_versions[i]}"
  done

  (( n_core + n_cask )) || return 0

  local query="{"$'\n'
  if (( n_core )); then
    query+='  core: repository(owner: "Homebrew", name: "homebrew-core") {'$'\n'
    query+="$query_core"
    query+="  }"$'\n'
  fi
  if (( n_cask )); then
    query+='  cask: repository(owner: "Homebrew", name: "homebrew-cask") {'$'\n'
    query+="$query_cask"
    query+="  }"$'\n'
  fi
  query+="}"$'\n'

  local response
  case $auth_method in
    gh)
      response=$(gh api graphql -f query="$query" 2>/dev/null) || return 1
      ;;
    token)
      local body
      body=$(jq -n --arg q "$query" '{query: $q}' 2>/dev/null) || return 1
      response=$(curl -fsSL --max-time 10 \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H 'Content-Type: application/json' \
        -d "$body" \
        https://api.github.com/graphql 2>/dev/null) || return 1
      ;;
  esac
  [[ -n $response ]] || return 1
  # Surface explicit GraphQL errors (auth, rate limit, syntax) as failure
  # so the caller falls through to the REST path.
  if print -r -- "$response" | jq -e 'has("errors")' >/dev/null 2>&1; then
    return 1
  fi

  # Stream alias\tcommittedDate pairs out of the response.
  local result_alias result_iso epoch pkg pkg_name pkg_version
  while IFS=$'\t' read -r result_alias result_iso; do
    [[ -n $result_alias && -n $result_iso ]] || continue
    pkg=${alias_to_pkg[$result_alias]:-}
    [[ -n $pkg ]] || continue
    pkg_name=${pkg%%$'\t'*}
    pkg_version=${pkg##*$'\t'}
    epoch=$(_zpun_min_age_parse_iso8601 "$result_iso") || continue
    [[ -n $epoch && $epoch == <-> ]] || continue
    _zpun_min_age_cache_put brew "$pkg_name" "$pkg_version" "$epoch"
  done < <(print -r -- "$response" | jq -r '
    [.data // {} | to_entries[]? | .value | to_entries[]?]
    | .[] | select(.value.history.nodes[0].committedDate != null)
    | "\(.key)\t\(.value.history.nodes[0].committedDate)"
  ' 2>/dev/null)

  return 0
}

# _zpun_min_age_prefetch_brew <name1> <version1> [<name2> <version2>...]
# Two-stage prefetch:
#   1. Single batched `brew info --json=v2` covering every uncached name to
#      build a name→ruby_source_path map (one CLI invocation regardless of
#      package count).
#   2. One GitHub GraphQL query (`gh api graphql` or `curl` with
#      `$GITHUB_TOKEN`) returning every commit date in a single round trip.
#      Falls back to per-package serial REST when neither auth path is
#      available — slow but correct, and rare in practice.
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
  local jq_name jq_path
  while IFS=$'\t' read -r jq_name jq_path; do
    [[ -n $jq_name && -n $jq_path ]] || continue
    path_map[$jq_name]=$jq_path
  done < <(print -r -- "$info" | jq -r '
    ((.formulae // [])[] | "\(.name)\t\(.ruby_source_path)"),
    ((.casks    // [])[] | "\(.token)\t\(.ruby_source_path)")
  ' 2>/dev/null)

  # Build the work list of (name, version, repo, source_path) tuples we
  # actually need to fetch. Skip entries with no resolved path or unknown
  # tap layout — they'll fall through to the per-row fail-open path.
  local -a job_names job_versions job_repos job_paths
  local source_path repo
  for (( i=1; i <= ${#uncached_names}; i+=1 )); do
    name=$uncached_names[$i]
    version=$uncached_versions[$i]
    source_path=${path_map[$name]:-}
    [[ -n $source_path ]] || continue
    repo=$(_zpun_min_age_brew_repo_for "$source_path") || continue
    job_names+=( "$name" )
    job_versions+=( "$version" )
    job_repos+=( "$repo" )
    job_paths+=( "$source_path" )
  done

  (( ${#job_names} )) || return 0

  # Fast path: one GraphQL query covers every package in a single round
  # trip (~1.5 s for 35 packages). Returns 0 only when the response was
  # delivered AND parsed; falls through on no-auth, network failure, or
  # GraphQL-level errors.
  if _zpun_min_age_brew_graphql_prefetch \
       job_names job_versions job_repos job_paths; then
    return 0
  fi

  # Fallback: parallel REST per package, using the already-batched path map
  # so we don't repay the per-name `brew info` cost. Each worker is a
  # background subshell whose stdout goes to its own temp file; the parent
  # waits per chunk and slurps results into the cache.
  #
  # Unauthenticated callers share a 60-requests/hour cap on this endpoint —
  # parallelism finishes faster but doesn't extend the quota; once the cap
  # is hit the lookup fails-open and a debug-log line records why.
  # Tunable via ZSH_PKG_UPDATE_NAG_LOOKUP_PARALLELISM (default 6).
  local max_parallel=${ZSH_PKG_UPDATE_NAG_LOOKUP_PARALLELISM:-6}
  (( max_parallel >= 1 )) || max_parallel=1
  local tmp_dir
  tmp_dir=$(mktemp -d -t zpun.parallel.XXXXXX) || return 0
  local total=${#job_names}
  local chunk_start chunk_end j

  for (( chunk_start=1; chunk_start <= total; chunk_start+=max_parallel )); do
    chunk_end=$(( chunk_start + max_parallel - 1 ))
    (( chunk_end > total )) && chunk_end=$total

    for (( j=chunk_start; j <= chunk_end; j+=1 )); do
      (
        emulate -L zsh
        setopt local_options
        local _e
        _e=$(_zpun_min_age_brew_github_lookup "$job_repos[$j]" "$job_paths[$j]")
        if [[ -n $_e && $_e == <-> ]]; then
          print -r -- "$job_names[$j]"$'\t'"$job_versions[$j]"$'\t'"$_e" > "$tmp_dir/r.$j"
        fi
      ) &
    done
    wait
  done

  # Drain results into the cache.
  local f line ln lv le
  for f in "$tmp_dir"/r.*(N); do
    line=$(<"$f")
    [[ $line == *$'\t'*$'\t'* ]] || continue
    ln=${line%%$'\t'*}
    le=${line##*$'\t'}
    lv=${line#*$'\t'}
    lv=${lv%$'\t'*}
    _zpun_min_age_cache_put brew "$ln" "$lv" "$le"
  done

  rm -rf "$tmp_dir"
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
