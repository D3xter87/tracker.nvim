-- Unsent editor text kept for the session: a comment, a reply, a comment
-- edit or a description closed without submitting comes back the next time
-- the same popup opens. Nothing is written to disk.
--
-- Drafts are kept per provider (and per project where keys like `#12` are
-- only unique inside one): the comment draft of Jira's ABC-1 isn't GitLab's.

local M = {}

---@type table<string, string>
local store = {}

---`key` within the provider the call comes from (see api.scope_key).
local function scoped(key)
  return require("tracker.api").scope_key() .. "\0" .. key
end

---@param key string
---@return string|nil
function M.get(key)
  return store[scoped(key)]
end

---@param key string|nil  nil = every draft
function M.clear(key)
  if key then
    store[scoped(key)] = nil
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
  local id = scoped(key) -- now: the popup may close with another tab shown
  return function(text)
    if text == opened then return end
    store[id] = vim.trim(text) ~= vim.trim(pristine or "") and text or nil
  end
end

return M
