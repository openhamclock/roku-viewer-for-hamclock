#!/usr/bin/env bash
# Package the channel into dist/hamclock-roku.zip
#   ./tools/build.sh                      plain build (address is entered on the Roku with the * key)
#   ./tools/build.sh 192.168.1.20         bake a default address into the manifest (sideload / simulator builds)
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build dist && mkdir -p build dist
cp -r channel/. build/
if [ $# -ge 1 ]; then printf '\ndefault_address=%s\n' "$1" >> build/manifest; echo "default address: $1"; fi
(cd build && zip -qr ../dist/hamclock-roku.zip . -x '.*')
echo "built dist/hamclock-roku.zip"
unzip -l dist/hamclock-roku.zip | tail -n +4 | head -n -2
