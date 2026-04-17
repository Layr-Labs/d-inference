#!/bin/bash
# Tests for install.sh PBS fallback logic (issue #45).
#
# Unit tests verify the condition in isolation.
# Integration tests extract the real Python-install section from install.sh
# and run it with mocked curl/binaries to verify end-to-end behaviour.
#
# Scenarios:
#   1. PYTHON_BIN does not exist        → PBS fallback MUST trigger
#   2. PYTHON_BIN exists but broken      → PBS fallback MUST trigger
#   3. PYTHON_BIN exists and works       → PBS fallback MUST NOT trigger
#
# Usage: bash scripts/test-install-pbs-fallback.sh

set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────

cleanup() {
    rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected=$expected got=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected output to contain '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  FAIL: $label (output should NOT contain '$needle')"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    fi
}

# ── Setup temp dir ───────────────────────────────────────────

TMPDIR_TEST=$(mktemp -d)
GOOD_PYTHON="$TMPDIR_TEST/good_python"
BAD_PYTHON="$TMPDIR_TEST/bad_python"
MISSING_PYTHON="$TMPDIR_TEST/no_such_python"

# Create a "good" python — accepts -c and exits 0
cat > "$GOOD_PYTHON" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$GOOD_PYTHON"

# Create a "bad" python — exists but always fails
cat > "$BAD_PYTHON" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$BAD_PYTHON"

# ── Build test snippets ─────────────────────────────────────

# Snippet using the FIXED condition (what install.sh should have now)
build_fixed_snippet() {
    local python_bin="$1"
    cat <<SNIPPET
#!/bin/bash
set -euo pipefail
PYTHON_BIN="$python_bin"
PBS_TRIGGERED=no
if ! { [ -f "\$PYTHON_BIN" ] && "\$PYTHON_BIN" -c "print('ok')" 2>/dev/null; }; then
    PBS_TRIGGERED=yes
fi
echo "\$PBS_TRIGGERED"
SNIPPET
}

# Snippet using the OLD (broken) condition for regression proof
build_old_snippet() {
    local python_bin="$1"
    cat <<SNIPPET
#!/bin/bash
set -euo pipefail
PYTHON_BIN="$python_bin"
PBS_TRIGGERED=no
if [ -f "\$PYTHON_BIN" ] && ! "\$PYTHON_BIN" -c "print('ok')" 2>/dev/null; then
    PBS_TRIGGERED=yes
fi
echo "\$PBS_TRIGGERED"
SNIPPET
}

# ══════════════════════════════════════════════════════════════
# UNIT TESTS — condition logic in isolation
# ══════════════════════════════════════════════════════════════

echo ""
echo "=== Unit: FIXED condition ==="
echo ""

RESULT=$(build_fixed_snippet "$MISSING_PYTHON" | bash)
assert_eq "missing binary triggers PBS fallback" "yes" "$RESULT"

RESULT=$(build_fixed_snippet "$BAD_PYTHON" | bash)
assert_eq "broken binary triggers PBS fallback" "yes" "$RESULT"

RESULT=$(build_fixed_snippet "$GOOD_PYTHON" | bash)
assert_eq "working binary skips PBS fallback" "no" "$RESULT"

echo ""
echo "=== Unit: OLD condition (regression proof) ==="
echo ""

RESULT=$(build_old_snippet "$MISSING_PYTHON" | bash)
assert_eq "OLD: missing binary FAILS to trigger (demonstrates bug)" "no" "$RESULT"

RESULT=$(build_old_snippet "$BAD_PYTHON" | bash)
assert_eq "OLD: broken binary triggers" "yes" "$RESULT"

RESULT=$(build_old_snippet "$GOOD_PYTHON" | bash)
assert_eq "OLD: working binary skips" "no" "$RESULT"

# ══════════════════════════════════════════════════════════════
# INTEGRATION TESTS — extract real install.sh section, mock externals
# ══════════════════════════════════════════════════════════════
#
# We extract lines 187–251 (the Python runtime + PBS fallback section)
# from scripts/install.sh and run them with:
#   - INSTALL_DIR pointing at a temp dir
#   - A fake curl that simulates coordinator 404s and PBS success
#   - PYTHON_BIN / PBS_URL overridden to our stubs

INSTALL_SH="$SCRIPT_DIR/install.sh"

echo ""
echo "=== Integration: coordinator 404 → PBS fallback triggers ==="
echo ""

# Set up a fake install dir and mock curl
INT_DIR="$TMPDIR_TEST/integration1"
MOCK_BIN="$TMPDIR_TEST/mock_bin1"
mkdir -p "$INT_DIR" "$MOCK_BIN"

