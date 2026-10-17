-- Editing single fields of an issue — shared by the list (`e` on a column),
-- the issue view (`e` on a section) and the field menu (`E`).
--
-- Every editor takes the issue as the caller has it (a list row or a full
-- issue) and `done()` to refresh the view after a successful change.

local M = {}

local api = require("tracker.api")
local notify = require("tracker.notify")
local actions = require("tracker.ui.actions")
local icons = require("tracker.ui.icons")
local editor = require("tracker.ui.editor")
local drafts = require("tracker.ui.drafts")

local WARN = vim.log.levels.WARN

local function project_of(issue) return issue.key:match("^(.-)%-%d+$") end

local function is_subtask(i) return i.type and (i.type.subtask or (i.type.level or 0) < 0) end

---Run api.update and report.
local function update(issue, fields, what, done)
  api.update(issue.key, fields, function(ok, err)
    if not ok then return notify.error(err) end
    notify.send("actions", ("%s: %s updated"):format(issue.key, what))
    if done then done() end
  end)
end

function M.summary(issue, done)
  vim.ui.input({ prompt = issue.key .. " summary: ", default = issue.summary }, function(text)
    if not text then return end
    text = vim.trim(text)
    if text == "" then return notify.send("actions", "summary can't be empty", WARN) end
    if text == issue.summary then return end
    update(issue, { summary = text }, "summary", done)
  end)
end

---Description in the Markdown popup. A list row has no description: fetch
---the issue first.
function M.description(issue, done)
  local function open(full)
    local lossy = full.lossy or {}
    local function go()
      local dkey = "description:" .. full.key
      local draft = drafts.get(dkey)
      local text = draft or full.description or ""
      editor.open({
        title = " Description of " .. full.key .. (draft and " (draft) " or " "),
        text = text,
        attachments = full.attachments,
        large = true,
        on_close = drafts.keeper(dkey, full.description, text),
        on_submit = function(body, finish)
          if vim.trim(body) == vim.trim(full.description or "") then
            drafts.clear(dkey)
            return finish(true)
          end
          api.update(full.key, { description = body }, function(ok, err)
            if not ok then
              notify.error(err)
              return finish(false)
            end
            notify.send("actions", full.key .. ": description updated")
            drafts.clear(dkey)
            finish(true)
            if done then done() end
          end)
        end,
      })
    end
    if #lossy == 0 then return go() end
    vim.ui.select({ "Edit anyway", "Cancel" }, {
      prompt = ("The description contains %s — saving from Markdown drops them"):format(table.concat(lossy, ", ")),
    }, function(choice)
      if choice == "Edit anyway" then go() end
    end)
  end
  if issue.description ~= nil then return open(issue) end
  api.get_issue(issue.key, function(full, err)
    if not full then return notify.error(err) end
    open(full)
  end)
end

function M.priority(issue, done)
  api.priorities(function(list, err)
    if not list then return notify.error(err) end
    vim.ui.select(list, {
      prompt = issue.key .. " priority",
      format_item = function(p)
        local glyph = icons.priority({ priority_id = p.id, priority = p.name })
        return glyph .. "  " .. p.name .. (p.id == issue.priority_id and "  (current)" or "")
      end,
    }, function(p)
      if p and p.id ~= issue.priority_id then update(issue, { priority_id = p.id }, "priority", done) end
    end)
  end)
end

function M.points(issue, done)
  local current = type(issue.story_points) == "number" and tostring(issue.story_points) or ""
  vim.ui.input({ prompt = issue.key .. " story points (empty clears): ", default = current }, function(text)
    if text == nil then return end
    text = vim.trim(text):gsub(",", ".")
    if text == current then return end
    if text == "" then return update(issue, { story_points = false }, "story points", done) end
    local n = tonumber(text)
    if not n or n < 0 then return notify.send("actions", "not a number: " .. text, WARN) end
    update(issue, { story_points = n }, "story points", done)
  end)
end

function M.labels(issue, done)
  local current = table.concat(issue.labels or {}, ", ")
  vim.ui.input({ prompt = issue.key .. " labels (comma separated): ", default = current }, function(text)
    if text == nil or vim.trim(text) == current then return end
    local labels = {}
    for l in text:gmatch("[^,%s]+") do table.insert(labels, l) end
    update(issue, { labels = labels }, "labels", done)
  end)
end

