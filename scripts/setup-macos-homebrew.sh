#!/usr/bin/env bash
# Find Homebrew on a macOS CI runner, or install it from a pinned installer,
# and export its environment to later steps. Replaces the setup-homebrew
# action, which the organization Actions policy does not allow.
set -euo pipefail

: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

# Homebrew/install commit and the SHA-256 of its install.sh. Change both together.
installer_commit=f6632bc2e9afc0ba20cdee1f2d28bcd7672b3245
installer_sha256=fa4ed743b4ca38316c8f32fd6623baa5bbb928fd4a47ad9f49c2be78ea833449
installer_url="https://raw.githubusercontent.com/Homebrew/install/$installer_commit/install.sh"
brew_locations=(/opt/homebrew/bin/brew /usr/local/bin/brew)

# Test-only overrides for scripts/test-setup-macos-homebrew.sh. CI never sets
# SETUP_MACOS_HOMEBREW_TEST, so the pinned values above always apply there.
if [ "${SETUP_MACOS_HOMEBREW_TEST:-}" = 1 ]; then
  installer_url="${SETUP_MACOS_HOMEBREW_INSTALLER_URL:-$installer_url}"
  installer_sha256="${SETUP_MACOS_HOMEBREW_INSTALLER_SHA256:-$installer_sha256}"
  read -r -a brew_locations <<< "${SETUP_MACOS_HOMEBREW_LOCATIONS:-${brew_locations[*]}}"
fi

find_brew() {
  local candidate
  if candidate="$(command -v brew)"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in "${brew_locations[@]}"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

install_brew() {
  if [ "$(uname -s)" != Darwin ]; then
    echo 'Homebrew bootstrap requires macOS' >&2
    exit 2
  fi
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  # Global, not local: the EXIT trap runs after this function returns.
  installer="$(mktemp "$RUNNER_TEMP/homebrew-install.XXXXXX")"
  trap 'rm -f "$installer"' EXIT
  curl --fail --silent --show-error --location --retry 3 --max-time 180 \
    "$installer_url" \
    --output "$installer"
  # Verify before executing.
  printf '%s  %s\n' "$installer_sha256" "$installer" | shasum -a 256 --check
  NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 /bin/bash "$installer"
}

if ! brew_bin="$(find_brew)"; then
  install_brew
  if ! brew_bin="$(find_brew)"; then
    echo 'Homebrew installer finished but brew was not found' >&2
    exit 1
  fi
fi

eval "$("$brew_bin" shellenv bash)"
: "${HOMEBREW_PREFIX:?brew shellenv did not set HOMEBREW_PREFIX}"
"$brew_bin" --version
{
  printf 'HOMEBREW_PREFIX=%s\n' "$HOMEBREW_PREFIX"
  printf 'HOMEBREW_CELLAR=%s\n' "${HOMEBREW_CELLAR:-$HOMEBREW_PREFIX/Cellar}"
  printf 'HOMEBREW_REPOSITORY=%s\n' "${HOMEBREW_REPOSITORY:-$HOMEBREW_PREFIX}"
} >> "$GITHUB_ENV"
printf '%s\n' "$HOMEBREW_PREFIX/sbin" "$HOMEBREW_PREFIX/bin" >> "$GITHUB_PATH"
