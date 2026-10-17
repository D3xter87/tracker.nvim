-- Unsent editor text kept for the session: a comment, a reply, a comment
-- edit or a description closed without submitting comes back the next time
-- the same popup opens. Nothing is written to disk.

local M = {}

---@type table<string, string>
local store = {}

---@param key string
---@return string|nil
function M.get(key)
  return store[key]
end

---@param key string|nil  nil = every draft
function M.clear(key)
  if key then
    store[key] = nil
  else
    store = {}
  end
end

---`on_close` for editor.open: keep the closed popup's text as the draft of
---`key`. Unchanged since opening → the draft stays as it was; back to
---`pristine` (nothing typed / the server's text) → dropped.
---@param key string
---@param pristine string|nil
---@param opened string  the text the popup opened with
---@return fun(text: string)
function M.keeper(key, pristine, opened)
  return function(text)
    if text == opened then return end
    store[key] = vim.trim(text) ~= vim.trim(pristine or "") and text or nil
  end
end

return M
