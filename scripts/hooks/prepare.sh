# Sourced by AppShell's build script before `swift build`: builds MediaRemoteAdapter.framework,
# which MusicNotch ships to read what's playing (see Sources/MusicNotch/Media/AdapterProcess.swift).

# mediaremote-adapter v0.7.7, pinned so a new upstream commit can't change what we ship.
ADAPTER_REPO="https://github.com/ungive/mediaremote-adapter.git"
ADAPTER_REV="e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6"
ADAPTER_SRC="$ROOT/.build/vendor/mediaremote-adapter"
ADAPTER_OUT="$ROOT/.build/adapter"
FRAMEWORK="$ADAPTER_OUT/MediaRemoteAdapter.framework"

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
