#!/usr/bin/env bash
set -euo pipefail

selector="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/select-range.sh"
fixture="$(mktemp -d)"
other="$(mktemp -d)"
trap 'rm -rf "$fixture" "$other"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

commit() {
  local repo="$1" file="$2"
  printf '%s\n' "$file" >"$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -qm "$file"
  git -C "$repo" rev-parse HEAD
}

init_repo() {
  git -C "$1" init -q -b main
  git -C "$1" config user.email ci-test@revenium.io
  git -C "$1" config user.name 'CI Test'
}

# Runs the selector in the fixture; prints its range output, or FAILED plus stderr.
select_range() {
  local out="$fixture/.output"
  : >"$out"
  if (cd "$fixture" && env GITHUB_OUTPUT="$out" "$@" "$selector") 2>"$fixture/.stderr"; then
    cat "$out"
  else
    printf 'FAILED %s\n' "$(cat "$fixture/.stderr")"
  fi
}

expect() {
  local expected="$1" actual="$2"
  [[ "$actual" == "$expected"* ]] || fail "expected '${expected}', got '${actual}'"
}

init_repo "$fixture"
root="$(commit "$fixture" root.txt)"
git -C "$fixture" switch -qc feature
feature="$(commit "$fixture" feature.txt)"

expect "commit_range=${root}..${feature}" \
  "$(select_range EVENT_NAME=pull_request PR_BASE_SHA="$root" PR_HEAD_SHA="$feature")"
expect "commit_range=${root}..${feature}" \
  "$(select_range EVENT_NAME=merge_group MG_BASE_SHA="$root" MG_HEAD_SHA="$feature")"

# Base advanced past the branch point: scan merge_base..head, never base-only commits.
git -C "$fixture" switch -q main
advanced="$(commit "$fixture" main-update.txt)"
expect "commit_range=${root}..${feature}" \
  "$(select_range EVENT_NAME=pull_request PR_BASE_SHA="$advanced" PR_HEAD_SHA="$feature")"

# Every untrustworthy range fails closed; none falls back to full history.
missing=1111111111111111111111111111111111111111
expect 'FAILED ::error::Revenium key scan cannot determine the commits to scan: pull request base SHA' \
  "$(select_range EVENT_NAME=pull_request PR_BASE_SHA="$missing" PR_HEAD_SHA="$feature")"
expect 'FAILED ::error::Revenium key scan cannot determine the commits to scan: pull request head SHA' \
  "$(select_range EVENT_NAME=pull_request PR_BASE_SHA="$root" PR_HEAD_SHA=)"
expect 'FAILED ::error::Revenium key scan cannot determine the commits to scan: pull request base SHA' \
  "$(select_range EVENT_NAME=pull_request PR_BASE_SHA='HEAD --all' PR_HEAD_SHA="$feature")"
expect 'FAILED ::error::Revenium key scan cannot determine the commits to scan: pull request head is behind its base' \
  "$(select_range EVENT_NAME=pull_request PR_BASE_SHA="$feature" PR_HEAD_SHA="$root")"
expect "FAILED ::error::Revenium key scan cannot determine the commits to scan: unsupported event 'push'" \
  "$(select_range EVENT_NAME=push)"

init_repo "$other"
unrelated="$(commit "$other" other.txt)"
git -C "$fixture" fetch -q "$other" main
expect 'FAILED ::error::Revenium key scan cannot determine the commits to scan: pull request base and head share no history' \
  "$(select_range EVENT_NAME=pull_request PR_BASE_SHA="$unrelated" PR_HEAD_SHA="$feature")"

printf 'PASS: scan range selection.\n'
