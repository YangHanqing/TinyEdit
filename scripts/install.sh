#!/bin/bash
# Builds Release signed with the local Apple Development identity and installs to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "no Apple Development identity in keychain" >&2; exit 1; }
# The build number is the minute of the build (yyyyMMddHHmm); the version comes from project.yml.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
xcodegen generate >/dev/null
xcodebuild -project TinyEdit.xcodeproj -scheme TinyEdit -configuration Release \
  -derivedDataPath build/rel CODE_SIGN_IDENTITY="$IDENTITY" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build | tail -3
# Quit normally first so the app can flush unsaved tabs to its recovery store.
# Do not terminate another copy by process name: it may contain an active session.
if pgrep -x TinyEdit >/dev/null; then
  echo "Quit all running TinyEdit copies with Command-Q, then run this script again." >&2
  exit 1
fi
rm -rf /Applications/TinyEdit.app
cp -R build/rel/Build/Products/Release/TinyEdit.app /Applications/TinyEdit.app
codesign --verify --strict --verbose=2 /Applications/TinyEdit.app
codesign -dv /Applications/TinyEdit.app 2>&1 | grep -E "Authority|TeamIdentifier|Identifier"
PLIST=/Applications/TinyEdit.app/Contents/Info.plist
echo "Installed TinyEdit $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST"))"
# Drop the build-tree copies so Spotlight and Open With list only /Applications/TinyEdit.app.
# The Debug app comes back on the next test run.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
while IFS= read -r -d '' app; do
  "$LSREGISTER" -u "$app" 2>/dev/null || true
  rm -rf "$app"
done < <(find build -type d -name TinyEdit.app -prune -print0)
"$LSREGISTER" -f /Applications/TinyEdit.app
