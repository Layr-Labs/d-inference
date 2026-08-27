#!/bin/bash
# Isolated PATH-setup tests for scripts/install.sh.
# Reproduces the bash-login "command not found" after curl | bash and
# checks zsh/fish/idempotency/symlink behavior without touching the host.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER="$REPO_ROOT/scripts/install.sh"
"$REPO_ROOT/scripts/sync-install-embed.sh" check

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-install-path.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_has_path() {
    local file=$1
    [ -f "$file" ] || fail "expected $file to exist"
    grep -q '\.darkbloom/bin' "$file" || fail "$file missing ~/.darkbloom/bin PATH entry"
}

assert_file_missing() {
    local file=$1
    [ ! -e "$file" ] || fail "expected $file to be absent"
}

assert_single_marker() {
    local file=$1
    local count
    count=$(grep -c '# Darkbloom' "$file" || true)
    [ "$count" = "1" ] || fail "$file has $count Darkbloom markers, want 1"
}

assert_command_on_path() {
    local home=$1
    local rc=$2
    local found
    found=$(HOME="$home" bash --noprofile --norc -c "set -euo pipefail; source \"$rc\"; command -v darkbloom") \
        || fail "sourcing $rc did not put darkbloom on PATH"
    [ "$found" = "$home/.darkbloom/bin/darkbloom" ] \
        || fail "expected $home/.darkbloom/bin/darkbloom, got $found"
}

seed_binary() {
    local home=$1
    mkdir -p "$home/.darkbloom/bin"
    printf '#!/bin/sh\necho darkbloom\n' > "$home/.darkbloom/bin/darkbloom"
    chmod +x "$home/.darkbloom/bin/darkbloom"
}

run_setup() {
    local home=$1
    shift
    HOME="$home" "$@" bash "$INSTALLER" --setup-path-test "$home"
}

# --- Tweet regression: zshrc exists, login shell is bash -------------------
# Old installer wrote only ~/.zshrc when that file existed. A bash login
# shell (macOS Terminal after chsh / Terminal.app → bash) never reads it.
TWEET="$ROOT/tweet"
mkdir -p "$TWEET"
printf 'export HISTSIZE=500\n' > "$TWEET/.zshrc"
seed_binary "$TWEET"
run_setup "$TWEET"

assert_file_has_path "$TWEET/.zshrc"
assert_file_has_path "$TWEET/.bashrc"
assert_file_has_path "$TWEET/.bash_profile"
assert_file_missing "$TWEET/.profile"
assert_single_marker "$TWEET/.zshrc"
assert_single_marker "$TWEET/.bash_profile"
assert_command_on_path "$TWEET" "$TWEET/.bash_profile"
assert_command_on_path "$TWEET" "$TWEET/.bashrc"
assert_command_on_path "$TWEET" "$TWEET/.zshrc"

# bash --login reads .bash_profile, not .zshrc
LOGIN_FOUND=$(HOME="$TWEET" bash --login -c 'command -v darkbloom' \
    || true)
[ "$LOGIN_FOUND" = "$TWEET/.darkbloom/bin/darkbloom" ] \
    || fail "bash --login did not find darkbloom (tweet regression); got ${LOGIN_FOUND:-empty}"

# --- Prefer existing ~/.profile over creating ~/.bash_profile --------------
PROFILE_HOME="$ROOT/profile"
mkdir -p "$PROFILE_HOME"
printf '# existing profile\n' > "$PROFILE_HOME/.profile"
seed_binary "$PROFILE_HOME"
run_setup "$PROFILE_HOME"
assert_file_has_path "$PROFILE_HOME/.profile"
assert_file_missing "$PROFILE_HOME/.bash_profile"
assert_command_on_path "$PROFILE_HOME" "$PROFILE_HOME/.profile"

# --- Existing bash_profile + profile both get patched ----------------------
BOTH="$ROOT/both"
mkdir -p "$BOTH"
printf '# bash_profile\n' > "$BOTH/.bash_profile"
printf '# profile\n' > "$BOTH/.profile"
seed_binary "$BOTH"
run_setup "$BOTH"
assert_file_has_path "$BOTH/.bash_profile"
assert_file_has_path "$BOTH/.profile"

