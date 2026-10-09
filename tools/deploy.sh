#!/usr/bin/env bash
# Sideload dist/hamclock-roku.zip to a real Roku in developer mode.
#   ROKU_IP=192.168.1.60 ROKU_PASS=yourdevpassword ./tools/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ROKU_IP:?set ROKU_IP}"; : "${ROKU_PASS:?set ROKU_PASS}"
curl --digest -u "rokudev:${ROKU_PASS}" -sS \
     -F "mysubmit=Install" -F "archive=@dist/hamclock-roku.zip" \
     "http://${ROKU_IP}/plugin_install" | grep -oE "Install Success|Identical to previous version|Install Failure[^<]*|Failed[^<]*" || true
