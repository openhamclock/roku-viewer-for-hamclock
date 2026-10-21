# HamClock for Roku

A thin-client Roku channel for [HamClock](https://github.com/openhamclock/hamclock). Roku can't run
HamClock's C++ engine the way the Android app does (no native code, no WebView), so HamClock keeps
running on a Pi / PC / Docker host / Android device and the Roku just displays it and sends
remote-control taps.

> **Unofficial.** This is an independent project. It is not made, endorsed or supported by the author of
> HamClock or by Roku, Inc. It contains no HamClock code; it only talks to a HamClock you run yourself.

# Use App Store Link (easy install)
See https://my.roku.com/account/add/9NPZQZD

# How to Sideload
1. Using your Roku remote, enable developer mode using this sequence: Home, Home, Home, Up, Up, Right, Left, Right, Left, Right. See https://developer.roku.com/dev/docs/developer-setup#sideloading-apps
2. Set a password for rokudev
3. Reboot Roku
4. Connect to Roku on a separate PC at http://\<roku-ip\> using the username and password you set (https does not work make sure it is http)
  <img width="1289" height="600" alt="image" src="https://github.com/user-attachments/assets/0e19b025-f20b-44a3-b6fc-4745cd8d397c" />

6. Download latest Release from [Releases](https://github.com/openhamclock/roku-viewer-for-hamclock/releases) page
7. Upload zip using the Roku web interface you connected to in Step 4
8. Click "Install with zip"
9. HamClock application will start on Roku
10. Press * button to set IP for your HamClock running on RPi, Quadra, WSL etc

# License

[LICENSE](LICENSE). HamClock is a separate project with its own license and trademarks; this repository
contains none of its code.