# --- Existing zprofile is patched; we do not create one --------------------
ZPROFILE="$ROOT/zprofile"
mkdir -p "$ZPROFILE"
printf 'eval true\n' > "$ZPROFILE/.zprofile"
seed_binary "$ZPROFILE"
run_setup "$ZPROFILE"
assert_file_has_path "$ZPROFILE/.zprofile"
assert_file_has_path "$ZPROFILE/.zshrc"

# --- Fish config is patched when present -----------------------------------
FISH="$ROOT/fish"
mkdir -p "$FISH/.config/fish"
printf '# fish\n' > "$FISH/.config/fish/config.fish"
seed_binary "$FISH"
run_setup "$FISH"
assert_file_has_path "$FISH/.config/fish/config.fish"
grep -q 'set -gx PATH' "$FISH/.config/fish/config.fish" \
    || fail "fish config missing set -gx PATH"

# --- Idempotent: second run does not duplicate -----------------------------
run_setup "$TWEET"
assert_single_marker "$TWEET/.zshrc"
assert_single_marker "$TWEET/.bashrc"
assert_single_marker "$TWEET/.bash_profile"

# --- Legacy eigeninference lines are replaced ------------------------------
LEGACY="$ROOT/legacy"
mkdir -p "$LEGACY"
cat > "$LEGACY/.zshrc" <<'RC'
# EigenInference
export PATH="$HOME/.eigeninference/bin:$PATH"
alias eigeninf=eigeninference
RC
seed_binary "$LEGACY"
run_setup "$LEGACY"
assert_file_has_path "$LEGACY/.zshrc"
assert_single_marker "$LEGACY/.zshrc"
grep -q '\.eigeninference/bin' "$LEGACY/.zshrc" \
    && fail "legacy eigeninference PATH survived"
grep -q 'alias eigeninf' "$LEGACY/.zshrc" \
    && fail "legacy eigeninf alias survived"

# --- Symlink into a writable dir already on PATH ---------------------------
LINK_HOME="$ROOT/link"
LINK_BIN="$ROOT/path-bin"
mkdir -p "$LINK_HOME" "$LINK_BIN"
seed_binary "$LINK_HOME"
DARKBLOOM_PATH_LINK_CANDIDATES="$LINK_BIN" \
    PATH="$LINK_BIN:/usr/bin:/bin" \
    run_setup "$LINK_HOME"
[ -L "$LINK_BIN/darkbloom" ] || fail "expected symlink at $LINK_BIN/darkbloom"
TARGET=$(readlink "$LINK_BIN/darkbloom")
[ "$TARGET" = "$LINK_HOME/.darkbloom/bin/darkbloom" ] \
    || fail "symlink target $TARGET"

# Parent-equivalent PATH (inherited dirs only, no ~/.darkbloom/bin) finds it
FOUND_VIA_LINK=$(PATH="$LINK_BIN:/usr/bin:/bin" command -v darkbloom) \
    || fail "darkbloom not visible via PATH symlink"
[ "$FOUND_VIA_LINK" = "$LINK_BIN/darkbloom" ] \
    || fail "command -v resolved $FOUND_VIA_LINK"

# --- Default --setup-path-test does not touch /usr/local/bin ---------------
# Guard: if the host already has that name, don't require it absent; just
# ensure this run did not create a symlink pointing at the fake home.
HOST_LINK=/usr/local/bin/darkbloom
BEFORE_HOST=""
if [ -L "$HOST_LINK" ]; then
    BEFORE_HOST=$(readlink "$HOST_LINK")
fi
SAFE="$ROOT/safe-host"
seed_binary "$SAFE"
run_setup "$SAFE"
if [ -L "$HOST_LINK" ]; then
    AFTER_HOST=$(readlink "$HOST_LINK")
    [ "$AFTER_HOST" != "$SAFE/.darkbloom/bin/darkbloom" ] \
        || fail "setup-path-test wrote host $HOST_LINK"
    [ "$AFTER_HOST" = "$BEFORE_HOST" ] \
        || fail "setup-path-test mutated host $HOST_LINK"
fi

echo "install path tests passed"
