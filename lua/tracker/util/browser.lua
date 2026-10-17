-- Open a URL in the system default browser.
-- Prefers `vim.ui.open` (Neovim 0.10+, cross-platform). Falls back to
-- `open` / `xdg-open` / `rundll32 url.dll,FileProtocolHandler` for older builds.

local M = {}

---@param url string
---@return boolean ok
function M.open(url)
  if type(url) ~= "string" or url == "" then return false end

  if type(vim.ui.open) == "function" then
    local ok = pcall(vim.ui.open, url)
    if ok then return true end
  end

  local cmd
  if vim.fn.has("mac") == 1 then cmd = { "open", url }
  elseif vim.fn.has("unix") == 1 then cmd = { "xdg-open", url }
  elseif vim.fn.has("win32") == 1 then cmd = { "rundll32", "url.dll,FileProtocolHandler", url }
  end
  if not cmd then return false end

  local ok = pcall(vim.system, cmd, { detach = true })
  return ok
end

return M
