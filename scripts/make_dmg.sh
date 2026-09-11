#!/bin/bash
# Packages dist/Facet.app into a distributable DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
APP="dist/Facet.app"
[ -d "$APP" ] || { echo "build the app first: bash scripts/build_app.sh" >&2; exit 1; }

STAGE="$(mktemp -d)/Facet"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read me first.txt" <<'TXT'
Facet is open source and signed only ad-hoc, so macOS will refuse it on first launch.

To open it the first time:
  1. Drag Facet into Applications.
  2. Right-click (or Control-click) Facet -> Open.
  3. Click "Open" in the dialog.

You only need to do this once.

Source: https://github.com/VigneshDev16/facet
TXT

OUT="dist/Facet-$VERSION-arm64.dmg"
rm -f "$OUT"
hdiutil create -volname "Facet $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "$OUT  ($(du -h "$OUT" | cut -f1))"
shasum -a 256 "$OUT" | awk '{print "sha256: "$1}'
