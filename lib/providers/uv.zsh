# uv tool outdated-global provider.
#
# `uv tool list --outdated` was added in uv 0.5. On older uv, we log and skip.

_zpun_provider_uv() {
  emulate -L zsh
  setopt local_options

  (( $+commands[uv] )) || return 0

  # Feature-detect the --outdated flag rather than parse versions.
  if ! uv tool list --help 2>/dev/null | grep -q -- '--outdated'; then
    _zpun_debug_log "uv: 'tool list --outdated' unsupported, skipping"
    return 0
  fi

  local raw
  raw=$(uv tool list --outdated 2>/dev/null) || return 0
  [[ -n $raw ]] || return 0

  # Typical output lines look like:
  #   ruff v0.6.0 (latest: v0.6.4)
  local line name current latest
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    line=${line## }
    if [[ $line =~ '^([A-Za-z0-9_.-]+)[[:space:]]+v?([^[:space:]]+)[[:space:]]+\(latest:[[:space:]]*v?([^)]+)\)' ]]; then
      name=${match[1]}
      current=${match[2]}
      latest=${match[3]}
      print -r -- "${name}"$'\t'"${current}"$'\t'"${latest}"
    fi
  done <<< "$raw" | _zpun_filter_by_allowlist uv
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
