' One-shot GET used for taps and other HamClock commands.

sub init()
    m.top.functionName = "taskMain"
end sub

sub taskMain()
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetUrl(m.top.url)
    if not xfer.AsyncGetToString() then
        m.top.code = -1
        return
    end if

    msg = wait(5000, port)
    if msg = invalid then
        xfer.AsyncCancel()
        m.top.code = -2
        return
    end if
    if type(msg) = "roUrlEvent" then
        m.top.body = msg.GetString()
        m.top.code = msg.GetResponseCode()
    else
        m.top.code = -3
    end if
end sub
