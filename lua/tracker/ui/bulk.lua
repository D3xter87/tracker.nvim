-- Field edits on several issues at once (the list's marked rows): one
-- question for all of them, then the change issue by issue — one report,
-- one refresh. Points, labels and priority skip an issue that already has
-- the value (as their single editors do), and clearing a field asks first.

local M = {}

local api = require("tracker.api")
local notify = require("tracker.notify")
local plan = require("tracker.ui.plan")
local fields = require("tracker.ui.fields")
local icons = require("tracker.ui.icons")

local WARN = vim.log.levels.WARN

local function is_subtask(i) return i.type and (i.type.subtask or (i.type.level or 0) < 0) end
local function is_epic(i) return i.type and (i.type.level or 0) >= 1 end

---`plan.each` over `issues`; nothing to change: nothing sent, no refresh.
local function apply(issues, step, what, done)
  if #issues == 0 then return end
  plan.each(issues, step, what, done)
end

local function update(issues, changes, what, done)
  apply(issues, function(issue, cb) api.update(issue.key, changes, cb) end, what, done)
end

---The issues whose value `differs` from the new one. None says so: the
---rows can be behind Jira's index right after an edit, and silence would
---look like a lost key press.
local function changing(issues, differs, what)
  local out = vim.tbl_filter(differs, issues)
  if #out == 0 then notify.send("actions", ("%s: %s unchanged"):format(plan.label(issues), what)) end
  return out
end

---What `get` gives for every issue alike, else nil.
local function common(issues, get)
  local first = get(issues[1])
  for n = 2, #issues do
    if get(issues[n]) ~= first then return nil end
  end
  return first
end

local function user_label(u) return u.name .. (u.email and (" <" .. u.email .. ">") or "") end

-- region Status

---Transitions differ per issue (workflow, current status): the picker lists
---every status some issue can go to, and each issue takes its own
---transition there. Issues without one are named, not failed.
function M.transition(issues, done)
  local pending, by_key, failure = #issues, {}, nil

  local function pick()
    local order, by_name = {}, {}
    for _, issue in ipairs(issues) do
      for _, t in ipairs(by_key[issue.key] or {}) do
        local name = t.to and t.to.name or t.name
        local target = by_name[name]
        if not target then
          target = { name = name, steps = {}, n = 0 }
          by_name[name] = target
          table.insert(order, target)
        end
        if not target.steps[issue.key] then
          target.steps[issue.key] = t
          target.n = target.n + 1
        end
      end
    end
    if #order == 0 then
      if failure then return notify.error(failure) end
      return notify.send("actions", plan.label(issues) .. ": no transitions available", WARN)
    end
    vim.ui.select(order, {
      prompt = "Status of " .. plan.label(issues),
      format_item = function(t)
        return t.name .. (t.n < #issues and ("  (%d of %d)"):format(t.n, #issues) or "")
      end,
    }, function(choice)
      if not choice then return end
      local moving, skipped = {}, {}
      for _, issue in ipairs(issues) do
        if choice.steps[issue.key] then
          table.insert(moving, issue)
        elseif not (issue.status and issue.status.name == choice.name) then
          table.insert(skipped, issue.key)
        end
      end
      if #skipped > 0 then
        notify.send("actions", ("no transition to %s for %s"):format(choice.name, table.concat(skipped, ", ")), WARN)
      end
      apply(moving, function(issue, cb)
        -- by the issue's own transition id: a status name could match
        -- another transition's name first
        api.transition(issue.key, choice.steps[issue.key].id, function(t, err) cb(t ~= nil, err) end)
      end, "status → " .. choice.name, done)
    end)
  end

  for _, issue in ipairs(issues) do
    api.transitions(issue.key, function(list, err)
      by_key[issue.key] = list
      failure = failure or (not list and err) or nil
      pending = pending - 1
      if pending == 0 then pick() end
    end)
  end
end

-- endregion

-- region Assignee

---Sent to every issue, whoever the row shows: assigning again is harmless,
---and a row can be behind Jira's index right after an edit.
---@param user TrackerUser|nil  nil unassigns
local function assign_all(issues, user, done)
  apply(issues, function(issue, cb)
    -- api.assign answers `false` for "unassigned": only nil is a failure
    api.assign(issue.key, user, function(a, err) cb(a ~= nil, err) end)
  end, "assignee → " .. (user and user.name or "unassigned"), done)
end

---The people offered are the first issue's assignable users.
function M.assign(issues, done)
  api.assignable_users(issues[1].key, nil, function(users, err)
    if not users then return notify.error(err) end
    local items = { { label = "Assign to me", me = true }, { label = "Unassigned" } }
    for _, u in ipairs(users) do table.insert(items, { label = user_label(u), user = u }) end
    vim.ui.select(items, {
      prompt = "Assignee of " .. plan.label(issues),
      format_item = function(i) return i.label end,
    }, function(choice)
      if not choice then return end
      if not choice.me then return assign_all(issues, choice.user, done) end
      api.myself(function(me, merr)
        if not me then return notify.error(merr) end
        assign_all(issues, me, done)
      end)
    end)
  end)
end

---All of them mine → unassign them; otherwise → the others become mine.
---The one edit without a picker, so it asks: marks outlive an edit, and a
---marked row may be out of sight (filtered, folded).
function M.toggle_me(issues, done)
  api.myself(function(me, err)
    if not me then return notify.error(err) end
    local others = vim.tbl_filter(function(i) return not (i.assignee and i.assignee.id == me.id) end, issues)
    if #others == 0 then
      return plan.confirm(("Unassign %s from you?"):format(plan.label(issues)), "Unassign",
        function() assign_all(issues, nil, done) end)
    end
    plan.confirm(("Assign %s to you?"):format(plan.label(others)), "Assign",
      function() assign_all(others, me, done) end)
  end)
end

-- endregion

-- region Fields

local function points_of(i) return type(i.story_points) == "number" and i.story_points or nil end
local function points_text(i) return points_of(i) and tostring(points_of(i)) or "" end

function M.points(issues, done)
  vim.ui.input({
    prompt = ("Story points of %s (empty clears): "):format(plan.label(issues)),
    default = common(issues, points_text) or "",
  }, function(text)
    if text == nil then return end
    text = vim.trim(text):gsub(",", ".")
    local n
    if text ~= "" then
      n = tonumber(text)
      if not n or n < 0 then return notify.send("actions", "not a number: " .. text, WARN) end
    end
    local todo = changing(issues, function(i) return points_of(i) ~= n end, "story points")
    if #todo == 0 then return end
    if n then return update(todo, { story_points = n }, "story points → " .. text, done) end
    plan.confirm(("Clear the story points of %s?"):format(plan.label(todo)), "Clear",
      function() update(todo, { story_points = false }, "story points cleared", done) end)
  end)
end

---An issue's labels as a set: sorted, joined.
local function labels_text(i)
  local sorted = vim.list_slice(i.labels or {})
  table.sort(sorted)
  return table.concat(sorted, ", ")
end

---The labels typed REPLACE each issue's own set.
function M.labels(issues, done)
  vim.ui.input({
    prompt = ("Labels of %s (comma separated, replaces theirs): "):format(plan.label(issues)),
    default = common(issues, labels_text) or "",
  }, function(text)
    if text == nil then return end
    local labels, seen = {}, {}
    for l in text:gmatch("[^,%s]+") do
      if not seen[l] then
        seen[l] = true
        table.insert(labels, l)
      end
    end
    local wanted = labels_text({ labels = labels })
    local todo = changing(issues, function(i) return labels_text(i) ~= wanted end, "labels")
    if #todo == 0 then return end
    if #labels > 0 then
      return update(todo, { labels = labels }, "labels → " .. table.concat(labels, ", "), done)
    end
    plan.confirm(("Remove all labels of %s?"):format(plan.label(todo)), "Remove",
      function() update(todo, { labels = labels }, "labels removed", done) end)
  end)
end

function M.priority(issues, done)
  api.priorities(function(list, err)
    if not list then return notify.error(err) end
    vim.ui.select(list, {
      prompt = "Priority of " .. plan.label(issues),
      format_item = function(p) return icons.priority({ priority_id = p.id, priority = p.name }) .. "  " .. p.name end,
    }, function(p)
      if not p then return end
      local todo = changing(issues, function(i) return i.priority_id ~= p.id end, "priority")
      update(todo, { priority_id = p.id }, "priority → " .. p.name, done)
    end)
  end)
end

---The people offered are the first issue's assignable users.
function M.reporter(issues, done)
  api.assignable_users(issues[1].key, nil, function(users, err)
    if not users then return notify.error(err) end
    vim.ui.select(users, { prompt = "Reporter of " .. plan.label(issues), format_item = user_label }, function(u)
      if u then update(issues, { reporter_id = u.id }, "reporter → " .. u.name, done) end
    end)
  end)
end

-- endregion

-- What several issues can share; summary and description stay per issue.
local EDITORS = {
  status = M.transition, assignee = M.assign, priority = M.priority, points = M.points,
  epic = plan.epic, labels = M.labels, reporter = M.reporter,
}
local MENU_ORDER = { "status", "assignee", "priority", "points", "epic", "labels", "reporter" }

---Edit `field` of all `issues` (the labels and capabilities are ui/fields').
function M.edit(issues, field, done)
  local e = fields.EDITORS[field]
  if e.cap and not api.has(e.cap) then
    return notify.send("actions", e.label .. " can't be edited on this tracker", WARN)
  end
  EDITORS[field](issues, done)
end

---Pick a field, then edit it on all `issues`. The epic is offered when
---every issue can have one (no sub-task, no epic among them).
function M.menu(issues, done)
  local standard = true
  for _, i in ipairs(issues) do
    if is_subtask(i) or is_epic(i) then standard = false end
  end
  local items = {}
  for _, f in ipairs(MENU_ORDER) do
    local e = fields.EDITORS[f]
    if (f ~= "epic" or standard) and (not e.cap or api.has(e.cap)) then table.insert(items, f) end
  end
  vim.ui.select(items, {
    prompt = "Edit " .. plan.label(issues),
    format_item = function(f) return fields.EDITORS[f].label end,
  }, function(f)
    if f then M.edit(issues, f, done) end
  end)
end

return M
