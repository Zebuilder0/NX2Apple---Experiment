#!/bin/bash
# Builds "NX2Apple Resigner.app" from this checkout (frontend/resigner/README.md): the release binary, the bundle with its texts
# (frontend/l10n) and, when this Xcode's actool can compile frontend/AppIcon.icon, the icon. Signed ad hoc, as tools/try-local signs
# the launcher: it runs on this Mac, and a copy for another Mac needs right-click, Open the first time.
# Usage: frontend/tools/build_resigner.sh [output folder]   (default frontend/.build/resigner)
# Writes <output>/NX2Apple Resigner.app and <output>/NX2Apple-Resigner-macOS-arm64.zip. Needs Xcode (swift, codesign, plutil, ditto).
set -euo pipefail
cd "$(dirname "$0")/.."
FRONTEND=$PWD
OUT=${1:-"$FRONTEND/.build/resigner"}
VERSION=1.0.0
APP="$OUT/NX2Apple Resigner.app"
say() { echo "[build_resigner] $*"; }

# The executable is its own small package (frontend/resigner/app) that links the frontend package's ResignerUI library
PKG="$FRONTEND/resigner/app"
say "swift build -c release --package-path resigner/app"
swift build -c release --package-path "$PKG"
BIN="$(swift build -c release --package-path "$PKG" --show-bin-path)/NX2AppleResigner"
[ -x "$BIN" ] || { say "FAIL: no binary at $BIN"; exit 1; }

mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NX2AppleResigner"
# LocalizationFiles reads Contents/Resources/l10n first
cp -R "$FRONTEND/l10n" "$APP/Contents/Resources/l10n"

ICON_KEYS=""
ICON_TMP=$(mktemp -d)
trap 'rm -rf "$ICON_TMP"' EXIT
if xcrun actool "$FRONTEND/AppIcon.icon" --compile "$ICON_TMP" --platform macosx --minimum-deployment-target 13.0 \
     --app-icon AppIcon --output-partial-info-plist "$ICON_TMP/partial.plist" > /dev/null 2>&1 \
   && [ -f "$ICON_TMP/Assets.car" ] && [ -f "$ICON_TMP/AppIcon.icns" ]; then
  cp "$ICON_TMP/Assets.car" "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/"
  ICON_KEYS="<key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleIconName</key><string>AppIcon</string>"
  say "icon: compiled"
else
  say "icon: this Xcode's actool cannot compile AppIcon.icon (Xcode 27.2 can), the app has the generic icon"
fi

COMMIT=$(git -C "$FRONTEND" rev-parse --short=12 HEAD 2> /dev/null || echo unknown)
if [ -n "$(git -C "$FRONTEND" status --porcelain --untracked-files=no 2> /dev/null)" ]; then COMMIT="$COMMIT+dirty"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>org.nxnative.NX2AppleResigner</string>
  <key>CFBundleName</key><string>NX2Apple Resigner</string>
  <key>CFBundleDisplayName</key><string>NX2Apple Resigner</string>
  <key>CFBundleExecutable</key><string>NX2AppleResigner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NXResignerCommit</key><string>$COMMIT</string>
  $ICON_KEYS
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" > /dev/null

say "codesign (ad hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

ZIP="$OUT/NX2Apple-Resigner-macOS-arm64.zip"
rm -f "$ZIP"
(cd "$OUT" && ditto -c -k --keepParent "NX2Apple Resigner.app" "$ZIP")
say "done: $APP ($(du -sh "$APP" | cut -f1)), $ZIP, version $VERSION, source $COMMIT"