# Mock curl: coordinator URLs fail (-f makes curl return non-zero on 404),
# PBS URL succeeds by creating a fake python tree.
cat > "$MOCK_BIN/curl" <<MOCK
#!/bin/bash
# Simulate: coordinator downloads fail, PBS download succeeds
for arg in "\$@"; do
    case "\$arg" in
        */dl/eigeninference-python-runtime.tar.gz|*/dl/dginf-python-runtime.tar.gz)
            exit 22  # curl -f returns 22 on HTTP 404
            ;;
        *python-build-standalone*)
            # Find the -o argument (output file)
            OUTPUT=""
            FOUND_O=false
            for a in "\$@"; do
                if [ "\$FOUND_O" = true ]; then
                    OUTPUT="\$a"
                    break
                fi
                [ "\$a" = "-o" ] && FOUND_O=true
            done
            if [ -n "\$OUTPUT" ]; then
                # Create a tarball with a fake python binary inside
                FAKE_ROOT="\$(mktemp -d)"
                mkdir -p "\$FAKE_ROOT/bin"
                mkdir -p "\$FAKE_ROOT/lib/python3.12"
                printf '#!/bin/bash\nexit 0\n' > "\$FAKE_ROOT/bin/python3.12"
                chmod +x "\$FAKE_ROOT/bin/python3.12"
                tar czf "\$OUTPUT" -C "\$FAKE_ROOT" .
                rm -rf "\$FAKE_ROOT"
            fi
            exit 0
            ;;
        *eigeninference-site-packages.tar.gz*)
            # Site-packages download succeeds (empty tarball is fine for test)
            OUTPUT=""
            FOUND_O=false
            for a in "\$@"; do
                if [ "\$FOUND_O" = true ]; then
                    OUTPUT="\$a"
                    break
                fi
                [ "\$a" = "-o" ] && FOUND_O=true
            done
            if [ -n "\$OUTPUT" ]; then
                FAKE_ROOT="\$(mktemp -d)"
                touch "\$FAKE_ROOT/dummy.py"
                tar czf "\$OUTPUT" -C "\$FAKE_ROOT" .
                rm -rf "\$FAKE_ROOT"
            fi
            exit 0
            ;;
    esac
done
# Default: fail (unknown URL)
exit 1
MOCK
chmod +x "$MOCK_BIN/curl"

