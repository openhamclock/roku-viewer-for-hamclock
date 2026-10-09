' Polls <baseUrl>/frame.jpg and publishes each downloaded frame as frameUri.
' status is "ok" or a human readable error.

sub init()
    m.top.functionName = "taskMain"
end sub

sub taskMain()
    seq = 0
    failures = 0
    clock = CreateObject("roTimespan")

    while true
        clock.Mark()
        base = m.top.baseUrl

        if base <> "" and not m.top.paused then
            seq = seq + 1
            file = "tmp:/frame" + seq.ToStr() + ".jpg"
            err = fetchToFile(base + "/frame.jpg?n=" + seq.ToStr(), file)
            if err = "" then
                failures = 0
                m.top.frameUri = file
                m.top.status = "ok"
                ' unique file names defeat the poster cache; prune old ones
                if seq > 3 then DeleteFile("tmp:/frame" + (seq - 3).ToStr() + ".jpg")
            else
                failures = failures + 1
                print "FrameTask: fetch failed: "; err; " ("; base; ")"
                DeleteFile(file)
                m.top.status = err
            end if
        end if

        delay = m.top.intervalMs - clock.TotalMilliseconds()
        if failures > 0 then delay = 2000
        if delay < 50 then delay = 50

        sleep(delay)
    end while
end sub

' returns "" on success, otherwise an error string
function fetchToFile(url as String, file as String) as String
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetUrl(url)
    if Left(url, 5) = "https" then
        xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        xfer.InitClientCertificates()
    end if

    if not xfer.AsyncGetToFile(file) then return "could not start request"

    msg = wait(6000, port)
    if msg = invalid then
        xfer.AsyncCancel()
        return "timed out"
    end if

    if type(msg) = "roUrlEvent" then
        code = msg.GetResponseCode()
        if code = 200 then return ""
        if code < 0 then return msg.GetFailureReason()
        return "HTTP " + code.ToStr()
    end if
    return "unexpected event"
end function
