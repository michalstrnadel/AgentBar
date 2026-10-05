#!/bin/bash
# Prints one version's section of CHANGELOG.md, without its heading — the text
# `gh release create --notes-file` takes. The app shows the same section from the
# CHANGELOG it bundles (Settings ▸ What's New), so GitHub and the app can never
# say different things about one release.
#
#   Scripts/dev/release-notes.sh 1.39.0 > /tmp/notes.md
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <version>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="$1"
OUT="$(awk -v v="$V" '
  /^## / { if (on) exit; split($2, a, " "); if (a[1] == v) { on = 1; next } }
  on { print }
' "$ROOT/CHANGELOG.md" | sed '/./,$!d')"  # leading blank lines; \$( ) drops trailing ones
[ -n "$OUT" ] || { echo "release-notes: no section for $V in CHANGELOG.md" >&2; exit 1; }
printf '%s\n' "$OUT"
