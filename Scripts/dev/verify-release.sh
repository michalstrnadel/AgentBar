#!/bin/bash
# Checks that a release asset is the bundle CI built, re-signed and nothing else.
# Usage: Scripts/dev/verify-release.sh <ci AgentBar.app.zip> <release AgentBar.app.zip>
#
# CI builds and attests an ad-hoc-signed bundle; the release is that bundle signed
# here with "AgentBar Local Signing" (see CONTRIBUTING.md, Releases). A signature
# cannot be compared byte for byte — removing one leaves the __LINKEDIT size it had
# — so both copies are re-signed ad-hoc, which is deterministic, and then compared:
# every file outside the signature must match, and each architecture's CDHash (the
# hash over the code pages and headers) must be the same. The release copy must
# also carry the project's signature and both architectures.
#
# Exits non-zero and says why on any difference. Runs locally and in
# .github/workflows/release-provenance.yml.
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <ci.zip> <release.zip>" >&2; exit 2; }
CI_ZIP="$1"
REL_ZIP="$2"
IDENTITY="${AGENTBAR_SIGN_ID:-AgentBar Local Signing}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/ci" "$WORK/rel"
ditto -xk "$CI_ZIP" "$WORK/ci"
ditto -xk "$REL_ZIP" "$WORK/rel"
CI_APP="$WORK/ci/AgentBar.app"
REL_APP="$WORK/rel/AgentBar.app"
BIN="Contents/MacOS/AgentBar"
for app in "$CI_APP" "$REL_APP"; do
  [ -f "$app/$BIN" ] || { echo "✗ no $BIN in $app" >&2; exit 1; }
done

fail() { echo "✗ $*" >&2; exit 1; }

# The release as published: intact signature, the project's identity, universal.
codesign --verify --deep --strict "$REL_APP" 2>/dev/null \
  || fail "release bundle does not pass codesign --verify --deep --strict"
# Captured, not piped into grep -q: that exits early and pipefail reads the
# resulting SIGPIPE in codesign as a failure.
SIGNATURE="$(codesign -dvvv "$REL_APP" 2>&1)"
grep -qx "Authority=$IDENTITY" <<<"$SIGNATURE" \
  || fail "release bundle is not signed by \"$IDENTITY\""
ARCHS="$(lipo -archs "$REL_APP/$BIN")"
[ "$ARCHS" = "x86_64 arm64" ] || fail "release binary is \"$ARCHS\", not \"x86_64 arm64\""

# Everything but the binary and the signature must be the same bytes. A notarized
# release also carries Contents/CodeResources, the ticket `stapler` attaches.
if ! DIFF="$(diff -r -x _CodeSignature -x AgentBar -x CodeResources "$CI_APP" "$REL_APP")"; then
  echo "$DIFF" >&2
  fail "bundle contents differ outside the signature"
fi
# -x AgentBar also skipped any other file of that name; the binary is compared below,
# and nothing else in the bundle may be called that.
[ "$(find "$CI_APP" "$REL_APP" -name AgentBar -not -path "*/Contents/MacOS/AgentBar" | wc -l)" -eq 0 ] \
  || fail "unexpected file named AgentBar inside the bundle"
# Same for -x CodeResources: the ticket may sit at Contents/CodeResources of the
# release and nowhere else, and the CI build has none.
[ "$(find "$CI_APP" "$REL_APP" -name CodeResources -not -path "*/_CodeSignature/CodeResources" \
     -not -path "$REL_APP/Contents/CodeResources" | wc -l)" -eq 0 ] \
  || fail "unexpected file named CodeResources inside the bundle"

# The binary: same code once both carry the same (ad-hoc) signature.
for side in ci rel; do
  ditto "$WORK/$side/AgentBar.app" "$WORK/$side-adhoc.app"
  codesign --force --deep -s - "$WORK/$side-adhoc.app" 2>/dev/null
done
for arch in x86_64 arm64; do
  a="$(codesign -dvvv --arch "$arch" "$WORK/ci-adhoc.app" 2>&1 | sed -n 's/^CDHash=//p')"
  b="$(codesign -dvvv --arch "$arch" "$WORK/rel-adhoc.app" 2>&1 | sed -n 's/^CDHash=//p')"
  [ -n "$a" ] || fail "no CDHash for $arch"
  [ "$a" = "$b" ] || fail "$arch code differs (CDHash $a vs $b)"
  echo "✓ $arch code identical (CDHash $a)"
done

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$REL_APP/Contents/Info.plist")"
echo "✓ AgentBar $VERSION: the release is the CI build, signed by \"$IDENTITY\""
