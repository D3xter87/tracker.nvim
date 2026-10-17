-- In-memory provider for API/UI tests. Mutations change its state, so a
-- test can check that a view refreshes with what the "server" now says.

local M = { name = "fake" }

M.capabilities = {
  comments = true, edit_comments = true, transitions = true, assign = true,
  edit = true, create = true, subtasks = true, boards = true, sprints = true, backlog = true,
  attachments = true, epics = true, children = true,
  priority = true, story_points = true, labels = true, epic_link = true, reporter = true,
  rank = true, sprint_move = true, sprint_manage = true, archive = true, delete = true, dates = true, timeline = true,
  delete_comments = true, clone = true, links = true, upload = true, remote_links = true,
}
M.defaults = {
  base_url = nil, project = "FAKE", board = nil,
  queries = {
    { name = "all", jql = "project = {project}" }, { name = "sprint", sprint = true }, { name = "backlog", backlog = true },
    { name = "kids", jql = "assignee = me", children = true },
  },
}

local TODO = { id = "1", name = "To Do", category = "todo" }
local PROG = { id = "2", name = "In Progress", category = "in_progress" }
local DONE = { id = "3", name = "Done", category = "done" }
local STATUSES = { ["1"] = TODO, ["2"] = PROG, ["3"] = DONE }

M.me = { id = "u1", name = "Jan Kowalski" }
M.calls = {}

function M.reset()
  M.hidden = {}
  M.stale_rank = false
  M.calls = {}
  M.issues = {
    {
      provider = "fake", id = "1", key = "FAKE-1", summary = "First issue", url = "https://fake/browse/FAKE-1",
      status = TODO, type = { id = "t", name = "Task", subtask = false }, assignee = M.me, labels = { "x" },
      subtasks = {}, description = "Hello **world**\n\n[attachment: shot.png](adf:1)", lossy = {},
      updated = "2026-10-16T09:00:00.000+0200",
      attachments = { { id = "9", filename = "shot.png", mime = "image/png", size = 2048 } },
    },
    {
      provider = "fake", id = "2", key = "FAKE-2", summary = "Second issue", url = "https://fake/browse/FAKE-2",
      status = PROG, type = { id = "t", name = "Bug", subtask = false }, labels = {}, subtasks = {},
      description = "", lossy = {},
    },
  }
  M.comments = { ["FAKE-1"] = { { id = "c1", author = M.me, body = "first comment", created = "2026-10-16T10:00:00.000+0200" } } }
  M.sprint_data = {
    { id = "10", name = "#59 Old", state = "closed", goal = "old goal\nsecond line",
      start_date = "2026-09-21T09:00:00.000Z", end_date = "2026-10-12T09:00:00.000Z", complete_date = "2026-10-12T10:00:00.000Z" },
    { id = "11", name = "#60 Now", state = "active", goal = "1. first\n2. second",
      start_date = "2026-10-12T09:00:00.000Z", end_date = "2026-11-02T09:00:00.000Z" },
  }
end
M.reset()

local function later(cb, ...)
  local args = { ... }
  vim.schedule(function() cb(unpack(args)) end)
end

local function find(key)
  for _, i in ipairs(M.issues) do
    if i.key == key then return i end
  end
end

function M.web_url(_, key) return "https://fake/browse/" .. key end
function M.myself(_, cb) later(cb, M.me) end
function M.search(_, q, opts, cb)
  table.insert(M.calls, { "search", q, opts })
  later(cb, vim.deepcopy(M.issues), nil, { truncated = false })
end
function M.get_issue(_, key, cb)
  local i = find(key)
  if not i then return later(cb, nil, "not found") end
  later(cb, vim.deepcopy(i))
