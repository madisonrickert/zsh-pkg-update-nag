#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

# ---------------------------------------------------------------------------
# _zpun_min_age_threshold: per-manager override semantics
# ---------------------------------------------------------------------------

@test "threshold defaults to 0 when no config is set" {
  run run_plugin_zsh "_zpun_min_age_threshold brew"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "threshold honors the global for every manager" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_days=7
    print -r -- \$(_zpun_min_age_threshold brew),\$(_zpun_min_age_threshold npm),\$(_zpun_min_age_threshold uv),\$(_zpun_min_age_threshold gem)
  "
  [ "$status" -eq 0 ]
  [ "$output" = "7,7,7,7" ]
}

@test "per-manager override wins over global" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_days=7
    zsh_pkg_update_nag_min_age_brew=14
    print -r -- \$(_zpun_min_age_threshold brew),\$(_zpun_min_age_threshold npm)
  "
  [ "$status" -eq 0 ]
  [ "$output" = "14,7" ]
}

@test "per-manager override of 0 disables that manager only" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_days=7
    zsh_pkg_update_nag_min_age_npm=0
    print -r -- \$(_zpun_min_age_threshold brew),\$(_zpun_min_age_threshold npm)
  "
  [ "$status" -eq 0 ]
  [ "$output" = "7,0" ]
}

@test "per-manager override of empty string treats as off" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_days=7
    zsh_pkg_update_nag_min_age_brew=''
    print -r -- \$(_zpun_min_age_threshold brew)
  "
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# _zpun_min_age_satisfied: gating decisions
# ---------------------------------------------------------------------------

@test "satisfied returns 0 (pass-through) when threshold is 0" {
  run run_plugin_zsh "_zpun_min_age_satisfied npm anything 1.0.0 && echo PASS || echo BLOCK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "satisfied passes when cached entry is older than threshold" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_days=7
    local old=\$((\$(date +%s) - 365*86400))
    _zpun_min_age_cache_put npm oldpkg 1.0.0 \$old
    _zpun_min_age_satisfied npm oldpkg 1.0.0 && echo PASS || echo BLOCK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "satisfied blocks when cached entry is fresher than threshold" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_days=7
    local fresh=\$((\$(date +%s) - 3600))
    _zpun_min_age_cache_put npm freshpkg 1.0.0 \$fresh
    _zpun_min_age_satisfied npm freshpkg 1.0.0 && echo PASS || echo BLOCK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCK"* ]]
}

@test "satisfied is fail-open when version is the '?' sentinel" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_days=7
    _zpun_min_age_satisfied brew gh '?' && echo PASS || echo BLOCK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "satisfied is fail-open when lookup function returns nothing" {
  # No fixtures will resolve "noexist@999.999.999" — npm fixture's view command
  # only honors ZPUN_FIXTURE_NPM_AGE=missing for empty output.
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_days=7
    ZPUN_FIXTURE_NPM_AGE=missing
    _zpun_min_age_satisfied npm noexist 999.999.999 && echo PASS || echo BLOCK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# Cache: round-trip and trim
# ---------------------------------------------------------------------------

@test "cache_put then cache_get returns the same epoch" {
  run run_plugin_zsh "
    _zpun_min_age_cache_put npm typescript 5.5.0 1700000000
    _zpun_min_age_cache_get npm typescript 5.5.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1700000000" ]
}

@test "cache_get returns 1 on miss and prints nothing" {
  run run_plugin_zsh "
    _zpun_min_age_cache_get npm absent 0.0.0 && echo HIT || echo MISS
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"MISS"* ]]
}

@test "cache_get returns the most recent entry on duplicate keys" {
  run run_plugin_zsh "
    _zpun_min_age_cache_put npm pkg 1.0.0 100
    _zpun_min_age_cache_put npm pkg 1.0.0 200
    _zpun_min_age_cache_get npm pkg 1.0.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}

@test "cache_trim keeps only the last 500 entries" {
  run run_plugin_zsh "
    integer i=0
    while (( i++ < 600 )); do
      _zpun_min_age_cache_put npm pkg\$i 1.0.0 \$i
    done
    print -r -- \$(_zpun_min_age_cache_count)
  "
  [ "$status" -eq 0 ]
  [ "$output" = "500" ]
}

# ---------------------------------------------------------------------------
# ISO-8601 parser
# ---------------------------------------------------------------------------

@test "iso8601 parses canonical Z-suffixed timestamp" {
  run run_plugin_zsh "_zpun_min_age_parse_iso8601 '2024-01-15T12:34:56Z'"
  [ "$status" -eq 0 ]
  [ "$output" = "1705322096" ]
}

@test "iso8601 parses fractional-seconds variant" {
  run run_plugin_zsh "_zpun_min_age_parse_iso8601 '2024-01-15T12:34:56.789Z'"
  [ "$status" -eq 0 ]
  [ "$output" = "1705322096" ]
}

