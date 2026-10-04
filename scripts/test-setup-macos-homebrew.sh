#!/usr/bin/env bash
# Offline tests for setup-macos-homebrew.sh:
# 1. brew is already on PATH: export its environment and download nothing.
# 2. brew is missing: run a local fake installer through to script exit, so the
#    EXIT trap runs after install_brew has returned.
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

# Install path. PATH holds only system tools and stubs, so no real brew is found.
install_prefix="$TEST_ROOT/installed"
runner_temp="$TEST_ROOT/runner-temp"
mkdir -p "$TEST_ROOT/stubs" "$runner_temp"
# The install path runs only on macOS; let it run on the Linux CI runner too.
printf '#!/bin/sh\necho Darwin\n' > "$TEST_ROOT/stubs/uname"
chmod +x "$TEST_ROOT/stubs/uname"

fake_installer="$TEST_ROOT/install.sh"
cat > "$fake_installer" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
printf 'NONINTERACTIVE=%s HOMEBREW_NO_ANALYTICS=%s\n' "\$NONINTERACTIVE" "\$HOMEBREW_NO_ANALYTICS" > "$TEST_ROOT/installer-ran"
mkdir -p "$install_prefix/bin"
sed "s|$prefix|$install_prefix|g" "$prefix/bin/brew" > "$install_prefix/bin/brew"
chmod +x "$install_prefix/bin/brew"
FAKE
fake_sha256=$(shasum -a 256 "$fake_installer" | cut -d' ' -f1)

run_install() {
  env PATH="$TEST_ROOT/stubs:/usr/bin:/bin" \
    GITHUB_PATH="$github_path" GITHUB_ENV="$github_env" RUNNER_TEMP="$runner_temp" \
    SETUP_MACOS_HOMEBREW_TEST=1 \
    SETUP_MACOS_HOMEBREW_INSTALLER_URL="file://$fake_installer" \
    SETUP_MACOS_HOMEBREW_INSTALLER_SHA256="$1" \
    SETUP_MACOS_HOMEBREW_LOCATIONS="$install_prefix/bin/brew" \
    "$ROOT/scripts/setup-macos-homebrew.sh"
}

# A wrong checksum must stop the step before the installer runs.
if run_install "$(printf '%064d' 0)" >/dev/null 2>&1; then
  echo 'setup accepted an installer with the wrong SHA-256' >&2
  exit 1
fi
[ ! -e "$TEST_ROOT/installer-ran" ]
# The EXIT trap removed the downloaded installer on the failure path.
[ -z "$(ls -A "$runner_temp")" ]

: > "$github_path"
: > "$github_env"
if ! install_out=$(run_install "$fake_sha256" 2>&1); then
  printf 'install path failed:\n%s\n' "$install_out" >&2
  exit 1
fi
grep -Fxq 'NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1' "$TEST_ROOT/installer-ran"
grep -Fxq "HOMEBREW_PREFIX=$install_prefix" "$github_env"
grep -Fxq "$install_prefix/bin" "$github_path"
# The EXIT trap removed the downloaded installer on the success path.
[ -z "$(ls -A "$runner_temp")" ]

echo 'setup-macos-homebrew: ok'
