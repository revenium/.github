#!/usr/bin/env bash
set -euo pipefail

# Proves revenium.toml flags every Revenium key format and ignores the
# fake fixtures and placeholders our tests and docs use. Keys are generated at runtime so no
# key-shaped literal is ever committed.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gitleaks-image.sh
source "${script_dir}/gitleaks-image.sh"
config="${script_dir}/revenium.toml"
docker_bin="${GITLEAKS_DOCKER_BIN:-docker}"
image="${GITLEAKS_DOCKER_IMAGE:-$GITLEAKS_PINNED_IMAGE}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

random_hex() { openssl rand -hex "$1"; }
random_base62() {
  local chars
  chars="$(openssl rand -base64 96 | LC_ALL=C tr -dc 'A-Za-z0-9')"
  printf '%s' "${chars:0:$1}"
}

# Backend shape: <prefix><hashids tenant, 6+ alphanumerics>_<32 random bytes as lowercase hex>.
short_tenant="$(random_base62 6)"
long_tenant="$(random_base62 11)"
hex_tail="$(printf 'dead%.0s' {1..16})"

mkdir -p "$work/positive" "$work/negative"
for prefix in rev_mk rev_sk rev_rk hak; do
  printf 'const key = "%s_%s_%s";\n' "$prefix" "$short_tenant" "$(random_hex 32)" \
    >"$work/positive/${prefix}.ts"
  printf 'KEY=%s_%s_%s\n' "$prefix" "$long_tenant" "$(random_hex 32)" \
    >"$work/positive/${prefix}.env"
done

cat >"$work/negative/fixtures.ts" <<FIXTURES
validateApiKey("rev_mk_TENANT1_${hex_tail}");
validateApiKey("rev_sk_tenant_$(printf '0%.0s' {1..64})");
validateApiKey("rev_rk_abc123_$(printf '0123456789abcdef%.0s' {1..4})");
validateApiKey("hak_tenant_$(printf 'deadbeef%.0s' {1..8})");
validateApiKey("rev_sk_your_key_here");
validateApiKey("rev_mk_your_metering_key");
validateApiKey("hak_tenant_abc123xyz");
validateApiKey("hak_test_key123");
validateApiKey("rev_ab_tenant1_$(random_hex 32)");
FIXTURES

scan() {
  local dir="$1"
  local status=0
  local log="$work/${dir}.log"

  "$docker_bin" run --rm \
    -v "${config}:/config/.gitleaks.toml:ro" \
    -v "${work}:/scan" \
    "$image" \
    dir \
      --config=/config/.gitleaks.toml \
      --no-banner \
      --redact \
      --report-format=json \
      --report-path="/scan/${dir}.json" \
      --exit-code=1 \
      "/scan/${dir}" >"$log" 2>&1 || status=$?

  # Exit codes 0 (clean) and 1 (findings) both write a report; anything else,
  # or a missing/invalid report despite one of those codes, is an operational
  # failure whose cause would otherwise be silently discarded.
  if [[ "$status" -gt 1 ]] || ! jq -e 'type == "array"' "$work/${dir}.json" >/dev/null 2>&1; then
    cat "$log" >&2
    fail "gitleaks scan of ${dir} did not complete cleanly (exit ${status}); see diagnostics above"
  fi
}

scan positive
scan negative

expect_flagged() {
  local rule="$1" prefix="$2" ext
  for ext in ts env; do
    jq -e --arg r "$rule" --arg f "${prefix}.${ext}" \
      'any(.[]; .RuleID == $r and (.File | endswith($f)))' \
      "$work/positive.json" >/dev/null || fail "${rule} did not flag ${prefix}.${ext}"
  done
}

expect_flagged revenium-metering-api-key rev_mk
expect_flagged revenium-write-api-key rev_sk
expect_flagged revenium-read-api-key rev_rk
expect_flagged revenium-legacy-api-key hak

negative_hits="$(jq '[.[] | select(.RuleID | startswith("revenium-"))] | length' "$work/negative.json")"
[[ "$negative_hits" -eq 0 ]] || fail "Revenium rules flagged ${negative_hits} fake fixture(s)"

printf 'PASS: Revenium key rules flag every format and skip fake fixtures.\n'
