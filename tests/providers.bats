#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

@test "brew provider emits tsv for outdated formulae and casks" {
  run run_plugin_zsh "_zpun_provider_brew"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh	2.60.0	2.62.0"* ]]
  [[ "$output" == *"fd	10.1.0	10.2.0"* ]]
  [[ "$output" == *"example-app@latest	0.9.0	0.9.1"* ]]
}

@test "brew provider is silent when nothing is outdated" {
  ZPUN_FIXTURE_BREW=empty run run_plugin_zsh "_zpun_provider_brew"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "npm provider tolerates exit 1 when any outdated" {
  run run_plugin_zsh "_zpun_provider_npm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pnpm	9.0.0	9.5.1"* ]]
  [[ "$output" == *"typescript	5.4.0	5.5.0"* ]]
}

@test "pnpm provider parses --format json output" {
  run run_plugin_zsh "_zpun_provider_pnpm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollup	4.30.0	4.31.0"* ]]
  [[ "$output" == *"vite	5.0.0	5.1.0"* ]]
}

@test "pnpm provider is silent when nothing is outdated" {
  ZPUN_FIXTURE_PNPM=empty run run_plugin_zsh "_zpun_provider_pnpm"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bun provider parses the outdated -g table" {
  run run_plugin_zsh "_zpun_provider_bun"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is-number	6.0.0	7.0.0"* ]]
  [[ "$output" == *"@scope/x	1.0.0	1.2.0"* ]]
  [[ "$output" != *"same"* ]]
  [[ "$output" != *"Package"* ]]
}

@test "bun provider is silent when nothing is outdated" {
  ZPUN_FIXTURE_BUN=empty run run_plugin_zsh "_zpun_provider_bun"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bun provider keeps bun-min-age-capped rows only when they upgrade" {
  ZPUN_FIXTURE_BUN=capped run run_plugin_zsh "_zpun_provider_bun"
  [ "$status" -eq 0 ]
  [[ "$output" == *"semver	7.5.0	7.6.0"* ]]
  [[ "$output" != *"is-number"* ]]
  [[ "$output" != *"*"* ]]
}

@test "bun provider is silent when bun fails" {
  ZPUN_FIXTURE_BUN=fail run run_plugin_zsh "_zpun_provider_bun"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bun versions hook delegates to the npm registry lookup" {
  run run_plugin_zsh "_zpun_min_age_versions_bun rollup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "uv provider parses 'latest: vX' lines" {
  run run_plugin_zsh "_zpun_provider_uv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruff	0.6.0	0.6.4"* ]]
}

@test "gem provider parses 'pkg (current < latest)' lines" {
  run run_plugin_zsh "zsh_pkg_update_nag_gem=all; _zpun_provider_gem"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rails	7.1.0	7.2.0"* ]]
  [[ "$output" == *"rspec	3.12.0	3.13.0"* ]]
}

@test "cargo provider emits tsv for rows tagged 'Yes'" {
  run run_plugin_zsh "_zpun_provider_cargo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ripgrep	13.0.0	14.1.0"* ]]
  [[ "$output" == *"cargo-edit	0.12.0	0.13.0"* ]]
  # Up-to-date rows ("No") must be filtered out.
  [[ "$output" != *"cargo-update	"* ]]
}

@test "cargo provider is silent when every row is 'No'" {
  ZPUN_FIXTURE_CARGO=empty run run_plugin_zsh "_zpun_provider_cargo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cargo provider skips silently when cargo-install-update is missing" {
  ZPUN_FIXTURE_CARGO=missing run run_plugin_zsh "_zpun_provider_cargo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cargo provider stays silent when 'install-update --list' fails" {
  # A non-zero `--list` (registry unreachable, malformed cooldown, etc.)
  # must fail-open to an empty result, not surface a partial/garbage row.
  ZPUN_FIXTURE_CARGO=fail run run_plugin_zsh "_zpun_provider_cargo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cargo provider forwards --cooldown when min_age threshold is set" {
  # Fixture's default mode emits no Yes rows when --cooldown is passed,
  # simulating native cargo-update cooldown filtering. A configured
  # threshold should round-trip through the fixture as an empty result set.
  run run_plugin_zsh "zsh_pkg_update_nag_min_age_cargo=7; _zpun_provider_cargo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cargo provider omits --cooldown when min_age is 0" {
  # Sanity: without a threshold, the full outdated set comes through (the
  # fixture only suppresses rows when --cooldown is on the command line).
  run run_plugin_zsh "_zpun_provider_cargo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ripgrep	13.0.0	14.1.0"* ]]
}

@test "cargo provider skips --cooldown on legacy cargo-update lacking the flag" {
  # 'old' mode's --help omits --cooldown; the provider should detect that
  # and not pass the flag, surfacing every Yes row unfiltered even when
  # min_age is set. We log the degradation but don't block the scan.
  ZPUN_FIXTURE_CARGO=old run run_plugin_zsh "zsh_pkg_update_nag_min_age_cargo=7; _zpun_provider_cargo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ripgrep	13.0.0	14.1.0"* ]]
  [[ "$output" == *"cargo-edit	0.12.0	0.13.0"* ]]
}

