#!/bin/bash
# Builds MusicNotch.app into ./build. Needs only the Xcode Command Line Tools.
#
#   scripts/build.sh            build ./build/MusicNotch.app
#   scripts/build.sh --install  also copy it to ~/Applications and launch it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MusicNotch"
APP="$ROOT/build/$APP_NAME.app"

# mediaremote-adapter v0.7.7, pinned so a new upstream commit can't change what we ship.
ADAPTER_REPO="https://github.com/ungive/mediaremote-adapter.git"
ADAPTER_REV="e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6"
ADAPTER_SRC="$ROOT/.build/vendor/mediaremote-adapter"
ADAPTER_OUT="$ROOT/.build/adapter"
FRAMEWORK="$ADAPTER_OUT/MediaRemoteAdapter.framework"

# Signing with a stable certificate (made once by scripts/create-signing-cert.sh) keeps macOS
# permissions such as Input Monitoring across rebuilds. Without it, builds are signed ad hoc
# and macOS treats every rebuild as a new app.
SIGN_IDENTITY="${SIGN_IDENTITY:-MusicNotch Local Signing}"

step() { printf '\n==> %s\n' "$1"; }

step "Fetching mediaremote-adapter"
if [ ! -d "$ADAPTER_SRC/.git" ]; then
  git clone --quiet "$ADAPTER_REPO" "$ADAPTER_SRC"
fi
if ! git -C "$ADAPTER_SRC" cat-file -e "$ADAPTER_REV^{commit}" 2>/dev/null; then
  git -C "$ADAPTER_SRC" fetch --quiet origin
fi
git -C "$ADAPTER_SRC" -c advice.detachedHead=false checkout --quiet "$ADAPTER_REV"

step "Building MediaRemoteAdapter.framework"
# Mirrors the upstream CMakeLists.txt, arm64 only, so cmake isn't needed. Adapter/*.m adds
# MusicNotch's own "sessions" stream, which reads every app's media session.
rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK/Versions/A/Resources"
(
  cd "$ADAPTER_SRC"
  clang -arch arm64 -mmacosx-version-min=14.0 -dynamiclib -O2 -w \
    -fobjc-arc -fvisibility=default \
    -Iinclude -Isrc \
    src/adapter/*.m src/private/MediaRemote.m src/utility/*.m "$ROOT"/Adapter/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FRAMEWORK/Versions/A/MediaRemoteAdapter"
)
ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MediaRemoteAdapter</string>
    <key>CFBundleIdentifier</key>
    <string>com.vandenbe.MediaRemoteAdapter</string>
    <key>CFBundleName</key>
    <string>MediaRemoteAdapter</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>0.7.7</string>
    <key>CFBundleVersion</key>
    <string>0.7.7</string>
</dict>
</plist>
PLIST

step "Building $APP_NAME"
swift build --package-path "$ROOT" -c release --arch arm64
BIN="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)/$APP_NAME"

step "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# Local symbols only bloat the binary (by about half); crash reports keep the global ones.
strip -x "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp "$ROOT/Adapter/musicnotch-adapter.pl" "$APP/Contents/Resources/"
cp "$ADAPTER_SRC/LICENSE" "$APP/Contents/Resources/mediaremote-adapter-LICENSE.txt"
cp -R "$FRAMEWORK" "$APP/Contents/Frameworks/"
# Folders synced by iCloud Drive tag files with Finder info, which codesign refuses.
xattr -cr "$APP"

step "Signing"
# The adapter framework is loaded by /usr/bin/perl and is fine signed ad hoc.
codesign --force --sign - "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null \
  | awk -v name="\"$SIGN_IDENTITY\"" 'index($0, name) {print $2; exit}')"
if [ -n "$SIGN_HASH" ]; then
  codesign --force --sign "$SIGN_HASH" "$APP"
  echo "Signed with \"$SIGN_IDENTITY\""
else
  codesign --force --sign - "$APP"
  echo "Signed ad hoc: no \"$SIGN_IDENTITY\" certificate, so macOS permissions reset on every rebuild"
fi

echo
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  step "Installing to ~/Applications"
  DEST="$HOME/Applications/$APP_NAME.app"
  pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
