-- GitLab provider against a stubbed transport: the requests it builds
-- (method, path, query, JSON body) and how it reads GitLab's answers.

local h = require("helpers")
local http = require("tracker.http.client")
local gitlab = require("tracker.providers.gitlab")
local mapper = require("tracker.providers.gitlab.mapper")
local query = require("tracker.providers.gitlab.query")
local cache = require("tracker.state")

require("tracker").setup({})

local PCFG = vim.tbl_extend("force", vim.deepcopy(gitlab.defaults), {
  name = "gitlab", type = "gitlab", base_url = "https://gitlab.example/", token = "glpat-x",
  project = "group/app", tier = "free",
})
local API = "https://gitlab.example/api/v4"
local PROJECT = API .. "/projects/group%2Fapp"

local real_request = http.request
local sent, responses

---Queue responses ({ status, body, headers }); every http.request pops the
---next one. The provider's caches start empty.
local function stub(list)
  cache.clear("gitlab:")
  sent, responses = {}, list
  http.request = function(opts, cb)
    table.insert(sent, opts)
    local r = table.remove(responses, 1) or { status = 200, body = "{}" }
    vim.schedule(function()
      local ok = r.status >= 200 and r.status < 300
      cb({ ok = ok, status = r.status, body = r.body, headers = r.headers or {},
           err = not ok and http.describe_error(r.status) or nil })
    end)
  end
end

---Run an async provider call to completion.
local function run(fn)
  local res, done = {}, false
  fn(function(...)
    res = vim.F.pack_len(...)
    done = true
  end)
  vim.wait(2000, function() return done end, 5)
  http.request = real_request
  assert(done, "callback never ran")
  return vim.F.unpack_len(res)
end

local function body(i) return vim.json.decode(sent[i].body) end
local function json(v) return { status = 200, body = vim.json.encode(v) } end

-- the project's first board: two label lists
local BOARD = json({ { id = 5, name = "Development", lists = {
  { id = 2, label = { name = "Review" }, position = 1 },
  { id = 1, label = { name = "Doing" }, position = 0 },
  { id = 3, list_type = "assignee", position = 2 },
} } })
local NO_BOARD = json({})

local function raw(iid, extra)
  return vim.tbl_extend("force", {
    id = 1000 + iid, iid = iid, project_id = 9, title = "Issue " .. iid, description = "Text",
    state = "opened", labels = {}, assignees = {}, author = { id = 1, name = "Jan Kowalski", username = "jan" },
    issue_type = "issue", web_url = "https://gitlab.example/group/app/-/issues/" .. iid,
    references = { short = "#" .. iid, full = "group/app#" .. iid },
    created_at = "2026-10-16T09:00:00.000Z", updated_at = "2026-10-16T10:00:00.000Z",
  }, extra or {})
end

local T = {}

T["query: a filter line becomes Issues API parameters"] = function()
  h.eq({ scope = "assigned_to_me", state = "opened", labels = "bug,ui", order_by = "updated_at", search = "login form" },
    query.parse("assignee=@me labels=bug,ui order=updated_at login form").params)
  h.eq({ assignee_id = "None", milestone = "Release 2", ["not[labels]"] = "wontfix" },
    query.parse('assignee=none state=all milestone="Release 2" not.labels=wontfix').params)
  h.eq({ state = "closed", author_username = "jan", iteration_id = "Current", weight = "3", issue_type = "incident",
         ["iids[]"] = { "1", "2" }, sort = "asc", confidential = "true" },
    query.parse("state=closed author=@jan iteration=current weight=3 type=Incident iids=1,2 sort=asc confidential=true").params)
  local q = query.parse("project=other/lib group=team search=crash")
  h.eq({ "other/lib", "team", "crash" }, { q.project, q.group, q.params.search })
  h.eq({ state = "opened" }, query.parse("").params)
end

