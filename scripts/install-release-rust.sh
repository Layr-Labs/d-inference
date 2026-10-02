#!/usr/bin/env bash
# Install the reviewed Rust bootstrap and exact parity toolchain on release Macs.
set -euo pipefail

if [ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]; then
  echo 'Release Rust bootstrap requires an Apple Silicon Mac' >&2
  exit 2
fi

bootstrap_dir="$(mktemp -d)"
rustup_init="$bootstrap_dir/rustup-init"
trap 'rm -rf "$bootstrap_dir"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  https://static.rust-lang.org/rustup/archive/1.28.2/aarch64-apple-darwin/rustup-init \
  --output "$rustup_init"
printf '%s  %s\n' \
  '20ef5516c31b1ac2290084199ba77dbbcaa1406c45c1d978ca68558ef5964ef5' \
  "$rustup_init" | shasum -a 256 --check
chmod +x "$rustup_init"
"$rustup_init" -y --no-modify-path --profile minimal --default-toolchain none

export PATH="$HOME/.cargo/bin:$PATH"
printf '%s\n' "$HOME/.cargo/bin" >> "$GITHUB_PATH"
rustup toolchain install 1.88.0 --profile minimal
test "$(rustc +1.88.0 --version | awk '{print $2}')" = 1.88.0
