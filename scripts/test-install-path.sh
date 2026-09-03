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
    local path_line='export PATH="$HOME/.darkbloom/bin:$PATH"'
    [ -f "$file" ] || fail "expected $file to exist"
    grep -Fqx "$path_line" "$file" \
        || fail "$file missing active ~/.darkbloom/bin PATH export"
}

assert_fish_has_path() {
    local file=$1
    local path_line='set -gx PATH "$HOME/.darkbloom/bin" $PATH'
    [ -f "$file" ] || fail "expected $file to exist"
    grep -Fqx "$path_line" "$file" \
        || fail "$file missing active ~/.darkbloom/bin fish PATH command"
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

file_mode() {
    case "$(uname)" in
        Darwin) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
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

# The selected login file is sourced directly: host /etc/profile files can
# overwrite HOME, which makes `bash --login` unsuitable for an isolated test.
assert_file_missing "$TWEET/.bash_login"

# --- Prefer existing ~/.profile over creating ~/.bash_profile --------------
PROFILE_HOME="$ROOT/profile"
mkdir -p "$PROFILE_HOME"
printf '# existing profile\n' > "$PROFILE_HOME/.profile"
seed_binary "$PROFILE_HOME"
run_setup "$PROFILE_HOME"
assert_file_has_path "$PROFILE_HOME/.profile"
assert_file_missing "$PROFILE_HOME/.bash_profile"
assert_command_on_path "$PROFILE_HOME" "$PROFILE_HOME/.profile"

# --- Prefer existing ~/.bash_login over creating ~/.bash_profile -----------
BASH_LOGIN="$ROOT/bash-login"
mkdir -p "$BASH_LOGIN"
printf '# existing bash_login\n' > "$BASH_LOGIN/.bash_login"
seed_binary "$BASH_LOGIN"
run_setup "$BASH_LOGIN"
assert_file_has_path "$BASH_LOGIN/.bash_login"
assert_file_missing "$BASH_LOGIN/.bash_profile"
assert_command_on_path "$BASH_LOGIN" "$BASH_LOGIN/.bash_login"

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
assert_fish_has_path "$FISH/.config/fish/config.fish"

# --- Idempotent: second run does not duplicate -----------------------------
run_setup "$TWEET"
assert_single_marker "$TWEET/.zshrc"
assert_single_marker "$TWEET/.bashrc"
assert_single_marker "$TWEET/.bash_profile"

# --- A commented mention does not suppress the active managed export -------
COMMENTED="$ROOT/commented"
mkdir -p "$COMMENTED"
cat > "$COMMENTED/.zshrc" <<'RC'
# export PATH="$HOME/.darkbloom/bin:$PATH"
# ~/.darkbloom/bin is installed by Darkbloom.
RC
seed_binary "$COMMENTED"
run_setup "$COMMENTED"
assert_file_has_path "$COMMENTED/.zshrc"
assert_command_on_path "$COMMENTED" "$COMMENTED/.zshrc"
[ "$(grep -Fxc 'export PATH="$HOME/.darkbloom/bin:$PATH"' "$COMMENTED/.zshrc")" = "1" ] \
    || fail "commented PATH mention suppressed or duplicated the managed export"

# --- Existing metadata and symlinked dotfiles are preserved ----------------
METADATA="$ROOT/metadata"
DOTFILES="$ROOT/dotfiles"
mkdir -p "$METADATA" "$DOTFILES"
printf 'export PRIVATE_SHELL_VALUE=secret\n' > "$DOTFILES/zshrc"
chmod 0600 "$DOTFILES/zshrc"
ln -s "$DOTFILES/zshrc" "$METADATA/.zshrc"
seed_binary "$METADATA"
run_setup "$METADATA"
[ -L "$METADATA/.zshrc" ] || fail "installer replaced symlinked ~/.zshrc"
[ "$(readlink "$METADATA/.zshrc")" = "$DOTFILES/zshrc" ] \
    || fail "installer changed ~/.zshrc symlink target"
[ "$(file_mode "$DOTFILES/zshrc")" = "600" ] \
    || fail "installer changed ~/.zshrc target mode"
grep -Fqx 'export PRIVATE_SHELL_VALUE=secret' "$DOTFILES/zshrc" \
    || fail "installer lost existing shell configuration"
assert_file_has_path "$METADATA/.zshrc"

# --- Legacy lines remain intact; Darkbloom is prepended independently -------
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
grep -Fqx 'export PATH="$HOME/.eigeninference/bin:$PATH"' "$LEGACY/.zshrc" \
    || fail "installer rewrote legacy PATH configuration"
grep -Fqx 'alias eigeninf=eigeninference' "$LEGACY/.zshrc" \
    || fail "installer rewrote legacy alias configuration"

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