T["search: bearer token, the project by its encoded path, statuses from the board's lists"] = function()
  stub({ BOARD, json({ raw(12, { labels = { "bug", "Doing", "Review" } }), raw(13), raw(14, { state = "closed" }) }) })
  local issues, err, meta = run(function(cb) gitlab.search(PCFG, "assignee=@me labels=bug", { limit = 50 }, cb) end)
  h.eq(nil, err)
  h.eq(false, meta.truncated)
  h.eq("Bearer glpat-x", sent[1].headers.Authorization)
  h.eq(PROJECT .. "/boards", sent[1].url)
  h.eq(PROJECT .. "/issues", sent[2].url)
  h.eq({ scope = "assigned_to_me", labels = "bug", state = "opened", page = 1, per_page = 50 }, sent[2].query)
  h.eq({ "#12", "#13", "#14" }, vim.tbl_map(function(i) return i.key end, issues))
  h.eq({ "gitlab", "group/app", "Issue 12", "https://gitlab.example/group/app/-/issues/12" },
    { issues[1].provider, issues[1].project, issues[1].summary, issues[1].url })
  -- the right-most list the issue has a label of
  h.eq({ id = "label:Review", name = "Review", category = "in_progress" }, issues[1].status)
  h.eq(mapper.OPEN, issues[2].status)
  h.eq(mapper.CLOSED, issues[3].status)
  h.eq({ "bug", "Doing", "Review" }, issues[1].labels)
  h.eq({}, issues[1].subtasks)
  h.eq({ id = "1", name = "Jan Kowalski", username = "jan" }, issues[1].reporter)
end

T["search: pages by x-next-page up to the limit"] = function()
  stub({
    NO_BOARD,
    { status = 200, body = vim.json.encode({ raw(1), raw(2) }), headers = { ["x-next-page"] = "2" } },
    { status = 200, body = vim.json.encode({ raw(3), raw(4) }), headers = { ["x-next-page"] = "3" } },
  })
  local issues, _, meta = run(function(cb) gitlab.search(PCFG, "", { limit = 3 }, cb) end)
  h.eq({ "#1", "#2", "#3" }, vim.tbl_map(function(i) return i.key end, issues))
  h.eq(true, meta.truncated)
  h.eq({ 1, 3 }, { sent[2].query.page, sent[2].query.per_page })
  h.eq(2, sent[3].query.page)
end

T["search: another project keeps its path in the key; a group lists its issues"] = function()
  stub({ NO_BOARD, json({ raw(3, { references = { full = "other/lib#3" } }) }) })
  local issues = run(function(cb) gitlab.search(PCFG, "project=other/lib", nil, cb) end)
  h.eq(API .. "/projects/other%2Flib/issues", sent[2].url)
  h.eq("other/lib#3", issues[1].key)
  stub({ NO_BOARD, json({}) })
  run(function(cb) gitlab.search(PCFG, "group=team/sub", nil, cb) end)
  h.eq(API .. "/groups/team%2Fsub/issues", sent[2].url)
end

T["an error says what GitLab said"] = function()
  stub({ NO_BOARD, { status = 403, body = '{"message":"403 Forbidden"}' } })
  local issues, err = run(function(cb) gitlab.search(PCFG, "", nil, cb) end)
  h.eq(nil, issues)
  h.eq("forbidden (token lacks permission) — 403 Forbidden", err)
  stub({ { status = 400, body = '{"message":{"title":["can\'t be blank"]}}' } })
  local _, cerr = run(function(cb) gitlab.create_issue(PCFG, { project = "group/app", summary = "" }, cb) end)
  h.eq("HTTP 400 — title: can't be blank", cerr)
end

T["get_issue: the issue with its links, uploads as attachments, premium fields"] = function()
  stub({
    BOARD,
    json(raw(12, {
      description = "See\n\n![shot.png](/uploads/0123abcd/shot.png)\n\n[spec.pdf](/uploads/ffee/spec.pdf)",
      weight = 5, due_date = "2026-11-30", assignees = { { id = 7, name = "Anna Nowak", username = "anna" } },
      milestone = { id = 3, title = "v1.2", state = "active", due_date = "2026-12-01" },
      epic = { id = 40, iid = 4, title = "Stability" },
    })),
    json({ raw(20, { issue_link_id = 91, link_type = "is_blocked_by" }), raw(21, { issue_link_id = 92, link_type = "relates_to", state = "closed" }) }),
  })
  local issue, err = run(function(cb) gitlab.get_issue(PCFG, "#12", cb) end)
  h.eq(nil, err)
  h.eq({ PROJECT .. "/issues/12", PROJECT .. "/issues/12/links" }, { sent[2].url, sent[3].url })
  h.eq({ 5, "2026-11-30", "Anna Nowak" }, { issue.story_points, issue.due_date, issue.assignee.name })
  h.eq({ { id = "0123abcd/shot.png", filename = "shot.png", ref = "/uploads/0123abcd/shot.png", mime = "image/png" },
         { id = "ffee/spec.pdf", filename = "spec.pdf", ref = "/uploads/ffee/spec.pdf", mime = "application/pdf" } }, issue.attachments)
  h.eq({ key = "&4", summary = "Stability", type = { id = "epic", name = "Epic", subtask = false, level = 1 } }, issue.parent)
  h.eq({ "3", "v1.2", "active", "milestone" }, { issue.sprints[1].id, issue.sprints[1].name, issue.sprints[1].state, issue.sprints[1].kind })
  h.eq({ "91", "blocks", "inward", "is blocked by", "#20" },
    { issue.links[1].id, issue.links[1].type, issue.links[1].direction, issue.links[1].label, issue.links[1].issue.key })
  h.eq({ "92", "relates_to", "outward", "relates to" }, { issue.links[2].id, issue.links[2].type, issue.links[2].direction, issue.links[2].label })
  h.eq(true, issue.blocked)
  h.eq({}, issue.lossy)
