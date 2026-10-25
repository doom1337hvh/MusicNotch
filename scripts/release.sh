#!/bin/bash
# Builds MusicNotch and packages it for a GitHub release:
#
#   dist/MusicNotch-<version>.zip
#   dist/MusicNotch-<version>.dmg
#   dist/SHA256SUMS.txt
#
# The version comes from Resources/Info.plist (CFBundleShortVersionString); bump it, and
# CFBundleVersion, before each release.
#
# Releases must be signed with the same "MusicNotch Local Signing" certificate every time
# (scripts/create-signing-cert.sh). macOS ties the permissions people grant MusicNotch
# (Input Monitoring, Automation) to that signature, so a release signed any other way
# makes everyone grant them again. Keep a backup of the certificate (see docs/RELEASING.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MusicNotch.app"
DIST="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
NAME="MusicNotch-$VERSION"

step() { printf '\n==> %s\n' "$1"; }

"$ROOT/scripts/build.sh"

# A clean copy is checked and packaged. ditto keeps the framework's symlinks and the
# signature intact, and leaves out the local file attributes macOS adds (provenance, and the
# Finder info iCloud Drive keeps putting back in synced folders), which the signature
# doesn't cover but `codesign --strict` refuses.
CLEAN=(--norsrc --noextattr --noqtn --noacl)
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "${CLEAN[@]}" "$APP" "$STAGING/MusicNotch.app"

step "Checking the signature"
codesign --verify --deep --strict "$STAGING/MusicNotch.app"
DETAILS="$(codesign -dvv "$STAGING/MusicNotch.app" 2>&1)"
AUTHORITY="$(awk -F= '/^Authority=/ {print $2; exit}' <<<"$DETAILS")"
if [ "$AUTHORITY" != "MusicNotch Local Signing" ] && [ "${ALLOW_ADHOC:-}" != "1" ]; then
  echo "The app isn't signed with \"MusicNotch Local Signing\" (got: ${AUTHORITY:-ad hoc})."
  echo "Everyone would have to grant MusicNotch's permissions again after updating."
  echo "Restore the certificate (docs/RELEASING.md), or set ALLOW_ADHOC=1 to release anyway."
  exit 1
fi
echo "Signed by $AUTHORITY"

step "Packaging $NAME"
rm -rf "$DIST"
mkdir -p "$DIST"
ditto -c -k "${CLEAN[@]}" --keepParent "$STAGING/MusicNotch.app" "$DIST/$NAME.zip"

ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "MusicNotch $VERSION" -srcfolder "$STAGING" -fs HFS+ \
  -format UDZO -ov "$DIST/$NAME.dmg"

(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)

step "Done"
ls -lh "$DIST"
cat "$DIST/SHA256SUMS.txt"
cat <<NEXT

Next:
  git tag v$VERSION && git push origin v$VERSION
  Then create a release for v$VERSION on GitHub and attach the three files in dist/.
NEXT
