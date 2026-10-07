#!/usr/bin/env bash
# HomeClerk build script
# Builds dist/HomeClerk.app and a zip of it.
# Usage:  ./build.sh [--install] [--clean] [--debug]
#         VERSION=v1.2.0 ./build.sh   (otherwise the latest git tag, or "dev")
#
# Options:
#   --install  Also put it in /Applications (replacing the app there) and open it
#   --clean    Remove dist/ and build/xcode first
#   --debug    Build the Debug configuration (default: Release)
#
# Needs Xcode; XcodeGen (brew install xcodegen) regenerates the project from project.yml first.

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="Release"
CLEAN=false
INSTALL=false
DERIVED="build/xcode"
DIST="dist"
APP="$DIST/HomeClerk.app"
INSTALLED="/Applications/HomeClerk.app"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) INSTALL=true ;;
        --clean)   CLEAN=true ;;
        --debug)   CONFIG="Debug" ;;
        *)         echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if $CLEAN; then
    echo "→  Cleaning..."
    rm -rf "$DIST" "$DERIVED"
fi

# The project is generated from project.yml; regenerate it when XcodeGen is installed, so a newly
# added Swift file is never left out
if command -v xcodegen >/dev/null; then
    xcodegen --quiet
fi

echo "→  Building ($CONFIG)..."
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
if ! xcodebuild -project HomeClerk.xcodeproj -scheme HomeClerk -configuration "$CONFIG" \
        -derivedDataPath "$DERIVED" build >"$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" >&2 || tail -40 "$LOG" >&2
    echo "✗  Build failed (full log: rerun xcodebuild by hand)" >&2
    exit 1
fi

echo "→  Assembling $APP..."
rm -rf "$APP"
mkdir -p "$DIST"
ditto "$DERIVED/Build/Products/$CONFIG/HomeClerk.app" "$APP"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")}"
if [[ "$VERSION" =~ ^v?([0-9]+(\.[0-9]+)*)$ ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${BASH_REMATCH[1]}" "$APP/Contents/Info.plist"
fi

# Signed after the version stamp changed Info.plist. With the "HomeClerk Local" certificate
# (scripts/make-signing-cert.sh) every build has the same signature, so macOS keeps HomeClerk's
# permissions across updates; without it (as on GitHub's runners), an ad-hoc signature.
# SIGN_IDENTITY picks another certificate. "DocuSort Local" is the same certificate made before
# the app was renamed.
IDENTITY="${SIGN_IDENTITY:-}"
for NAME in "HomeClerk Local" "DocuSort Local"; do
    if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning ${SIGN_KEYCHAIN:-} 2>/dev/null | grep -q "\"$NAME\""; then
        IDENTITY="$NAME"
    fi
done
echo "→  Signing${IDENTITY:+ as $IDENTITY}..."
codesign --force --deep --sign "${IDENTITY:--}" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"
codesign --verify --deep --strict "$APP"

ZIP="HomeClerk-${VERSION}-osx-arm64.zip"
rm -f "$ZIP"
# ditto keeps the bundle intact (permissions, symlinks, signatures) — what Finder's Compress does
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "  ✓ ${APP}"
echo "  ✓ ${ZIP}  ($(du -sh "$ZIP" | cut -f1))"

if $INSTALL; then
    echo ""
    # Quit HomeClerk first — copies run from Xcode included — so the new one starts cleanly
    if pgrep -f "HomeClerk.app/Contents/MacOS/HomeClerk" >/dev/null; then
        echo "→  Quitting HomeClerk..."
        osascript -e 'tell application id "com.mockclan.homeclerk" to quit' >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            pgrep -f "HomeClerk.app/Contents/MacOS/HomeClerk" >/dev/null || break
            sleep 0.5
        done
        if pgrep -f "HomeClerk.app/Contents/MacOS/HomeClerk" >/dev/null; then
            echo "✗  HomeClerk is still running — quit it (and any copy in Xcode), then run this again" >&2
            exit 1
        fi
    fi

    echo "→  Installing to $INSTALLED..."
    # Removed first, so nothing from the old app is left inside the new one
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED"
    open "$INSTALLED"
    echo "  ✓ Installed and opened $INSTALLED"
    if [[ -d "/Applications/DocuSort.app" ]]; then
        echo "  ! The app's old version, /Applications/DocuSort.app, is still installed. HomeClerk has taken"
        echo "    over its settings and folder; quit DocuSort and move it to the Trash."
    fi
fi
echo ""
