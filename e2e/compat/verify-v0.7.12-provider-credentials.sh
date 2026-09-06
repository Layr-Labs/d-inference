#!/usr/bin/env bash
# Prove the fixture-only overlay against the released coordinator, without
# executing Swift, PostgreSQL, a model, or the candidate CLI/app. Logs persist.
set -euo pipefail

compat_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$compat_dir" rev-parse --show-toplevel)"
released_revision=78701be8c9111fad0926fba3206dc1ab5b59be35
fixture_patch="$compat_dir/v0.7.12-provider-credentials.patch"
test "$(git -C "$repo_root" rev-parse 'v0.7.12^{commit}')" = "$released_revision"
results_dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-v0712-credentials-results.XXXXXX")}"
mkdir -p "$results_dir"
results_dir="$(cd "$results_dir" && pwd)"
checkout_parent="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-v0712-credentials-check.XXXXXX")"
released="$checkout_parent/released"
cleanup() {
  git -C "$repo_root" worktree remove --force "$released" >/dev/null 2>&1 || true
  rmdir "$checkout_parent" 2>/dev/null || true
}
trap cleanup EXIT

git -C "$repo_root" worktree add --quiet --detach "$released" "$released_revision"
git -C "$released" apply --check "$fixture_patch"
cp "$compat_dir/testdata/v0.7.12_provider_credentials_test.go" "$released/e2e/testbed/reverse_compat_provider_credentials_test.go"
printf 'Validation logs: %s\n' "$results_dir"

# The same process probe must fail on the unmodified released suite for the
# concrete inherited-account/issuer mismatch, not an unrelated compile error.
if (cd "$released" && go test -mod=readonly ./e2e/testbed -count=1 -v -timeout 60s -p=1 \
    -run '^TestReverseCompatProviderCredentials$/complete$') >"$results_dir/unpatched.log" 2>&1; then
  echo 'ERROR: unpatched fixture unexpectedly passed' >&2
  exit 1
fi
if ! grep -q 'REVERSE_COMPAT_CREDENTIAL_MISMATCH:' "$results_dir/unpatched.log"; then
  cat "$results_dir/unpatched.log"
  echo 'ERROR: baseline failed for a different reason' >&2
  exit 1
fi
echo 'PASS: retained expected unpatched credential mismatch'

git -C "$released" apply "$fixture_patch"
test "$(git -C "$released" diff --name-only)" = e2e/testbed/suite.go
git -C "$released" diff --check
if ! (cd "$released" && go test -mod=readonly ./e2e/testbed -count=1 -v -timeout 60s -p=1 \
    -run '^TestReverseCompatProviderCredential') >"$results_dir/patched.log" 2>&1; then
  cat "$results_dir/patched.log"
  exit 1
fi
cat "$results_dir/patched.log"
# Compile the actual released E2E callers too, but select no model tests.
if ! (cd "$released" && go test -mod=readonly ./e2e -count=1 -timeout 60s -p=1 \
    -run '^$') >"$results_dir/e2e-compile.log" 2>&1; then
  cat "$results_dir/e2e-compile.log"
  exit 1
fi
cat "$results_dir/e2e-compile.log"
# Check again after Go runs; preserve every released source except suite.go.
git -C "$released" diff --exit-code -- coordinator go.mod go.sum
test "$(git -C "$released" diff --name-only)" = e2e/testbed/suite.go
{
  printf 'Released commit: %s\n' "$(git -C "$released" rev-parse HEAD)"
  printf 'Released coordinator tree: %s\n' "$(git -C "$released" rev-parse HEAD:coordinator)"
  printf 'Changed tracked paths:\n'
  git -C "$released" diff --name-only
  printf 'PASS: coordinator source unchanged; only released suite.go patched\n'
  printf 'PASS: fixture paths isolated; candidate CLI/app never invoked or modified\n'
} | tee "$results_dir/provenance.log"
