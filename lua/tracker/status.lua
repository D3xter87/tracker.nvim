-- The issue of the current branch, for statuslines.
--
-- Read model only: `M.current()` is a table lookup, cheap enough for every
-- statusline redraw. Nothing runs until `M.enable()` — then the branch is
-- re-resolved (async `git`) on DirChanged / FocusGained / BufEnter and after
-- tracker mutations, the issue is fetched when stale (`config.status.ttl`),
-- and `User TrackerStatusChanged` fires with `data = { cwd, entry }`.
--
--   require("tracker.status").enable()
--   local e = require("tracker.status").current()
--   -- e = { key, summary, status = TrackerStatus, url, error? } or nil

local M = {}

local config = require("tracker.config")
local events = require("tracker.events")

---@class TrackerStatusEntry
---@field key string
---@field summary string|nil
---@field status TrackerStatus|nil
---@field url string|nil
---@field error string|nil
---@field fetched_at integer

---@type table<string, string|false>  cwd → issue key (false = branch has none)
local key_of_cwd = {}
---@type table<string, TrackerStatusEntry>  issue key → entry
local entries = {}
local inflight = {}

local uv = vim.uv or vim.loop

local function cwd() return vim.fs.normalize(vim.fn.getcwd()) end

---@return TrackerStatusEntry|nil
function M.current()
  local key = key_of_cwd[cwd()]
  return key and entries[key] or nil
end

local function fetch(key, dir, force)
  local e = entries[key]
  if not force and e and uv.now() - e.fetched_at < config.get().status.ttl then return end
  if inflight[key] then return end
  inflight[key] = true
  require("tracker.api").get_issue(key, function(issue, err)
    inflight[key] = nil
    entries[key] = issue and {
      key = key, summary = issue.summary, status = issue.status, url = issue.url, fetched_at = uv.now(),
    } or { key = key, error = err, fetched_at = uv.now() }
    events.emit(events.STATUS_CHANGED, { cwd = dir, entry = entries[key] })
  end)
end

---Re-resolve the branch of the current directory and refresh its issue.
---@param force boolean|nil  refetch even when fresh
function M.refresh(force)
  local dir = cwd()
  vim.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, { cwd = dir, text = true }, function(res)
    vim.schedule(function()
      local branch = res.code == 0 and vim.trim(res.stdout or "") or nil
      local key = branch and require("tracker.api").current_issue_key({ branch = branch }) or nil
      local before = key_of_cwd[dir]
      key_of_cwd[dir] = key or false
      if key then
        fetch(key, dir, force)
        if before ~= key and entries[key] then
          events.emit(events.STATUS_CHANGED, { cwd = dir, entry = entries[key] })
        end
      elseif before then
        events.emit(events.STATUS_CHANGED, { cwd = dir, entry = nil })
      end
    end)
  end)
end

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true
  local group = vim.api.nvim_create_augroup("TrackerStatus", { clear = true })
  local pending = false
  local function soon(force)
    if pending then return end
    pending = true
    vim.defer_fn(function()
      pending = false
      M.refresh(force)
    end, 200)
  end
  vim.api.nvim_create_autocmd({ "DirChanged", "FocusGained", "BufEnter" }, {
    group = group,
    callback = function() soon(false) end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { events.TRANSITIONED, events.ISSUE_UPDATED, events.ASSIGNED },
    callback = function(ev)
      local key = ev.data and ev.data.key
      if key and entries[key] then fetch(key, cwd(), true) end
    end,
  })
  M.refresh(false)
end

return M