@test "cargo provider skips silently when another cargo holds the package-cache lock" {
  # Simulate a concurrent cargo process by holding an exclusive flock on the
  # package-cache file in a background subshell while the provider runs.
  mkdir -p "$TMP_DIR/cargo-home"
  : > "$TMP_DIR/cargo-home/.package-cache"

  CARGO_HOME="$TMP_DIR/cargo-home" run run_plugin_zsh '
    zmodload zsh/system
    coproc { zsystem flock "$CARGO_HOME/.package-cache" && read -r _ }
    # Wait until the coprocess has acquired the lock — probe non-blockingly
    # ourselves until acquisition fails, which means the coproc holds it.
    integer i=0
    while (( i++ < 50 )); do
      if ! ( zsystem flock -t 0 "$CARGO_HOME/.package-cache" ) 2>/dev/null; then
        break
      fi
      sleep 0.05
    done
    _zpun_provider_cargo
    # Release the coprocess so it can exit cleanly.
    print -p done
    wait
  '
  [ "$status" -eq 0 ]
  # The fixture would normally emit ripgrep + cargo-edit rows; the lock probe
  # should bail before invoking the fixture, leaving stdout empty.
  [ -z "$output" ]
}

@test "allowlist filters brew results" {
  run run_plugin_zsh "zsh_pkg_update_nag_brew=(gh); _zpun_config_load; _zpun_provider_brew"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh	"* ]]
  [[ "$output" != *"fd	"* ]]
}

@test "manager set to off is skipped" {
  run run_plugin_zsh "zsh_pkg_update_nag_brew=off; _zpun_manager_enabled brew && echo ENABLED || echo DISABLED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISABLED"* ]]
}

@test "npm versions hook classifies stable/prerelease and excludes unpublished" {
  run run_plugin_zsh "_zpun_min_age_versions_npm typescript"
  [ "$status" -eq 0 ]
  # stable release
  [[ "$output" == *$'5.4.5\t'*$'\tstable'* ]]
  # prerelease (semver -)
  [[ "$output" == *$'5.5.0-rc.1\t'*$'\tprerelease'* ]]
  # `npm view --json` returns `.versions` as a plain array with no per-version
  # deprecation, so a normal version is classified stable. (Deprecation is a
  # registry-document signal, exercised by the pnpm hook below.)
  [[ "$output" == *$'5.4.0\t'*$'\tstable'* ]]
  # header keys must not leak as versions
  [[ "$output" != *"created"* ]]
  [[ "$output" != *"modified"* ]]
  # unpublished version (in .time but absent from the .versions array) excluded
  [[ "$output" != *$'5.4.6\t'* ]]
}

@test "npm versions hook returns non-zero on fetch failure" {
  ZPUN_FIXTURE_NPM_VERSIONS=fail run run_plugin_zsh "_zpun_min_age_versions_npm typescript"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "pnpm versions hook classifies stable/prerelease/yanked from registry" {
  run run_plugin_zsh "_zpun_min_age_versions_pnpm rollup"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'5.1.0\t'*$'\tstable'* ]]
  [[ "$output" == *$'5.2.0-rc.1\t'*$'\tprerelease'* ]]
  [[ "$output" == *$'4.0.0\t'*$'\tyanked'* ]]
}

@test "pnpm versions hook returns non-zero on curl failure" {
  ZPUN_FIXTURE_CURL=fail run run_plugin_zsh "_zpun_min_age_versions_pnpm rollup"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "uv versions hook classifies stable/prerelease/yanked from pypi" {
  run run_plugin_zsh "_zpun_min_age_versions_uv ruff"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'0.6.4\t'*$'\tstable'* ]]
  [[ "$output" == *$'0.7.0a1\t'*$'\tprerelease'* ]]
  [[ "$output" == *$'0.5.0\t'*$'\tyanked'* ]]
}

@test "uv versions hook returns non-zero on curl failure" {
  ZPUN_FIXTURE_CURL=fail run run_plugin_zsh "_zpun_min_age_versions_uv ruff"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "gem versions hook classifies stable/prerelease from rubygems" {
  run run_plugin_zsh "_zpun_min_age_versions_gem rails"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'7.2.0\t'*$'\tstable'* ]]
  [[ "$output" == *$'7.3.0.beta1\t'*$'\tprerelease'* ]]
}

@test "gem versions hook returns non-zero on curl failure" {
  ZPUN_FIXTURE_CURL=fail run run_plugin_zsh "_zpun_min_age_versions_gem rails"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
