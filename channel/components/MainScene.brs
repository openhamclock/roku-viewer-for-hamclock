' HamClock for Roku
'
' Shows HamClock's screen and turns remote presses into HamClock taps.
' Two ways to reach HamClock, chosen by the saved address:
'   ws://host:8081     direct to HamClock's live web port (WebSocket, PNG pictures)   <- default
'   http://host:8090   through tools/hcproxy.py (for Rokus without roWebSocket)
'   Arrows   move the on-screen cursor (hold to accelerate)
'   OK       tap at the cursor (first press just wakes the cursor)
'   Options  change proxy address     (Rewind does the same, for simulators without Options)
'   Play     pause / resume updates
'   Replay   re-centre cursor
'   Back     exit

sub init()
    m.top.backgroundColor = "0x000000FF"
    m.top.backgroundURI = ""

    m.frame = m.top.findNode("frame")       ' the poster currently on screen
    m.back = m.top.findNode("frameB")       ' the hidden one a new picture loads into
    m.cursor = m.top.findNode("cursor")
    m.hbar = m.top.findNode("hbar")
    m.vbar = m.top.findNode("vbar")
    m.statusBar = m.top.findNode("statusBar")
    m.statusLabel = m.top.findNode("statusLabel")
    m.cursorTimer = m.top.findNode("cursorTimer")
    m.statusTimer = m.top.findNode("statusTimer")
    m.tapTimer = m.top.findNode("tapTimer")

    ' Where the HamClock picture sits, in scene (FHD 1920x1080) coordinates. HamClock is 5:3, so keep
    ' W:H = 5:3. It is deliberately smaller than the screen: many TVs overscan (crop a few percent off every
    ' edge), which cut off the top and bottom rows. For a bigger picture raise W and H together
    ' (1800x1080 = full height, the old setting) and re-centre X = (1920-W)/2, Y = (1080-H)/2.
    m.posterW = 1650
    m.posterH = 990
    m.posterX = (1920 - m.posterW) / 2
    m.posterY = (1080 - m.posterH) / 2
    for each p in [m.frame, m.back]
        p.translation = [m.posterX, m.posterY]
        p.width = m.posterW
        p.height = m.posterH
    end for

    m.cx = m.posterX + m.posterW / 2
    m.cy = m.posterY + m.posterH / 2
    m.cursor.translation = [m.cx, m.cy]

    m.sinceMove = CreateObject("roTimespan")
    m.streak = 0
    m.lastDir = ""
    m.tasks = []
    m.errorShown = false
    m.dialog = invalid
    m.reopen = false

    m.cursorTimer.observeField("fire", "onCursorTimer")
    m.statusTimer.observeField("fire", "onStatusTimer")
    m.tapTimer.observeField("fire", "onTapTimer")

    ' proxy mode: polls JPEGs over HTTP
    m.frameTask = CreateObject("roSGNode", "FrameTask")
    m.frameTask.intervalMs = 1000
    m.frameTask.observeField("frameUri", "onFrame")
    m.frameTask.observeField("status", "onStatus")

    ' live mode: PNGs over HamClock's WebSocket
    m.wsTask = CreateObject("roSGNode", "WsTask")
    m.wsTask.intervalMs = 1000
    m.wsTask.observeField("frameUri", "onFrame")
    m.wsTask.observeField("status", "onStatus")
    m.sendSeq = 0

    ' Roku launch-time beacons: AppLaunchComplete says "the UI is up and usable". If the first thing the
    ' user sees is the address dialog, that time is bracketed with AppDialogInitiate/AppDialogComplete.
    m.launched = false
    m.launchDialog = false

    m.base = loadBase()
    if m.base = "" then
        showSettings()
    else
        startFrames()
    end if

    m.top.setFocus(true)
    if not m.launchDialog then launchDone()
end sub

sub beacon(name as String)
    try
        m.top.signalBeacon(name)
    catch err
        ' not every engine (e.g. the desktop simulator) has beacons
    end try
end sub

sub launchDone()
    if m.launched then return
    m.launched = true
    beacon("AppLaunchComplete")
end sub

' ---------------------------------------------------------------- settings

function loadBase() as String
    sec = CreateObject("roRegistrySection", "hamclock")
    saved = ""
    if sec.Exists("base") then saved = sec.Read("base")
    seen = ""
    if sec.Exists("cfg_seen") then seen = sec.Read("cfg_seen")

    ' optional address baked in at build time (tools/build.sh <address> adds a default_address line to the
    ' manifest). When it is new (different from the last one we applied) it replaces whatever was saved,
    ' so a bad entry typed earlier can never trap you - just rebuild with the right address.
    ' A store build has no such line, so this is empty and nothing is read from disk.
    cfg = ""
    raw = CreateObject("roAppInfo").GetValue("default_address")
    if Type(raw) = "String" or Type(raw) = "roString" then
        cfg = normalizeBase(raw, "ws://")
    end if
    if cfg <> "" and cfg <> seen then
        sec.Write("cfg_seen", cfg)
        sec.Write("base", cfg)
        sec.Flush()
        return cfg
    end if
    return saved
