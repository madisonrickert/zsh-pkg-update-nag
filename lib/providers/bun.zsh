# bun outdated-global provider.
#
# `bun outdated -g` has no machine-readable output mode (as of bun 1.4), so we
# parse its box table:
#
#   |---------------------------------------|
#   | Package   | Current | Update | Latest |
#   |-----------|---------|--------|--------|
#   | is-number | 6.0.0   | 6.0.0  | 7.0.0  |
#   |---------------------------------------|
#
# Data rows are the `|`-prefixed lines that aren't rules (`|---`) or the
# header. Bun exits 0 whether or not anything is outdated. NO_COLOR keeps ANSI
# out of the cells; we run from $HOME so a bunfig.toml in the caller's cwd
# can't redirect the scan.
#
# Bun's own minimum-release-age (`install.minimumReleaseAge` in the global
# bunfig, or --minimum-release-age) is honoured by `bun outdated`: Latest then
# shows the newest old-enough version, marked with a trailing ` *`. When no
# newer version is old enough, bun (1.4.4) still lists the row, with a Latest
# that is OLDER than Current, e.g. `6.0.0 | 6.0.0 | 4.0.0 *`. Taken at face
# value, that row would offer a downgrade, so marked rows are kept only when
# Latest > Current.

# Captured at source time: the provider runs in a `zsh -c` subshell where
# $_ZPUN_DIR isn't set, and min_age.zsh (for _zpun_version_compare) is only
# sourced on demand.
typeset -g _ZPUN_BUN_LIB_DIR="${${(%):-%x}:A:h:h}"

_zpun_provider_bun() {
  emulate -L zsh
  setopt local_options extended_glob

  (( $+commands[bun] )) || return 0

  local raw
  raw=$(cd ~ && NO_COLOR=1 bun outdated -g --no-progress 2>/dev/null) || {
    _zpun_debug_log "bun: outdated -g failed, skipping provider"
    return 0
  }

  local line name current latest capped
  local -a cells
  while IFS= read -r line; do
    [[ $line == '|'* && $line != '|-'* ]] || continue
    # ${(s:|:)} drops the empty leading/trailing fields; trim each cell.
    cells=( ${${${(s:|:)line}##[[:space:]]#}%%[[:space:]]#} )
    (( ${#cells} >= 4 )) || continue
    [[ ${cells[1]} != Package ]] || continue
    # Workspace tables tag dev/peer deps as "name (dev)"; globals shouldn't,
    # but strip defensively so the upgrade command gets a bare name.
    name=${cells[1]%% \(*\)}
    current=${cells[2]}
    latest=${cells[4]}
    capped=0
    if [[ $latest == *' *' ]]; then
      latest=${latest% \*}
      capped=1
    fi
    [[ -n $name && -n $current && -n $latest && $current != $latest ]] || continue
    if (( capped )); then
      (( $+functions[_zpun_version_compare] )) \
        || source "$_ZPUN_BUN_LIB_DIR/min_age.zsh"
      [[ $(_zpun_version_compare "$latest" "$current") == 1 ]] || continue
    fi
    print -r -- "${name}"$'\t'"${current}"$'\t'"${latest}"
  done <<< "$raw" | _zpun_filter_by_allowlist bun
}

# Min-age hooks: bun resolves from the npm registry, so the answers are
# identical to pnpm's registry lookups. Delegate rather than duplicate; the
# pnpm provider file is sourced on first use (these run in the parent shell,
# where _ZPUN_DIR is set).
_zpun_bun_need_pnpm_hooks() {
  (( $+functions[_zpun_min_age_lookup_pnpm] )) \
    || source "$_ZPUN_DIR/lib/providers/pnpm.zsh"
}

_zpun_min_age_lookup_bun() {
  _zpun_bun_need_pnpm_hooks || return 1
  _zpun_min_age_lookup_pnpm "$@"
}

_zpun_min_age_versions_bun() {
  _zpun_bun_need_pnpm_hooks || return 1
  _zpun_min_age_versions_pnpm "$@"
}
