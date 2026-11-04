# Sourced by build.sh, release.sh and create-signing-cert.sh next to it: finds the AppShell
# checkout this app is built with (Swift Package Manager fetches it the first time, or uses
# your own copy after `swift package edit AppShell --path ...`) and runs AppShell's script of
# the same name for this app.
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export APP_ROOT
DEPENDENCIES="$(swift package --package-path "$APP_ROOT" show-dependencies --format json)"
APPSHELL=""
i=0
while DEPENDENCY="$(plutil -extract "dependencies.$i.name" raw -o - - <<<"$DEPENDENCIES" 2>/dev/null)"; do
  if [ "$DEPENDENCY" = "AppShell" ]; then
    APPSHELL="$(plutil -extract "dependencies.$i.path" raw -o - - <<<"$DEPENDENCIES")"
    break
  fi
  i=$((i + 1))
done
if [ ! -d "$APPSHELL/scripts" ]; then
  echo "Couldn't find AppShell among this app's dependencies (Package.swift)." >&2
  exit 1
fi
exec "$APPSHELL/scripts/$(basename "$0")" "$@"
