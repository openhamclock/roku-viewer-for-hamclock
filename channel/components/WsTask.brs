' Talks directly to HamClock's live web server - the same WebSocket its own live.html page uses.
'   send "get_live.png?"               -> HamClock answers with ONE binary message: a full PNG of the screen
'   send "set_touch?x=X&y=Y&button=0"  -> a tap; X,Y are in HamClock's 800x480 "app" coordinates
' Default ports: 8081 read-write (taps work), 8082 read-only (view only).
'
' This does NOT use Roku's roWebSocket: on real Rokus that component refuses to open
' ("WebSockets are not allowed"). Instead this file speaks RFC 6455 itself over a plain TCP
' roStreamSocket: HTTP upgrade handshake, masked client frames, unmasked server frames.
'
' Scene -> task: set sendText, then bump sendSeq, to send a command.
' Task -> scene: frameUri (a PNG in tmp:/) and status ("ok" or a short error).

sub init()
    m.top.functionName = "taskMain"
end sub

sub taskMain()
    port = CreateObject("roMessagePort")
    c = invalid                             ' the open connection (see openConn)
    wsUrl = ""
    seq = 0
    waiting = false                         ' a picture has been requested and not yet received
    needNow = false                         ' ask for a picture immediately (right after connecting)
    sinceReq = CreateObject("roTimespan")   ' time since the last picture request
    reqAge = CreateObject("roTimespan")     ' how long the outstanding request has been waiting
    sinceReq.Mark()
    seenSend = m.top.sendSeq                ' persists so a tap is never missed
    seen = 0                                ' frames logged so far (just the first few, for diagnosis)

    while true
        url = m.top.url

        ' ---- connect (or reconnect) when we have an address but no live socket
        if url <> "" and (c = invalid or url <> wsUrl) then
            closeConn(c)
            c = invalid
            waiting = false
            wsUrl = url
            res = openConn(url, port)
            if res.conn <> invalid then
                c = res.conn
                sinceReq.Mark()
                needNow = true
            else
                m.top.status = res.err
                sleep(2000)
                wsUrl = ""                                          ' forces another attempt
            end if
        end if

        if c <> invalid then
            ' ---- ask for a new picture when it is due
            if not waiting and not m.top.paused and (needNow or sinceReq.TotalMilliseconds() >= m.top.intervalMs) then
                sendFrame(c, 1, "get_live.png?")
                waiting = true
                needNow = false
                reqAge.Mark()
                sinceReq.Mark()
            end if

            ' ---- a tap queued by the scene
            if m.top.sendSeq <> seenSend then
                seenSend = m.top.sendSeq
                ' "" + forces a plain string (a value read from a node field can be a boxed roString)
                sendFrame(c, 1, "" + m.top.sendText)
            end if

            ' ---- sleep until the socket has something (or 50 ms), then read and parse whatever came
            wait(50, port)
            frames = readFrames(c)
            for each f in frames
                if seen < 6 then
                    seen = seen + 1
                    print "WsTask: frame op="; f.op; " len="; f.len
                end if
                if f.op = 2 then
                    ' binary message = the PNG
                    waiting = false
                    if f.len > 8 then
                        seq = seq + 1
                        file = "tmp:/live" + seq.ToStr() + ".png"
                        if seq = 1 then print "WsTask: first picture, "; f.len; " bytes"
                        if c.rx.WriteFile(file, f.start, f.len) then
                            m.top.frameUri = file
                            m.top.status = "ok"
                            ' a new file name each time defeats the poster cache; prune old ones
                            if seq > 3 then DeleteFile("tmp:/live" + (seq - 3).ToStr() + ".png")
                        else
                            m.top.status = "could not save the picture"
                        end if
                    end if
                else if f.op = 1 then
                    ' text from HamClock; the only one that matters is the idle-timeout notice
                    text = bytesToStr(c.rx, f.start, f.len)
                    print "WsTask: text: "; text
                    if Left(text, 7) = "Session" then
                        m.top.status = text
                        c.closed = true
                    end if
                else if f.op = 9 then
                    ' ping: answer with a pong carrying the same bytes
                    sendFrame(c, 10, bytesToStr(c.rx, f.start, f.len))
                else if f.op = 8 then
                    print "WsTask: HamClock sent a close frame"
                    c.closed = true
                end if
            end for
            finishFrames(c)

            if c.closed then
                if m.top.status = "ok" or m.top.status = "" then m.top.status = "connection closed by HamClock"
                print "WsTask: connection closed"
                closeConn(c)
                c = invalid
                sleep(1500)
            end if

            ' ---- picture never arrived
            if c <> invalid and waiting and reqAge.TotalMilliseconds() > 8000 then
                print "WsTask: no picture within 8 s (have "; c.len - c.start; " unparsed bytes, need="; c.need; ") - reconnecting"
                m.top.status = "no picture from HamClock (timed out)"
                closeConn(c)
                c = invalid
            end if
        else
            sleep(200)
        end if
    end while