end function

sub saveBase(v as String)
    sec = CreateObject("roRegistrySection", "hamclock")
    sec.Write("base", v)
    sec.Flush()
end sub

' "192.168.1.50" -> "ws://192.168.1.50:8081", "ws://host:9000" stays, "http://host" -> "http://host:8090"
' defaultScheme is used when none was typed
function normalizeBase(s as String, defaultScheme as String) as String
    s = s.Trim()
    if s = "" then return ""

    scheme = ""
    if Left(s, 5) = "ws://" then
        scheme = "ws://"
    else if Left(s, 6) = "wss://" then
        scheme = "wss://"
    else if Left(s, 7) = "http://" then
        scheme = "http://"
    else if Left(s, 8) = "https://" then
        scheme = "https://"
    end if
    if scheme = "" then
        scheme = defaultScheme
    else
        s = Mid(s, Len(scheme) + 1)
    end if

    while Right(s, 1) = "/"
        s = Left(s, Len(s) - 1)
    end while

    if Instr(1, s, ":") = 0 then
        if scheme = "ws://" then s = s + ":8081"
        if scheme = "http://" then s = s + ":8090"
    end if
    return scheme + s
end function

' true when the saved address is a live-port (WebSocket) address
function isLive() as Boolean
    return Left(m.base, 3) = "ws:" or Left(m.base, 4) = "wss:"
end function

sub showSettings()
    dlg = CreateObject("roSGNode", "StandardKeyboardDialog")
    ' Always start with an EMPTY field (nothing to delete), and show what is saved in the title.
    ' Cancel keeps the current address.
    if m.base <> "" then
        dlg.title = "HamClock IP (now " + m.base + ")"
    else
        dlg.title = "HamClock IP, e.g. 192.168.1.20"
    end if
    dlg.text = ""
    ' "HamClock" = its live port 8081 (no proxy needed); "proxy" = hcproxy.py on port 8090
    dlg.buttons = ["Connect to HamClock", "Connect via proxy", "Cancel"]
    dlg.observeField("buttonSelected", "onSettingsButton")
    dlg.observeField("wasClosed", "onSettingsClosed")
    m.dialog = dlg
    m.top.dialog = dlg
    if not m.launched and not m.launchDialog then
        m.launchDialog = true
        beacon("AppDialogInitiate")
    end if
end sub

sub onSettingsButton()
    if m.dialog = invalid then return
    pick = m.dialog.buttonSelected
    if pick = 0 or pick = 1 then
        defScheme = "ws://"
        if pick = 1 then defScheme = "http://"
        newBase = normalizeBase(m.dialog.text, defScheme)
        if newBase <> "" then
            m.base = newBase
            saveBase(newBase)
            startFrames()
            showStatus("Connecting to " + newBase + " ...", 3)
        else
            m.reopen = true
        end if
    end if
    m.dialog.close = true
end sub

sub onSettingsClosed()
    m.dialog = invalid
    m.top.setFocus(true)
    if m.reopen then
        m.reopen = false
        showSettings()
    else
        if m.base = "" then
            showStatus("No HamClock address set  -  press * (Options) or Rewind to enter one", 0)
        end if
        if m.launchDialog then
            m.launchDialog = false
            beacon("AppDialogComplete")
            launchDone()
        end if
    end if
end sub

' ---------------------------------------------------------------- frames

sub startFrames()
    m.frameTask.control = "STOP"
    m.wsTask.control = "STOP"
    if isLive() then
        m.wsTask.url = m.base
        m.wsTask.control = "RUN"
    else
        m.frameTask.baseUrl = m.base
        m.frameTask.control = "RUN"
    end if
end sub

' double buffering: load the new picture into the hidden poster, swap when it has finished loading
sub onFrame(event as Object)
    m.back.unobserveField("loadStatus")
    m.back.observeField("loadStatus", "onLoaded")
    m.back.uri = event.getData()
end sub

sub onLoaded(event as Object)
    if event.getData() <> "ready" then return        ' still loading (or failed: keep showing the old picture)
    shown = event.getRoSGNode()
    shown.unobserveField("loadStatus")
    shown.visible = true
    m.frame.visible = false
    m.back = m.frame
    m.frame = shown
end sub

sub onStatus(event as Object)
    s = event.getData()
    if s = "ok" then
        if m.errorShown then
            m.errorShown = false
            hideStatus()
        end if
    else
        m.errorShown = true
        showStatus("Can't reach " + m.base + "  (" + s + ")   -   press * to change address", 0)
    end if
end sub

' ---------------------------------------------------------------- status bar

sub showStatus(text as String, seconds as Integer)
    m.statusLabel.text = text
    m.statusBar.visible = true
    m.statusTimer.control = "stop"
    if seconds > 0 then
        m.statusTimer.duration = seconds
        m.statusTimer.control = "start"
    end if
