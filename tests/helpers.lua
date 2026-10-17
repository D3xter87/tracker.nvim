local M = {}

function M.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\n  actual: %s"):format(msg or "values differ", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.truthy(v, msg)
  if not v then error(msg or "expected a truthy value", 2) end
end

---Load a JSON fixture from tests/fixtures (null → nil, like the HTTP client).
function M.fixture(name)
  local root = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  local f = assert(io.open(root .. "/fixtures/" .. name, "r"))
  local s = f:read("*a")
  f:close()
  return vim.json.decode(s, { luanil = { object = true, array = true } })
end

---Drop volatile attrs (task localIds) so ADF trees compare structurally.
function M.strip_ids(node)
  if type(node) ~= "table" then return node end
  local out = {}
  for k, v in pairs(node) do
    if k ~= "localId" then out[k] = M.strip_ids(v) end
  end
  return out
end

return M
