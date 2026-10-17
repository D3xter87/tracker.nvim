-- Minimal ~/.netrc (_netrc on Windows) parser sufficient for tracker token lookup.
-- Only reads machine/login/password triples and the `default` fallback; skips
-- macdef blocks. Matching is case-insensitive on hostnames. GPG-encrypted
-- netrc files are out of scope.

local M = {}

local function homedir()
  return (vim.uv or vim.loop).os_homedir() or vim.env.USERPROFILE or vim.env.HOME
end

local function candidate_paths()
  local home = homedir()
  if not home then return {} end
  home = home:gsub("\\", "/")
  return { home .. "/_netrc", home .. "/.netrc" }
end

---@return string|nil path to the first existing netrc file, or nil
local function find_netrc()
  for _, p in ipairs(candidate_paths()) do
    if (vim.uv or vim.loop).fs_stat(p) then
      return p
    end
  end
  return nil
end

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local content = fd:read("*a")
  fd:close()
  return content
end

---Parses a netrc string into { entries = {host -> {login, password}}, default = {login,password}|nil }.
---Tokenizer handles whitespace/newlines uniformly and skips macdef blocks.
---@param text string
function M.parse_string(text)
  local entries = {}
  local default = nil

  -- Tokenize: split on whitespace, but macdef bodies must be consumed until
  -- a blank line. We walk char-by-char to manage that.
  local tokens = {}
  local i = 1
  local len = #text
  while i <= len do
    local c = text:sub(i, i)
    if c:match("%s") then
      i = i + 1
    else
      -- read one token
      local j = i
      while j <= len and not text:sub(j, j):match("%s") do
        j = j + 1
      end
      local tok = text:sub(i, j - 1)
      -- if macdef: consume until blank line
      if tok == "macdef" then
        -- skip macdef name token
        local k = j
        while k <= len and text:sub(k, k):match("[ \t]") do k = k + 1 end
        local m = k
        while m <= len and not text:sub(m, m):match("%s") do m = m + 1 end
        -- now advance until \n\n (blank line)
        local rest = text:sub(m)
        local blank_start = rest:find("\n[ \t]*\n") or rest:find("\r\n[ \t]*\r\n") or #rest + 1
        i = m + blank_start
      else
        table.insert(tokens, tok)
        i = j
      end
    end
  end

  -- Consume tokens: expected sequences
  --   machine <host> [login <x>] [password <y>]  (in any interleaved order)
  --   default        [login <x>] [password <y>]
  local current = nil
  local function flush()
    if not current then return end
    if current.kind == "machine" and current.host then
      entries[current.host:lower()] = {
        login = current.login,
        password = current.password,
      }
    elseif current.kind == "default" then
      default = { login = current.login, password = current.password }
    end
    current = nil
  end

  local idx = 1
  while idx <= #tokens do
    local tok = tokens[idx]
    if tok == "machine" then
      flush()
      current = { kind = "machine", host = tokens[idx + 1] }
      idx = idx + 2
    elseif tok == "default" then
      flush()
      current = { kind = "default" }
      idx = idx + 1
    elseif tok == "login" and current then
      current.login = tokens[idx + 1]
      idx = idx + 2
    elseif tok == "password" and current then
      current.password = tokens[idx + 1]
      idx = idx + 2
    elseif tok == "account" and current then
      idx = idx + 2 -- skip account <value>
    else
      idx = idx + 1
    end
  end
  flush()

  return { entries = entries, default = default }
end

---@return table|nil parsed netrc, nil if no netrc file found or unreadable
function M.load()
  local path = find_netrc()
  if not path then return nil end
  local content = read_file(path)
  if not content then return nil end
  return M.parse_string(content)
end

---@param host string
---@return string|nil token  the `password` field for the host (or default), if any
---@return string|nil login  the `login` field (may be useful for Basic-auth callers)
function M.resolve(host)
  if not host or host == "" then return nil end
  local parsed = M.load()
  if not parsed then return nil end
  local entry = parsed.entries[host:lower()] or parsed.default
  if not entry then return nil end
  return entry.password, entry.login
end

return M
