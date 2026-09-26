#!/usr/bin/env bash
set -euo pipefail

# Scans COMMIT_RANGE of the repository at GITHUB_WORKSPACE with the shared
# Revenium config. Exit 1 only when a Revenium API key rule matches; every other
# gitleaks finding is reported as a warning. Exit 2 on operational failure.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gitleaks-image.sh
source "${script_dir}/gitleaks-image.sh"
workspace="${GITHUB_WORKSPACE:-$(pwd)}"
config="${script_dir}/revenium.toml"
docker_bin="${GITLEAKS_DOCKER_BIN:-docker}"
image="${GITLEAKS_DOCKER_IMAGE:-$GITLEAKS_PINNED_IMAGE}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
report_dir="$(mktemp -d)"
report="${report_dir}/report.json"
trap 'rm -rf "$report_dir"' EXIT

if [[ ! "${COMMIT_RANGE:-}" =~ ^[0-9a-fA-F]{40,64}\.\.[0-9a-fA-F]{40,64}$ ]]; then
  printf '::error::Revenium key scan received an invalid commit range.\n' >&2
  exit 2
fi
printf 'Scanning commits %s\n' "$COMMIT_RANGE"

# gitleaks reads the scanned repo's own .gitleaksignore from /repo.
status=0
"$docker_bin" run --rm \
  -v "${workspace}:/repo:ro" \
  -v "${config}:/config/revenium.toml:ro" \
  -v "${report_dir}:/report" \
  "$image" \
  git \
    --config=/config/revenium.toml \
    --log-opts="--diff-merges=separate ${COMMIT_RANGE}" \
    --no-banner \
    --redact \
    --report-format=json \
    --report-path=/report/report.json \
    --exit-code=1 \
    /repo || status=$?

if [[ "$status" -gt 1 ]] || ! jq -e 'type == "array"' "$report" >/dev/null 2>&1; then
  printf '::error::gitleaks failed operationally (exit %s); no result.\n' "$status" >&2
  exit 2
fi

annotate() {
  local level="$1" filter="$2"
  jq -r --arg level "$level" "[.[] | ${filter}][] |
    \"::\(\$level) file=\(.File),line=\(.StartLine)::\(.RuleID) in commit \(.Commit[0:12])\"" "$report"
}

revenium_filter='select(.RuleID | startswith("revenium-"))'
other_filter='select(.RuleID | startswith("revenium-") | not)'
revenium_count="$(jq "[.[] | ${revenium_filter}] | length" "$report")"
other_count="$(jq "[.[] | ${other_filter}] | length" "$report")"

annotate error "$revenium_filter"
annotate warning "$other_filter"

{
  printf '## Revenium key scan\n\nCommits scanned: `%s`\n\n' "$COMMIT_RANGE"
  printf -- '- Revenium API keys (blocking): **%s**\n- Other possible secrets (report only): **%s**\n\n' \
    "$revenium_count" "$other_count"
  if [[ "$((revenium_count + other_count))" -gt 0 ]]; then
    printf '| Rule | File | Line | Commit |\n|---|---|---|---|\n'
    jq -r '.[] | "| \(.RuleID) | \(.File) | \(.StartLine) | \(.Commit[0:12]) |"' "$report"
    printf '\n'
  fi
  if [[ "$revenium_count" -gt 0 ]]; then
    printf 'Remove the key from the branch and rotate it: once pushed, treat it as exposed. '
    printf 'If a match is a confirmed-dead fixture, add its fingerprint to `.gitleaksignore`.\n'
  fi
} >>"$summary"

if [[ "$revenium_count" -gt 0 ]]; then
  printf '::error::Found %s Revenium API key(s) in this change.\n' "$revenium_count" >&2
  exit 1
fi
if [[ "$other_count" -gt 0 ]]; then
  printf '::warning::Found %s possible secret(s) outside the Revenium rules; report only.\n' "$other_count" >&2
fi
exit 0