end sub

' ------------------------------------------------------------------ connection

' Open a TCP connection to the live port and do the WebSocket upgrade handshake.
' Returns { conn: <connection or invalid>, err: <message> }.
function openConn(url as String, port as Object) as Object
    p = parseWsUrl(url)
    if p.err <> "" then return { conn: invalid, err: p.err }

    print "WsTask: connecting to "; p.host; ":"; p.port
    addr = CreateObject("roSocketAddress")
    addr.SetHostName(p.host)
    addr.SetPort(p.port)
    sock = CreateObject("roStreamSocket")
    sock.SetSendToAddress(addr)
    print "WsTask: calling Connect()"
    okc = sock.Connect()
    print "WsTask: Connect() returned "; okc
    if not okc then
        print "WsTask: Connect() failed"
        return { conn: invalid, err: "can't reach " + url + " (is HamClock running and the port open?)" }
    end if

    ' get woken when data arrives (set after Connect so connecting stays a simple blocking call;
    ' if unsupported we simply poll every 50 ms)
    try
        sock.SetMessagePort(port)
        sock.NotifyReadable(true)
    catch err
        print "WsTask: async notify unavailable: "; err.message
    end try

    cap = 256 * 1024                        ' receive buffer; grows on demand for big pictures
    rx = CreateObject("roByteArray")
    rx[cap - 1] = 0                         ' pre-size it
    c = { sock: sock, rx: rx, cap: cap, start: 0, len: 0, need: 0, zero: 0, closed: false }

    ' ---- HTTP upgrade request
    kb = CreateObject("roByteArray")
    for i = 0 to 15
        kb[i] = Rnd(256) - 1
    end for
    crlf = Chr(13) + Chr(10)
    req = "GET / HTTP/1.1" + crlf
    req = req + "Host: " + p.host + ":" + p.port.ToStr() + crlf
    req = req + "Upgrade: websocket" + crlf
    req = req + "Connection: Upgrade" + crlf
    req = req + "Sec-WebSocket-Key: " + kb.ToBase64String() + crlf
    req = req + "Sec-WebSocket-Version: 13" + crlf + crlf
    rb = CreateObject("roByteArray")
    rb.FromAsciiString(req)
    if not sendAll(sock, rb) then
        print "WsTask: could not send the handshake"
        closeConn(c)
        return { conn: invalid, err: "could not send the handshake to " + url }
    end if

    ' ---- wait for the reply headers (ending in a blank line), read into a small scratch array
    hb = CreateObject("roByteArray")
    hb[4095] = 0
    hlen = 0
    t = CreateObject("roTimespan")
    t.Mark()
    hdrEnd = -1
    while hdrEnd < 0 and t.TotalMilliseconds() < 5000
        if sock.IsReadable() then
            n = sock.Receive(hb, hlen, 4096 - hlen)
            if n <= 0 then exit while
            hlen = hlen + n
            hdrEnd = findHeaderEnd(hb, hlen)
            if hlen >= 4096 then exit while
        else
            wait(100, port)
        end if
    end while
    if hdrEnd < 0 then
        print "WsTask: no handshake reply (received "; hlen; " bytes)"
        closeConn(c)
        return { conn: invalid, err: "no handshake reply from " + url }
    end if
    first = bytesToStr(hb, 0, minInt(hdrEnd, 60))
    print "WsTask: handshake reply: "; first
    if Instr(1, first, " 101") = 0 then
        closeConn(c)
        return { conn: invalid, err: "HamClock refused the WebSocket (" + first + ")" }
    end if

    ' anything after the blank line already belongs to the frame stream
    for i = hdrEnd + 4 to hlen - 1
        rx[c.len] = hb[i]
        c.len = c.len + 1
    end for

    print "WsTask: connected"
    return { conn: c, err: "" }
