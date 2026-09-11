#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/Facet.app"
VERSION="1.0"

echo "==> swift build (release)"
swift build -c release

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/Facet" "$APP/Contents/MacOS/Facet"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SPM emits resources as a side-by-side bundle; Bundle.module finds it in Resources/.
if [ -d "$ROOT/.build/release/Facet_Facet.bundle" ]; then
  cp -R "$ROOT/.build/release/Facet_Facet.bundle" "$APP/Contents/Resources/"
else
  echo "ERROR: Facet_Facet.bundle not found — resources would be missing" >&2
  exit 1
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Facet</string>
  <key>CFBundleDisplayName</key><string>Facet</string>
  <key>CFBundleIdentifier</key><string>com.vicky.facet</string>
  <key>CFBundleExecutable</key><string>Facet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSDesktopFolderUsageDescription</key><string>Facet needs access to read photos from folders you import.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Facet needs access to read photos from folders you import.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Facet needs access to read photos from folders you import.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Facet needs access to read photos from external drives you import.</string>
</dict>
</plist>
PLIST

echo "==> codesigning (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>&1 | tail -2
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

du -sh "$APP"
echo "==> built $APP"
