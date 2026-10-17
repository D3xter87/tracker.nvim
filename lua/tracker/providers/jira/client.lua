-- Jira transport: base URL, auth header, JSON in/out, Jira's error format.

local http = require("tracker.http.client")
local auth = require("tracker.http.auth")

local M = {}

---@param pcfg table
---@return string base URL without trailing slash ("" when unset)
function M.base_url(pcfg)
  return ((pcfg.base_url or ""):gsub("/+$", ""))
end

---Jira puts details in `errorMessages` (list) and `errors` (field → text).
local function describe(res)
  local data = http.decode_json(res.body)
  local parts = {}
  if type(data) == "table" then
    for _, m in ipairs(data.errorMessages or {}) do table.insert(parts, m) end
    if type(data.errors) == "table" then
      for k, v in pairs(data.errors) do table.insert(parts, k .. ": " .. tostring(v)) end
    end
  end
  if #parts > 0 then return res.err .. " — " .. table.concat(parts, "; ") end
  return res.err
end

---@param pcfg table
---@param method string
---@param path string            "/rest/api/3/..." or "/rest/agile/1.0/..."
---@param opts { query: table?, body: any?, form: table?, timeout: integer? }|nil
---  form = multipart fields { { name, value } } (value "@path" = a file)
---@param cb fun(data: any|nil, err: string|nil, status: integer|nil, errbody: table|nil)
---  `errbody` = the decoded error response (Jira's `errors` per field …)
function M.request(pcfg, method, path, opts, cb)
  opts = opts or {}
  local base = M.base_url(pcfg)
  if base == "" then
    vim.schedule(function() cb(nil, "jira: providers.jira.base_url is not set") end)
    return
  end
  local creds, err = auth.credentials("jira", pcfg)
  if not creds then
    vim.schedule(function() cb(nil, err) end)
    return
  end

  local headers = { Authorization = auth.header(creds), Accept = "application/json" }
  local body
  if opts.body ~= nil then
    headers["Content-Type"] = "application/json"
    body = vim.json.encode(opts.body)
  end
  -- uploads: Jira refuses multipart without this (XSRF check)
  if opts.form then headers["X-Atlassian-Token"] = "no-check" end

  http.request({ url = base .. path, method = method, headers = headers, query = opts.query, body = body,
                 form = opts.form, timeout = opts.timeout },
    function(res)
      if not res.ok then
        local errbody = http.decode_json(res.body)
        cb(nil, describe(res), res.status, type(errbody) == "table" and errbody or nil)
        return
      end
      if res.status == 204 or not res.body or res.body:match("^%s*$") then
        cb({}, nil, res.status)
        return
      end
      local data, derr = http.decode_json(res.body)
      if data == nil then
        cb(nil, derr, res.status)
        return
      end
      cb(data, nil, res.status)
    end)
end

---Where a GET of `path` redirects to (its Location header), not followed.
---@param cb fun(location: string|nil, err: string|nil)
function M.location(pcfg, path, cb)
  local creds, err = auth.credentials("jira", pcfg)
  if not creds then return vim.schedule(function() cb(nil, err) end) end
  http.request({ url = M.base_url(pcfg) .. path, method = "GET", headers = { Authorization = auth.header(creds) } },
    function(res)
      local loc = res.headers and (res.headers.location or res.headers.Location)
      if loc then return cb(loc) end
      cb(nil, res.err or ("no redirect (HTTP %s)"):format(tostring(res.status)))
    end)
end

---Download a file: `target` is a "/rest/..." path (authenticated) or an
---absolute URL (external media, fetched without credentials).
---@param cb fun(path: string|nil, err: string|nil)
function M.download(pcfg, target, path, cb)
  if target:match("^https?://") then
    return http.download({ url = target }, path, cb)
  end
  local creds, err = auth.credentials("jira", pcfg)
  if not creds then
    vim.schedule(function() cb(nil, err) end)
    return
  end
  http.download({ url = M.base_url(pcfg) .. target, headers = { Authorization = auth.header(creds) } }, path, cb)
end

---Page through an Agile API collection (`startAt` / `maxResults` / `isLast`
---or `total`) and collect `values` (or `issues`) up to `limit` items.
---@param pcfg table
---@param path string
---@param query table|nil
---@param list_key "values"|"issues"
---@param limit integer
---@param cb fun(items: table[]|nil, err: string|nil)
function M.collect(pcfg, path, query, list_key, limit, cb)
  local out = {}
  local function page(start)
    local q = vim.tbl_extend("force", query or {}, { startAt = start, maxResults = math.min(100, limit - #out) })
    M.request(pcfg, "GET", path, { query = q }, function(data, err)
      if not data then
        cb(nil, err)
        return
      end
      local items = data[list_key] or {}
      vim.list_extend(out, items)
      local done = data.isLast == true or #items == 0 or #out >= limit
        or (data.total and start + #items >= data.total)
      if done then cb(out) else page(start + #items) end
    end)
  end
  page(0)
end

return M