end function

sub closeConn(c as Dynamic)
    if c <> invalid then
        try
            c.sock.Close()
        catch err
            print "WsTask: close: "; err.message
        end try
    end if
end sub

' "ws://192.168.1.20:8081" -> { host, port, err }
function parseWsUrl(url as String) as Object
    s = url
    if Left(s, 5) = "ws://" then
        s = Mid(s, 6)
    else if Left(s, 6) = "wss://" then
        return { host: "", port: 0, err: "wss:// is not supported (HamClock uses plain ws://)" }
    end if
    slash = Instr(1, s, "/")
    if slash > 0 then s = Left(s, slash - 1)
    host = s
    portNum = 8081
    colon = Instr(1, s, ":")
    if colon > 0 then
        host = Left(s, colon - 1)
        portNum = Mid(s, colon + 1).ToInt()
    end if
    if host = "" or portNum <= 0 then return { host: "", port: 0, err: "bad address: " + url }
    return { host: host, port: portNum, err: "" }
end function

' ------------------------------------------------------------------ sending

' Send all of a byte array, tolerating partial writes.
function sendAll(sock as Object, data as Object) as Boolean
    total = data.Count()
    sent = 0
    tries = 0
    while sent < total and tries < 200
        n = sock.Send(data, sent, total - sent)
        if n > 0 then
            sent = sent + n
        else
            tries = tries + 1
            sleep(20)
        end if
    end while
    return sent >= total
end function

function xor8(a as Integer, b as Integer) as Integer
    return ((a or b) and (not (a and b))) and 255
end function

' One client frame. Client frames MUST be masked (RFC 6455). Short payloads only (< 65536 bytes).
' op: 1 = text, 10 = pong
sub sendFrame(c as Object, op as Integer, text as String)
    pl = CreateObject("roByteArray")
    pl.FromAsciiString(text)
    n = pl.Count()
    out = CreateObject("roByteArray")
    out.Push(128 + op)                       ' FIN + opcode
    if n < 126 then
        out.Push(128 + n)                    ' mask bit + length
    else
        out.Push(128 + 126)
        out.Push(n \ 256)
        out.Push(n mod 256)
    end if
    mask = [Rnd(256) - 1, Rnd(256) - 1, Rnd(256) - 1, Rnd(256) - 1]
    for i = 0 to 3
        out.Push(mask[i])
    end for
    for i = 0 to n - 1
        out.Push(xor8(pl[i], mask[i mod 4]))
    end for
    if not sendAll(c.sock, out) then
        print "WsTask: send failed (op "; op; ")"
        c.closed = true
    end if
end sub

' ------------------------------------------------------------------ receiving

