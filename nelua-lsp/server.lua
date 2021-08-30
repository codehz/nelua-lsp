local lfs = require 'lfs'
local console = require 'nelua.utils.console'
local inspect = require 'nelua.thirdparty.inspect'
local json = require 'nelua-lsp.json'
local utils = require 'nelua-lsp.utils'

local lenfmt = 'Content-Length: %d\r\n\r\n'

local server = {
  -- List of callbacks for each method.
  methods = {},
  -- Table of capabilities supported by this language server.
  capabilities = {}
}

-- Some LSP constants
local LSPErrorsCodes = {
  ParseError = -32700,
  InvalidRequest = -32600,
  MethodNotFound = -32601,
  InvalidParams = -32602,
  InternalError = -32603,
  serverErrorStart = -32099,
  serverErrorEnd = -32000,
  ServerNotInitialized = -32002,
  UnknownErrorCode = -32001,
}

-- Send a JSON response.
function server.send_response(id, result, error)
  local ans = {jsonrpc="2.0", id=id, result=result, error=error}
  local content = json.encode(ans)
  local header = string.format(lenfmt, #content)
  server.stdout:write(header)
  server.stdout:write(content)
  server.stdout:flush()
end

-- Send an error response with optional message.
function server.send_error(id, code, message)
  if type(code) == 'string' then
    -- convert a named code to its numeric error code
    message = message or code
    code = LSPErrorsCodes[code]
  end
  message = message or 'Error: '..tostring(code)
  server.send_response(id, nil, {code=code, message=message})
end

-- Send an notification
function server.send_notification(method, params)
  local ans = {jsonrpc="2.0", method=method, params=params}
  local content = json.encode(ans)
  local header = string.format(lenfmt, #content)
  server.stdout:write(header)
  server.stdout:write(content)
  server.stdout:flush()
end

-- Show message
function server.error(message)
  server.send_notification("window/showMessage", {type=1, message=message})
end
function server.warn(message)
  server.send_notification("window/showMessage", {type=2, message=message})
end
function server.info(message)
  server.send_notification("window/showMessage", {type=3, message=message})
end
function server.log(message)
  server.send_notification("window/showMessage", {type=4, message=message})
end

-- Wait and read next JSON request, returning it as a table.
local function read_request()
  local header = {}
  -- parse all lines from header
  while true do
    local line = server.stdin:read('L')
    line = line:gsub('[\r\n]+$', '') -- strip \r\n from line ending
    if line == '' then break end -- empty line means end of header
    local field, value = line:match('^([%w-]+):%s*(.*)')
    if field and value then
      header[field:lower()] = value
    end
  end
  -- check content length
  local length = tonumber(header['content-length'])
  assert(length and length > 0, 'invalid header content-length')
  -- read the content
  local content = server.stdin:read(length)
  -- parse JSON
  return json.decode(content)
end

-- Listen for incoming requests until the server is requested to shutdown.
function server.listen(stdin, stdout)
  server.stdin, server.stdout = stdin, stdout
  console.debug('LSP - listening')
  local shutdown = false
  local initialized = false
  for req in read_request do
    console.debug('LSP - '..req.method)
    if req.method == 'initialize' then
      -- send back the supported capabilities
      if req.params.rootPath then
        lfs.chdir(req.params.rootPath)
      end
      server.send_response(req.id, {capabilities=server.capabilities, serverInfo={name="Nelua LSP Server"}})
    elseif req.method == 'initialized' then
      -- both client and server agree on initialization
      initialized = true
    elseif req.method == 'shutdown' then
      -- we now expect an exit method for the next request
      shutdown = true
    elseif req.method == 'exit' then
      -- exit with 0 (success) when shutdown was requested
      os.exit(shutdown and 0 or 1)
    elseif initialized and not shutdown then
      -- process usual requests
      local method = server.methods[req.method]
      if method then
        local ok, err = pcall(method, req.id, req.params)
        if not ok then
          local errmsg = 'error while handling method:\n'..tostring(err)
          server.send_error(req.id, 'InternalError', errmsg)
        end
      else
        console.debug('error: unsupported method "'.. tostring(method)..'"')
        -- we must response that we were unable to fulfill the request
        server.send_error(req.id, 'MethodNotFound')
      end
    else -- invalid request when shutting down or initializing
      console.debug('error: invalid request "'..tostring(req.method)..'"')
      server.send_error(req.id, 'InvalidRequest')
    end
  end
  console.debug('LSP - connection closed')
end

return server
