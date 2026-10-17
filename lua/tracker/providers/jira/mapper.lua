-- Jira REST JSON → tracker.model shapes.

local adf = require("tracker.providers.jira.adf")

local M = {}

local CATEGORY = { new = "todo", indeterminate = "in_progress", done = "done" }

---@return TrackerUser|nil
function M.user(u)
  if type(u) ~= "table" then return nil end
  return {
    id = u.accountId or u.name or u.key,
    name = u.displayName or u.name or "?",
    email = u.emailAddress,
  }
end

---@return TrackerStatus|nil
function M.status(s)
  if type(s) ~= "table" then return nil end
  return {
    id = s.id and tostring(s.id) or nil,
    name = s.name or "?",
    category = CATEGORY[(s.statusCategory or {}).key] or "todo",
  }
end

---@return TrackerIssueType|nil
function M.issue_type(t)
  if type(t) ~= "table" then return nil end
  local level = tonumber(t.hierarchyLevel) or (t.subtask and -1 or 0)
  return { id = tostring(t.id or ""), name = t.name or "?", subtask = t.subtask == true or level < 0, level = level }
end

---@return TrackerIssueRef
local function ref(raw)
  local f = raw.fields or {}
  return {
    key = raw.key,
    summary = f.summary or "",
    status = M.status(f.status),
    type = M.issue_type(f.issuetype),
  }
end

---Where the nodes stashed for one rich-text field live until it is saved
---(see adf.lua PRESERVED). Session-long: editing follows viewing.
---@param what string  "description" | "comment:<id>"
function M.stash_key(pcfg, key, what)
  return ("jira:stash:%s:%s:%s"):format(pcfg.base_url or "", key, what)
end

---Rich text field: ADF on v3, a plain (wiki) string on the Agile API.
---@param stash_key string|nil  remember preserved nodes under this key
---@return string markdown, string[] lossy
local function text(value, stash_key)
  if type(value) == "table" then
    local stash = stash_key and {} or nil
    local md = adf.to_markdown(value, stash)
    if stash_key then require("tracker.state").set(stash_key, stash) end
    return md, adf.lossy(value, stash ~= nil)
  end
  if type(value) == "string" then return value, {} end
  return "", {}
end

---@param raw table   Jira issue JSON
---@param pcfg table  provider config (base_url, fields.story_points)
---@return TrackerIssue
function M.issue(raw, pcfg)
  local f = raw.fields or {}
  local base = (pcfg.base_url or ""):gsub("/+$", "")
  local issue = {
    provider = "jira",
    id = tostring(raw.id or ""),
    key = raw.key,
    summary = f.summary or "",
    url = base .. "/browse/" .. tostring(raw.key),
    status = M.status(f.status),
    type = M.issue_type(f.issuetype),
    priority = f.priority and f.priority.name or nil,
    priority_id = f.priority and f.priority.id and tostring(f.priority.id) or nil,
    assignee = M.user(f.assignee),
    reporter = M.user(f.reporter),
    labels = f.labels or {},
    created = f.created,
    updated = f.updated,
    subtasks = {},
  }
  if f.parent then issue.parent = ref(f.parent) end
  for _, st in ipairs(f.subtasks or {}) do
    table.insert(issue.subtasks, ref(st))
  end
  local cf = pcfg.fields or {}
  if cf.story_points and type(f[cf.story_points]) == "number" then issue.story_points = f[cf.story_points] end
  if type(f.duedate) == "string" then issue.due_date = f.duedate end
  if cf.start_date and type(f[cf.start_date]) == "string" then issue.start_date = f[cf.start_date] end
  if type(f.issuelinks) == "table" then
    -- Read from this issue's side: an `outwardIssue` entry means "this
    -- <outward> that" (blocks), an `inwardIssue` one "this <inward> that"
    -- (is blocked by).
    issue.links = {}
    for _, l in ipairs(f.issuelinks) do
      local t = l.type or {}
      local other, dir = l.outwardIssue, "outward"
      if not other then other, dir = l.inwardIssue, "inward" end
      if other then
        local link = {
          id = tostring(l.id), type = t.name, direction = dir,
          label = (dir == "outward" and t.outward or t.inward) or t.name, issue = ref(other),
        }
        table.insert(issue.links, link)
        local done = link.issue.status and link.issue.status.category == "done"
        if t.name == "Blocks" and dir == "inward" and not done then issue.blocked = true end
      end
    end
  end
  if cf.sprint and type(f[cf.sprint]) == "table" then
    issue.sprints = {}
    for _, s in ipairs(f[cf.sprint]) do
      if type(s) == "table" then table.insert(issue.sprints, M.sprint(s)) end
    end
  end
  if f.description ~= nil then
    issue.description, issue.lossy = text(f.description, M.stash_key(pcfg, raw.key, "description"))
  end
  if f.attachment then
    issue.attachments = {}
    for _, a in ipairs(f.attachment) do
      table.insert(issue.attachments, {
        id = tostring(a.id), filename = a.filename or "?", mime = a.mimeType,
        size = a.size, created = a.created, author = M.user(a.author),
      })
    end
  end
  return issue
end

---@param c table       Jira comment JSON
---@param pcfg table|nil with `key`: stash preserved nodes for a later edit
---@param key string|nil issue key
---@return TrackerComment
function M.comment(c, pcfg, key)
  local sk = pcfg and key and M.stash_key(pcfg, key, "comment:" .. tostring(c.id)) or nil
  local body, lossy = text(c.body, sk)
  return {
    id = tostring(c.id),
    author = M.user(c.author),
    body = body,
    lossy = lossy,
    created = c.created,
    updated = c.updated,
  }
end

---@return TrackerTransition
function M.transition(t)
  return { id = tostring(t.id), name = t.name or "?", to = M.status(t.to) }
end

---@return TrackerSprint
function M.sprint(s)
  return {
    id = tostring(s.id),
    name = s.name or "?",
    state = s.state,
    goal = s.goal,
    start_date = s.startDate,
    end_date = s.endDate,
    complete_date = s.completeDate,
    board_id = s.originBoardId and tostring(s.originBoardId) or nil,
  }
end

return M
