#!/usr/bin/env bash
# Packs a signed AgentBar.app into the disk image people download by hand:
# the app on the left, Applications on the right, an arrow between them, and a
# file on how to open it the first time (releases are signed, not notarized), under
# the AgentBar wordmark with Clawd peeking up from the bottom.
#
#   Scripts/dev/make-dmg.sh path/to/AgentBar.app [out.dmg]
#
# The zip stays the release's other asset and the one everything automatic uses —
# the in-app updater, the Homebrew cask, install.sh and the attestation. This is
# for the Download button.
#
# Signs the image with the same identity as the app when that identity is in the
# keychain ("AgentBar Local Signing"; AGENTBAR_SIGN_ID overrides).
set -euo pipefail

app="${1:?usage: make-dmg.sh path/to/AgentBar.app [out.dmg]}"
out="${2:-AgentBar.dmg}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
sign_id="${AGENTBAR_SIGN_ID:-AgentBar Local Signing}"
volname="AgentBar"

[[ -d "$app" && -x "$app/Contents/MacOS/AgentBar" ]] || { echo "make-dmg: not an AgentBar.app: $app" >&2; exit 1; }
codesign --verify --deep --strict "$app" || { echo "make-dmg: the app's signature does not verify" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-dmg.XXXXXX")"
mnt=""
trap '[[ -n "$mnt" ]] && hdiutil detach "$mnt" -quiet >/dev/null 2>&1; rm -rf "$work"' EXIT
stage="$work/stage"
mkdir -p "$stage/.background"
# Finder lays the window out by volume name, so another "AgentBar" volume already
# mounted (an older download, say) would take the layout instead.
[[ -d "/Volumes/$volname" ]] && { echo "make-dmg: eject /Volumes/$volname first" >&2; exit 1; }

ditto "$app" "$stage/AgentBar.app"
ln -s /Applications "$stage/Applications"
swift "$root/Scripts/dev/dmg-background.swift" "$work" "$root" >/dev/null
# How to get past Gatekeeper the first time, as a file beside the app rather than
# small print on the picture.
cat > "$stage/How to open AgentBar.txt" <<'TXT'
AgentBar — how to open it the first time

1. Drag AgentBar onto Applications.
2. Open it from Applications.
3. If macOS says it cannot check the developer: open System Settings ▸
   Privacy & Security, scroll down, and click "Open Anyway" next to AgentBar.
   You only do this once.

Why: AgentBar is free and open source and signed with its own certificate,
but not notarized by Apple. Every release is built by GitHub Actions and
attested; you can check the download with
  gh attestation verify AgentBar.dmg -R michalstrnadel/AgentBar

Source, release notes and help: https://github.com/michalstrnadel/AgentBar
TXT
# One TIFF with both scales: Finder shows the @2x one on a Retina screen.
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" \
  -out "$stage/.background/background.tiff" >/dev/null 2>&1
# The volume's own icon: the app's.
cp "$app/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns" 2>/dev/null || true

size_mb=$(( $(du -sm "$stage" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$volname" -srcfolder "$stage" -fs HFS+ \
  -format UDRW -size "${size_mb}m" "$work/rw.dmg"
# Under /Volumes, where Finder knows it as a disk.
mnt="$(hdiutil attach -readwrite -noverify -noautoopen "$work/rw.dmg" | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -1)"
[[ -d "$mnt" ]] || { echo "make-dmg: the image did not mount" >&2; exit 1; }

[[ -f "$mnt/.VolumeIcon.icns" ]] && SetFile -a C "$mnt" 2>/dev/null || true

# The window: icon view, no toolbar, the background, both icons placed.
osascript <<EOF
tell application "Finder"
  tell disk "$volname"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "AgentBar.app" of container window to {170, 215}
    set position of item "Applications" of container window to {490, 215}
    set position of item "How to open AgentBar.txt" of container window to {580, 340}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# Finder writes .DS_Store lazily; give it a moment, then make sure it is there.
for _ in 1 2 3 4 5; do [[ -f "$mnt/.DS_Store" ]] && break; sleep 1; done
[[ -f "$mnt/.DS_Store" ]] || { echo "make-dmg: Finder did not save the window layout" >&2; exit 1; }
chmod -Rf go-w "$mnt" 2>/dev/null || true
sync
hdiutil detach -quiet "$mnt"
mnt=""

rm -f "$out"
# lzfse: smaller and faster to open than zlib, and every supported macOS reads it.
hdiutil convert -quiet "$work/rw.dmg" -format ULFO -o "$out"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$sign_id\""; then
  codesign --force -s "$sign_id" "$out"
  codesign --verify "$out"
  echo "make-dmg: signed with \"$sign_id\""
else
  echo "make-dmg: \"$sign_id\" is not in the keychain — the image is unsigned" >&2
fi
hdiutil verify -quiet "$out"
echo "make-dmg: wrote $out ($(du -h "$out" | cut -f1 | tr -d ' '))"
