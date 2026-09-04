#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PLISTS=(scripts/entitlements.plist provider-swift/entitlements.plist)
GEN=scripts/generate-entitlements.sh

# `! cmd` is exempt from `set -e`, so a negated assertion never fails the script.
# Assert absence through this helper instead.
refute() { if "$@"; then echo "FAIL: expected non-zero from: $*" >&2; exit 1; fi; }

# Never clobber a developer's in-progress edits; the restore below is a hard checkout.
git diff --quiet -- "${PLISTS[@]}" || { echo "entitlements plists have uncommitted changes; commit or stash first" >&2; exit 1; }
trap 'git checkout -- "${PLISTS[@]}"' EXIT

# 1. both vars unset -> byte-identical to what is committed
env -u TEAM_ID -u APPLE_TEAM_ID "$GEN"
git diff --quiet -- "${PLISTS[@]}"

# 2. empty values fall back to the default: an unset Actions variable must not break a release
TEAM_ID= APPLE_TEAM_ID= "$GEN"
git diff --quiet -- "${PLISTS[@]}"

# 3. APPLE_TEAM_ID alone is honoured (release-swift.yml exports exactly this)
env -u TEAM_ID APPLE_TEAM_ID=TEST123456 "$GEN"
grep -q 'TEST123456\.io\.darkbloom\.provider' scripts/entitlements.plist

# 4. TEAM_ID wins, rewrites every occurrence, touches nothing else
TEAM_ID=ZZZZ999999 APPLE_TEAM_ID=TEST123456 "$GEN"
for f in "${PLISTS[@]}"; do
  refute grep -q SLDQ2GJ6TL "$f"
  refute grep -qF '${TEAM_ID}' "$f"
done
[ "$(grep -c 'ZZZZ999999\.io\.darkbloom\.provider' scripts/entitlements.plist)" = 1 ]
[ "$(grep -c 'ZZZZ999999\.io\.darkbloom\.provider' provider-swift/entitlements.plist)" = 2 ]
[ "$(git diff --numstat -- scripts/entitlements.plist | cut -f1,2)" = "$(printf '1\t1')" ]
[ "$(git diff --numstat -- provider-swift/entitlements.plist | cut -f1,2)" = "$(printf '2\t2')" ]

# 5. output parses as a plist and the entitlement values really carry the new prefix
command -v plutil >/dev/null && plutil -lint "${PLISTS[@]}"
python3 - "${PLISTS[@]}" <<'PYCHECK'
import plistlib, sys
want = {
  'scripts/entitlements.plist': ['com.apple.security.keychain-access-groups'],
  'provider-swift/entitlements.plist': ['com.apple.application-identifier', 'keychain-access-groups'],
}
for p in sys.argv[1:]:
    with open(p, 'rb') as fh:
        d = plistlib.load(fh)
    for k in want[p]:
        v = d[k]
        v = v if isinstance(v, str) else v[0]
        assert v == 'ZZZZ999999.io.darkbloom.provider', (p, k, v)
PYCHECK

# 6. malformed IDs are rejected and leave the tree untouched
git checkout -- "${PLISTS[@]}"
for bad in short sldq2gj6tl SLDQ2GJ6TL.io "AB CD123456" 'A$(id)BCDEFGH'; do
  refute env TEAM_ID="$bad" "$GEN"
done
git diff --quiet -- "${PLISTS[@]}"

# 7. check mode: green on a clean tree, red on drift
"$GEN" check
printf '\n' >> provider-swift/entitlements.plist
refute "$GEN" check
git checkout -- "${PLISTS[@]}"

echo "entitlements generation: OK"
