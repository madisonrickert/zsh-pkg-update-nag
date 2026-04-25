# Homebrew outdated-package provider. Covers both formulae and casks.
# Cask upgrades may prompt for sudo when replacing bundles in /Applications.

_zpun_provider_brew() {
  emulate -L zsh
  setopt local_options

  (( $+commands[brew] )) || return 0

  local raw parsed name
  if (( $+commands[jq] )); then
    raw=$(brew outdated --json=v2 2>/dev/null) || return 0
    parsed=$(print -r -- "$raw" | jq -r '
      (.formulae[]?, .casks[]?) |
      [.name, (.installed_versions[0] // "?"), .current_version] |
      @tsv
    ' 2>/dev/null) || return 0
    print -r -- "$parsed" | _zpun_filter_by_allowlist brew
  else
    # No jq: degrade to names-only, version fields become "?".
    raw=$({ brew outdated --quiet --formula 2>/dev/null; brew outdated --quiet --cask 2>/dev/null; })
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      print -r -- "${name}"$'\t?\t?'
    done <<< "$raw" | _zpun_filter_by_allowlist brew
  fi
}

# ---------------------------------------------------------------------------
# Min-age publish-date lookups for Homebrew.
#
# The brew signal is the formula/cask file's commit time in
# Homebrew/homebrew-core (or homebrew-cask), reached via the GitHub API since
# Homebrew 4.0+ no longer clones the tap locally. Two paths:
#   - prefetch_brew: one batched `brew info --json=v2` for paths, then one
#     GraphQL query for every commit date in a single round trip.
#   - lookup_brew: per-row fallback for cache misses outside the prefetched
#     set; one `brew info` call plus one REST call.
# ---------------------------------------------------------------------------

# _zpun_min_age_brew_github_lookup <repo> <file_path> — print epoch seconds
# of the latest commit touching <file_path> in <repo>. Used by both the
# per-row lookup and the batch prefetch.
#
# Note: `path` cannot be a local var name in this file — zsh ties scalar
# $path to the $PATH array, so shadowing it would break every external
# command call.
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

  _zpun_progress_emit "Resolving Homebrew paths (${#uncached_names} package$( (( ${#uncached_names} == 1 )) || print s ))…"
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
  _zpun_progress_emit "Fetching Homebrew publish dates (${#job_names} via GitHub)…"
  if _zpun_min_age_brew_graphql_prefetch \
       job_names job_versions job_repos job_paths; then
    return 0
  fi

  _zpun_progress_emit "Fetching Homebrew publish dates (${#job_names} via GitHub REST)…"

  # Fallback: parallel REST per package, using the already-batched path map
  # so we don't repay the per-name `brew info` cost. Each worker is a
  # background subshell whose stdout goes to its own temp file; the parent
  # waits per chunk and slurps results into the cache.
  #
  # Unauthenticated callers share a 60-requests/hour cap on this endpoint —
  # parallelism finishes faster but doesn't extend the quota; once the cap
  # is hit the lookup fails-open and a debug-log line records why.
  # Tunable via ZSH_PKG_UPDATE_NAG_MIN_AGE_LOOKUP_PARALLELISM (default 6).
  local max_parallel=${ZSH_PKG_UPDATE_NAG_MIN_AGE_LOOKUP_PARALLELISM:-6}
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
