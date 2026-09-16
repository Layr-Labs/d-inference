#!/bin/bash
# Renders the GitHub Release notes heredoc from release-swift.yml the way the
# "Create GitHub Release" step does, and checks that the notes name the source
# commit the bundle was built from. The step itself only runs on a prod tag on a
# macOS runner, so the heredoc is the part CI can exercise.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/release-swift.yml"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-release-notes.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

# Heredoc body, de-indented from the YAML block, with ${{ }} expressions
# (resolved by Actions before the shell runs) replaced by a placeholder.
body=$(awk '/cat > \/tmp\/release-notes.md <<NOTES/{f=1;next} f&&/^ *NOTES$/{exit} f' "$WORKFLOW" |
    sed -e 's/^          //' -e 's/\${{[^}]*}}/EXPR/g')
if [ -z "$body" ]; then
    echo "heredoc not found in $WORKFLOW" >&2
    exit 1
fi

# Same shell flags as the step.
printf 'set -euo pipefail\ncat <<NOTES\n%s\nNOTES\n' "$body" > "$TEST_ROOT/render.sh"

# Every shell variable the heredoc uses except GITHUB_SHA gets a placeholder, so
# a new field needs no fixture here. Both greps may match nothing; that must not
# abort the script under pipefail before the checks below can report.
vars=$(printf '%s\n' "$body" | { grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' || true; } |
    tr -d '${}' | sort -u | { grep -vx GITHUB_SHA || true; } | sed 's/$/=x/')
# env -i: CI exports GITHUB_SHA itself, which would hide the unset case.
render() {
    # shellcheck disable=SC2086 # $vars is NAME=x words, split on purpose
    env -i PATH="$PATH" $vars "$@" bash "$TEST_ROOT/render.sh"
}

SHA=73093957b8f2f7058f9eabab3ab004c3d758ec16
# Capture first: piping into grep -q would SIGPIPE render once grep exits early,
# and pipefail would report that as a missing line.
notes=$(render GITHUB_SHA="$SHA" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=Layr-Labs/d-inference)
if ! grep -qxF "**Commit:**        [\`$SHA\`](https://github.com/Layr-Labs/d-inference/commit/$SHA)" <<<"$notes"; then
    echo "release notes missing the source commit line" >&2
    exit 1
fi

# Never publish notes with an empty commit.
if render >/dev/null 2>&1; then
    echo "release notes rendered without GITHUB_SHA" >&2
    exit 1
fi

echo "release notes: ok"
