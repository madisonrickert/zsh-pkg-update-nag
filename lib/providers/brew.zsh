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
