#!/bin/bash
# Tests, builds and publishes the version in project.yml as a GitHub release with a .pkg installer.
# Usage: scripts/release.sh NOTES.md [--dry-run|--draft]
#   NOTES.md: this version's changes, Chinese first, then English. The install section
#   and the package's SHA-256 are appended here, so the notes file carries only the changes.
#   --dry-run: everything except publishing; prints where the package and final notes are.
#   --draft:   publishes a draft release, visible only to the owner until published.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "$*" >&2; exit 1; }

NOTES="${1:-}"
MODE="${2:-}"
[ -f "$NOTES" ] || fail "usage: scripts/release.sh NOTES.md [--dry-run|--draft]"
case "$MODE" in ""|--dry-run|--draft) ;; *) fail "unknown option: $MODE" ;; esac
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
[ -n "$VERSION" ] || fail "no MARKETING_VERSION in project.yml"
TAG="v$VERSION"

# Release only what is on GitHub's main, and never reuse a version.
[ "$(git branch --show-current)" = main ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "uncommitted changes; commit them first"
git fetch -q origin
if [ "$MODE" != --dry-run ]; then
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main differs from origin/main; push first"
  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || gh release view "$TAG" >/dev/null 2>&1; then
    fail "$TAG is already released; bump MARKETING_VERSION in project.yml"
  fi
fi

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || fail "no Apple Development identity in keychain"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
mkdir -p build
xcodegen generate >/dev/null

echo "Testing…"
xcodebuild -project TinyEdit.xcodeproj -scheme TinyEdit -derivedDataPath build test >build/release-test.log 2>&1 || {
  grep -E "\.swift:[0-9]+: error|error:|failed \(|TEST FAILED" build/release-test.log | tail -30; fail "tests failed (build/release-test.log)"; }
grep -E "Executed [0-9]+ tests" build/release-test.log | tail -1

echo "Building $VERSION ($BUILD_NUMBER)…"
rm -rf build/release
xcodebuild -project TinyEdit.xcodeproj -scheme TinyEdit -configuration Release -derivedDataPath build/release \
  CODE_SIGN_IDENTITY="$IDENTITY" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build >build/release-build.log 2>&1 || {
  tail -30 build/release-build.log; fail "build failed (build/release-build.log)"; }
APP=build/release/Build/Products/Release/TinyEdit.app
codesign --verify --strict "$APP"
[ "$(lipo -archs "$APP/Contents/MacOS/TinyEdit")" = arm64 ] || fail "app is not arm64-only"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || fail "Info.plist version is not $VERSION"
# The signed entitlements must be exactly the checked-in ones (no injected get-task-allow).
diff <(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | sort) \
     <(plutil -p TinyEdit/TinyEdit.entitlements | sort) >/dev/null || fail "signed entitlements differ from TinyEdit.entitlements"

echo "Packaging…"
DIST=build/dist
PKG="$DIST/TinyEdit-$VERSION-arm64.pkg"
rm -rf build/dist
mkdir -p "$DIST/root" "$DIST/parts"
ditto "$APP" "$DIST/root/TinyEdit.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
# Always install into /Applications: a relocatable bundle would instead update whatever
# TinyEdit.app Installer finds elsewhere (Downloads, a build folder).
pkgbuild --analyze --root "$DIST/root" "$DIST/parts/components.plist" >/dev/null
i=0
while plutil -extract "$i" raw -o /dev/null "$DIST/parts/components.plist" 2>/dev/null; do
  plutil -replace "$i.BundleIsRelocatable" -bool NO "$DIST/parts/components.plist"
  i=$((i + 1))
done
[ "$i" -gt 0 ] || fail "no bundle found to package"
pkgbuild --root "$DIST/root" --component-plist "$DIST/parts/components.plist" --install-location /Applications \
  --identifier "$BUNDLE_ID" --version "$VERSION" "$DIST/parts/TinyEdit.pkg" >/dev/null
cat >"$DIST/parts/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>TinyEdit $VERSION</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="15.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="TinyEdit"><pkg-ref id="$BUNDLE_ID"/></choice>
    <pkg-ref id="$BUNDLE_ID" version="$VERSION" onConclusion="none">TinyEdit.pkg</pkg-ref>
</installer-gui-script>
EOF
# Signing a package needs an Installer certificate, which an Apple Development account does
# not have, so the package is unsigned; the app inside keeps its own signature.
productbuild --distribution "$DIST/parts/distribution.xml" --package-path "$DIST/parts" "$PKG" >/dev/null
rm -rf build/dist/root build/dist/parts
pkgutil --payload-files "$PKG" | grep -qx "./TinyEdit.app/Contents/MacOS/TinyEdit" || fail "package payload is missing the app"
SHA="$(shasum -a 256 "$PKG" | cut -d' ' -f1)"

FINAL="$DIST/notes-$VERSION.md"
{
  cat "$NOTES"
  cat <<EOF

---

### 安装 / Install

需要 macOS 15 或更高版本、Apple 芯片（M 系列）Mac。下载 \`$(basename "$PKG")\` 并双击，按安装器的提示完成，TinyEdit 会装进“应用程序”。安装包未经 Apple 公证，第一次双击会被系统阻止：到 **系统设置 ▸ 隐私与安全性** 点击 **仍要打开**；或在终端执行 \`xattr -d com.apple.quarantine ~/Downloads/$(basename "$PKG")\` 后再双击。

Requires macOS 15 or later on an Apple silicon (M-series) Mac. Download \`$(basename "$PKG")\`, double-click it and follow the installer; TinyEdit is installed into Applications. The installer is not notarized by Apple, so macOS blocks the first double-click: click **Open Anyway** in **System Settings ▸ Privacy & Security**, or run \`xattr -d com.apple.quarantine ~/Downloads/$(basename "$PKG")\` in Terminal and double-click it again.

SHA-256 (\`$(basename "$PKG")\`):
\`$SHA\`
EOF
} >"$FINAL"

if [ "$MODE" = --dry-run ]; then
  echo "Dry run: $PKG"
  echo "Notes:   $FINAL"
  exit 0
fi
gh release create "$TAG" "$PKG" --target main --title "TinyEdit $VERSION" --notes-file "$FINAL" \
  ${MODE:+--draft}
