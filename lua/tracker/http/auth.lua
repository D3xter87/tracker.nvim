-- Credential lookup and the Authorization header.
--
-- Lookup order for the token (first hit wins):
--   1. providers.<name>.token            explicit value from setup()
--   2. netrc (_netrc on Windows)         `password` of the machine named by
--                                        providers.<name>.netrc_machine, or of
--                                        the base_url host when unset
--   3. $TRACKER_<NAME>_TOKEN             e.g. $TRACKER_JIRA_TOKEN
--
-- The login (Jira Cloud: the account e-mail) comes from providers.<name>.login,
-- then the netrc entry's `login`, then $TRACKER_<NAME>_LOGIN. Nothing here is
-- cached, logged or written anywhere.

local M = {}

local netrc = require("tracker.http.netrc")

---@param url string|nil
---@return string|nil
function M.host_of(url)
  return url and url:match("^%a[%w+.-]*://([^/:]+)") or nil
end

---@class TrackerCredentials
---@field token string
---@field login string|nil
---@field scheme "basic"|"bearer"
---@field source string  where the token came from, for :checkhealth

---@param name string  provider name ("jira")
---@param pcfg table   resolved provider config
---@return TrackerCredentials|nil, string|nil err
function M.credentials(name, pcfg)
  pcfg = pcfg or {}
  local env = "TRACKER_" .. name:upper()
  local scheme = pcfg.auth or "basic"
  local token, login, source = pcfg.token, pcfg.login, "config"

  if not token or token == "" then
    local machine = pcfg.netrc_machine or M.host_of(pcfg.base_url)
    local t, l = netrc.resolve(machine)
    if t and t ~= "" then
      token, source = t, "netrc (" .. machine .. ")"
      if not login or login == "" then login = l end
    end
  end

  if not token or token == "" then
    local t = vim.env[env .. "_TOKEN"]
    if t and t ~= "" then token, source = t, "$" .. env .. "_TOKEN" end
  end

  if not login or login == "" then login = vim.env[env .. "_LOGIN"] end

  if not token or token == "" then
    return nil, ("%s: no token — add `machine %s login <e-mail> password <token>` to netrc or set $%s_TOKEN")
      :format(name, pcfg.netrc_machine or M.host_of(pcfg.base_url) or "<host>", env)
  end
  if scheme == "basic" and (not login or login == "") then
    return nil, ("%s: no login (e-mail) for basic auth — set providers.%s.login or the netrc `login` field")
      :format(name, name)
  end
  return { token = token, login = login, scheme = scheme, source = source }
end

---@param creds TrackerCredentials
---@return string
function M.header(creds)
  if creds.scheme == "bearer" then
    return "Bearer " .. creds.token
  end
  return "Basic " .. vim.base64.encode(creds.login .. ":" .. creds.token)
end

return M