' Pull whatever has arrived into the buffer, then list the complete frames now in it:
' [ { op, start, len } ] where start/len locate the payload inside c.rx.
' (c.start moves to just past the last complete frame; call finishFrames() when they have been handled.)
function readFrames(c as Object) as Object
    frames = []

    ' keep asking to be told about incoming data (harmless if it is already on)
    try
        c.sock.NotifyReadable(true)
    catch err
    end try

    guard = 0
    while c.sock.IsReadable() and guard < 300
        guard = guard + 1
        if c.cap - c.len < 65536 then growBuf(c, c.cap * 2)
        n = c.sock.Receive(c.rx, c.len, 65536)
        if n > 0 then
            c.len = c.len + n
            c.zero = 0
        else
            ' Nothing came back. On a real Roku that is often just "no data yet" (would-block), so only
            ' call the connection closed when the socket says so, or it keeps claiming readable-but-empty.
            c.zero = c.zero + 1
            if c.zero <= 5 then
                print "WsTask: Receive returned "; n; " connected="; c.sock.IsConnected(); " zero#"; c.zero
            end if
            if not c.sock.IsConnected() then
                print "WsTask: socket reports disconnected"
                c.closed = true
            else if c.zero >= 40 then
                print "WsTask: socket readable but empty for too long - treating as closed"
                c.closed = true
            end if
            exit while
        end if
    end while

    ' a frame we already measured is still arriving: nothing to parse yet
    if c.need > 0 and c.len < c.need then return frames
    c.need = 0

    off = c.start
    while true
        avail = c.len - off
        if avail < 2 then exit while
        b0 = c.rx[off]
        b1 = c.rx[off + 1]
        op = b0 and 15
        plen = b1 and 127
        hdr = 2
        if plen = 126 then
            if avail < 4 then exit while
            plen = c.rx[off + 2] * 256 + c.rx[off + 3]
            hdr = 4
        else if plen = 127 then
            if avail < 10 then exit while
            if c.rx[off + 2] + c.rx[off + 3] + c.rx[off + 4] + c.rx[off + 5] <> 0 or c.rx[off + 6] >= 128 then
                print "WsTask: absurd frame length - closing"
                c.closed = true              ' absurd length
                exit while
            end if
            plen = ((c.rx[off + 6] * 256 + c.rx[off + 7]) * 256 + c.rx[off + 8]) * 256 + c.rx[off + 9]
            hdr = 10
        end if
        if (b1 and 128) <> 0 then hdr = hdr + 4   ' servers must not mask, but skip the key if one is there
        if plen > 64 * 1024 * 1024 then
            c.closed = true
            exit while
        end if
        total = hdr + plen
        if avail < total then
            ' frame still arriving: remember where it ends (absolute index) and make room for all of it
            c.need = off + total
            if c.need > c.cap then growBuf(c, c.need + 65536)
            exit while
        end if
        frames.Push({ op: op, start: off + hdr, len: plen })
        off = off + total
    end while
    c.start = off
    return frames
end function

' Called once the frames from readFrames() have been handled. When everything received has been
' consumed the buffer simply starts over (no copying); a half-received frame is left exactly where it is.
sub finishFrames(c as Object)
    if c.start >= c.len then
        c.start = 0
        c.len = 0
        c.need = 0
    end if
end sub

sub growBuf(c as Object, newCap as Integer)
    if newCap <= c.cap then return
    print "WsTask: growing buffer to "; newCap
    nb = CreateObject("roByteArray")
    nb.Append(c.rx)
    nb[newCap - 1] = 0
    c.rx = nb
    c.cap = newCap
end sub

' index of the blank line ending the HTTP headers (the position of the first CR of CRLFCRLF), or -1
function findHeaderEnd(rx as Object, n as Integer) as Integer
    for i = 0 to n - 4
        if rx[i] = 13 and rx[i + 1] = 10 and rx[i + 2] = 13 and rx[i + 3] = 10 then return i
    end for
    return -1
end function

function bytesToStr(rx as Object, start as Integer, n as Integer) as String
    s = ""
    if n > 300 then n = 300
    for i = 0 to n - 1
        b = rx[start + i]
        if b > 0 then s = s + Chr(b)
    end for
    return s
end function

function minInt(a as Integer, b as Integer) as Integer
    if a < b then return a
    return b
end function
