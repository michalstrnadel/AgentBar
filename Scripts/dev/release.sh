#!/usr/bin/env bash
# One command for CONTRIBUTING.md ▸ Releases, steps 2–8, after the version is bumped
# and the CHANGELOG section dated (step 1) and committed:
#
#   Scripts/dev/release.sh "1.66.0 — what it is"        # sign as SIGNER below says
#
# It refuses a dirty tree, a branch other than main, versions that disagree or a
# CHANGELOG whose top section is not this version. Then: CI on, push, wait for this
# commit's push run to pass (cancelled macOS jobs are rerun), sign the CI bundle,
# check it is the CI build and nothing else, pack and check the disk image, publish
# the release, bump the Homebrew cask, wait for the attestations, CI off.
#
# Every step checks what it made rather than trusting an exit code; any failure
# stops before anything is published, and nothing published is ever deleted.
set -euo pipefail

# Who signs. "local" is the project's own certificate (every release up to 1.65.1);
# "developer-id" signs with the Apple Developer ID and notarizes the app and the
# disk image — every release from 1.66.0 on. Copies older than 1.65.1 refuse a
# Developer ID update (UpdateSignature) and have to be downloaded again by hand.
SIGNER="${AGENTBAR_SIGNER:-developer-id}"
LOCAL_ID="AgentBar Local Signing"
DEVELOPER_ID="Developer ID Application: MICHAL STRNADEL (GP69592GM8)"
NOTARY_PROFILE="${AGENTBAR_NOTARY_PROFILE:-agentbar-notary}"
REPO="michalstrnadel/AgentBar"
TAP="michalstrnadel/homebrew-tap"

TITLE="${1:?usage: release.sh \"X.Y.Z — title\"}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
say() { printf '\n▸ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

# ---- Preconditions -------------------------------------------------------------
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' Scripts/build.sh)"
[[ "$TITLE" == "$VERSION"* ]] || fail "title must start with the version ($VERSION)"
grep -q "\"version\": \"$VERSION\"" Scripts/mods/claude/.claude-plugin/plugin.json \
  || fail "the mod's plugin.json is not $VERSION"
grep -q "VERSION = \"$VERSION\"" Scripts/mods/claude/hooks/register.js \
  || fail "the mod's register.js is not $VERSION"
TOP="$(grep -m1 '^## ' CHANGELOG.md)"
[[ "$TOP" == "## $VERSION - "* ]] || fail "CHANGELOG's top section is \"$TOP\", not $VERSION"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "not on main"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes"
gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 && fail "v$VERSION is already released"
case "$SIGNER" in
  local) SIGN_ID="$LOCAL_ID" ;;
  developer-id)
    SIGN_ID="$DEVELOPER_ID"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
      || fail "notary profile \"$NOTARY_PROFILE\" does not work (xcrun notarytool store-credentials)" ;;
  *) fail "AGENTBAR_SIGNER is local or developer-id, not \"$SIGNER\"" ;;
esac
[ -d "/Volumes/AgentBar" ] && fail "eject /Volumes/AgentBar first"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-release.XXXXXX")"
echo "work: $WORK"

# CI goes off again however this ends: the repo keeps it disabled between releases.
ci_off() { gh workflow disable ci.yml -R "$REPO" >/dev/null 2>&1 || true; }
trap ci_off EXIT

# ---- CI ------------------------------------------------------------------------
say "CI for $(git rev-parse --short HEAD)"
gh workflow enable ci.yml -R "$REPO"
git push origin main
SHA="$(git rev-parse HEAD)"
RID=""
for _ in $(seq 60); do
  RID="$(gh run list -R "$REPO" --workflow ci.yml --commit "$SHA" --event push --limit 1 \
           --json databaseId -q '.[0].databaseId')"
  [ -n "$RID" ] && break
  sleep 5
done
[ -n "$RID" ] || fail "no CI run started for $SHA"
for attempt in 1 2 3; do
  # `gh run watch` can return early (a dropped connection, a long queue), so the
  # run is judged only once GitHub itself says it has completed.
  until [ "$(gh run view "$RID" -R "$REPO" --json status -q .status 2>/dev/null)" = completed ]; do
    gh run watch "$RID" -R "$REPO" --interval 30 >/dev/null 2>&1 || sleep 30
  done
  CONCLUSION="$(gh run view "$RID" -R "$REPO" --json conclusion -q .conclusion)"
  [ "$CONCLUSION" = success ] && break
  # A failed test is a failed release; a job GitHub cancelled in its queue is not.
  FAILED="$(gh run view "$RID" -R "$REPO" --json jobs -q '[.jobs[]|select(.conclusion=="failure")]|length')"
  [ "$FAILED" = 0 ] || { gh run view "$RID" -R "$REPO" --json jobs \
    -q '.jobs[]|select(.conclusion=="failure")|.name' >&2; fail "CI failed — fix it and run again"; }
  [ "$attempt" = 3 ] && fail "CI was cancelled three times"
  echo "cancelled jobs, rerunning ($attempt)"
  gh run rerun "$RID" -R "$REPO" --failed
  sleep 15
done