# Extract the Python install section (step 3, lines 187–251) from install.sh
# and wrap it so we can run it with our mocks.
cat > "$TMPDIR_TEST/run_integration1.sh" <<HARNESS
#!/bin/bash
set -euo pipefail
export PATH="$MOCK_BIN:\$PATH"
COORD_URL="https://api.darkbloom.dev"
INSTALL_DIR="$INT_DIR"
PYTHON_BIN="$INT_DIR/python/bin/python3.12"
PBS_TAG="20260408"
PBS_PYTHON_VERSION="3.12.13"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/\${PBS_TAG}/cpython-\${PBS_PYTHON_VERSION}+\${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
VERSION="0.3.8"

$(sed -n '188,251p' "$INSTALL_SH")
HARNESS
chmod +x "$TMPDIR_TEST/run_integration1.sh"

OUTPUT=$(bash "$TMPDIR_TEST/run_integration1.sh" 2>&1) || true

# The PBS fallback should have run and created python
assert_contains "integration: PBS fallback message printed" "Python runtime missing or broken" "$OUTPUT"
assert_contains "integration: portable Python installed" "Portable Python installed" "$OUTPUT"
assert_eq "integration: python binary created" "yes" \
    "$([ -f "$INT_DIR/python/bin/python3.12" ] && echo yes || echo no)"

echo ""
echo "=== Integration: working Python skips both downloads ==="
echo ""

INT_DIR2="$TMPDIR_TEST/integration2"
mkdir -p "$INT_DIR2/python/bin"
# Pre-install a working python
cp "$GOOD_PYTHON" "$INT_DIR2/python/bin/python3.12"

# Mock curl that logs calls (should NOT be called at all)
MOCK_BIN2="$TMPDIR_TEST/mock_bin2"
mkdir -p "$MOCK_BIN2"
cat > "$MOCK_BIN2/curl" <<'MOCK2'
#!/bin/bash
echo "UNEXPECTED_CURL_CALL: $*" >&2
exit 1
MOCK2
chmod +x "$MOCK_BIN2/curl"

cat > "$TMPDIR_TEST/run_integration2.sh" <<HARNESS
#!/bin/bash
set -euo pipefail
export PATH="$MOCK_BIN2:\$PATH"
COORD_URL="https://api.darkbloom.dev"
INSTALL_DIR="$INT_DIR2"
PYTHON_BIN="$INT_DIR2/python/bin/python3.12"
PBS_TAG="20260408"
PBS_PYTHON_VERSION="3.12.13"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/\${PBS_TAG}/cpython-\${PBS_PYTHON_VERSION}+\${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
VERSION="0.3.8"

# The pre-check at line 192 passes → skips to line 214.
# The PBS check at line 217 also passes → skips to line 251.
$(sed -n '188,251p' "$INSTALL_SH")
HARNESS
chmod +x "$TMPDIR_TEST/run_integration2.sh"

OUTPUT2=$(bash "$TMPDIR_TEST/run_integration2.sh" 2>&1) || true

assert_contains "integration: existing python recognized" "Python runtime" "$OUTPUT2"
assert_not_contains "integration: no PBS fallback for working python" "python-build-standalone" "$OUTPUT2"
assert_not_contains "integration: curl not called" "UNEXPECTED_CURL_CALL" "$OUTPUT2"

echo ""
echo "=== Integration: broken Python triggers PBS fallback ==="
echo ""

INT_DIR3="$TMPDIR_TEST/integration3"
MOCK_BIN3="$TMPDIR_TEST/mock_bin3"
mkdir -p "$INT_DIR3/python/bin" "$MOCK_BIN3"

# Pre-install a broken python
cp "$BAD_PYTHON" "$INT_DIR3/python/bin/python3.12"

# Mock curl: coordinator fails, PBS succeeds (same as integration1)
cp "$MOCK_BIN/curl" "$MOCK_BIN3/curl"

cat > "$TMPDIR_TEST/run_integration3.sh" <<HARNESS
#!/bin/bash
set -euo pipefail
export PATH="$MOCK_BIN3:\$PATH"
COORD_URL="https://api.darkbloom.dev"
INSTALL_DIR="$INT_DIR3"
PYTHON_BIN="$INT_DIR3/python/bin/python3.12"
PBS_TAG="20260408"
PBS_PYTHON_VERSION="3.12.13"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/\${PBS_TAG}/cpython-\${PBS_PYTHON_VERSION}+\${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
VERSION="0.3.8"

$(sed -n '188,251p' "$INSTALL_SH")
HARNESS
chmod +x "$TMPDIR_TEST/run_integration3.sh"

OUTPUT3=$(bash "$TMPDIR_TEST/run_integration3.sh" 2>&1) || true

assert_contains "integration: broken python detected" "Python runtime missing or broken" "$OUTPUT3"
assert_contains "integration: PBS replaces broken python" "Portable Python installed" "$OUTPUT3"

# ══════════════════════════════════════════════════════════════
# SOURCE VERIFICATION — both install.sh copies have the fix
# ══════════════════════════════════════════════════════════════

echo ""
echo "=== Source verification ==="
echo ""

for f in "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/../coordinator/internal/api/install.sh"; do
    if [ ! -f "$f" ]; then
        echo "  SKIP: $f not found"
        continue
    fi
    fname=$(basename "$(dirname "$f")")/$(basename "$f")
    if grep -q 'if ! { \[ -f "\$PYTHON_BIN" \] && "\$PYTHON_BIN" -c "print' "$f"; then
        assert_eq "$fname has fixed condition" "yes" "yes"
    else
        assert_eq "$fname has fixed condition" "yes" "no"
    fi
    if grep -q 'if \[ -f "\$PYTHON_BIN" \] && ! "\$PYTHON_BIN" -c "print' "$f"; then
        assert_eq "$fname old condition removed" "gone" "still present"
    else
        assert_eq "$fname old condition removed" "gone" "gone"
    fi
done

# ── Both install.sh files must stay in sync on PBS fallback ──

SCRIPTS_CONDITION=$(grep -n 'if.*PYTHON_BIN.*print' "$SCRIPT_DIR/install.sh" | head -2)
API_CONDITION=$(grep -n 'if.*PYTHON_BIN.*print' "$SCRIPT_DIR/../coordinator/internal/api/install.sh" | head -2)

# Extract just the conditions (strip line numbers for comparison)
SCRIPTS_COND_ONLY=$(echo "$SCRIPTS_CONDITION" | sed 's/^[0-9]*://')
API_COND_ONLY=$(echo "$API_CONDITION" | sed 's/^[0-9]*://')

if [ "$SCRIPTS_COND_ONLY" = "$API_COND_ONLY" ]; then
    assert_eq "install.sh copies have matching PBS conditions" "yes" "yes"
else
    assert_eq "install.sh copies have matching PBS conditions" "yes" "no"
fi

# ── Summary ──────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
