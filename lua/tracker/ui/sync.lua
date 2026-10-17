-- Reloading a view after an action, until the server shows the change.
--
-- Jira's search index — behind JQL search and the board / backlog endpoints
-- alike — catches up with a change only after a moment, so a reload right
-- after a transition or a sprint move can still bring the old state (the
-- rank, `p` / `P`, is reordered in place for the same reason). A view
-- attaches a sync: every mutation the API announces (|tracker-events|)
-- marks its issue keys, and after each reload the view hands over what it
-- got. A marked issue that came back unchanged (its `updated` stamp as
-- before) means the index is still behind: the reload is repeated after a
-- growing delay until the issue shows the change — or is gone from the list
-- (closed out of a `statusCategory != Done` query, moved to another sprint,
-- deleted). Providers without an `updated` stamp never look stale.

local M = {}

local events = require("tracker.events")

---Delays (ms) before each repeated reload; after the last one the view
---gives up and says so (`r` reloads by hand). Tests shorten them.
M.delays = { 1000, 2000, 3000, 5000 }

-- Events whose effect a list or board shows. Comments, links and
-- attachments are left out: an issue row has nothing to wait for.
local WATCHED = {
  events.TRANSITIONED, events.ASSIGNED, events.ISSUE_UPDATED, events.MOVED,
  events.ARCHIVED, events.DELETED, events.SPRINT_COMPLETED,
}

---@class TrackerSync
---@field dirty table<string, true>    keys changed, not yet seen changed
---@field seen table<string, string>   key → `updated` as last loaded
---@field attempt integer              repeated reloads so far
---@field timer uv_timer_t|nil         the pending repeat
---@field buf integer                  the view's buffer

---Watch mutations for the view in `buf`; the watch ends with the buffer.
---@param buf integer
---@return TrackerSync
function M.attach(buf)
  local s = { buf = buf, dirty = {}, seen = {}, attempt = 0 }
  local group = vim.api.nvim_create_augroup("TrackerSync" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = WATCHED,
    callback = function(ev)
      local d = ev.data or {}
      -- a web link is a remote link: it leaves the issue's `updated` alone
      if d.fields and #d.fields == 1 and d.fields[1] == "remotelinks" then return end
      for _, key in ipairs(d.keys or d.moved or { d.key }) do s.dirty[key] = true end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      M.cancel(s)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  return s
end

---Drop a pending repeat (a reload is starting anyway).
---@param s TrackerSync
function M.cancel(s)
  local t = s.timer
  s.timer = nil
  if t and not t:is_closing() then
    t:stop()
    t:close()
  end
end

---Is a repeated reload pending?
---@param s TrackerSync
function M.pending(s) return s.timer ~= nil end

---After a reload: `lists` = the issues it brought (one list per section for
---a sectioned view). Marked issues that show their change (or are gone) are
---settled; while any is still as before, `retry` is scheduled.
---@param s TrackerSync
---@param lists TrackerIssue[][]
---@param retry fun()
---@return boolean settled  false = a repeat is pending
function M.check(s, lists, retry)
  local stale, now = {}, {}
  for _, list in ipairs(lists) do
    for _, i in ipairs(list) do
      if type(i.updated) == "string" then
        now[i.key] = now[i.key] or i.updated
        if s.dirty[i.key] and s.seen[i.key] == i.updated then stale[i.key] = true end
      end
    end
  end
  for key in pairs(s.dirty) do
    if not stale[key] then s.dirty[key] = nil end
  end
  -- A stale key keeps its old stamp: the next reload is measured against it.
  for key, stamp in pairs(now) do
    if not s.dirty[key] then s.seen[key] = stamp end
  end
  M.cancel(s)
  if not next(stale) then
    s.attempt = 0
    return true
  end
  s.attempt = s.attempt + 1
  local delay = M.delays[s.attempt]
  if not delay then
    local keys = vim.tbl_keys(stale)
    table.sort(keys)
    s.attempt, s.dirty = 0, {}
    require("tracker.notify").send("sync",
      ("Jira hasn't caught up with %s yet — r refreshes"):format(table.concat(keys, ", ")), vim.log.levels.WARN)
    return true
  end
  s.timer = vim.defer_fn(function()
    s.timer = nil
    -- In the view's own window: the user may be in another tab page by now,
    -- and a reload resolves the repository (its boards) from the cwd.
    local win = require("tracker.ui.window").win_of_buf(s.buf)
    if win then
      vim.api.nvim_win_call(win, retry)
    else
      retry()
    end
  end, delay)
  return false
end

return M
