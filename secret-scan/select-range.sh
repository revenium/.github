#!/usr/bin/env bash
set -euo pipefail

# Selects the commits a pull request or merge-queue group adds, and nothing else.
# This scan is required on every repo, and nine repos still hold old keys in
# history, so it never falls back to a full-history scan: when the range cannot
# be trusted it fails closed instead.

output_file="${GITHUB_OUTPUT:-/dev/stdout}"

fail_closed() {
  printf '::error::Revenium key scan cannot determine the commits to scan: %s.\n' "$1" >&2
  exit 2
}

# The hex-only anchor is a security control: the range is passed to gitleaks
# --log-opts, which forwards it to `git log`.
is_commit() {
  [[ "$1" =~ ^[0-9a-fA-F]{40,64}$ ]] && git cat-file -e "${1}^{commit}" 2>/dev/null
}

emit_range() {
  local base_sha="$1" head_sha="$2" label="$3" start canonical_head

  is_commit "$base_sha" || fail_closed "${label} base SHA is missing or unavailable"
  is_commit "$head_sha" || fail_closed "${label} head SHA is missing or unavailable"

  if git merge-base --is-ancestor "$base_sha" "$head_sha" 2>/dev/null; then
    start="$base_sha"
  else
    # The base branch moved on after this branch was cut; the PR's own
    # commits are merge_base..head.
    start="$(git merge-base "$base_sha" "$head_sha" 2>/dev/null | head -n 1 || true)"
    canonical_head="$(git rev-parse --verify "${head_sha}^{commit}")"
    [[ -n "$start" ]] || fail_closed "${label} base and head share no history"
    [[ "$start" != "$canonical_head" ]] || fail_closed "${label} head is behind its base"
    is_commit "$start" || fail_closed "${label} merge base is unavailable"
    printf '::notice::Base branch has advanced; scanning from the merge base %s.\n' "$start" >&2
  fi

  [[ "$(git rev-list --count "${start}..${head_sha}")" -gt 0 ]] ||
    fail_closed "${label} adds no commits"

  printf 'commit_range=%s..%s\n' "$start" "$head_sha" >>"$output_file"
}

case "${EVENT_NAME:-}" in
  pull_request | pull_request_target)
    emit_range "${PR_BASE_SHA:-}" "${PR_HEAD_SHA:-}" "pull request"
    ;;
  merge_group)
    emit_range "${MG_BASE_SHA:-}" "${MG_HEAD_SHA:-}" "merge group"
    ;;
  *)
    fail_closed "unsupported event '${EVENT_NAME:-missing}'"
    ;;
esac
