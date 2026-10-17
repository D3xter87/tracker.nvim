-- Async HTTP client built on `vim.system` + the `curl` binary.
--
-- Same transport as cicd.nvim / review.nvim: no plenary, so a curl failure
-- (no network, DNS, timeout) lands in our completion handler as an exit code
-- instead of an unhandled libuv error.
--
-- Request bodies go through stdin (`--data-binary @-`), never argv: Jira
-- descriptions and comments can be long, and Windows caps a command line at
-- 32k characters.
--
-- Contract: cb receives { ok, status, body, headers, err }. Network failures
-- and non-2xx responses both set ok=false with err populated; cb always runs
-- on the main loop.

local M = {}

local CURL_EXIT_MESSAGES = {
  [3] = "malformed URL",
  [5] = "couldn't resolve proxy",
  [6] = "couldn't resolve host",
  [7] = "could not connect (offline / VPN?)",
  [22] = "HTTP error returned",
  [26] = "could not read request body",
  [28] = "request timed out",
  [35] = "SSL handshake failed",
  [47] = "too many redirects",
  [52] = "empty reply from server",
  [56] = "network connection reset",
  [60] = "SSL certificate problem",
  [77] = "CA certificate read error",
}

---@param status number|nil
---@return string
function M.describe_error(status)
  if status == 401 then return "auth failed (check the netrc entry / token)" end
  if status == 403 then return "forbidden (token lacks permission)" end
  if status == 404 then return "not found" end
  if status == 429 then return "rate limited" end
  if status and status >= 500 then return "server error " .. status end
  return "HTTP " .. tostring(status or "?")
end

---@param code integer  curl process exit code
---@return string
function M.describe_curl_exit(code)
  return CURL_EXIT_MESSAGES[code] or ("curl exit code " .. code)
end

---URL-encode a string for use as a path segment / query value. Encodes every
---byte outside the unreserved set (alpha / digit / "-" / "." / "_" / "~").
---@param s string
---@return string
function M.uri_encode(s)
  return (s:gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function build_query_string(query)
  if not query or vim.tbl_isempty(query) then return "" end
  local keys = vim.tbl_keys(query)
  table.sort(keys) -- stable URLs: easier to read in debug logs
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, M.uri_encode(tostring(k)) .. "=" .. M.uri_encode(tostring(query[k])))
  end
  return "?" .. table.concat(parts, "&")
end

local function build_args(opts)
  local args = { "curl", "--silent", "--include", "--max-time", tostring(opts.timeout or 30),
                 "-X", (opts.method or "GET"):upper() }
  if opts.follow_redirects then
    table.insert(args, "--location")
  end
  if opts.headers then
    for k, v in pairs(opts.headers) do
      table.insert(args, "-H")
      table.insert(args, k .. ": " .. v)
    end
  end
  if opts.body then
    table.insert(args, "--data-binary")
    table.insert(args, "@-")
  end
  -- Multipart fields (attachments). A value starting with "@" is a file path,
  -- which is curl's own -F convention.
  for _, field in ipairs(opts.form or {}) do
    table.insert(args, "-F")
    table.insert(args, field[1] .. "=" .. field[2])
  end
  table.insert(args, opts.url .. build_query_string(opts.query))
  return args
end

---Parses a curl --include response into status/body/headers. Walks the stream
---line by line so blank lines inside a JSON body never get mistaken for the
---header/body separator, and restarts at every fresh status line (1xx
---preludes, followed redirects).
---@param raw string
---@return integer|nil status, string|nil body, table|nil headers
local function parse_response(raw)
  if not raw or raw == "" then return nil end

  local pos = 1
  local len = #raw
  local status
  local headers = {}

  while pos <= len do
    local nl = raw:find("\n", pos, true)
    local line, line_end
    if not nl then
      line = raw:sub(pos)
      line_end = len + 1
    else
      local stop = nl - 1
      if stop >= pos and raw:sub(stop, stop) == "\r" then stop = stop - 1 end
      line = raw:sub(pos, stop)
      line_end = nl + 1
    end

    if line == "" then
      local peek = raw:sub(line_end, line_end + 4)
      if peek == "HTTP/" then
        status = nil
        headers = {}
        pos = line_end
      else
        return status, raw:sub(line_end), headers
      end
    else
      local code = line:match("^HTTP/[%d%.]+ (%d+)")
      if code then
        status = tonumber(code)
        headers = {}
      else
        local k, v = line:match("^([^:]+):%s*(.-)%s*$")
        if k then headers[k:lower()] = v end
      end
      pos = line_end
    end
  end

  return status, "", headers
