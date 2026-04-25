# pnpm outdated-global provider.
#
# `pnpm outdated --global --format json` emits a single JSON object keyed by
# package name with `current` / `latest` / `wanted` fields. Like npm, pnpm
# exits non-zero when anything is outdated, so we ignore the status and parse
# whatever JSON came out. The empty-result case is `{}`.

_zpun_provider_pnpm() {
  emulate -L zsh
  setopt local_options

  (( $+commands[pnpm] && $+commands[jq] )) || return 0

  local raw
  raw=$(pnpm outdated --global --format json 2>/dev/null)
  # Exit non-zero is normal here; ignore status and parse whatever came out.
  [[ -n $raw ]] || return 0

  print -r -- "$raw" | jq -r '
    if type == "object" then
      to_entries[] |
      select(.value.current and .value.latest and .value.current != .value.latest) |
      [.key, .value.current, .value.latest] | @tsv
    else
      empty
    end
  ' 2>/dev/null | _zpun_filter_by_allowlist pnpm
}

# _zpun_min_age_lookup_pnpm <name> <version> — npm registry's JSON metadata
# exposes a `.time` map of version → ISO-8601. pnpm resolves from the same
# registry, so the answer is identical to npm's; we hit the registry directly
# rather than shell out to a CLI so users without `npm` installed can still
# get min-age gating on their pnpm globals.
_zpun_min_age_lookup_pnpm() {
  emulate -L zsh
  setopt local_options

  local name=$1 version=$2
  (( $+commands[curl] && $+commands[jq] )) || return 1

  local json
  json=$(curl -fsSL --max-time 5 "https://registry.npmjs.org/${name}" 2>/dev/null) || return 1
  [[ -n $json ]] || return 1

  local iso
  iso=$(print -r -- "$json" | jq -r --arg v "$version" '.time[$v] // empty' 2>/dev/null)
  [[ -n $iso && $iso != null ]] || return 1
  _zpun_min_age_parse_iso8601 "$iso"
}
