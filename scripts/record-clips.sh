#!/bin/bash
# Records the README's clips from build/MusicNotch.app, with AppShell's shared recorder. The
# clips are listed in scripts/clips.jsonc, and acted out by Sources/MusicNotch/DemoScene.swift.
#
#   scripts/build.sh && scripts/record-clips.sh             every clip
#   scripts/build.sh && scripts/record-clips.sh tour full   just these
#
# Needs Screen Recording for the terminal it runs in, a MacBook with a notch, and a normal
# desktop in front. A running MusicNotch is quit meanwhile and opened again afterwards.
set -euo pipefail
source "$(dirname "$0")/appshell.sh"