function M.reporter(issue, done)
  api.assignable_users(issue.key, nil, function(users, err)
    if not users then return notify.error(err) end
    vim.ui.select(users, {
      prompt = issue.key .. " reporter",
      format_item = function(u) return u.name .. (u.email and (" <" .. u.email .. ">") or "") end,
    }, function(u)
      if u then update(issue, { reporter_id = u.id }, "reporter", done) end
    end)
  end)
end

---Create an epic (popup: first line = summary) and hand its key to `cb`.
function M.new_epic(project, cb)
  api.issue_types(project, function(types, err)
    if not types then return notify.error(err) end
    local epic_type
    for _, t in ipairs(types) do
      if (t.level or 0) >= 1 then epic_type = t break end
    end
    if not epic_type then return notify.error("tracker: project " .. project .. " has no epic type") end
    editor.open({
      title = (" New %s in %s — first line is the summary "):format(epic_type.name, project),
      text = "",
      large = true,
      on_submit = function(text, finish)
        local summary, description = editor.split_summary(text)
        if summary == "" then
          notify.error("tracker: the first line (summary) is empty")
          return finish(false)
        end
        api.create({ project = project, type_id = epic_type.id, summary = summary, description = description },
          function(created, cerr)
            if not created then
              notify.error(cerr)
              return finish(false)
            end
            notify.send("actions", "created epic " .. created.key)
            finish(true)
            cb(created.key)
          end)
      end,
    })
  end)
end

---Epic of a standard issue: pick an open epic, "no epic", or create one.
function M.epic(issue, done)
  if is_subtask(issue) then
    return notify.send("actions", issue.key .. " is a sub-task: its epic comes from its parent", WARN)
  end
  if issue.type and (issue.type.level or 0) >= 1 then
    return notify.send("actions", issue.key .. " is an epic itself", WARN)
  end
  local project = project_of(issue)
  api.epic_list(project, function(epics, err)
    if not epics then return notify.error(err) end
    local current = issue.parent and issue.parent.key
    local items = { { label = "+ New epic…", new = true }, { label = "No epic", none = true } }
    for _, e in ipairs(epics) do
      table.insert(items, { label = ("%s  %s%s"):format(e.key, e.summary, e.key == current and "  (current)" or ""), epic = e })
    end
    vim.ui.select(items, { prompt = issue.key .. " epic", format_item = function(i) return i.label end }, function(choice)
      if not choice then return end
      if choice.none then
        if current then update(issue, { parent = false }, "epic", done) end
      elseif choice.new then
        M.new_epic(project, function(key) update(issue, { parent = key }, "epic", done) end)
      elseif choice.epic.key ~= current then
        update(issue, { parent = choice.epic.key }, "epic", done)
      end
    end)
  end)
end

M.EDITORS = {
  summary = { label = "Summary", fn = M.summary },
  description = { label = "Description", fn = M.description },
  status = { label = "Status", fn = function(i, done) actions.transition(i.key, done) end },
  assignee = { label = "Assignee", fn = function(i, done) actions.assign(i.key, done) end },
  priority = { label = "Priority", fn = M.priority, cap = "priority" },
  points = { label = "Story points", fn = M.points, cap = "story_points" },
  epic = { label = "Epic", fn = M.epic, cap = "epic_link" },
  labels = { label = "Labels", fn = M.labels, cap = "labels" },
  reporter = { label = "Reporter", fn = M.reporter, cap = "reporter" },
}
local MENU_ORDER = { "summary", "description", "status", "assignee", "priority", "points", "epic", "labels", "reporter" }

---Edit `field` of `issue`; false when the field isn't editable here.
---@return boolean
function M.edit(issue, field, done)
  local e = M.EDITORS[field]
  if not e then return false end
  if e.cap and not api.has(e.cap) then
    notify.send("actions", e.label .. " can't be edited on this tracker", WARN)
    return true
  end
  e.fn(issue, done)
  return true
end

---Pick a field, then edit it.
function M.menu(issue, done)
  local items = {}
  for _, f in ipairs(MENU_ORDER) do
    local e = M.EDITORS[f]
    local skip = (f == "epic" and (is_subtask(issue) or (issue.type and (issue.type.level or 0) >= 1)))
    if not skip and (not e.cap or api.has(e.cap)) then table.insert(items, f) end
  end
  vim.ui.select(items, {
    prompt = "Edit " .. issue.key,
    format_item = function(f) return M.EDITORS[f].label end,
  }, function(f)
    if f then M.edit(issue, f, done) end
  end)
end

return M
