#!/bin/bash
# Builds MusicNotch.app into ./build, with AppShell's shared build script. Needs only the Xcode
# Command Line Tools.
#
#   scripts/build.sh            build ./build/MusicNotch.app
#   scripts/build.sh --install  also copy it to ~/Applications and launch it
#
# MusicNotch's own steps, building and adding the media adapter, are in scripts/hooks/.
set -euo pipefail
source "$(dirname "$0")/appshell.sh"
