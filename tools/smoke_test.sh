#!/usr/bin/env bash
# Headless end-to-end test, no Roku and no real HamClock needed.
#   mode 1  channel -> HamClock live WebSocket (mock)          address baked as  127.0.0.1
#   mode 2  channel -> hcproxy.py -> HamClock REST (mock)      address baked as  http://127.0.0.1:8090
# The channel runs in the brs-engine CLI emulator; remote keys are injected over its ECP port (8060).
# Needs: python3 (+pillow numpy), node 22+/npm.  Ports used: 8080, 8081, 8090, 8060.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p .emu
if [ ! -x .emu/node_modules/.bin/brs-cli ]; then
  echo "installing brs-node into .emu/ ..."
  (cd .emu && echo '{"name":"hc-emu","private":true}' > package.json && npm install brs-node >/dev/null 2>&1)
fi

fail=0
run_mode() {   # $1=label  $2=baked address
  ./tools/build.sh "$2" >/dev/null
  python3 tools/hcproxy.py --mock --mock-size 1600x960 >".emu/$1.log" 2>&1 &
  PROXY=$!
  sleep 2
  .emu/node_modules/.bin/brs-cli -e dist/hamclock-roku.zip >".emu/$1.emu.log" 2>&1 &
  EMU=$!
  sleep 8
  for k in Right Right Right Down Down Select; do
    curl -s -X POST "localhost:8060/keypress/$k" >/dev/null; sleep 0.4
  done
  sleep 2
  kill $PROXY $EMU 2>/dev/null; wait $PROXY $EMU 2>/dev/null
  echo "== $1"
}
check() {      # $1=label  $2=description  $3=pattern
  if grep -q "$3" ".emu/$1.log"; then echo "PASS  $2"; else echo "FAIL  $2"; fail=1; fi
}

run_mode live  127.0.0.1
check live "channel fetched pictures over the live WebSocket"   'get_live.png'
check live "remote OK sent a tap over the WebSocket"            'set_touch [0-9]'

run_mode proxy http://127.0.0.1:8090
check proxy "channel fetched frames through the proxy"          'GET /frame.jpg'
check proxy "remote OK sent a tap through the proxy"            'GET /touch?x='
check proxy "proxy forwarded the tap to HamClock"               'GET /set_touch?x='

for l in live proxy; do
  grep -q "fetch failed\|ERROR" ".emu/$l.emu.log" && { echo "NOTE  errors in emulator log ($l):"; grep "fetch failed\|ERROR" ".emu/$l.emu.log" | head -2; }
done
exit $fail
