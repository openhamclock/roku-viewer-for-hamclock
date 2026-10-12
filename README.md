# HamClock for Roku

A thin-client Roku channel for [HamClock](https://github.com/openhamclock/hamclock). Roku can't run
HamClock's C++ engine the way the Android app does (no native code, no WebView), so HamClock keeps
running on a Pi / PC / Docker host / Android device and the Roku just displays it and sends
remote-control taps.

> **Unofficial.** This is an independent project. It is not made, endorsed or supported by the author of
> HamClock or by Roku, Inc. It contains no HamClock code; it only talks to a HamClock you run yourself.

# How to Install
1. Using your Roku remote, enable developer mode using this sequence: Home, Home, Home, Up, Up, Right, Left, Right, Left, Right. See https://developer.roku.com/dev/docs/developer-setup#sideloading-apps
2. Set a password for rokudev
3. Reboot Roku
4. Connect to Roku on a separate PC at http://<roku-ip> using the username and password you set (https does not work make sure it is http)
5. Download latest Release from Releases page
6. Upload zip using the Roku web interface you connected to in Step 4
7. Click "Install with zip"
8. HamClock application will start on Roku
9. Press * button to set IP for your HamClock running on RPi, Quadra, WSL etc

## Two ways to connect

```
LIVE (default)   Roku --WebSocket--> HamClock live port 8081          no extra software
PROXY (fallback) Roku --HTTP-------> hcproxy.py :8090 --> HamClock    only if live mode can't connect
```

**Live mode** speaks the same WebSocket protocol HamClock's own `live.html` web page uses:

| message sent | HamClock's reply |
|---|---|
| `get_live.png?` | one binary message: a complete PNG of the screen |
| `set_touch?x=X&y=Y&button=0` | none; performs a tap. X,Y are in HamClock's **800x480** app space even on 1600x960+ builds |

HamClock's live ports are **8081 read-write** (taps work) and **8082 read-only** (view only); change them
with HamClock's `-w` / `-r` options. Anyone on your LAN who can reach 8081 can control HamClock, so do not
expose it to the internet.

**Why not Roku's `roWebSocket`?** On tested hardware a sideloaded channel could create the component, but
`Open()` failed with error 29, "WebSockets are not allowed". So `channel/components/WsTask.brs` implements
the WebSocket protocol itself (RFC 6455: HTTP upgrade, masked client frames, unmasked server frames) over a
plain `roStreamSocket`. It needs no special Roku OS version and no proxy. It speaks plain `ws://` only.

**Proxy mode** exists because HamClock's REST `get_capture.bmp` is a top-down RGB565 BMP that Roku
can't decode; `tools/hcproxy.py` converts it to JPEG. Use it only if live mode isn't available.

## Layout

```
channel/              the Roku package (manifest, source, components, images)
tools/build.sh        builds dist/hamclock-roku.zip (optionally with a default address baked in)
tools/smoke_test.sh   headless end-to-end test of both modes (no Roku, no HamClock needed)
tools/deploy.sh       sideload to a real Roku
tools/hcproxy.py      proxy (fallback) + built-in mock HamClock for testing
tools/make_poster.py  generates the Streaming Store poster
tools/fit_screenshot.py  resizes Roku screenshots to 1920x1080 for the store
store/                store listing text, privacy policy and terms drafts, poster
PUBLISHING.md         how to publish to the Roku Streaming Store
```

## 1. Quick start

Make sure HamClock is running and its live port is reachable from the Roku. Then either bake the
address in (a `default_address` line is added to the manifest):

```bash
./tools/build.sh 192.168.1.20                  # live mode, port 8081 added
./tools/build.sh 192.168.1.20:9000             # live mode, custom port
./tools/build.sh http://192.168.1.50:8090      # proxy mode
```
...or build plainly (`./tools/build.sh`) and enter the address on the Roku.

**Entering the address** (first launch, or `*` / Rewind later). The dialog opens with an empty field:
1. Press **Up** to move onto the on-screen keyboard and type the **IP only** (e.g. `192.168.1.20`).
   The on-screen keyboard has no `:` on its letters page, so the default port is added for you
   (8081 live, 8090 proxy).
2. Press **Down** four times to reach the buttons. **Connect to HamClock** = live mode;
   **Connect via proxy** = proxy mode (needs `hcproxy.py`).

A newly baked address replaces whatever was saved before. The bar at the bottom shows the address
being tried.

Remote: arrows move the cursor, **OK** taps (first press wakes the cursor), `*`/Rewind change the
address, Play pauses, Replay re-centres the cursor, Back exits.

## 2. Real Roku

1. Enable developer mode: Home x3, Up x2, Right, Left, Right, Left, Right. Set a password.
2. `ROKU_IP=192.168.1.60 ROKU_PASS=... ./tools/deploy.sh` (or upload the zip at `http://<roku-ip>`).
3. Debug console: `telnet <roku-ip> 8085` (the channel logs lines starting with `WsTask:`).

Only one sideloaded channel can be installed at a time; installing again replaces it.

## 3. HamClock running in WSL2 (Windows)

WSL2 sits on a private virtual network by default, so a Roku on your LAN cannot reach it. What worked:

1. Windows 11 22H2 or newer: put this in `%UserProfile%\.wslconfig`, then run `wsl --shutdown`:
   ```
   [wsl2]
   networkingMode=mirrored
   ```
2. In an Administrator PowerShell, allow inbound traffic to WSL and open the HamClock port:
   ```
   Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow
   New-NetFirewallRule -DisplayName "HamClock 8081" -Direction Inbound -Protocol TCP -LocalPort 8081 -Action Allow
   ```
3. Use the **Windows PC's LAN IP** on the Roku (WSL then shows the same address on `eth0`).
4. Check from a phone first: `http://<pc-ip>:8081/live.html` should show HamClock.

If HamClock says `Bind port 8081 failed: Address already in use`, something else holds the port: another
HamClock (`pgrep -a hamclock`), a Windows program (`netstat -ano | findstr :8081`), or a leftover port
forward (`netsh interface portproxy show all`). Without mirrored mode you can forward the port with
`netsh interface portproxy add v4tov4 ...`; the author did not test that route.

## 4. Try it in a simulator (no Roku, no HamClock)

Roku has no official emulator; this uses the community **brs-engine** (needs **Node 22+**).

```bash
pip install pillow numpy
python3 tools/hcproxy.py --mock --mock-size 1600x960   # fake HamClock: live WS :8081, REST :8080, proxy :8090
./tools/build.sh 127.0.0.1                             # live mode (or http://127.0.0.1:8090 for proxy mode)
```
Load `dist/hamclock-roku.zip` in **brs-desktop**, or headless: `npx brs-cli -e dist/hamclock-roku.zip`
(remote keys over HTTP: `curl -X POST localhost:8060/keypress/Right`). `./tools/smoke_test.sh` runs both
modes automatically. Note the simulator is slow at indexing very large byte arrays, so big pictures
display slowly there; a real Roku does not have that problem.

## Troubleshooting

* **"can't reach ws://..."** - the TCP connection failed. Check from another machine that
  `http://<hamclock-ip>:8081/live.html` loads. If HamClock is the Android app, turn on its "allow external
  access" setting. Docker needs `-p 8081:8081`. WSL2: see section 3.
* **"no handshake reply" / "HamClock refused the WebSocket"** - something answers on that port but it is not
  HamClock's live server (wrong port?), or HamClock already has its maximum number of live sessions.
* **"no picture from HamClock (timed out)"** - connected but no picture arrived within 8 s; the channel
  reconnects by itself. The `telnet <roku-ip> 8085` log shows what each read returned.
* **Taps do nothing** - you may be on the read-only port (8082); use 8081.
* **Taps land in the wrong place** - touches are sent in 800x480 app coordinates (HamClock's own web page
  does the same). The picture area is set near the top of `MainScene.brs` (`posterW` / `posterH`).
* **Top or bottom cut off** - your TV is overscanning. The picture is inset to about 92% of the screen; lower
  `posterW` / `posterH` further (keep them 5:3) or switch the TV's overscan / "Just Scan" setting.
* In proxy mode, `hcproxy.py --verbose` logs how long each HamClock capture takes.

## Verified / not verified

Verified:
* In the brs-engine simulator against a mock HamClock and against a real HamClock 4.33b99
  (`hamclock-web-1600x960`): connects, shows the dashboard about once a second, and a tap at the cursor opens
  the right popup. `tools/smoke_test.sh` covers both modes.
* On one real Roku (sideloaded, 1600x960 HamClock on WSL2 with mirrored networking): live mode connects,
  pictures display without flicker (two posters are swapped once the next picture has loaded), taps work, and
  the picture fits the TV after the overscan inset.

Not verified: other Roku models and OS versions; behaviour on a slow Pi or at larger HamClock sizes;
Roku Streaming Store certification (see PUBLISHING.md); the incremental `get_live.bin?` update format (not
used - every picture is a full PNG).

## License

[LICENSE](LICENSE). HamClock is a separate project with its own license and trademarks; this repository
contains none of its code.
