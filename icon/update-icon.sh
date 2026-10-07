#!/usr/bin/env bash
# After editing a layer SVG here: copies the layers into HomeClerk.icon (the icon the app uses) and
# renders appearances.png, every appearance macOS draws, with Icon Composer's own renderer.
# Needs Xcode (for Icon Composer) and rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")"

cp folder-back.svg document.svg folder-front.svg HomeClerk.icon/Assets/

# One image of every appearance macOS draws, rendered by Icon Composer's own tool
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ -x "$ICTOOL" ]]; then
    TMP=$(mktemp -d)
    for rendition in Default Dark ClearLight ClearDark TintedLight TintedDark; do
        "$ICTOOL" HomeClerk.icon --export-image --output-file "$TMP/$rendition.png" --platform macOS \
            --rendition "$rendition" --width 256 --height 256 --scale 1 >/dev/null
    done
    python3 - "$TMP" <<'PY'
import base64, sys
tmp = sys.argv[1]
names = ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"]
parts = []
for i, n in enumerate(names):
    data = base64.b64encode(open(f"{tmp}/{n}.png", "rb").read()).decode()
    x, light = 20 + i * 276, n == "Default" or "Light" in n
    parts.append(f'<rect x="{x - 10}" width="276" height="320" fill="{"#ECECEC" if light else "#1E1E1E"}"/>'
                 f'<image x="{x}" y="20" width="256" height="256" href="data:image/png;base64,{data}"/>'
                 f'<text x="{x + 128}" y="305" font-family="Helvetica" font-size="18" text-anchor="middle" '
                 f'fill="{"#000" if light else "#FFF"}">{n}</text>')
open(f"{tmp}/sheet.svg", "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{20 + 6 * 276}" height="320">'
                                    + "".join(parts) + "</svg>")
PY
    rsvg-convert "$TMP/sheet.svg" -o appearances.png
    # The icon at the top of the README
    "$ICTOOL" HomeClerk.icon --export-image --output-file ../docs/icon.png --platform macOS \
        --rendition Default --width 256 --height 256 --scale 1 >/dev/null
    rm -rf "$TMP"
fi
echo "✓ HomeClerk.icon, appearances.png, ../docs/icon.png"
