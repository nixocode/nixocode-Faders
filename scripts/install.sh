#!/usr/bin/env bash
#
# Builds Faders from this folder and puts it in your Applications folder.
#
#   git clone https://github.com/nixocode/nixocode-Faders.git Faders
#   cd Faders
#   ./scripts/install.sh
#
# Run it again after a `git pull` to update. Needs Apple's Command Line Tools
# (macOS offers to install them the first time you use `git`) or Xcode.

set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

# Update a copy that's already installed in place. Otherwise use /Applications
# if you're allowed to write there, or the Applications folder in your home.
if [ -d "$HOME/Applications/Faders.app" ]; then
  DEST="$HOME/Applications"
elif [ -w "/Applications" ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

# Quit a copy that's already running. macOS hands every app its normal sound
# back the moment Faders quits.
if pgrep -xq Faders; then
  echo "▸ Quitting the running Faders…"
  pkill -x Faders || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Faders || break; sleep 0.3; done
fi

echo "▸ Installing in ${DEST}…"   # braces: bash 3.2 would read "…" as part of the name
rm -rf "$DEST/Faders.app"
ditto build/Faders.app "$DEST/Faders.app"
open "$DEST/Faders.app"

echo "✓ Faders is in your menu bar (the three-sliders icon)."
