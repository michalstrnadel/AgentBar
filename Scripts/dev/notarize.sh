#!/bin/bash
# Signs a release bundle with a Developer ID, has Apple notarize it, staples the
# ticket and writes the zip users download. Replaces step 3's `codesign` line in
# CONTRIBUTING.md ▸ Releases once an Apple Developer account exists; until then
# releases stay on "AgentBar Local Signing" and this script is not used.
#
#   AGENTBAR_DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   AGENTBAR_NOTARY_PROFILE=agentbar-notary \
#   Scripts/dev/notarize.sh /tmp/rel/AgentBar.app
#
# One-time setup: create the Developer ID Application certificate in Xcode or on
# developer.apple.com, then store the notary credentials in the keychain:
#   xcrun notarytool store-credentials agentbar-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific password>
#
# BEFORE THE FIRST NOTARIZED RELEASE: every copy in the field pins the old
# certificate (UpdateSignature), so it would refuse this one. Ship a bridge release
# first — still signed with "AgentBar Local Signing" — that lists the Developer ID
# requirement in UpdateSignature.successors. This script refuses to run until that
# list names the team it is signing for.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <AgentBar.app>" >&2; exit 2; }
APP="${1%/}"
ID="${AGENTBAR_DEVELOPER_ID:?set AGENTBAR_DEVELOPER_ID to the Developer ID Application identity}"
PROFILE="${AGENTBAR_NOTARY_PROFILE:-agentbar-notary}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENTITLEMENTS="$ROOT/Scripts/dev/AgentBar.entitlements"
fail() { echo "✗ $*" >&2; exit 1; }

[ -d "$APP/Contents/MacOS" ] || fail "$APP is not an app bundle"
TEAM="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$ID")"
[ -n "$TEAM" ] || fail "cannot read a team id from \"$ID\""
grep -q "subject.OU\] = \"$TEAM\"" "$ROOT/Sources/AgentBar/UpdateSignature.swift" \
  || fail "UpdateSignature.successors does not name team $TEAM — ship the bridge release first"

# Hardened runtime and a secure timestamp are what notarization requires. The
# bundle has no nested code — the hooks are scripts, resources — so one signature
# over the bundle is the whole of it; --deep is deprecated for signing.
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$ID" "$APP"
codesign --verify --deep --strict "$APP" || fail "signature does not verify"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/submit.zip"
# --wait prints the verdict; the log says why when it is not "Accepted".
OUT="$(xcrun notarytool submit "$WORK/submit.zip" --keychain-profile "$PROFILE" --wait 2>&1)" || true
echo "$OUT"
if ! grep -q "status: Accepted" <<<"$OUT"; then
  SUB="$(sed -n 's/^ *id: //p' <<<"$OUT" | head -1)"
  [ -n "$SUB" ] && xcrun notarytool log "$SUB" --keychain-profile "$PROFILE" >&2 || true
  fail "notarization was not accepted"
fi

# Stapled so the first launch passes Gatekeeper offline too.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ASSESS="$(spctl -a -vvv -t exec "$APP" 2>&1)" || { echo "$ASSESS" >&2; fail "Gatekeeper rejects it"; }
grep -q "source=Notarized Developer ID" <<<"$ASSESS" || { echo "$ASSESS" >&2; fail "not assessed as notarized"; }

OUT_ZIP="$(dirname "$APP")/AgentBar.app.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT_ZIP"
echo "✓ notarized and stapled: $OUT_ZIP"
echo "  next: AGENTBAR_SIGN_ID=\"$ID\" Scripts/dev/verify-release.sh <ci zip> \"$OUT_ZIP\""
