# Sourced by AppShell's build script once MusicNotch.app is put together in $STAGED: adds the
# media adapter (built by prepare.sh) and its licence.
cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$STAGED/Contents/Resources/"
cp "$ROOT/Adapter/musicnotch-adapter.pl" "$STAGED/Contents/Resources/"
cp "$ADAPTER_SRC/LICENSE" "$STAGED/Contents/Resources/mediaremote-adapter-LICENSE.txt"
mkdir -p "$STAGED/Contents/Frameworks"
cp -R "$FRAMEWORK" "$STAGED/Contents/Frameworks/"
xattr -cr "$STAGED"
# The adapter framework is loaded by /usr/bin/perl and is fine signed ad hoc.
codesign --force --sign - "$STAGED/Contents/Frameworks/MediaRemoteAdapter.framework"