end

T["a key without a project says so"] = function()
  stub({})
  local pcfg = vim.tbl_extend("force", PCFG, { project = vim.NIL })
  pcfg.project = nil
  local issue, err = run(function(cb) gitlab.get_issue(pcfg, "#12", cb) end)
  h.eq(nil, issue)
  h.truthy(err:find("no project for #12", 1, true), err)
  local _, kerr = run(function(cb) gitlab.get_issue(PCFG, "ABC-12", cb) end)
  h.truthy(kerr:find("is no issue key", 1, true), kerr)
  h.eq(0, #sent)
end

T["comments: the notes people wrote, oldest first; system notes left out"] = function()
  stub({ json({
    { id = 1, body = "first", author = { id = 1, name = "Jan" }, created_at = "t1", updated_at = "t1", system = false },
    { id = 2, body = "added ~bug label", system = true },
    { id = 3, body = "second", author = { id = 2, name = "Anna" }, created_at = "t2", updated_at = "t3" },
  }) })
  local comments = run(function(cb) gitlab.get_comments(PCFG, "#12", cb) end)
  h.eq(PROJECT .. "/issues/12/notes", sent[1].url)
  h.eq({ "asc", "created_at", "only_comments" }, { sent[1].query.sort, sent[1].query.order_by, sent[1].query.activity_filter })
  h.eq({ { "1", "first", nil }, { "3", "second", "t3" } }, vim.tbl_map(function(c) return { c.id, c.body, c.updated } end, comments))
end

T["add / edit / delete comment; callouts become GitLab alerts"] = function()
  stub({ json({ id = 9, body = "x", created_at = "t", updated_at = "t" }) })
  run(function(cb) gitlab.add_comment(PCFG, "#12", "> [!INFO]\n> done\n\n> [!WARNING]\n> careful", cb) end)
  h.eq({ "POST", PROJECT .. "/issues/12/notes" }, { sent[1].method, sent[1].url })
  h.eq("> [!NOTE]\n> done\n\n> [!WARNING]\n> careful", body(1).body)
  stub({ json({ id = 9, body = "y" }) })
  run(function(cb) gitlab.edit_comment(PCFG, "other/lib#3", "9", "> [!SUCCESS]\n> ok", cb) end)
  h.eq({ "PUT", API .. "/projects/other%2Flib/issues/3/notes/9" }, { sent[1].method, sent[1].url })
  h.eq("> [!TIP]\n> ok", body(1).body)
  stub({ { status = 204, body = "" } })
  h.eq(true, (run(function(cb) gitlab.delete_comment(PCFG, "#12", "9", cb) end)))
  h.eq({ "DELETE", PROJECT .. "/issues/12/notes/9" }, { sent[1].method, sent[1].url })
end

T["an (upload:…) line is uploaded to the project and becomes GitLab's link"] = function()
  local path = vim.fs.normalize(vim.fn.tempname()) .. ".png"
  vim.fn.writefile({ "x" }, path)
  stub({
    json({ id = 5, alt = "shot", url = "/uploads/66dbcd21/shot.png", markdown = "![shot](/uploads/66dbcd21/shot.png)" }),
    json({ id = 9, body = "x" }),
  })
  run(function(cb) gitlab.add_comment(PCFG, "#12", "Look:\n\n> ![shot.png](upload:" .. path .. ")\n\nbye", cb) end)
  h.eq({ "POST", PROJECT .. "/uploads" }, { sent[1].method, sent[1].url })
  h.eq({ { "file", '@"' .. path .. '"' } }, sent[1].form)
  h.eq("Look:\n\n> ![shot](/uploads/66dbcd21/shot.png)\n\nbye", body(2).body)
  -- mid-text: refused before anything is sent
  stub({})
  local _, err = run(function(cb) gitlab.add_comment(PCFG, "#12", "see ![a](upload:" .. path .. ") here", cb) end)
  h.truthy(err:find("must be on a line of its own", 1, true), err)
  h.eq(0, #sent)
  os.remove(path)
end

T["upload: the files, then a comment that ties them to the issue"] = function()
  local path = vim.fs.normalize(vim.fn.tempname()) .. ".txt"
  vim.fn.writefile({ "x" }, path)
  stub({ json({ alt = "notes", url = "/uploads/aa11/notes.txt", markdown = "[notes.txt](/uploads/aa11/notes.txt)" }), json({ id = 1 }) })
  local atts = run(function(cb) gitlab.upload_attachments(PCFG, "#12", { path }, cb) end)
  h.eq({ PROJECT .. "/uploads", PROJECT .. "/issues/12/notes" }, { sent[1].url, sent[2].url })
  h.eq("[notes.txt](/uploads/aa11/notes.txt)", body(2).body)
  h.eq({ { id = "aa11/notes.txt", filename = "notes.txt", ref = "/uploads/aa11/notes.txt", mime = "text/plain" } }, atts)
  os.remove(path)
end

T["transitions: Open, the board's lists, Closed — minus where the issue is"] = function()
  stub({ BOARD, json(raw(12, { labels = { "Doing", "bug" } })) })
  local list = run(function(cb) gitlab.get_transitions(PCFG, "#12", cb) end)
  h.eq({ { "open", "Open" }, { "label:Review", "Review" }, { "closed", "Close" } },
    vim.tbl_map(function(t) return { t.id, t.name } end, list))
  h.eq("done", list[3].to.category)
  stub({ NO_BOARD, json(raw(12, { state = "closed" })) })
  list = run(function(cb) gitlab.get_transitions(PCFG, "#12", cb) end)
  h.eq({ { "open", "Reopen" } }, vim.tbl_map(function(t) return { t.id, t.name } end, list))
end

T["transition: a list swaps the list label, closing and reopening set the state"] = function()
  stub({ BOARD, json(raw(12, { labels = { "Doing", "bug" } })), json(raw(12)) })
  run(function(cb) gitlab.transition(PCFG, "#12", "label:Review", cb) end)
  h.eq({ "PUT", PROJECT .. "/issues/12" }, { sent[3].method, sent[3].url })
  h.eq({ add_labels = "Review", remove_labels = "Doing" }, body(3))

  stub({ BOARD, json(raw(12, { labels = { "Doing" } })), json(raw(12)) })
  run(function(cb) gitlab.transition(PCFG, "#12", "closed", cb) end)
  h.eq({ state_event = "close" }, body(3))

  stub({ BOARD, json(raw(12, { state = "closed", labels = { "Review" } })), json(raw(12)) })
  run(function(cb) gitlab.transition(PCFG, "#12", "open", cb) end)
  h.eq({ state_event = "reopen", remove_labels = "Review" }, body(3))

  stub({ BOARD, json(raw(12, { state = "closed" })), json(raw(12)) })
  run(function(cb) gitlab.transition(PCFG, "#12", "label:Doing", cb) end)
  h.eq({ state_event = "reopen", add_labels = "Doing" }, body(3))
end

T["assign, unassign and the people to pick from"] = function()
  stub({ json(raw(12)) })
  run(function(cb) gitlab.assign(PCFG, "#12", "7", cb) end)
  h.eq({ assignee_ids = { 7 } }, body(1))
  stub({ json(raw(12)) })
  run(function(cb) gitlab.assign(PCFG, "#12", nil, cb) end)
  h.eq({ assignee_ids = { 0 } }, body(1))
  stub({ json({
    { id = 2, name = "Zofia", username = "zofia", state = "active" },
    { id = 3, name = "Blocked", username = "b", state = "blocked" },
    { id = 1, name = "anna", username = "anna", state = "active" },
  }) })
  local users = run(function(cb) gitlab.assignable_users(PCFG, "#12", "an", cb) end)
  h.eq(PROJECT .. "/members/all", sent[1].url)
  h.eq("an", sent[1].query.query)
  h.eq({ "anna", "Zofia" }, vim.tbl_map(function(u) return u.name end, users))
  h.eq("@anna", gitlab.mention(PCFG, users[1]))
end

T["update: fields under GitLab's names; false clears"] = function()
  stub({ json(raw(12)) })
  run(function(cb)
    gitlab.update_issue(PCFG, "#12", { summary = "New", labels = { "a", "b" }, story_points = 3, due_date = "2026-12-01", description = "> [!ERROR]\n> x" }, cb)
  end)
  h.eq({ title = "New", labels = "a,b", weight = 3, due_date = "2026-12-01", description = "> [!CAUTION]\n> x" }, body(1))
  stub({ json(raw(12)) })
  run(function(cb) gitlab.update_issue(PCFG, "#12", { story_points = false, due_date = false }, cb) end)
  h.eq({ weight = vim.NIL, due_date = "" }, body(1))
end

T["priority is a label out of priority_labels"] = function()
  local pcfg = vim.tbl_extend("force", PCFG, { priority_labels = { "prio::high", "prio::mid", "prio::low" } })
  h.eq(true, gitlab.capabilities(pcfg).priority)
  h.eq(nil, gitlab.capabilities(PCFG).priority)
  h.eq({ { id = "1", name = "prio::high" }, { id = "2", name = "prio::mid" }, { id = "3", name = "prio::low" } },
    (run(function(cb) gitlab.priorities(pcfg, cb) end)))
  local issue = mapper.issue(raw(1, { labels = { "bug", "prio::mid" } }), pcfg, {})
  h.eq({ "prio::mid", "2" }, { issue.priority, issue.priority_id })
  stub({ json(raw(1)) })
  run(function(cb) gitlab.update_issue(pcfg, "#1", { priority_id = "1" }, cb) end)
  h.eq({ add_labels = "prio::high", remove_labels = "prio::mid,prio::low" }, body(1))
end

T["create, delete and a clone related to its original"] = function()
  stub({ json(raw(13, { title = "New one" })) })
  local created = run(function(cb)
    gitlab.create_issue(PCFG, { project = "group/app", type_id = "incident", summary = "New one", description = "d" }, cb)
  end)
  h.eq({ "POST", PROJECT .. "/issues" }, { sent[1].method, sent[1].url })
  h.eq({ title = "New one", description = "d", issue_type = "incident" }, body(1))
  h.eq({ id = "1013", key = "#13", url = "https://gitlab.example/group/app/-/issues/13" }, created)

  stub({ { status = 204, body = "" } })
  h.eq(true, (run(function(cb) gitlab.delete_issue(PCFG, "#13", false, cb) end)))
  h.eq({ "DELETE", PROJECT .. "/issues/13" }, { sent[1].method, sent[1].url })

  stub({
    json(raw(12, { labels = { "bug" }, weight = 2, assignees = { { id = 7, name = "Anna" } }, milestone = { id = 3, title = "v1" } })),
    json(raw(14)), json({}),
  })
  local res = run(function(cb) gitlab.clone_issue(PCFG, "#12", { summary = "CLONE - Issue 12", link = true }, cb) end)
  h.eq({ title = "CLONE - Issue 12", description = "Text", labels = "bug", assignee_ids = { 7 }, milestone_id = 3, weight = 2 }, body(2))
  h.eq({ PROJECT .. "/issues/14/links", { target_project_id = "group/app", target_issue_iid = 12, link_type = "relates_to" } }, { sent[3].url, body(3) })
  h.eq({ "#14", {}, {}, {} }, { res.key, res.subtasks, res.dropped, res.failed })
end

T["links: relates_to always, blocks with the licence; removed under the issue"] = function()
  h.eq({ "relates_to" }, vim.tbl_map(function(t) return t.name end, (run(function(cb) gitlab.link_types(PCFG, cb) end))))
  local premium = vim.tbl_extend("force", PCFG, { tier = "premium" })
  h.eq({ "relates_to", "blocks" }, vim.tbl_map(function(t) return t.name end, (run(function(cb) gitlab.link_types(premium, cb) end))))
  stub({ json({}) })
  run(function(cb) gitlab.add_link(premium, "#12", { type = "blocks", direction = "inward", key = "other/lib#3" }, cb) end)
  h.eq({ "POST", PROJECT .. "/issues/12/links" }, { sent[1].method, sent[1].url })
  h.eq({ target_project_id = "other/lib", target_issue_iid = 3, link_type = "is_blocked_by" }, body(1))
  stub({ json({}) })
  run(function(cb) gitlab.delete_link(PCFG, "#12", "91", cb) end)
  h.eq({ "DELETE", PROJECT .. "/issues/12/links/91" }, { sent[1].method, sent[1].url })
end

T["board: its lists are the columns; issues in its order, open then the latest closed"] = function()
  stub({ BOARD })
  local columns, _, meta = run(function(cb) gitlab.board_columns(PCFG, "default", cb) end)
  h.eq({ { name = "Open", statuses = { "open" } }, { name = "Doing", statuses = { "label:Doing" } },
         { name = "Review", statuses = { "label:Review" } }, { name = "Closed", statuses = { "closed" } } }, columns)
  h.eq("Development", meta.name)

  stub({ BOARD, json({ raw(1, { labels = { "Doing" } }) }), json({ raw(2, { state = "closed" }) }) })
  local issues = run(function(cb) gitlab.board_issues(vim.tbl_extend("force", PCFG, { sprints = false }), "default", nil, cb) end)
  h.eq({ state = "opened", order_by = "relative_position", sort = "asc", page = 1, per_page = 100 }, sent[2].query)
  h.eq({ state = "closed", order_by = "updated_at", sort = "desc", page = 1, per_page = 50 }, sent[3].query)
  h.eq({ { "#1", "label:Doing" }, { "#2", "closed" } }, vim.tbl_map(function(i) return { i.key, i.status.id } end, issues))

  stub({ json({ id = 8, name = "Ops", hide_backlog_list = true, hide_closed_list = true, lists = {} }) })
  columns = run(function(cb) gitlab.board_columns(PCFG, "8", cb) end)
  h.eq(PROJECT .. "/boards/8", sent[1].url)
  h.eq({}, columns)
end

T["sprints are milestones on Free: listed, created, closed, issues moved"] = function()
  local today = os.date("%Y-%m-%d")
  stub({ json({
    { id = 3, title = "v1.2", state = "active", start_date = "2020-01-01", due_date = "2020-02-01" },
    { id = 2, title = "v1.1", state = "closed", start_date = "2019-01-01" },
    { id = 4, title = "v2", state = "active", start_date = "2999-01-01" },
  }) })
  local sprints = run(function(cb) gitlab.sprints(PCFG, "default", cb) end)
  h.eq(PROJECT .. "/milestones", sent[1].url)
  h.eq({ { "2", "v1.1", "closed" }, { "3", "v1.2", "active" }, { "4", "v2", "future" } },
    vim.tbl_map(function(s) return { s.id, s.name, s.state } end, sprints))
  h.truthy(today > "2020-01-01")

  stub({ json({ id = 5, title = "v3", state = "active" }) })
  run(function(cb) gitlab.create_sprint(PCFG, "default", { name = "v3", goal = "ship", start_date = "2026-11-02T09:00:00.000Z", end_date = "2026-11-16T09:00:00.000Z" }, cb) end)
  h.eq({ title = "v3", description = "ship", start_date = "2026-11-02", due_date = "2026-11-16" }, body(1))

  stub({ json({ id = 5, title = "v3", state = "closed" }) })
  local closed = run(function(cb) gitlab.update_sprint(PCFG, "5", { state = "closed" }, cb) end)
  h.eq({ "PUT", PROJECT .. "/milestones/5", { state_event = "close" } }, { sent[1].method, sent[1].url, body(1) })
  h.eq("closed", closed.state)

  stub({ json(raw(1)), json(raw(2)) })
  run(function(cb) gitlab.move_to_sprint(PCFG, "5", { "#1", "#2" }, cb) end)
  h.eq({ { milestone_id = 5 }, { milestone_id = 5 } }, { body(1), body(2) })
  stub({ json(raw(1)) })
  run(function(cb) gitlab.move_to_backlog(PCFG, { "#1" }, cb) end)
  h.eq({ milestone_id = 0 }, body(1))
end

T["rank: reorder names the neighbour that ends up before / after"] = function()
  -- #1 and #2 right after #9: #9 before #1, then #1 before #2
  stub({ json(raw(9)), json({}), json(raw(1)), json({}) })
  run(function(cb) gitlab.rank(PCFG, { "#1", "#2" }, { after = "#9" }, cb) end)
  h.eq({ "PUT", PROJECT .. "/issues/1/reorder", { move_before_id = 1009 } }, { sent[2].method, sent[2].url, body(2) })
  h.eq({ PROJECT .. "/issues/2/reorder", { move_before_id = 1001 } }, { sent[4].url, body(4) })
  -- #1 right before #9: #9 after #1
  stub({ json(raw(9)), json({}) })
  run(function(cb) gitlab.rank(PCFG, { "#1" }, { before = "#9" }, cb) end)
  h.eq({ move_after_id = 1009 }, body(2))
end

T["capabilities follow the licence; the probe reads it off an issue"] = function()
  local free = gitlab.capabilities(PCFG)
  h.eq({ nil, true, true, true, true }, { free.story_points, free.sprints, free.sprint_move, free.sprint_manage, free.boards })
  local premium = gitlab.capabilities(vim.tbl_extend("force", PCFG, { tier = "premium" }))
  -- iterations: shown and filtered, but REST can't move an issue between them
  h.eq({ true, true, nil, nil }, { premium.story_points, premium.sprints, premium.sprint_move, premium.sprint_manage })
  local milestones = gitlab.capabilities(vim.tbl_extend("force", PCFG, { tier = "premium", sprints = "milestone" }))
  h.eq({ true, true }, { milestones.sprint_move, milestones.sprint_manage })
  h.eq(nil, gitlab.capabilities(vim.tbl_extend("force", PCFG, { sprints = false })).sprints)
  h.eq(nil, gitlab.capabilities(PCFG).archive)

  local auto = vim.tbl_extend("force", PCFG, { tier = "auto" })
  stub({ { status = 200, body = '[{"id":1,"iid":1,"weight":null}]' } })
  h.eq(nil, gitlab.capabilities(auto).story_points) -- before the probe: Free
  run(function(cb) gitlab.prepare(auto, cb) end)
  h.eq({ per_page = 1, state = "all" }, sent[1].query)
  h.eq(true, gitlab.capabilities(auto).story_points)
  -- no weight in an issue: Free; nothing asked twice
  stub({ { status = 200, body = '[{"id":1,"iid":1}]' } })
  run(function(cb) gitlab.prepare(auto, cb) end)
  run(function(cb) gitlab.prepare(auto, cb) end)
  h.eq(1, #sent)
  h.eq(nil, gitlab.capabilities(auto).story_points)
  -- a project without issues: only Premium has iterations
  stub({ json({}), json({}) })
  run(function(cb) gitlab.prepare(auto, cb) end)
  h.eq(PROJECT .. "/iterations", sent[2].url)
  h.eq(true, gitlab.capabilities(auto).story_points)
  cache.clear("gitlab:")
end

T["detect: the remote's host is the instance's, its path the project"] = function()
  h.eq({ project = "group/sub/app" }, gitlab.detect(PCFG, { root = "/r", host = "gitlab.example", path = "group/sub/app" }))
  h.eq(nil, gitlab.detect(PCFG, { root = "/r", host = "github.com", path = "owner/repo" }))
  h.eq(nil, gitlab.detect(PCFG, { root = "/r" }))
  h.eq({ project = "g/p" }, gitlab.detect(vim.tbl_extend("force", PCFG, { hosts = { "Git-Corp" } }), { root = "/r", host = "git-corp", path = "g/p" }))
  h.eq({ project = "g/p" }, gitlab.detect(vim.tbl_extend("force", PCFG, { base_url = "https://host.example/gitlab" }),
    { root = "/r", host = "host.example", path = "gitlab/g/p" }))
end

T["ui: the list and the issue view show GitLab's issues; keys it can't serve aren't mapped"] = function()
  local window = require("tracker.ui.window")
  local tracker = require("tracker")
  local messages = {}
  local function text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end
  local function wait_for(pred, what)
    if not vim.wait(3000, pred, 10) then error("timed out waiting for " .. what .. "\n" .. vim.inspect(messages) .. "\n" .. text(), 2) end
  end
  local function has_map(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      -- by key code: `<` is listed as `<lt>`
      if vim.keycode(m.lhs) == vim.keycode(lhs) then return m end
    end
  end
  window.close_all()
  cache.clear("gitlab:")
  tracker.setup({ providers = { gitlab = { base_url = "https://gitlab.example", token = "t", project = "group/app", tier = "free" } } })
  require("tracker.notify").set_sink(function(m) table.insert(messages, m) end)
  -- answers by address: the views ask in whatever order they like
  http.request = function(opts, cb)
    local url, res = opts.url, "{}"
    if url:find("/boards", 1, true) then
      res = BOARD.body
    elseif url:match("/issues/12/links$") then
      res = "[]"
    elseif url:match("/issues/12/notes$") then
      res = vim.json.encode({ { id = 1, body = "a comment", author = { id = 1, name = "Jan Kowalski" }, created_at = "2026-10-16T09:00:00.000Z" } })
    elseif url:match("/issues/12$") then
      res = vim.json.encode(raw(12, { labels = { "Doing" }, description = "The **description**" }))
    elseif url:match("/issues$") then
      local closed = opts.query and opts.query.state == "closed"
      res = vim.json.encode(closed and { raw(14, { state = "closed" }) } or { raw(12, { labels = { "Doing" } }), raw(13) })
    elseif url:match("/milestones$") then
      -- over long ago and not started yet: the board has no active sprint to narrow it to
      res = vim.json.encode({
        { id = 3, title = "v1.2", state = "closed", start_date = "2026-10-05", due_date = "2026-10-19", description = "ship it" },
        { id = 4, title = "v2.0", state = "active", start_date = "2999-01-01", due_date = "2999-01-15" },
      })
    elseif url:match("/user$") then
      res = vim.json.encode({ id = 1, name = "Jan Kowalski", username = "jan" })
    end
    vim.schedule(function() cb({ ok = true, status = 200, body = res, headers = {} }) end)
  end
  local ok, err = pcall(function()
    tracker.search("open")
    wait_for(function() return text():find("#12", 1, true) and text():find("Issue 13", 1, true) end, "the list")
    h.truthy(text():find("Doing", 1, true), "the board list as the status")
    h.truthy(has_map("c") and has_map("s") and has_map("a") and has_map("p"), "comment, status, assign, rank")
    h.eq(nil, has_map("d"), "no archive on GitLab")
    h.eq(nil, has_map("S"), "no weights on Free")
    for lnum, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find("#12", 1, true) then vim.api.nvim_win_set_cursor(0, { lnum, 0 }) end
    end
    has_map("<CR>").callback()
    wait_for(function() return vim.bo.filetype == "tracker_issue" and text():find("a comment", 1, true) end, "the issue")
    h.truthy(text():find("The **description**", 1, true), "the description as GitLab wrote it")
    h.truthy(vim.inspect(vim.api.nvim_win_get_config(0).title):find("#12", 1, true), "the key in the title")
    h.eq(nil, has_map("S"), "no sub-tasks through REST")

    -- the board: its lists as columns, each card under its own
    tracker.board()
    wait_for(function() return vim.bo.filetype == "tracker_board" and text():find("#14", 1, true) end, "the board")
    local head
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find("DOING", 1, true) then head = l end
    end
    h.truthy(head, "column headers:\n" .. text())
    local open, doing, review, closed = head:find("OPEN", 1, true), head:find("DOING", 1, true), head:find("REVIEW", 1, true), head:find("CLOSED", 1, true)
    h.truthy(open and doing and review and closed and open < doing and doing < review and review < closed, head)
    local function column_of(key)
      for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        local at = l:find(key, 1, true)
        if at then return at end
      end
    end
    h.truthy(column_of("#13") < doing, "#13 is open")
    h.truthy(column_of("#12") >= doing and column_of("#12") < review, "#12 is in Doing")
    h.truthy(column_of("#14") >= closed, "#14 is closed")
    h.truthy(has_map("<") and has_map(">") and has_map("B"), "move between lists, backlog")

    -- sprints: milestones, with their date-only dates
    tracker.sprints()
    wait_for(function() return vim.bo.filetype == "tracker_sprints" and text():find("v2.0", 1, true) end, "the sprints")
    -- date-only dates read as dates; the closed milestone sits in the folded group
    h.truthy(text():find("2999-01-01 → 2999-01-15", 1, true), text())
    h.truthy(text():find("Closed  1", 1, true), text())
    h.truthy(has_map("n") and has_map("e"), "milestones can be created and edited")
    h.eq({}, vim.tbl_filter(function(m) return m:find("tracker:", 1, true) or m:find("gitlab:", 1, true) end, messages))
  end)
  http.request = real_request
  window.close_all()
  cache.clear("gitlab:")
  tracker.setup({})
  if not ok then error(err, 0) end
end

T["http: a list in the query repeats its key"] = function()
  h.eq("?iids%5B%5D=1&iids%5B%5D=2&state=opened", http._build_query_string({ ["iids[]"] = { "1", "2" }, state = "opened" }))
  h.eq("", http._build_query_string({}))
end

return T
