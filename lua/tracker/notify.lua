-- Category-aware notification sink (same scheme as cicd.nvim): every
-- user-facing message goes through `M.send(category, ...)` so classes of
-- message can be silenced from setup():
--
--   require("tracker").setup({ notify = { actions = false } })

local M = {}

local config_mod = require("tracker.config")

local sink

---Replace the transport used for every category that passes the filter.
---@param fn fun(msg: string, level: integer)|nil  nil restores `vim.notify`
function M.set_sink(fn)
  sink = fn
end

---@param category string  key in `config.notify`
---@return boolean
function M.enabled(category)
  local cfg = config_mod.get().notify or {}
  if cfg.enabled == false then return false end
  return cfg[category] ~= false
end

---@param category string
---@param msg string
---@param level integer|nil  vim.log.levels.*, defaults to INFO
function M.send(category, msg, level)
  if not M.enabled(category) then return end
  level = level or vim.log.levels.INFO
  if sink then
    sink(msg, level)
  else
    vim.notify(msg, level, { title = "Tracker" })
  end
end

---Shorthand for API failures.
---@param msg string
function M.error(msg)
  M.send("errors", msg, vim.log.levels.ERROR)
end

return M
