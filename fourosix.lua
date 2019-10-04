function readFile(file)
    local f = io.open(file, "rb")
    local content = f:read("a*")
    f:close()
    return content
end

local function fourosix(applet)
    -- If client is POSTing request, receive body
    -- local request = applet:receive()

    local response = string.format([[ %s ]], readFile("/usr/local/etc/haproxy/errors/406.http"))

    applet:set_status(406)
    applet:add_header("content-length", string.len(response))
    applet:add_header("content-type", "text/html")
    applet:start_response()
    applet:send(response)
end

core.register_service("fourosix", "http", fourosix)
