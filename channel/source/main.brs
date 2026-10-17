' HamClock for Roku - entry point
sub Main()
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)
    screen.CreateScene("MainScene")
    screen.Show()

    ' memory monitoring (Roku certification checks for these calls)
    mon = invalid
    try
        mon = CreateObject("roAppMemoryMonitor")
        mon.SetMessagePort(port)
        mon.EnableMemoryWarningEvent(true)
        mon.EnableLowGeneralMemoryEvent(true)
        print "Memory: limit "; mon.GetChannelMemoryLimit(); " bytes, available "; mon.GetChannelAvailableMemory(); ", used "; mon.GetMemoryLimitPercent(); "% of limit"
    catch e
        mon = invalid     ' older firmware or simulator without the memory monitor
    end try

    while true
        msg = wait(0, port)
        if type(msg) = "roSGScreenEvent" then
            if msg.IsScreenClosed() then return
        else if type(msg) = "roAppMemoryMonitorEvent" then
            print "Memory event: "; msg.GetInfo()
        end if
    end while
end sub
