-- Jira-style quick filters (`f`) and grouping (`F`) for list views — pure
-- functions over the loaded issues, no network.
--
-- filters = { epic = set, assignee = set, type = set, status = set, label = set }
-- A missing / empty category is inactive. Within a category the values are
-- OR-ed, categories are AND-ed (epic X or Y, AND assigned to Anna). NONE is
-- the "no epic" / "unassigned" value.

local M = {}

M.NONE = "\0none"

M.CATEGORIES = {
  { id = "epic", label = "Epic" },
  { id = "assignee", label = "Assignee" },
  { id = "type", label = "Type" },
  { id = "status", label = "Status" },
  { id = "label", label = "Label" },
}

M.GROUPINGS = {
  { id = "epic", label = "Epic" },
  { id = "assignee", label = "Assignee" },
  { id = "status", label = "Status" },
}

local function is_subtask(i) return i.type and (i.type.subtask or (i.type.level or 0) < 0) end
local function is_epic_type(t) return t and (t.level or 0) >= 1 end

---Epic key of an issue: its parent when that is an epic; for a sub-task the
---epic of its parent (looked up in `by_key`). nil = no epic.
---@param by_key table<string, TrackerIssue>
function M.epic_of(i, by_key)
  if is_epic_type(i.type) then return nil end
  if is_subtask(i) then
    local p = i.parent and by_key[i.parent.key]
    return p and M.epic_of(p, by_key) or nil
  end
  if i.parent and (is_epic_type(i.parent.type) or (i.parent.type and (i.parent.type.name or ""):lower():find("epi", 1, true))) then
    return i.parent.key
  end
  return nil
end

---The value(s) of `category` for an issue (labels: several).
---@return string[]
function M.values(i, category, by_key)
  if category == "epic" then return { M.epic_of(i, by_key) or M.NONE } end
  if category == "assignee" then return { i.assignee and i.assignee.id or M.NONE } end
  if category == "type" then return { i.type and i.type.name or "?" } end
  if category == "status" then return { i.status and i.status.name or "?" } end
  if category == "label" then
    if #(i.labels or {}) == 0 then return { M.NONE } end
    return i.labels
  end
  return {}
end

---@return boolean
function M.active(filters)
  for _, set in pairs(filters or {}) do
    if next(set) then return true end
  end
  return false
end

---Issues passing every active category, in their original order.
---@param issues TrackerIssue[]
---@return TrackerIssue[]
function M.apply(issues, filters)
  if not M.active(filters) then return issues end
  local by_key = {}
  for _, i in ipairs(issues) do by_key[i.key] = i end
  return vim.tbl_filter(function(i)
    for cat, set in pairs(filters) do
      if next(set) then
        local hit = false
        for _, val in ipairs(M.values(i, cat, by_key)) do
          if set[val] then hit = true break end
        end
        if not hit then return false end
      end
    end
    return true
  end, issues)
end

---Picker items for `category`: every value present in `issues`, in order of
---first appearance (NONE last), pre-selected from the current filter.
---@param epics table<string, TrackerEpic>  for epic summaries
---@return TrackerMultiItem[]
function M.candidates(issues, category, filters, epics)
  local by_key = {}
  for _, i in ipairs(issues) do by_key[i.key] = i end
  local seen, out, none = {}, {}, nil
  local current = (filters or {})[category] or {}
  for _, i in ipairs(issues) do
    for _, val in ipairs(M.values(i, category, by_key)) do
      if not seen[val] then
        seen[val] = true
        local item = { value = val, selected = current[val] or false }
        if val == M.NONE then
          item.label = ({ epic = "No epic", assignee = "Unassigned", label = "No labels" })[category] or "None"
          none = item
        else
          if category == "epic" then
            local e = epics and epics[val]
            item.label = val .. (e and ("  " .. e.summary) or "")
            item.hl = e and require("tracker.ui.icons").epic_hl(e.color) or nil
          elseif category == "assignee" then
            item.label = i.assignee and i.assignee.name or val
          else
            item.label = val
          end
          table.insert(out, item)
        end
      end
    end
  end
  if none then table.insert(out, none) end
  return out
end

---Split `issues` into groups by `kind`, in order of first appearance
---(the NONE group last).
---@return { id: string, value: string, issues: TrackerIssue[] }[]
function M.groups(issues, kind)
  local by_key = {}
  for _, i in ipairs(issues) do by_key[i.key] = i end
  local order, groups, none = {}, {}, nil
  for _, i in ipairs(issues) do
    local val = M.values(i, kind, by_key)[1]
    local g = groups[val]
    if not g then
      g = { id = kind .. ":" .. val, value = val, issues = {} }
      groups[val] = g
      if val == M.NONE then none = g else table.insert(order, g) end
    end
    table.insert(g.issues, i)
  end
  if none then table.insert(order, none) end
  return order
end

---Points of a group: closed / total over its non-sub-task issues (sub-task
---points belong to their story already).
---@return number closed, number total, integer count
function M.points(issues)
  local closed, total = 0, 0
  for _, i in ipairs(issues) do
    if not is_subtask(i) and type(i.story_points) == "number" then
      total = total + i.story_points
      if i.status and i.status.category == "done" then closed = closed + i.story_points end
    end
  end
  return closed, total, #issues
end

return M
