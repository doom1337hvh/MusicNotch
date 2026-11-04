#!/bin/bash
# Builds MusicNotch and packages it for a GitHub release in ./dist, with AppShell's shared
# release script. See docs/RELEASING.md.
set -euo pipefail
source "$(dirname "$0")/appshell.sh"
