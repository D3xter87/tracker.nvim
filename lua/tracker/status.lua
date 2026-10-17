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
--   -- e = { key, provider, summary, status = TrackerStatus, url, error? } or nil

local M = {}

local config = require("tracker.config")
local events = require("tracker.events")

---@class TrackerStatusEntry
---@field key string
---@field provider string|nil  the tracker the branch's key belongs to
---@field summary string|nil
---@field status TrackerStatus|nil
---@field url string|nil
---@field error string|nil
---@field fetched_at integer

---@type table<string, string|false>  cwd → entry id (false = branch has none)
local id_of_cwd = {}
---@type table<string, TrackerStatusEntry>  entry id (provider + key) → entry
local entries = {}
local inflight = {}

local uv = vim.uv or vim.loop

local function cwd() return vim.fs.normalize(vim.fn.getcwd()) end

---Entries go by provider and key: two trackers may both have a `#12`.
local function id_of(provider, key) return (provider or "") .. "\0" .. key end

---@return TrackerStatusEntry|nil
function M.current()
  local id = id_of_cwd[cwd()]
  return id and entries[id] or nil
end

---@param found { key: string, provider: string|nil }
local function fetch(found, dir, force)
  local key, provider = found.key, found.provider
  local id = id_of(provider, key)
  local e = entries[id]
  if not force and e and uv.now() - e.fetched_at < config.get().status.ttl then return end
  if inflight[id] then return end
  inflight[id] = true
  -- named outright: a statusline refresh isn't a call from a tracker view
  require("tracker.api").get_issue(key, function(issue, err)
    inflight[id] = nil
    entries[id] = issue and {
      key = key, provider = provider, summary = issue.summary, status = issue.status, url = issue.url,
      fetched_at = uv.now(),
    } or { key = key, provider = provider, error = err, fetched_at = uv.now() }
    events.emit(events.STATUS_CHANGED, { cwd = dir, entry = entries[id] })
  end, { provider = provider, cwd = dir })
end

---Re-resolve the branch of the current directory and refresh its issue.
---@param force boolean|nil  refetch even when fresh
function M.refresh(force)
  local dir = cwd()
  vim.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, { cwd = dir, text = true }, function(res)
    vim.schedule(function()
      local branch = res.code == 0 and vim.trim(res.stdout or "") or nil
      -- no scope: the branch decides the tracker, not the tab a tracker window shows
      local api = require("tracker.api")
      local found = branch and api.with_scope(nil, api.branch_issue, { branch = branch, cwd = dir }) or nil
      local id = found and id_of(found.provider, found.key) or nil
      local before = id_of_cwd[dir]
      id_of_cwd[dir] = id or false
      if found then
        fetch(found, dir, force)
        if before ~= id and entries[id] then
          events.emit(events.STATUS_CHANGED, { cwd = dir, entry = entries[id] })
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
      local d = ev.data or {}
      local e = d.key and entries[id_of(d.provider, d.key)]
      if e then fetch(e, cwd(), true) end
    end,
  })
  M.refresh(false)
end

return M