@test "iso8601 parses +HH:MM offset variant" {
  run run_plugin_zsh "_zpun_min_age_parse_iso8601 '2024-01-15T12:34:56+00:00'"
  [ "$status" -eq 0 ]
  [ "$output" = "1705322096" ]
}

@test "iso8601 returns 1 on garbage input" {
  run run_plugin_zsh "_zpun_min_age_parse_iso8601 'not a timestamp' && echo OK || echo FAIL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# ---------------------------------------------------------------------------
# Per-manager lookups (using fixtures)
# ---------------------------------------------------------------------------

@test "npm lookup returns epoch from fixture" {
  run run_plugin_zsh "_zpun_min_age_lookup_npm typescript 5.5.0"
  [ "$status" -eq 0 ]
  [ "$output" = "1579091696" ]   # 2020-01-15T12:34:56Z
}

@test "npm lookup returns nothing when fixture is in 'missing' mode" {
  ZPUN_FIXTURE_NPM_AGE=missing run run_plugin_zsh "_zpun_min_age_lookup_npm typescript 5.5.0"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "uv lookup returns epoch from PyPI curl fixture" {
  run run_plugin_zsh "_zpun_min_age_lookup_uv ruff 0.6.4"
  [ "$status" -eq 0 ]
  [ "$output" = "1579091696" ]
}

@test "uv lookup returns nothing when curl fixture fails" {
  ZPUN_FIXTURE_CURL=fail run run_plugin_zsh "_zpun_min_age_lookup_uv ruff 0.6.4"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "gem lookup returns epoch from RubyGems curl fixture" {
  run run_plugin_zsh "_zpun_min_age_lookup_gem rails 7.2.0"
  [ "$status" -eq 0 ]
  [ "$output" = "1579091696" ]
}

@test "brew lookup returns epoch from GitHub curl fixture" {
  run run_plugin_zsh "_zpun_min_age_lookup_brew cmake 4.3.2"
  [ "$status" -eq 0 ]
  [ "$output" = "1579091696" ]
}

@test "brew lookup falls back to cask when formula path 404s" {
  ZPUN_FIXTURE_CURL=missing run run_plugin_zsh "_zpun_min_age_lookup_brew cmake 4.3.2 && echo OK || echo FAIL"
  [ "$status" -eq 0 ]
  # 'missing' mode returns [] for both repos, so the lookup should fail-open.
  [[ "$output" == *"FAIL"* ]]
}

@test "brew lookup returns nothing when curl fixture fails" {
  ZPUN_FIXTURE_CURL=fail run run_plugin_zsh "_zpun_min_age_lookup_brew cmake 4.3.2"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "prefetch_brew populates the cache for every name in one batch" {
  run run_plugin_zsh "
    _zpun_min_age_prefetch_brew cmake 4.3.2 gh 2.62.0 blender 5.1.1
    print -r -- \$(_zpun_min_age_cache_count)
    _zpun_min_age_cache_get brew cmake 4.3.2
    _zpun_min_age_cache_get brew gh 2.62.0
    _zpun_min_age_cache_get brew blender 5.1.1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"3"* ]]               # three cache entries
  [[ "$output" == *"1579091696"* ]]      # 2020-01-15Z, repeated 3 times
}

@test "prefetch_brew skips entries that are already cached" {
  run run_plugin_zsh "
    _zpun_min_age_cache_put brew cmake 4.3.2 1234567890
    _zpun_min_age_prefetch_brew cmake 4.3.2 gh 2.62.0
    print -r -- COUNT=\$(_zpun_min_age_cache_count)
    _zpun_min_age_cache_get brew cmake 4.3.2
  "
  [ "$status" -eq 0 ]
  # cmake's pre-existing cache value must not be overwritten
  [[ "$output" == *"COUNT=2"* ]]
  [[ "$output" == *"1234567890"* ]]
}

@test "prefetch dispatcher is a no-op for managers without a hook" {
  run run_plugin_zsh "_zpun_min_age_prefetch npm typescript 5.5.0 && echo OK || echo FAIL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# End-to-end: a fresh fixture timestamp causes the row to be dropped
# ---------------------------------------------------------------------------

@test "satisfied uses npm lookup and blocks fresh entries" {
  ZPUN_FIXTURE_NPM_AGE=fresh run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_npm=7
    _zpun_min_age_satisfied npm typescript 5.5.0 && echo PASS || echo BLOCK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCK"* ]]
}

@test "satisfied uses uv lookup (via curl fixture) and blocks fresh entries" {
  ZPUN_FIXTURE_CURL=fresh run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_uv=7
    _zpun_min_age_satisfied uv ruff 0.6.4 && echo PASS || echo BLOCK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCK"* ]]
}