end sub

sub hideStatus()
    m.statusBar.visible = false
end sub

sub onStatusTimer()
    if not m.errorShown then hideStatus()
end sub

' ---------------------------------------------------------------- cursor + keys

sub wakeCursor()
    m.cursor.visible = true
    m.cursorTimer.control = "stop"
    m.cursorTimer.control = "start"
end sub

sub onCursorTimer()
    m.cursor.visible = false
end sub

sub onTapTimer()
    m.hbar.color = "0xFFFFFFFF"
    m.vbar.color = "0xFFFFFFFF"
end sub

sub moveCursor(key as String)
    ' Acceleration only for a sustained run of rapid presses in ONE direction (i.e. a held key).
    ' A couple of quick taps, or a change of direction, always move a precise 10 px.
    if key = m.lastDir and m.sinceMove.TotalMilliseconds() < 180 then
        m.streak = m.streak + 1
    else
        m.streak = 0
    end if
    m.lastDir = key
    m.sinceMove.Mark()

    stepPx = 10
    if m.streak > 3 then stepPx = 10 + (m.streak - 3) * 6
    if stepPx > 60 then stepPx = 60

    if key = "left" then m.cx = m.cx - stepPx
    if key = "right" then m.cx = m.cx + stepPx
    if key = "up" then m.cy = m.cy - stepPx
    if key = "down" then m.cy = m.cy + stepPx

    if m.cx < m.posterX then m.cx = m.posterX
    if m.cx > m.posterX + m.posterW - 1 then m.cx = m.posterX + m.posterW - 1
    if m.cy < m.posterY then m.cy = m.posterY
    if m.cy > m.posterY + m.posterH - 1 then m.cy = m.posterY + m.posterH - 1

    m.cursor.translation = [m.cx, m.cy]
    wakeCursor()
end sub

sub sendTap()
    if isLive() then
        ' HamClock's touch space is always its 800x480 "app" size, whatever the screen resolution
        ax = Int(((m.cx - m.posterX) * 800) / m.posterW)
        ay = Int(((m.cy - m.posterY) * 480) / m.posterH)
        if ax < 0 then ax = 0
        if ax > 799 then ax = 799
        if ay < 0 then ay = 0
        if ay > 479 then ay = 479
        m.wsTask.sendText = "set_touch?x=" + ax.ToStr() + "&y=" + ay.ToStr() + "&button=0"
        m.sendSeq = m.sendSeq + 1
        m.wsTask.sendSeq = m.sendSeq
    else
        ' proxy mode: position as 0..9999 across the picture; the proxy scales it to HamClock's 800x480
        nx = Int(((m.cx - m.posterX) * 10000) / m.posterW)
        ny = Int(((m.cy - m.posterY) * 10000) / m.posterH)
        if nx < 0 then nx = 0
        if nx > 9999 then nx = 9999
        if ny < 0 then ny = 0
        if ny > 9999 then ny = 9999
        runHttp(m.base + "/touch?x=" + nx.ToStr() + "&y=" + ny.ToStr())
    end if

    m.hbar.color = "0xFFD000FF"
    m.vbar.color = "0xFFD000FF"
    m.tapTimer.control = "stop"
    m.tapTimer.control = "start"
    wakeCursor()
end sub

sub togglePause()
    paused = not m.frameTask.paused
    m.frameTask.paused = paused
    m.wsTask.paused = paused
    if paused then
        showStatus("Paused  -  press Play to resume", 0)
    else
        showStatus("Resumed", 2)
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false

    if key = "left" or key = "right" or key = "up" or key = "down" then
        moveCursor(key)
        return true
    else if key = "OK" then
        if m.cursor.visible then
            sendTap()
        else
            wakeCursor()
        end if
        return true
    else if key = "options" or key = "rewind" then
        showSettings()
        return true
    else if key = "play" then
        togglePause()
        return true
    else if key = "replay" then
        m.cx = m.posterX + m.posterW / 2
        m.cy = m.posterY + m.posterH / 2
        m.cursor.translation = [m.cx, m.cy]
        wakeCursor()
        return true
    end if

    ' Back and anything else: let the system handle it (Back exits the channel)
    return false
end function

' ---------------------------------------------------------------- one-shot HTTP

sub runHttp(url as String)
    t = CreateObject("roSGNode", "HttpTask")
    t.url = url
    t.observeField("state", "onHttpState")
    m.tasks.Push(t)
    t.control = "RUN"
end sub

sub onHttpState(event as Object)
    t = event.getRoSGNode()
    if t.state <> "stop" then return

    if t.code <> 200 then
        showStatus("Tap failed (" + t.code.ToStr() + ")", 3)
    end if

    keep = []
    for each x in m.tasks
        if not x.isSameNode(t) then keep.Push(x)
    end for
    m.tasks = keep
end sub
