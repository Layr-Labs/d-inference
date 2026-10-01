#!/usr/bin/env bash
# Offline test: when brew is already on PATH, setup-macos-homebrew.sh exports
# its environment and downloads nothing.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-homebrew.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

prefix="$TEST_ROOT/homebrew"
mkdir -p "$prefix/bin" "$TEST_ROOT/tools"
cat > "$prefix/bin/brew" <<FAKE
#!/usr/bin/env bash
case "\$1" in
  shellenv)
    printf 'export HOMEBREW_PREFIX="%s";\n' "$prefix"
    printf 'export HOMEBREW_CELLAR="%s/Cellar";\n' "$prefix"
    printf 'export HOMEBREW_REPOSITORY="%s";\n' "$prefix"
    ;;
  --version) echo 'Homebrew 0.0.0-test' ;;
  *) echo "unexpected brew call: \$*" >&2; exit 1 ;;
esac
FAKE
# Any download means the script took the install path.
printf '#!/usr/bin/env bash\necho "curl must not run" >&2\nexit 1\n' > "$TEST_ROOT/tools/curl"
chmod +x "$prefix/bin/brew" "$TEST_ROOT/tools/curl"

github_path="$TEST_ROOT/github_path"
github_env="$TEST_ROOT/github_env"
: > "$github_path"
: > "$github_env"

env -u RUNNER_TEMP PATH="$prefix/bin:$TEST_ROOT/tools:$PATH" \
  GITHUB_PATH="$github_path" GITHUB_ENV="$github_env" \
  "$ROOT/scripts/setup-macos-homebrew.sh" >/dev/null

grep -Fxq "HOMEBREW_PREFIX=$prefix" "$github_env"
grep -Fxq "HOMEBREW_CELLAR=$prefix/Cellar" "$github_env"
grep -Fxq "HOMEBREW_REPOSITORY=$prefix" "$github_env"
grep -Fxq "$prefix/bin" "$github_path"
grep -Fxq "$prefix/sbin" "$github_path"

# Missing GitHub output files must fail before any other work.
if env -u GITHUB_ENV PATH="$prefix/bin:$TEST_ROOT/tools:$PATH" GITHUB_PATH="$github_path" \
  "$ROOT/scripts/setup-macos-homebrew.sh" >/dev/null 2>&1; then
  echo 'setup accepted a missing GITHUB_ENV' >&2
  exit 1
fi

echo 'setup-macos-homebrew: ok'
