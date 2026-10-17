-- GitLab transport: REST API v4, token auth, JSON in/out, GitLab's error
-- format and its page-number pagination.

local http = require("tracker.http.client")
local auth = require("tracker.http.auth")

local M = {}

---@param pcfg table
---@return string base URL without trailing slash ("" when unset)
function M.base_url(pcfg)
  return ((pcfg.base_url or ""):gsub("/+$", ""))
end

local function api(pcfg) return M.base_url(pcfg) .. "/api/v4" end

---`/projects/<url-encoded path>`: GitLab takes the path where it takes a
---project id.
---@param project string  "group/sub/project" (or a numeric id)
---@return string
function M.project_path(project)
  return "/projects/" .. http.uri_encode(tostring(project))
end

---GitLab answers `{ message = "…" }`, `{ message = { field = { "…" } } }` or
---`{ error = "…" }`.
local function describe(res)
  local data = http.decode_json(res.body)
  local parts = {}
  if type(data) == "table" then
    local msg = data.message or data.error_description or data.error
    if type(msg) == "string" then
      table.insert(parts, msg)
    elseif type(msg) == "table" then
      for k, v in pairs(msg) do
        local text = type(v) == "table" and table.concat(vim.tbl_map(tostring, v), ", ") or tostring(v)
        table.insert(parts, type(k) == "number" and text or (k .. ": " .. text))
      end
      table.sort(parts)
    end
  end
  if #parts > 0 then return res.err .. " — " .. table.concat(parts, "; ") end
  return res.err
end

---@return table<string, string>|nil headers, string|nil err
local function auth_headers(pcfg)
  local creds, err = auth.credentials(pcfg.name or "gitlab", pcfg)
  if not creds then return nil, err end
  return { Authorization = auth.header(creds) }
end

---@param pcfg table
---@param method string
---@param path string  below /api/v4, e.g. "/projects/g%2Fp/issues"
---@param opts { query: table?, body: any?, form: table?, timeout: integer? }|nil
---@param cb fun(data: any|nil, err: string|nil, status: integer|nil, headers: table|nil, raw: string|nil)
function M.request(pcfg, method, path, opts, cb)
  opts = opts or {}
  if M.base_url(pcfg) == "" then
    return vim.schedule(function()
      cb(nil, ("gitlab: providers.%s.base_url is not set"):format(pcfg.name or "gitlab"))
    end)
  end
  local headers, err = auth_headers(pcfg)
  if not headers then
    return vim.schedule(function() cb(nil, err) end)
  end
  headers.Accept = "application/json"
  local body
  if opts.body ~= nil then
    headers["Content-Type"] = "application/json"
    body = vim.json.encode(opts.body)
  end
  http.request({ url = api(pcfg) .. path, method = method, headers = headers, query = opts.query, body = body,
                 form = opts.form, timeout = opts.timeout },
    function(res)
      if not res.ok then return cb(nil, describe(res), res.status, res.headers) end
      if res.status == 204 or not res.body or res.body:match("^%s*$") then
        return cb({}, nil, res.status, res.headers, "")
      end
      local data, derr = http.decode_json(res.body)
      if data == nil then return cb(nil, derr, res.status, res.headers) end
      cb(data, nil, res.status, res.headers, res.body)
    end)
end

---Collect a list endpoint page by page (`page` / `per_page`, the next page
---from the `x-next-page` header) up to `limit` items.
---@param cb fun(items: table[]|nil, err: string|nil, meta: { truncated: boolean }|nil)
function M.paged(pcfg, path, query, limit, cb)
  local out = {}
  local function page(n)
    local q = vim.tbl_extend("force", query or {}, { page = n, per_page = math.max(1, math.min(100, limit - #out)) })
    M.request(pcfg, "GET", path, { query = q }, function(data, err, _, headers)
      if not data then return cb(nil, err) end
      for _, item in ipairs(data) do
        if #out < limit then table.insert(out, item) end
      end
      local next_page = tonumber(headers and headers["x-next-page"] or "")
      if next_page and #out < limit and #data > 0 then return page(next_page) end
      cb(out, nil, { truncated = next_page ~= nil })
    end)
  end
  page(1)
end

---Download a file: `target` is a path below /api/v4 (authenticated) or an
---absolute URL (fetched without credentials).
---@param cb fun(path: string|nil, err: string|nil)
function M.download(pcfg, target, path, cb)
  if target:match("^https?://") then
    return http.download({ url = target }, path, cb)
  end
  local headers, err = auth_headers(pcfg)
  if not headers then
    return vim.schedule(function() cb(nil, err) end)
  end
  http.download({ url = api(pcfg) .. target, headers = headers }, path, cb)
end

return M
