-- sigsci-module-haproxy
-- Copyright 2017 Signal Sciences Corp. All Right Reserved
-- Proprietary and Confidential
--

--
-- INITIALIZATION AND CONFIGURATION
--

--
-- version inserted automatically to keep in sync
-- moduleVersion send back upstream
local version = "1.1.6"
local moduleVersion = "sigsci-module-haproxy " .. version

sigsci = {
  -- location of signal sciences agent.
  -- can be
  -- * "unix@/path or /path for unix domain sockets"
  -- * or 8.8.8.8:8080 for TCP/IP
  --
  agenthost = "/var/run/sigsci.sock",
  agentport = nil,

  -- if true, log internal errors
  log_internal_errors = false,

  -- if true, log verbosely
  log_debug = false,

  -- if true, log socket connection errors.
  log_network_errors = false,

  -- in seconds, integer only :-( 0 is off.
  timeout = 1,

  -- maximum post body size to capture
  maxpost = 100000,

  -- maxtime in milliseconds. If request took longer than
  -- this, send data upstream
  maxtime = 5000,

  -- maxsize in bytes. If response took most then this number
  -- of bytes, send data upstream. With HAProxy this number
  -- is often inaccurrate due to limitations of the API.
  maxsize = 512 * 1024,

  -- these are over-ridden in the init section
  server_name = "tbd",
  server_version = "tbd",
}

local mp = require 'sigsci/MessagePack'
local pprint = require 'sigsci/pprint'

-- log network errors, socket connection/read/write issues
local function network_error (...)
  if sigsci.log_network_errors then
    core.Warning("SIGSCI: NETWORK: " .. string.format(...))
  end
end

-- log internal errors -- nginx specific items, corrupted data, etc
local function internal_error (...)
  if sigsci.log_internal_errors then
    core.Warning("SIGSCI: INTERNAL: ".. string.format(...))
  end
end

-- log debug -- log internal debugging
local function debug (...)
  if sigsci.log_debug then
    core.Debug("SIGSCI: DEBUG: " .. string.format(...))
  end
end

-- string starts with http://lua-users.org/wiki/StringRecipes
local function string_starts_with (str, prefix)
  return string.sub(str, 1, string.len(prefix)) == prefix
end

-- simple function to help
local function istable (t)
  return type(t) == 'table'
end

-- This transforms the http request headers into a form usable by SigSci
--
-- nginx headers are stored as
-- header-name = value (single string)
-- header-name = { value1, value2 } (array of string)
--
-- SigSci API expects a list of key value pairs
-- {{ header: value }, {header: value} ... }
--
local function transform_headers (hapheaders)
  local headers = {}
  for k, values in pairs(hapheaders) do
    for i in pairs(values) do
      table.insert(headers, {k, values[i]})
    end
  end
  return headers
end

-- is the content-length valid and reflects a small enough
-- size that we can process?
local function valid_content_length (val, maxlen)
  if val == nil then
    return false
  end
  local len = tonumber(val)
  if len == nil then
    return false
  end
  if len < 0 then
    return false
  end
  return len <= maxlen
end

-- is this a valid method
-- we do not support some methods
--
local function valid_method (meth)
  if meth == nil then
    return false
  end
  local lcmeth = meth:lower()
  return not (lcmeth == "options" or lcmeth == "connect")
end

-- is this a content-type we can process
--
-- note: many content-types for JSON
-- http://stackoverflow.com/questions/477816/what-is-the-correct-json-content-type
--
local function valid_content_type (val)
  if val == nil then
    return false
  end
  val = val:lower()
  if string_starts_with(val, "application/x-www-form-urlencoded") then
    return true
  end
  if string_starts_with(val, "multipart/form-data") then
    return true
  end
  if val:find "json" or val:find "javascript" then
    return true
  end
  -- https://en.wikipedia.org/wiki/XML_and_MIME
  if val:find "xml" then
    return true
  end
  return false
end

local function now_millis()
  local timepair = core.now()
  return math.floor(timepair.sec * 1000 + timepair.usec/1000)
end

--- get a rpcid value
---
--- right now it returns random number, but this could
--- improvement
---
local function get_rpcid(txn)
  return txn.f:rand()
end

local function get_rdata (txn)

  local nowmillis = now_millis()

  -- http://cbonte.github.io/haproxy-dconv/1.7/configuration.html#7.3.4-ssl_fc
  local scheme
  if txn.f:ssl_fc() == true then
    scheme = "https"
  else
    scheme = "http"
  end

  return {
    AccessKeyID = "",
    ModuleVersion = moduleVersion,
    ServerVersion = sigsci.server_version,
    ServerFlavor = sigsci.server_name,
    -- ServerName = ngx.var.http_host,
    -- can we get rid of Timestamp and just use NowMillis?
    Timestamp = math.floor(nowmillis/1000),
    NowMillis = nowmillis,
    RemoteAddr = txn.f:src(),
    Method = txn.f:method(),
    Scheme = scheme,
    URI = txn.f:url(),
    Protocol = txn.f:req_ver(),
    TLSProtocol = txn.f:ssl_fc_protocol(),
    TLSCipher = txn.f:ssl_fc_cipher(),
    HeadersIn = transform_headers(txn.http:req_get_headers())
  }
end

-- returns a socket to agent or nil
local function get_socket ()
  local ok, err
  local sock = core.tcp()
  if sigsci.timeout > 0 then
    sock:settimeout(sigsci.timeout)
  end
  ok, err = sock:connect(sigsci.agenthost)
  if ok == nil then
    network_error("failed to connect to agent on %s: %s", sigsci.agenthost, err)
    return nil
  end
  return sock
end

-- sends a RPC call to agent
--
-- rpc_call = name of RPC method
-- rpcid a unique number.. not really used but part of spec
-- payload an lua table to be serialized.
-- returns nil or a lua table of response object
--
local function send_rpc (rpc_call, rpcid, payload)
  local ok, err, resp, buf, raw
  local sock = get_socket()
  if sock == nil then
    return nil
  end

  local obj = {
    0,
    rpcid,
    rpc_call,
    {
      payload,
    },
  }
  ok, buf = pcall(mp.pack, obj)
  if not ok then
    -- lua is tricky here.
    -- if ok == true, then buf is the result of mp.pack
    -- if ok == false, then buf is the error message
    internal_error("unable to create object for %s: %s", rpc_call, buf)
    return nil
  end
  debug("RPC LENGTH: %d", string.len(buf))
  ok, err = sock:send(buf)
  if ok == nil then
    network_error("unable to send %s: %s", rpc_call, err)
    return nil
  end
  raw, err = sock:receive("*a")
  if raw == nil then
    network_error("unable to recieve %s: %s", rpc_call, err)
    return nil
  end
  ok, resp = pcall(mp.unpack, raw)
  if not ok then
    debug("failed to unpack: %s", resp)
    return nil
  end
  --debug("Dump: " .. pprint.pformat(resp))
  if #resp ~= 4 or resp[1] ~= 1 or resp[2] ~= rpcid or resp[3] then
    internal_error("corrupted reply for %s: %s", rpc_call, pprint.pformat(resp))
    return nil
  end

  return resp[4]
end

-- pre-request
--
local function sigsci_prerequest(txn)
  local ctx
  local rdata = get_rdata(txn)

  if not valid_method(rdata.Method) then
    debug("prerequest: ignoring method '%s'", rdata.Method)
    ctx = {
      -- indicate that inspection was not performed on the request
      predata = nil
    }
    txn:set_priv(ctx)
    return
  end

  -- get post data if content-type is right, and not too large
  local content_len = txn.f:req_body_size()
  local content_type = txn.f:req_hdr("content-type")
  debug("method %s prerequest: content_len %d content_type = %s", rdata.Method, content_len, content_type)

  local postbody = nil
  if valid_content_length(content_len, sigsci.maxpost) and valid_content_type(content_type) then
    postbody = txn.f:req_body()
  end
  rdata["PostBody"] = postbody

  -- save current state in rdata.. some thing in HAProxy are not available
  -- in the post request
  ctx = {
    predata = rdata
  }
  txn:set_priv(ctx)

  local resp = send_rpc("RPC.PreRequest", get_rpcid(txn), rdata)
  if resp == nil then
    -- agent or module down, fail open. Error already logged.
    return
  end

  -- Fixups for RPCv1
  --
  -- RPCv1 will include empty values in the response that in
  -- RPCv0 were not included, so these need to be fixed
  -- to support RPCv1 if the missing value is relied upon.
  -- (e.g., RequestID missing means do not run the
  -- RPC.UpdateRequest call).
  --
  -- See: https://github.com/tinylib/msgp/issues/103
  if resp.RequestID == nil then
    resp.RequestID = ""
  end

  -- save in context... maybe wish to use a table so we can store other
  -- data
  -- zap out stuff we don't need
  -- and add stuff we do need.
  rdata.PostData = ""
  rdata.RequestID = resp.RequestID
  rdata.WAFResponse = resp.WAFResponse
  ctx = {
    predata = rdata
  }
  txn:set_priv(ctx)

  txn.http:req_add_header("X-SigSci-RequestID", resp.RequestID)
  txn.http:req_add_header("X-SigSci-AgentResponse", resp.WAFResponse)

  -- Add any headers to the response
  local request_headers = resp.RequestHeaders
  if istable(request_headers) then
    for i = 1, #request_headers do
      local v = request_headers[i]
      txn.http:res_add_header(v[1], v[2])
      debug("set additional request header: %s: %s", v[1], v[2])
    end
  end

  local waf_response = tonumber(resp.WAFResponse)
  if waf_response == 406 then
    -- blocking case
    debug("blocking with status=%d", waf_response)
    -- txn.res:send("HTTP/1.1 406 Not Acceptable\r\nContent-Length: 19\r\n" ..
    -- "Content-Type: text/plain; charset=utf-8\r\n\r\n406 Not Acceptable\n")
    txn.http:req_add_header("X-SigSci-Blocking", "yes")
    -- txn.http:res_set_status(waf_response)
    -- txn.done()
    local updatedata = {
      RequestID = resp.RequestID,
      ResponseCode = waf_response,
      ResponseSize = 0,
      ResponseMillis = 0
      -- HeadersOut = transform_headers(txn.http:res_get_headers())
    }
    -- just update status, time, size, etc
    send_rpc("RPC.UpdateRequest", get_rpcid(txn), updatedata)
    txn:done()
    return
  else
    txn.http:req_add_header("X-SigSci-Blocking", "no")
    return
  end

  -- unknown response, fail open
  internal_error("failing open, agent responded with invalid exit code ", resp.WAFResponse)

end

local function sigsci_postrequest(txn)
  -- local method = txn.f:method()
  -- if not valid_method(method) then
  -- debug("postrequest: ignoring method '%s'", request_method)
  -- return
  -- end

  -- get the context stored from the prerequest processing
  local ctx = txn:get_priv()
  if ctx == nil then
    internal_error("postrequest: missing context!")
    return
  end

  -- get the prerequest data from the context - nil means that request was not inspected, so ignore the response
  local rdata = ctx.predata
  if rdata == nil then
    return
  end

  local requestid = rdata.RequestID

  -- make sure we don't double send the post data
  rdata.PostData = ""

  -- http response status
  local status = txn.f:status()

  -- response headers
  local hdr = txn.http:res_get_headers()

  -- unclear when this fires or if it's acurate at all.
  local bytesout = 0
  local cl = hdr["content-length"]
  if cl ~= nil then
    bytesout = tonumber(cl[0])
  end
  -- total request time in milliseconds
  local millis = now_millis() - rdata.NowMillis
  if millis < 0 then
    -- can happen due to clock drift, lack of montonicity, etc
    millis = 0
  end

  debug("postrequest: id=%s, code=%d, size=%d, millis=%s", requestid, status, bytesout, millis)

  -- following conditions:
  -- * the request has a request ID
  -- * the response size exceeds the configured maximum size
  -- * the response time exceeds the configured maximum response time
  -- The update returned to the agent simply updates the stored metadata.
  --
  if requestid ~= "" then
    local updatedata = {
      RequestID = requestid,
      ResponseCode = status,
      ResponseSize = bytesout,
      ResponseMillis = millis,
      HeadersOut = transform_headers(hdr)
    }

    --if access_key_id ~= nil then
    -- updatedata.AccessKeyID = access_key_id
    --end

    -- just update status, time, size, etc
    send_rpc("RPC.UpdateRequest", get_rpcid(txn), updatedata)
    return
  end

  -- We do not have a request id. The original request looked fine
  -- TODO or if time is too long, or if size is too large
  --
  if status >= 300 or bytesout > sigsci.maxsize or millis > sigsci.maxtime then
    -- just update status, time, size, etc
    -- copy full request, minus post data and headers locally

    --if access_key_id ~= nil then
    -- rdata.AccessKeyID = access_key_id
    --end

    -- fill in response data
    rdata.HeadersOut = transform_headers(txn.http:res_get_headers())
    rdata.ResponseCode = status
    rdata.ResponseSize = bytesout
    rdata.ResponseMillis = millis

    send_rpc("RPC.PostRequest", get_rpcid(txn), rdata)
    return
  end

  -- nothing to do
end

local function sigsci_init()
  -- lua *should* support 123.123.123.13:9090 forms
  -- but also supports a two-arg version of connect
  -- if you with to specify a (host,port) pair, then
  -- merged into combined host:port
  if type(sigsci.agentport) == 'number' then
    sigsci.agenthost = string.format("%s:%d", sigsci.agenthost, sigsci.agentport)
  end
  core.Info(string.format("SIGSCI_INIT %s on %s", moduleVersion, sigsci.agenthost))
  local infos = core.get_info()
  -- globals
  sigsci.server_name = infos.Name
  sigsci.server_version = infos.Version
end

---
--- REGISTRATION
---
core.register_init(sigsci_init)
core.register_action("sigsci_prerequest", { "http-req" }, sigsci_prerequest)
core.register_action("sigsci_postrequest", { "http-res" }, sigsci_postrequest)

-- vim: tabstop=2 expandtab shiftwidth=2 softtabstop=2