# ---- Sign ----------------------------------------------------------------------
say "Signing the CI bundle ($SIGNER)"
gh run download "$RID" -R "$REPO" -n AgentBar-app-universal -D "$WORK/ci"
ditto -xk "$WORK/ci/AgentBar.app.zip" "$WORK"
APP="$WORK/AgentBar.app"
if [ "$SIGNER" = developer-id ]; then
  AGENTBAR_DEVELOPER_ID="$DEVELOPER_ID" AGENTBAR_NOTARY_PROFILE="$NOTARY_PROFILE" \
    Scripts/dev/notarize.sh "$APP"           # signs, notarizes, staples, zips
else
  codesign --force --deep -s "$LOCAL_ID" "$APP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/AgentBar.app.zip"
fi
codesign --verify --deep --strict "$APP"
[ "$(lipo -archs "$APP/Contents/MacOS/AgentBar")" = "x86_64 arm64" ] || fail "not universal"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] \
  || fail "the bundle is not $VERSION"
AGENTBAR_SIGN_ID="$SIGN_ID" Scripts/dev/verify-release.sh "$WORK/ci/AgentBar.app.zip" "$WORK/AgentBar.app.zip"

# ---- Disk image ----------------------------------------------------------------
say "Disk image"
AGENTBAR_SIGN_ID="$SIGN_ID" Scripts/dev/make-dmg.sh "$APP" "$WORK/AgentBar.dmg"
DMG="$WORK/AgentBar.dmg"
# A secure timestamp is what notarization asks for; the project's own certificate
# has always signed without one.
if [ "$SIGNER" = developer-id ]; then codesign --force --timestamp -s "$SIGN_ID" "$DMG"
else codesign --force -s "$SIGN_ID" "$DMG"; fi
if [ "$SIGNER" = developer-id ]; then
  OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
  echo "$OUT"
  grep -q "status: Accepted" <<<"$OUT" || fail "the disk image was not notarized"
  xcrun stapler staple "$DMG"
  ASSESS="$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 || true)"
  grep -q "Notarized Developer ID" <<<"$ASSESS" || fail "Gatekeeper does not take the disk image as notarized"
fi
# Read into a variable first: grep -q stops reading at its match, and under
# pipefail the SIGPIPE codesign then gets reads as a failure (verify-release.sh
# says the same).
DMG_SIG="$(codesign -dvvv "$DMG" 2>&1)"
grep -qx "Authority=$SIGN_ID" <<<"$DMG_SIG" || fail "the disk image is not signed by $SIGN_ID"
mkdir -p "$WORK/mnt"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$WORK/mnt" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$WORK/mnt/AgentBar.app" "$WORK/dmg-app.zip"
hdiutil detach -quiet "$WORK/mnt"
AGENTBAR_SIGN_ID="$SIGN_ID" Scripts/dev/verify-release.sh "$WORK/ci/AgentBar.app.zip" "$WORK/dmg-app.zip"

# ---- Publish -------------------------------------------------------------------
say "Publishing v$VERSION"
Scripts/dev/release-notes.sh "$VERSION" > "$WORK/notes.md"
[ -s "$WORK/notes.md" ] || fail "empty release notes"
gh release create "v$VERSION" "$WORK/AgentBar.app.zip" "$DMG" -R "$REPO" \
  --target "$SHA" --title "$TITLE" --notes-file "$WORK/notes.md"

say "Homebrew cask"
SUM="$(shasum -a 256 "$WORK/AgentBar.app.zip" | cut -d' ' -f1)"
CASK_SHA="$(gh api "repos/$TAP/contents/Casks/agentbar.rb" -q .sha)"
gh api "repos/$TAP/contents/Casks/agentbar.rb" -H "Accept: application/vnd.github.raw" > "$WORK/agentbar.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SUM\"/" "$WORK/agentbar.rb"
grep -q "version \"$VERSION\"" "$WORK/agentbar.rb" && grep -q "sha256 \"$SUM\"" "$WORK/agentbar.rb" \
  || fail "could not rewrite the cask"
gh api -X PUT "repos/$TAP/contents/Casks/agentbar.rb" -f message="agentbar $VERSION" \
  -f content="$(base64 -i "$WORK/agentbar.rb")" -f sha="$CASK_SHA" >/dev/null

say "Attestations"
PROV=""
for _ in $(seq 60); do
  PROV="$(gh run list -R "$REPO" --workflow release-provenance.yml --limit 5 \
            --json databaseId,headBranch -q ".[]|select(.headBranch==\"v$VERSION\")|.databaseId" | head -1)"
  [ -n "$PROV" ] && break
  sleep 5
done
[ -n "$PROV" ] || fail "release-provenance.yml did not start — check it by hand"
gh run watch "$PROV" -R "$REPO" --exit-status --interval 20 >/dev/null || fail "release-provenance failed: the asset is not attested"
mkdir -p "$WORK/check"
gh release download "v$VERSION" -R "$REPO" -p AgentBar.app.zip -p AgentBar.dmg -D "$WORK/check"
gh attestation verify "$WORK/check/AgentBar.app.zip" -R "$REPO" >/dev/null
gh attestation verify "$WORK/check/AgentBar.dmg" -R "$REPO" >/dev/null

say "Released v$VERSION — https://github.com/$REPO/releases/tag/v$VERSION (cask $SUM)"