end

M._parse_response = parse_response

---@class TrackerHttpRequest
---@field url string
---@field method string?
---@field headers table<string,string>?
---@field query table?
---@field body string?            sent through stdin
---@field form table?             list of { name, value } multipart fields
---@field timeout integer?        seconds, default 30
---@field follow_redirects boolean?

---@param opts TrackerHttpRequest
---@param cb fun(result: { ok: boolean, status: number?, body: string?, headers: table?, err: string? })
function M.request(opts, cb)
  local args = build_args(opts)
  if require("tracker.config").get().debug then
    vim.schedule(function()
      vim.notify(("tracker: %s %s"):format(args[7], args[#args]), vim.log.levels.DEBUG)
    end)
  end
  local ok, err = pcall(vim.system, args, { text = true, stdin = opts.body }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        cb({ ok = false, err = M.describe_curl_exit(out.code) })
        return
      end
      local status, body, headers = parse_response(out.stdout or "")
      if not status then
        cb({ ok = false, err = "malformed response" })
        return
      end
      if status >= 200 and status < 300 then
        cb({ ok = true, status = status, body = body, headers = headers })
      else
        cb({
          ok = false, status = status, body = body, headers = headers,
          err = M.describe_error(status),
        })
      end
    end)
  end)

  if not ok then
    vim.schedule(function() cb({ ok = false, err = "curl invocation failed: " .. tostring(err) }) end)
  end
end

---Download `url` to the file `path` (binary-safe: curl writes the file, the
---body never passes through Lua). Redirects are followed — curl drops the
---Authorization header when a redirect leaves the host, so a pre-signed
---media URL never sees the token. A failed download leaves no file behind.
---@param opts { url: string, headers: table<string,string>?, timeout: integer? }
---@param path string
---@param cb fun(path: string|nil, err: string|nil)
function M.download(opts, path, cb)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local part = path .. ".part"
  local args = { "curl", "--silent", "--location", "--max-time", tostring(opts.timeout or 120),
                 "-o", part, "-w", "%{http_code}" }
  for k, v in pairs(opts.headers or {}) do
    table.insert(args, "-H")
    table.insert(args, k .. ": " .. v)
  end
  table.insert(args, opts.url)
  local ok, err = pcall(vim.system, args, { text = true }, function(out)
    vim.schedule(function()
      local status = tonumber(vim.trim(out.stdout or ""))
      if out.code ~= 0 or not status or status < 200 or status >= 300 then
        os.remove(part)
        cb(nil, out.code ~= 0 and M.describe_curl_exit(out.code) or M.describe_error(status))
        return
      end
      os.remove(path)
      local moved, merr = os.rename(part, path)
      if not moved then return cb(nil, "download: " .. tostring(merr)) end
      cb(path)
    end)
  end)
  if not ok then
    vim.schedule(function() cb(nil, "curl invocation failed: " .. tostring(err)) end)
  end
end

---Decode a JSON body. JSON null becomes Lua nil (not vim.NIL), so mappers can
---use plain `x and x.y` chains.
---@param body string|nil
---@return any|nil, string|nil
function M.decode_json(body)
  if not body or body == "" then return nil, "empty body" end
  local ok, val = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok then return nil, "json decode failed" end
  return val
end

return M
