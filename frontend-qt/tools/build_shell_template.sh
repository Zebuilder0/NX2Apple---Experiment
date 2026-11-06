#!/bin/bash
# The empty shared app the Windows launcher puts every game into (frontend-qt/nspb_qt/shell.py).
#
# The Mac launcher builds the shared app with Xcode at every install (engine dm/ios/tools/build_shell.sh), with the
# games' frameworks embedded. Windows cannot compile its Swift (the frontend-ios package), so build-qt.yml runs this
# on GitHub's xcode-27 runner and the Windows zip carries the result: the same project, with no game framework,
# built unsigned for iPhone and iPad. Each game's framework carries its own engine host (loader FH), so the app needs
# none of its own and works with frameworks built by a later engine, as long as dm_glue_version matches
# (dm/ios/Shell/ShellGlue.h).
#
# The executable then gets an ad-hoc signature with the Increased Memory Limit request: the signing tool on the PC
# (Impactor's plumesign) reads the executable's entitlements to ask Apple for the capability, then signs the app with
# the player's Apple ID.
#
# Usage: frontend-qt/tools/build_shell_template.sh <out folder>     (on a Mac with Xcode 27, xcodegen and fontTools,
#        after python3 tools/engine.py sync)        → <out folder>/DmShell.app
set -euo pipefail
OUT=${1:?usage: build_shell_template.sh <out folder>}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE=$REPO/engine
IOS=$ENGINE/dm/ios
DM=$ENGINE/dm
[ -f "$IOS/project-shell.yml" ] || { echo "no $IOS/project-shell.yml: run python3 tools/engine.py sync first" >&2; exit 1; }
command -v xcodegen > /dev/null || { echo "xcodegen is not installed (brew install xcodegen)" >&2; exit 1; }
VERSION=$(sed -n "s/^APP_VERSION = '\(.*\)'/\1/p" "$REPO/frontend-qt/nspb_qt/app_update.py")
[ -n "$VERSION" ] || { echo "no APP_VERSION in frontend-qt/nspb_qt/app_update.py" >&2; exit 1; }

WORK=$(mktemp -d)
S=$WORK/shell
mkdir -p "$S"
# build_shell.sh's layout: the shell project beside links to the engine's iOS sources
for item in Sources Shell tools; do ln -sfn "$IOS/$item" "$S/$item"; done
cd "$S"
mkdir -p Gen/dm/font Gen/Assets.xcassets
: > Gen/dm.xcconfig
cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" Gen/dm/font/standard.ttf
python3 "$DM/tools/make_ext_font.py" Gen/dm/font/nintendo_ext.ttf > /dev/null
printf '{"info":{"author":"xcode","version":1}}\n' > Gen/Assets.xcassets/Contents.json
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>com.apple.developer.kernel.increased-memory-limit</key><true/></dict></plist>' > Gen/DmShell.entitlements
# project-shell.yml with no game framework where it says @FRAMEWORKS@
grep -v '# @FRAMEWORKS@' "$IOS/project-shell.yml" > project.yml
grep -q '@FRAMEWORKS@' "$IOS/project-shell.yml" || { echo "project-shell.yml has no @FRAMEWORKS@ line: update this script" >&2; exit 1; }

export LC_ALL=C DM_BUNDLE_ID=org.nxnative.shell DM_TEAM_ID=0000000000 DM_SHELL_NAME=NX2Apple DM_APP_VERSION=$VERSION
export DM_SHELL_PACKAGE=$REPO/frontend-ios
xcodegen generate -q > /dev/null
CHAIN=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM/gfx/nvn/dmsh_chain.h")
COMMIT=$(git -C "$ENGINE" rev-parse --short=12 HEAD 2> /dev/null || echo unknown)
/usr/libexec/PlistBuddy -c "Add :DMCommit string $COMMIT" Gen/Info.plist
/usr/libexec/PlistBuddy -c "Add :DMChain string $CHAIN" Gen/Info.plist
/usr/libexec/PlistBuddy -c "Add :DMForkPatches string $(paste -sd, "$DM/fork_patches.txt" 2>/dev/null || true)" Gen/Info.plist

echo "xcodebuild (Release, unsigned, iPhone + iPad, no game framework), app version $VERSION"
xcodebuild -project DmShell.xcodeproj -scheme DmShell -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$S/dd" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build > "$S/build.log" 2>&1 \
  || { grep -E 'error:' "$S/build.log" | head -30; echo "xcodebuild failed, log $S/build.log" >&2; exit 1; }
APP=$S/dd/Build/Products/Release-iphoneos/DmShell.app
[ -x "$APP/DmShell" ] || { echo "no built app at $APP" >&2; exit 1; }
rm -rf "$APP/Frameworks"   # the games' frameworks go here on the PC
# The ad-hoc signature carries the Increased Memory Limit request to the signing tool
codesign --force --sign - --entitlements Gen/DmShell.entitlements "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -q increased-memory-limit \
  || { echo "the ad-hoc signature has no Increased Memory Limit entitlement" >&2; exit 1; }
mkdir -p "$OUT"
rm -rf "$OUT/DmShell.app"
ditto "$APP" "$OUT/DmShell.app"
echo "done: $OUT/DmShell.app ($(du -sh "$OUT/DmShell.app" | cut -f1)), chain $CHAIN, engine $COMMIT"
