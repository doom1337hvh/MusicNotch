#!/bin/bash
# Creates the "MusicNotch Local Signing" certificate in the login keychain, so the permissions
# you grant MusicNotch survive rebuilds. Run once.
set -euo pipefail
source "$(dirname "$0")/appshell.sh"
