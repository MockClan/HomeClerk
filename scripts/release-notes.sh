#!/usr/bin/env bash
# Prints one version's section of CHANGELOG.md — the notes the release workflow publishes.
#   scripts/release-notes.sh 1.1.0                     preview them
#   scripts/release-notes.sh 1.1.0 | gh release edit v1.1.0 --notes-file -    replace a release's notes
# Prints nothing (and exits 1) when CHANGELOG.md has no section for that version.
set -euo pipefail
VERSION="${1#v}"
cd "$(dirname "$0")/.."
NOTES=$(awk -v v="$VERSION" '
    /^## / { if (found) exit; found = ($2 == v); next }
    found && (printed || NF) { print; printed = 1 }
' CHANGELOG.md)
[[ -n "$NOTES" ]] || exit 1
printf '%s\n' "$NOTES"
