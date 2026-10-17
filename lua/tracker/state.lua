-- Small in-memory TTL cache shared by providers (current user, issue types,
-- board configuration — data that changes rarely but costs a round trip).
-- Issue data itself is never cached: views always show what the server says.

local M = {}

local uv = vim.uv or vim.loop

---@type table<string, { v: any, exp: number|nil }>
local store = {}

---@param key string
---@return any|nil
function M.get(key)
  local e = store[key]
  if not e then return nil end
  if e.exp and e.exp <= uv.now() then
    store[key] = nil
    return nil
  end
  return e.v
end

---@param key string
---@param value any
---@param ttl_ms integer|nil  nil = until cleared
function M.set(key, value, ttl_ms)
  store[key] = { v = value, exp = ttl_ms and (uv.now() + ttl_ms) or nil }
end

---Drop every entry whose key starts with `prefix` (all entries when nil).
---@param prefix string|nil
function M.clear(prefix)
  if not prefix then
    store = {}
    return
  end
  for k in pairs(store) do
    if k:sub(1, #prefix) == prefix then store[k] = nil end
  end
end

return M
