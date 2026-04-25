# RubyGems outdated-global provider.
#
# `gem outdated` prints lines of the form:
#   pkgname (current < latest)

_zpun_provider_gem() {
  emulate -L zsh
  setopt local_options

  (( $+commands[gem] )) || return 0

  local raw
  raw=$(gem outdated 2>/dev/null) || return 0

  local line name current latest
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if [[ $line =~ '^([A-Za-z0-9_.-]+)[[:space:]]+\(([^<]+)<[[:space:]]*([^)]+)\)' ]]; then
      name=${match[1]}
      current=${match[2]// /}
      latest=${match[3]// /}
      print -r -- "${name}"$'\t'"${current}"$'\t'"${latest}"
    fi
  done <<< "$raw" | _zpun_filter_by_allowlist gem
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
