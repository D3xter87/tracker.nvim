-- Planning actions on one or more issues (the list's marked rows, or the
-- issue under the cursor): move to a sprint / the backlog / another parent,
-- archive, delete. Everything destructive asks first.

local M = {}

local api = require("tracker.api")
local notify = require("tracker.notify")
local fields = require("tracker.ui.fields")

local WARN = vim.log.levels.WARN

local function is_subtask(i) return i.type and (i.type.subtask or (i.type.level or 0) < 0) end
local function is_epic(i) return i.type and (i.type.level or 0) >= 1 end

local function keys_of(issues) return vim.tbl_map(function(i) return i.key end, issues) end

local function label(issues)
  if #issues == 1 then return issues[1].key end
  return ("%d issues (%s)"):format(#issues, table.concat(keys_of(issues), ", "))
end

---Yes / no through vim.ui.select (so pickers and tests handle it alike).
local function confirm(prompt, yes, fn)
  vim.ui.select({ yes, "Cancel" }, { prompt = prompt }, function(choice)
    if choice == yes then fn() end
  end)
end

---Run `step(issue, cb)` for each issue in turn; report once.
local function each(issues, step, what, done)
  local i, failed = 0, {}
  local function next_one()
    i = i + 1
    local issue = issues[i]
    if not issue then
      if #failed > 0 then
        notify.error(("%s failed for %s"):format(what, table.concat(failed, "; ")))
      else
        notify.send("actions", ("%s: %s"):format(what, label(issues)))
      end
      if done then done() end
      return
    end
    step(issue, function(ok, err)
      if not ok then table.insert(failed, issue.key .. ": " .. tostring(err)) end
      next_one()
    end)
  end
  next_one()
end

-- region Move

local function to_sprint(issues, done)
  api.open_sprints(function(sprints, err)
    if not sprints then return notify.error(err) end
    if #sprints == 0 then return notify.send("actions", "no active or future sprint on the board", WARN) end
    vim.ui.select(sprints, {
      prompt = "Move " .. label(issues) .. " to sprint",
      format_item = function(s) return ("%s  (%s)"):format(s.name, s.state or "?") end,
    }, function(s)
      if not s then return end
      api.move_to_sprint(s, keys_of(issues), function(ok, merr)
        if not ok then return notify.error(merr) end
        notify.send("actions", ("moved %s to %s"):format(label(issues), s.name))
        if done then done() end
      end)
    end)
  end)
end

local function to_backlog(issues, done)
  api.move_to_backlog(keys_of(issues), function(ok, err)
    if not ok then return notify.error(err) end
    notify.send("actions", "moved " .. label(issues) .. " to the backlog")
    if done then done() end
  end)
end

---Standard issues → an epic (or none, or a new one).
local function to_epic(issues, done)
  local project = issues[1].key:match("^(.-)%-%d+$")
  api.epic_list(project, function(epics, err)
    if not epics then return notify.error(err) end
    local items = { { label = "+ New epic…", new = true }, { label = "No epic", none = true } }
    for _, e in ipairs(epics) do table.insert(items, { label = e.key .. "  " .. e.summary, epic = e }) end
    vim.ui.select(items, { prompt = "Epic for " .. label(issues), format_item = function(i) return i.label end },
      function(choice)
        if not choice then return end
        local function apply(key)
          each(issues, function(issue, cb) api.update(issue.key, { parent = key }, cb) end,
            key and ("epic → " .. key) or "epic removed", done)
        end
        if choice.none then return apply(false) end
        if choice.new then return fields.new_epic(project, apply) end
        apply(choice.epic.key)
      end)
  end)
end

---Sub-tasks → another parent: a story / task from `candidates`, or a key.
local function to_parent(issues, candidates, done)
  local items = {}
  for _, c in ipairs(candidates or {}) do
    if not is_subtask(c) and not is_epic(c) then
      table.insert(items, { label = c.key .. "  " .. c.summary, key = c.key })
    end
  end
  table.insert(items, { label = "Other key…", other = true })
  vim.ui.select(items, { prompt = "New parent for " .. label(issues), format_item = function(i) return i.label end },
    function(choice)
      if not choice then return end
      local function apply(key)
        each(issues, function(issue, cb) api.update(issue.key, { parent = key }, cb) end, "parent → " .. key, done)
      end
      if not choice.other then return apply(choice.key) end
      vim.ui.input({ prompt = "Parent key: " }, function(k)
        if k and vim.trim(k) ~= "" then apply(vim.trim(k):upper()) end
      end)
    end)
end

---The move menu. `candidates` = issues visible in the view (parent picks).
---@param issues TrackerIssue[]
---@param candidates TrackerIssue[]|nil
function M.move(issues, candidates, done)
  if #issues == 0 then return end
  local subtasks, standard = 0, 0
  for _, i in ipairs(issues) do
    if is_subtask(i) then subtasks = subtasks + 1 elseif not is_epic(i) then standard = standard + 1 end
  end
  local items = {}
  local info = api.provider_info()
  if api.has("sprint_move") and info and info.board then
    table.insert(items, { label = "Sprint…", fn = function() to_sprint(issues, done) end })
    table.insert(items, { label = "Backlog", fn = function() to_backlog(issues, done) end })
  end
  if standard == #issues and api.has("epic_link") then
    table.insert(items, { label = "Epic…", fn = function() to_epic(issues, done) end })
  end
  if subtasks == #issues then
    table.insert(items, { label = "Parent…", fn = function() to_parent(issues, candidates, done) end })
  end
  vim.ui.select(items, { prompt = "Move " .. label(issues), format_item = function(i) return i.label end },
    function(choice)
      if choice then choice.fn() end
    end)
end

-- endregion

---Archive (Jira Cloud Premium / Enterprise).
function M.archive(issues, done)
  if #issues == 0 then return end
  confirm(("Archive %s?"):format(label(issues)), "Archive", function()
    api.archive(keys_of(issues), function(ok, err)
      if not ok then return notify.error(err) end
      notify.send("actions", "archived " .. label(issues))
      if done then done() end
    end)
  end)
end

---Delete for good — sub-tasks of a deleted issue go with it, and the
---question says so.
function M.delete(issues, done)
  if #issues == 0 then return end
  local subs = 0
  for _, i in ipairs(issues) do subs = subs + #(i.subtasks or {}) end
  local what = #issues == 1 and (issues[1].key .. " " .. issues[1].summary) or label(issues)
  local prompt = ("DELETE %s for good?%s This can't be undone."):format(what,
    subs > 0 and (" Its %d sub-task(s) go too."):format(subs) or "")
  confirm(prompt, "Delete", function()
    each(issues, function(issue, cb) api.delete(issue.key, #(issue.subtasks or {}) > 0, cb) end, "deleted", done)
  end)
end

return M
