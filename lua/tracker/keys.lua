-- Issue-key rules: what a key looks like, which project it belongs to, how
-- a branch names it. The defaults are the `ABC-123` shape (see
-- config.issue_key_pattern); a provider replaces any of them in its `keys`
-- table (GitLab: `#123`, branches like `issue-123-fix`).
--
-- Every rule takes the resolved provider config (`pcfg`) first:
--   normalize(pcfg, text)              → key   what the user typed, as a key (lenient)
--   parse(pcfg, text)                  → key|nil   `text` when it is exactly one key
--   project(pcfg, key)                 → project|nil
--   normalize_project(pcfg, text)      → project   what the user typed, as a project
--   find(pcfg, text)                   → key|nil   the first key inside a line
--   from_branch(pcfg, branch, allowed) → key|nil   `allowed` = project keys that count
--   in_branch(pcfg, branch, key)       → boolean   whether `branch` names `key`
--   branch_vars(pcfg, issue)           → table     values for the branch template
--   scope(pcfg)                        → string    what keys are unique within, below the
--                                                  provider ("" = the whole tracker)
--   restricted(pcfg)                   → boolean   whether from_branch only takes known projects

local M = {}

local git = require("tracker.util.git")

---@param pcfg table|nil
---@return string  Lua pattern of one key
local function pattern(pcfg)
  return (pcfg and pcfg.key_pattern) or require("tracker.config").get().issue_key_pattern
end

M.default = {}

function M.default.normalize(_, text)
  return vim.trim(text):upper()
end

function M.default.parse(pcfg, text)
  return vim.trim(text):upper():match("^" .. pattern(pcfg) .. "$")
end

function M.default.project(_, key)
  return key and key:match("^(.-)%-%d+$") or nil
end

function M.default.normalize_project(_, text)
  return vim.trim(text):upper()
end

function M.default.find(pcfg, text)
  return (text or ""):match(pattern(pcfg))
end

function M.default.from_branch(pcfg, branch, allowed)
  return git.issue_key(branch, pattern(pcfg), allowed)
end

function M.default.in_branch(pcfg, branch, key)
  return git.has_key(branch, key, pattern(pcfg))
end

function M.default.branch_vars(_, issue)
  return { key = issue.key, key_lower = issue.key:lower() }
end

function M.default.scope()
  return ""
end

---Any `WORD-123` in a branch reads as a key unless the config names the
---projects that count.
function M.default.restricted(pcfg)
  return (pcfg.projects ~= nil and #pcfg.projects > 0) or pcfg.boards ~= nil or pcfg.project ~= nil
end

---@type table<table, table>  provider module → its rules
local cache = setmetatable({}, { __mode = "k" })

---The rules of a provider module: its `keys` over the defaults.
---@param mod table|nil
---@return table
function M.rules(mod)
  if not mod or not mod.keys then return M.default end
  local r = cache[mod]
  if not r then
    r = setmetatable({}, { __index = function(_, k) return mod.keys[k] or M.default[k] end })
    cache[mod] = r
  end
  return r
end

return M
