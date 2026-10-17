-- GitLab JSON → normalized shapes (see tracker.model). Text is GitLab
-- Flavored Markdown and passes through untouched.

local keys = require("tracker.providers.gitlab.keys")

local M = {}

---@return TrackerUser|nil
function M.user(u)
  if type(u) ~= "table" or not u.id then return nil end
  return { id = tostring(u.id), name = u.name or u.username or "?", username = u.username, email = u.public_email }
end

M.OPEN = { id = "open", name = "Open", category = "todo" }
M.CLOSED = { id = "closed", name = "Closed", category = "done" }

---Status of a label list.
---@param name string  the list's label
---@param pcfg table
---@return TrackerStatus
function M.list_status(name, pcfg)
  local categories = type(pcfg.workflow) == "table" and pcfg.workflow.categories or {}
  return { id = "label:" .. name, name = name, category = categories[name] or "in_progress" }
end

---The status an issue shows: Closed, else the right-most board list whose
---label it carries, else Open. GitLab itself only knows open / closed; the
---lists of the issue board are what a team reads as its workflow.
---@param raw table       issue JSON
---@param lists string[]  labels of the board's lists, left to right
---@param pcfg table
---@return TrackerStatus
function M.status(raw, lists, pcfg)
  if raw.state == "closed" then return M.CLOSED end
  local has = {}
  for _, l in ipairs(raw.labels or {}) do has[type(l) == "table" and l.name or l] = true end
  for n = #(lists or {}), 1, -1 do
    if has[lists[n]] then return M.list_status(lists[n], pcfg) end
  end
  return M.OPEN
end

local TYPE_NAMES = { issue = "Issue", incident = "Incident", test_case = "Test case", task = "Task" }

---@param name string|nil  issue_type of the API
---@return TrackerIssueType
function M.issue_type(name)
  name = (name or "issue"):lower()
  local task = name == "task"
  return { id = name, name = TYPE_NAMES[name] or name, subtask = task, level = task and -1 or 0 }
end

local MIME = {
  png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif", webp = "image/webp",
  svg = "image/svg+xml", bmp = "image/bmp", pdf = "application/pdf", txt = "text/plain",
}

---Files uploaded into a Markdown text: GitLab keeps them with the project
---and the text links them as `/uploads/<secret>/<name>`.
---@param md string|nil
---@param into TrackerAttachment[]
---@param seen table<string, true>
function M.uploads(md, into, seen)
  for secret, name in (md or ""):gmatch("/uploads/(%x+)/([^%s%)\"'>]+)") do
    local id = secret .. "/" .. name
    if not seen[id] then
      seen[id] = true
      local shown = vim.uri_decode and vim.uri_decode(name) or name
      table.insert(into, {
        id = id, filename = shown, ref = "/uploads/" .. id,
        mime = MIME[(shown:match("%.(%w+)$") or ""):lower()],
      })
    end
  end
end

---A milestone / an iteration as a sprint.
---@param raw table
---@param kind "milestone"|"iteration"
---@return TrackerSprint
function M.sprint(raw, kind)
  local state = raw.state
  if kind == "iteration" then
    -- 1 upcoming, 2 current, 3 closed
    state = ({ [1] = "future", [2] = "active", [3] = "closed" })[tonumber(raw.state)] or tostring(raw.state)
  else
    local today = os.date("%Y-%m-%d")
    if raw.state == "closed" then
      state = "closed"
    elseif raw.start_date and raw.start_date > today then
      state = "future"
    else
      state = "active"
    end
  end
  return {
    id = tostring(raw.id),
    name = raw.title or (kind == "iteration" and ((raw.start_date or "?") .. " – " .. (raw.due_date or "?"))) or "?",
    state = state,
    goal = raw.description,
    start_date = raw.start_date,
    end_date = raw.due_date,
    kind = kind,
  }
end

---@param raw table       GitLab issue JSON
---@param pcfg table      provider config (project, base_url, workflow)
---@param lists string[]|nil  labels of the board's lists
---@return TrackerIssue
function M.issue(raw, pcfg, lists)
  local project = raw.references and raw.references.full and raw.references.full:match("^(.-)#%d+$") or nil
  if not project and raw.web_url then
    local base = (pcfg.base_url or ""):gsub("/+$", "")
    project = raw.web_url:sub(#base + 2):match("^(.-)/%-/") or nil
  end
  local labels = {}
  for _, l in ipairs(raw.labels or {}) do table.insert(labels, type(l) == "table" and l.name or l) end
  local issue = {
    provider = pcfg.name or "gitlab",
    id = tostring(raw.id or ""),
    key = keys.make(pcfg, project, raw.iid),
    project = project or pcfg.project,
    summary = raw.title or "",
    url = raw.web_url or "",
    status = M.status(raw, lists, pcfg),
    type = M.issue_type(raw.issue_type),
    assignee = M.user((raw.assignees or {})[1] or raw.assignee),
    reporter = M.user(raw.author),
    labels = labels,
    created = raw.created_at,
    updated = raw.updated_at,
    subtasks = {},
    lossy = {},
  }
  if type(raw.weight) == "number" then issue.story_points = raw.weight end
  if type(raw.due_date) == "string" then issue.due_date = raw.due_date end
  if type(raw.start_date) == "string" then issue.start_date = raw.start_date end
  if type(raw.epic) == "table" and raw.epic.iid then
    issue.parent = { key = "&" .. raw.epic.iid, summary = raw.epic.title or "", type = { id = "epic", name = "Epic", subtask = false, level = 1 } }
  end
  local sprints = {}
  if type(raw.iteration) == "table" then table.insert(sprints, M.sprint(raw.iteration, "iteration")) end
  if type(raw.milestone) == "table" then table.insert(sprints, M.sprint(raw.milestone, "milestone")) end
  if #sprints > 0 then issue.sprints = sprints end
  -- priority: the first of `priority_labels` the issue carries ("1" = the first one)
  for n, name in ipairs(pcfg.priority_labels or {}) do
    if vim.tbl_contains(labels, name) then
      issue.priority, issue.priority_id = name, tostring(n)
      break
    end
  end
  if raw.description ~= nil or raw.title then
    issue.description = raw.description or ""
    issue.attachments = {}
    M.uploads(issue.description, issue.attachments, {})
  end
  return issue
end

---@param note table  GitLab note JSON
---@return TrackerComment
function M.comment(note)
  return {
    id = tostring(note.id),
    author = M.user(note.author),
    body = note.body or "",
    lossy = {},
    created = note.created_at,
    updated = note.updated_at ~= note.created_at and note.updated_at or nil,
  }
end

---A linked issue, as the links endpoint lists it.
---@return TrackerLink
function M.link(raw, pcfg, lists)
  local other = M.issue(raw, pcfg, lists)
  local kind = raw.link_type or "relates_to"
  local label = ({ relates_to = "relates to", blocks = "blocks", is_blocked_by = "is blocked by" })[kind] or kind
  return {
    id = tostring(raw.issue_link_id),
    type = kind == "relates_to" and "relates_to" or "blocks",
    direction = kind == "is_blocked_by" and "inward" or "outward",
    label = label,
    issue = { key = other.key, summary = other.summary, status = other.status, type = other.type },
  }
end

return M
