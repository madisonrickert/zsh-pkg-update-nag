# npm outdated-global provider.
#
# `npm outdated -g --parseable` emits colon-delimited rows even when npm itself
# exits 1 (which it does whenever *any* package is outdated). We tolerate that.

_zpun_provider_npm() {
  emulate -L zsh
  setopt local_options

  (( $+commands[npm] )) || return 0

  # A misconfigured npm prefix shouldn't break shell startup.
  npm config get prefix >/dev/null 2>&1 || {
    _zpun_debug_log "npm: config get prefix failed, skipping provider"
    return 0
  }

  local raw
  raw=$(npm outdated -g --parseable 2>/dev/null)
  # Exit 1 is normal here; ignore status and parse whatever came out.

  local line name current latest
  local -a parts
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    # Format: path:wanted:current:latest:location[:type]
    parts=( ${(s.:.)line} )
    (( ${#parts} >= 4 )) || continue

    # Fields 3/4 are name@version (or @scope/name@version). The last `@` is the
    # version separator; everything before is the name, everything after is the
    # version. This correctly handles scoped packages like @types/node@1.2.3.
    current=${parts[3]##*@}
    latest=${parts[4]##*@}
    name=${parts[3]%@*}

    # Fallback to path basename if the @-split didn't yield a name (shouldn't
    # happen for npm's parseable output, but is defensive).
    [[ -n $name ]] || name=${parts[1]:t}

    [[ -n $name && -n $current && -n $latest && $current != $latest ]] || continue
    print -r -- "${name}"$'\t'"${current}"$'\t'"${latest}"
  done <<< "$raw" | _zpun_filter_by_allowlist npm
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