end
function M.get_comments(_, key, cb) later(cb, vim.deepcopy(M.comments[key] or {})) end
function M.add_comment(_, key, md, cb)
  M.comments[key] = M.comments[key] or {}
  local c = { id = "c" .. (#M.comments[key] + 2), author = M.me, body = md }
  table.insert(M.comments[key], c)
  later(cb, c)
end
function M.edit_comment(_, key, id, md, cb)
  for _, c in ipairs(M.comments[key] or {}) do
    if c.id == id then c.body = md return later(cb, c) end
  end
  later(cb, nil, "no comment")
end
function M.delete_comment(_, key, id, cb)
  table.insert(M.calls, { "delete_comment", key, id })
  M.comments[key] = vim.tbl_filter(function(c) return c.id ~= id end, M.comments[key] or {})
  later(cb, true)
end
M.link_type_data = {
  { id = "1", name = "Blocks", inward = "is blocked by", outward = "blocks" },
  { id = "2", name = "Relates", inward = "relates to", outward = "relates to" },
}
function M.link_types(_, cb) later(cb, vim.deepcopy(M.link_type_data)) end
M.link_seq = 0
function M.add_link(_, key, link, cb)
  table.insert(M.calls, { "link", key, vim.deepcopy(link) })
  local from, to = find(key), find(link.key)
  if not from then return later(cb, nil, "no issue " .. key) end
  M.link_seq = M.link_seq + 1
  local t
  for _, lt in ipairs(M.link_type_data) do
    if lt.name == link.type then t = lt end
  end
  local function add(i, dir, other)
    i.links = i.links or {}
    table.insert(i.links, { id = "L" .. M.link_seq, type = t.name, direction = dir,
      label = dir == "outward" and t.outward or t.inward,
      issue = { key = other.key, summary = other.summary, status = other.status, type = other.type } })
  end
  add(from, link.direction, to or { key = link.key, summary = "?" })
  if to then add(to, link.direction == "outward" and "inward" or "outward", from) end
  later(cb, true)
end
function M.delete_link(_, id, cb)
  table.insert(M.calls, { "unlink", id })
  for _, i in ipairs(M.issues) do
    i.links = i.links and vim.tbl_filter(function(l) return l.id ~= id end, i.links) or nil
  end
  later(cb, true)
end
function M.add_remote_link(_, key, link, cb)
  table.insert(M.calls, { "remote_link", key, vim.deepcopy(link) })
  later(cb, true)
end
M.att_seq = 100
function M.upload_attachments(_, key, paths, cb)
  table.insert(M.calls, { "upload", key, vim.deepcopy(paths) })
  local i = find(key)
  local out = {}
  for _, p in ipairs(paths) do
    M.att_seq = M.att_seq + 1
    local a = { id = tostring(M.att_seq), filename = vim.fs.basename(p), size = 10, mime = "image/png" }
    table.insert(out, a)
    if i then
      i.attachments = i.attachments or {}
      table.insert(i.attachments, a)
    end
  end
  later(cb, out)
end
function M.delete_attachment(_, id, cb)
  table.insert(M.calls, { "delete_attachment", id })
  for _, i in ipairs(M.issues) do
    i.attachments = i.attachments and vim.tbl_filter(function(a) return a.id ~= id end, i.attachments) or nil
  end
  later(cb, true)
end
function M.clone_issue(_, key, opts, cb)
  table.insert(M.calls, { "clone", key, vim.deepcopy(opts) })
  local orig = find(key)
  if not orig then return later(cb, nil, "not found") end
  local copy = vim.deepcopy(orig)
  copy.id = tostring(#M.issues + 1)
  copy.key = "FAKE-" .. copy.id
  copy.summary = opts.summary
  copy.url = M.web_url(nil, copy.key)
  table.insert(M.issues, copy)
  later(cb, { id = copy.id, key = copy.key, url = copy.url, subtasks = {}, dropped = { "customfield_10015" }, failed = {} })
end
function M.get_transitions(_, _, cb)
  later(cb, {
    { id = "11", name = "Start", to = PROG },
    { id = "21", name = "Finish", to = DONE },
    { id = "31", name = "Reopen", to = TODO },
  })
end
function M.transition(_, key, id, cb)
  table.insert(M.calls, { "transition", key, id })
  local to = ({ ["11"] = "2", ["21"] = "3", ["31"] = "1" })[id]
  find(key).status = STATUSES[to]
  later(cb, true)
end
function M.assignable_users(_, _, _, cb) later(cb, { M.me, { id = "u2", name = "Anna Nowak" } }) end
function M.assign(_, key, id, cb)
  table.insert(M.calls, { "assign", key, id })
  find(key).assignee = id and { id = id, name = id } or nil
  later(cb, true)
end
function M.update_issue(_, key, fields, cb)
  table.insert(M.calls, { "update", key, fields })
  local i = find(key)
  if not i then return later(cb, true) end -- e.g. a freshly created epic
  if fields.summary then i.summary = fields.summary end
  if fields.description then i.description = fields.description end
  if fields.priority_id then i.priority_id = fields.priority_id end
  if fields.labels then i.labels = fields.labels end
  if fields.story_points ~= nil then i.story_points = fields.story_points or nil end
  if fields.parent ~= nil then
    i.parent = fields.parent and { key = fields.parent, summary = fields.parent, type = { name = "Epik", level = 1 } } or nil
  end
  if fields.start_date ~= nil then i.start_date = fields.start_date or nil end
  if fields.due_date ~= nil then i.due_date = fields.due_date or nil end
  later(cb, true)
end
-- Timeline: epics (as issues) in rank order; children come from M.hidden.
M.epic_rows = {}
function M.epic_issues(_, project, opts, cb)
  table.insert(M.calls, { "epic_issues", project, vim.deepcopy(opts) })
  later(cb, vim.deepcopy(M.epic_rows))
end
function M.issue_types(_, _, cb)
  later(cb, {
    { id = "t", name = "Task", subtask = false, level = 0 },
    { id = "st", name = "Sub-task", subtask = true, level = -1 },
    { id = "ep", name = "Epik", subtask = false, level = 1 },
  })
end
function M.priorities(_, cb)
  later(cb, { { id = "1", name = "Highest" }, { id = "2", name = "High" }, { id = "3", name = "Medium" } })
end
function M.epic_list(_, project, cb)
  table.insert(M.calls, { "epic_list", project })
  later(cb, { { key = "FAKE-E", summary = "Stability", color = 8 }, { key = "FAKE-F", summary = "Features", color = 3 } })
end
function M.create_issue(_, f, cb)
  table.insert(M.calls, { "create", f })
  local key = "FAKE-" .. (#M.issues + 1)
  table.insert(M.issues, {
    provider = "fake", id = tostring(#M.issues + 1), key = key, summary = f.summary, url = M.web_url(nil, key),
    status = TODO, labels = {}, subtasks = {}, description = f.description or "", lossy = {},
  })
  later(cb, { id = tostring(#M.issues), key = key, url = M.web_url(nil, key) })
end
function M.boards(_, _, cb) later(cb, { { id = "7", name = "FAKE board", type = "scrum" } }) end
function M.board_columns(_, _, cb)
  later(cb, {
    { name = "To Do", statuses = { "1" } },
    { name = "Doing", statuses = { "2" } },
    { name = "Done", statuses = { "3" } },
  })
end
function M.active_sprints(_, _, cb) later(cb, { { id = "s1", name = "Sprint 42", start_date = "2026-10-12", end_date = "2026-10-26" } }) end
function M.board_issues(_, _, sprint, cb)
  table.insert(M.calls, { "board_issues", sprint })
  later(cb, vim.deepcopy(M.issues))
end
function M.backlog(_, board, cb)
  table.insert(M.calls, { "backlog", board })
  later(cb, { vim.deepcopy(M.issues[2]) })
end
-- Issues only reachable as children (not returned by search).
M.hidden = {}
function M.children(_, keys, cb)
  table.insert(M.calls, { "children", vim.deepcopy(keys) })
  local want, out = {}, {}
  for _, k in ipairs(keys) do want[k] = true end
  for _, i in ipairs(M.hidden) do
    if i.parent and want[i.parent.key] then table.insert(out, vim.deepcopy(i)) end
  end
  later(cb, out)
end
-- Planning: rank reorders M.issues like Jira's rank would — unless
-- `stale_rank`, which plays Jira's search index still behind the rank.
function M.rank(_, keys, where, cb)
  table.insert(M.calls, { "rank", vim.deepcopy(keys), vim.deepcopy(where) })
  if M.stale_rank then return later(cb, true) end
  local moving, rest = {}, {}
  local set = {}
  for _, k in ipairs(keys) do set[k] = true end
  for _, i in ipairs(M.issues) do
    if set[i.key] then table.insert(moving, i) else table.insert(rest, i) end
  end
  local target = where.after or where.before
  local out = {}
  for _, i in ipairs(rest) do
    if i.key == target and where.before then vim.list_extend(out, moving) end
    table.insert(out, i)
    if i.key == target and where.after then vim.list_extend(out, moving) end
  end
  M.issues = out
  later(cb, true)
end
function M.open_sprints(_, _, cb)
  later(cb, { { id = "s1", name = "Sprint 42", state = "active" }, { id = "s2", name = "Sprint 43", state = "future" } })
end
function M.sprints(_, _, cb) later(cb, vim.deepcopy(M.sprint_data)) end
function M.create_sprint(_, board, f, cb)
  table.insert(M.calls, { "create_sprint", board, vim.deepcopy(f) })
  local s = { id = tostring(100 + #M.sprint_data), name = f.name, state = "future", goal = f.goal,
              start_date = f.start_date or nil, end_date = f.end_date or nil }
  table.insert(M.sprint_data, s)
  later(cb, vim.deepcopy(s))
end
function M.update_sprint(_, id, f, cb)
  table.insert(M.calls, { "update_sprint", id, vim.deepcopy(f) })
  for _, s in ipairs(M.sprint_data) do
    if s.id == id then
      for k, v in pairs(f) do
        if v == false then s[k] = nil else s[k] = v end
      end
      return later(cb, vim.deepcopy(s))
    end
  end
  later(cb, nil, "no sprint " .. id)
end
function M.move_to_sprint(_, id, keys, cb)
  table.insert(M.calls, { "sprint", id, vim.deepcopy(keys) })
  later(cb, true)
end
function M.move_to_backlog(_, keys, cb)
  table.insert(M.calls, { "to_backlog", vim.deepcopy(keys) })
  later(cb, true)
end
function M.archive(_, keys, cb)
  table.insert(M.calls, { "archive", vim.deepcopy(keys) })
  later(cb, true)
end
function M.delete_issue(_, key, with_subtasks, cb)
  table.insert(M.calls, { "delete", key, with_subtasks })
  M.issues = vim.tbl_filter(function(i) return i.key ~= key end, M.issues)
  later(cb, true)
end
M.epic_data = { ["FAKE-E"] = { key = "FAKE-E", summary = "Stability", color = 8 } }
function M.epics(_, keys, cb)
  local out = {}
  for _, k in ipairs(keys) do out[k] = M.epic_data[k] end
  later(cb, out)
end
M.downloads = 0
function M.download_attachment(_, att, path, cb)
  M.downloads = M.downloads + 1
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write("PNG" .. (att.id or att.url))
  f:close()
  later(cb, path)
end

return M
