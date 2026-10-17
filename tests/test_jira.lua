-- Jira provider against a stubbed transport: checks the requests it builds
-- (method, path, query, JSON body) and how it reads Jira's responses.

local h = require("helpers")
local http = require("tracker.http.client")
local jira = require("tracker.providers.jira")

local PCFG = {
  base_url = "https://example.atlassian.net/", login = "me@x.pl", token = "tok",
  fields = { story_points = "customfield_10016", epic_color = "customfield_10013",
             start_date = "customfield_10015", sprint = "customfield_10020" },
}

local real_request = http.request
local sent, responses

---Queue responses; every http.request pops the next one.
local function stub(list)
  sent, responses = {}, list
  http.request = function(opts, cb)
    table.insert(sent, opts)
    local r = table.remove(responses, 1) or { status = 200, body = "{}" }
    vim.schedule(function()
      local ok = r.status >= 200 and r.status < 300
      cb({ ok = ok, status = r.status, body = r.body, headers = {}, err = not ok and http.describe_error(r.status) or nil })
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
  assert(done, "callback never ran")
  return vim.F.unpack_len(res)
end

local function body(i) return vim.json.decode(sent[i].body) end

local T = {}

T["search pages by nextPageToken and asks for list fields"] = function()
  local issue = vim.json.encode(h.fixture("issue.json"))
  stub({
    { status = 200, body = '{"issues":[' .. issue .. '],"nextPageToken":"p2","isLast":false}' },
    { status = 200, body = '{"issues":[' .. issue .. '],"isLast":true}' },
  })
  local issues, err, meta = run(function(cb) jira.search(PCFG, "project = ABC", { limit = 10 }, cb) end)
  h.eq(nil, err)
  h.eq(2, #issues)
  h.eq(false, meta.truncated)
  h.eq("POST", sent[1].method)
  h.eq("https://example.atlassian.net/rest/api/3/search/jql", sent[1].url)
  h.eq("project = ABC", body(1).jql)
  h.eq(nil, body(1).nextPageToken)
  h.eq("p2", body(2).nextPageToken)
  h.truthy(vim.tbl_contains(body(1).fields, "customfield_10016"))
  h.eq("Basic " .. vim.base64.encode("me@x.pl:tok"), sent[1].headers.Authorization)
end

T["search stops at limit and reports truncation"] = function()
  local issue = vim.json.encode(h.fixture("issue.json"))
  stub({ { status = 200, body = '{"issues":[' .. issue .. "," .. issue .. '],"nextPageToken":"p2"}' } })
  local issues, _, meta = run(function(cb) jira.search(PCFG, "x", { limit = 2 }, cb) end)
  h.eq(2, #issues)
  h.eq(true, meta.truncated)
  h.eq(1, #sent)
end

T["get_issue maps description from ADF"] = function()
  stub({ { status = 200, body = vim.json.encode(h.fixture("issue.json")) } })
  local issue = run(function(cb) jira.get_issue(PCFG, "ABC-12", cb) end)
  h.eq("GET", sent[1].method)
  h.eq("https://example.atlassian.net/rest/api/3/issue/ABC-12", sent[1].url)
  h.truthy(sent[1].query.fields:find("description", 1, true))
  h.truthy(issue.description:find("- [x] analiza", 1, true))
end

T["description edit puts stashed media back"] = function()
  local raw = h.fixture("issue.json")
  local media = { type = "mediaSingle", content = { { type = "media", attrs = { id = "m1", type = "file", collection = "", alt = "a.png" } } } }
  raw.key = "ABC-77"
  raw.fields.description = { type = "doc", version = 1, content = { { type = "paragraph", content = { { type = "text", text = "see" } } }, media } }
  stub({ { status = 200, body = vim.json.encode(raw) }, { status = 204, body = "" } })
  local issue = run(function(cb) jira.get_issue(PCFG, "ABC-77", cb) end)
  h.eq("see\n\n[attachment: a.png](adf:1)", issue.description)
  h.eq({}, issue.lossy)
  run(function(cb) jira.update_issue(PCFG, "ABC-77", { description = "seen\n\n[attachment: a.png](adf:1)" }, cb) end)
  local sent_doc = body(2).fields.description
  h.eq("seen", sent_doc.content[1].content[1].text)
  h.eq(media, sent_doc.content[2])
end

T["errors carry Jira's errorMessages and field errors"] = function()
  stub({ { status = 400, body = '{"errorMessages":["Bad JQL"],"errors":{"summary":"required"}}' } })
  local res, err = run(function(cb) jira.get_issue(PCFG, "ABC-1", cb) end)
  h.eq(nil, res)
  h.truthy(err:find("Bad JQL", 1, true), err)
  h.truthy(err:find("summary: required", 1, true), err)
end

T["unassign sends JSON null"] = function()
  stub({ { status = 204, body = "" } })
  local ok = run(function(cb) jira.assign(PCFG, "ABC-1", nil, cb) end)
  h.eq(true, ok)
  h.eq("PUT", sent[1].method)
  h.truthy(sent[1].body:find('"accountId":null', 1, true), sent[1].body)
end

T["assignable users: one big page, people only, sorted"] = function()
  stub({ { status = 200, body = vim.json.encode({
    { accountId = "1", displayName = "Zenon", accountType = "atlassian", active = true },
    { accountId = "2", displayName = "JiraGitLab", accountType = "app", active = true },
    { accountId = "3", displayName = "adam", accountType = "atlassian", active = true },
    { accountId = "4", displayName = "Gone", accountType = "atlassian", active = false },
  }) } })
  local users = run(function(cb) jira.assignable_users(PCFG, "ABC-1", nil, cb) end)
  h.eq(1000, sent[1].query.maxResults)
  h.eq({ "adam", "Zenon" }, vim.tbl_map(function(u) return u.name end, users))
end

T["attachment download goes to the content endpoint"] = function()
  local real_download = http.download
  local got
  http.download = function(opts, path, cb) got = { opts = opts, path = path } vim.schedule(function() cb(path) end) end
  local p = run(function(cb) jira.download_attachment(PCFG, { id = "10500", filename = "a.png" }, "/tmp/x.png", cb) end)
  h.eq("/tmp/x.png", p)
  h.eq("https://example.atlassian.net/rest/api/3/attachment/content/10500", got.opts.url)
  h.truthy(got.opts.headers.Authorization:find("^Basic "))
  run(function(cb) jira.download_attachment(PCFG, { url = "https://img.example/x.png" }, "/tmp/y.png", cb) end)
  h.eq("https://img.example/x.png", got.opts.url)
  h.eq(nil, got.opts.headers) -- external media never gets the token
  http.download = real_download
end

T["fields: board estimation wins, epic colour found by schema"] = function()
  require("tracker.state").clear()
  stub({
    { status = 200, body = vim.json.encode({ estimation = { type = "field", field = { fieldId = "customfield_10030" } } }) },
    { status = 200, body = vim.json.encode({
      { id = "customfield_10016", name = "Story point estimate", schema = {} },
      { id = "customfield_10013", name = "Epic Color", schema = { custom = "com.pyxis.greenhopper.jira:gh-epic-color" } },
      { id = "customfield_10015", name = "Data rozpoczęcia", untranslatedName = "Start date", schema = { type = "date" } },
      { id = "customfield_10020", name = "Sprint", schema = { custom = "com.pyxis.greenhopper.jira:gh-sprint" } },
    }) },
  })
  local f = run(function(cb) jira.fields({ base_url = "https://example.atlassian.net", login = "a", token = "t", board = 7 }, cb) end)
  h.eq({ story_points = "customfield_10030", epic_color = "customfield_10013",
         start_date = "customfield_10015", sprint = "customfield_10020" }, f)
  -- no board: by name
  require("tracker.state").clear()
  stub({ { status = 200, body = vim.json.encode({ { id = "customfield_10016", name = "Story point estimate" } }) } })
  f = run(function(cb) jira.fields({ base_url = "https://example.atlassian.net", login = "a", token = "t" }, cb) end)
  h.eq("customfield_10016", f.story_points)
end

T["epics: one search, colour index from the Epic Color field"] = function()
  require("tracker.state").clear()
  stub({ { status = 200, body = vim.json.encode({ issues = {
    { key = "ABC-1", fields = { summary = "Stability", customfield_10013 = "ghx-label-8" } },
  } }) } })
  local epics = run(function(cb) jira.epics(PCFG, { "ABC-1" }, cb) end)
  h.eq({ key = "ABC-1", summary = "Stability", color = 8 }, epics["ABC-1"])
  h.eq("key in (ABC-1)", body(1).jql)
  -- cached: no second request
  stub({})
  run(function(cb) jira.epics(PCFG, { "ABC-1" }, cb) end)
  h.eq(0, #sent)
end

T["planning: rank, sprint / backlog moves, archive, delete requests"] = function()
  stub({ { status = 204, body = "" } })
  h.eq(true, run(function(cb) jira.rank(PCFG, { "ABC-2", "ABC-3" }, { after = "ABC-9" }, cb) end))
  h.eq("PUT", sent[1].method)
  h.truthy(sent[1].url:find("/rest/agile/1.0/issue/rank$"), sent[1].url)
  h.eq({ issues = { "ABC-2", "ABC-3" }, rankAfterIssue = "ABC-9" }, body(1))

  -- 207: a partial failure is an error, with the issue named
  stub({ { status = 207, body = vim.json.encode({ entries = {
    { issueKey = "ABC-2", status = 200 }, { issueKey = "ABC-3", status = 400, errors = { "cannot rank" } },
  } }) } })
  local ok, err = run(function(cb) jira.rank(PCFG, { "ABC-2", "ABC-3" }, { before = "ABC-1" }, cb) end)
  h.eq(nil, ok)
  h.truthy(err:find("ABC-3: cannot rank", 1, true), err)
  h.eq("ABC-1", body(1).rankBeforeIssue)

  stub({ { status = 204, body = "" }, { status = 204, body = "" } })
  run(function(cb) jira.move_to_sprint(PCFG, "55", { "ABC-1" }, cb) end)
  run(function(cb) jira.move_to_backlog(PCFG, { "ABC-2" }, cb) end)
  h.truthy(sent[1].url:find("/rest/agile/1.0/sprint/55/issue$"), sent[1].url)
  h.eq({ issues = { "ABC-1" } }, body(1))
  h.truthy(sent[2].url:find("/rest/agile/1.0/backlog/issue$"), sent[2].url)

  stub({ { status = 200, body = vim.json.encode({ numberOfIssuesUpdated = 1 }) } })
  run(function(cb) jira.archive(PCFG, { "ABC-1" }, cb) end)
  h.eq("PUT", sent[1].method)
  h.eq({ issueIdsOrKeys = { "ABC-1" } }, body(1))

  stub({ { status = 204, body = "" } })
  run(function(cb) jira.delete_issue(PCFG, "ABC-1", true, cb) end)
  h.eq("DELETE", sent[1].method)
  h.eq({ deleteSubtasks = "true" }, sent[1].query)
end

T["transition posts the id"] = function()
  stub({ { status = 204, body = "" } })
  run(function(cb) jira.transition(PCFG, "ABC-1", 31, cb) end)
  h.eq({ transition = { id = "31" } }, body(1))
end

T["comment body is ADF"] = function()
  stub({ { status = 201, body = '{"id":"9","body":{"type":"doc","version":1,"content":[]},"author":{"accountId":"a","displayName":"A"}}' } })
  local c = run(function(cb) jira.add_comment(PCFG, "ABC-1", "**hi**", cb) end)
  h.eq("9", c.id)
  local b = body(1).body
  h.eq("doc", b.type)
  h.eq({ { type = "strong" } }, b.content[1].content[1].marks)
end

T["update clears an emptied description with null"] = function()
  stub({ { status = 204, body = "" } })
  run(function(cb) jira.update_issue(PCFG, "ABC-1", { summary = "S", description = "  " }, cb) end)
  h.truthy(sent[1].body:find('"description":null', 1, true), sent[1].body)
  h.eq("S", body(1).fields.summary)
end

T["create sends project, type, parent"] = function()
  stub({ { status = 201, body = '{"id":"100","key":"ABC-100"}' } })
  local res = run(function(cb)
    jira.create_issue(PCFG, { project = "ABC", type_id = "10003", summary = "Sub", parent = "ABC-12" }, cb)
  end)
  h.eq("ABC-100", res.key)
  h.eq("https://example.atlassian.net/browse/ABC-100", res.url)
  h.eq({ project = { key = "ABC" }, issuetype = { id = "10003" }, summary = "Sub", parent = { key = "ABC-12" } }, body(1).fields)
end

T["board columns keep only mapped statuses"] = function()
  require("tracker.state").clear()
  stub({ { status = 200, body = vim.json.encode({ columnConfig = { columns = {
    { name = "Backlog", statuses = {} },
    { name = "To Do", statuses = { { id = "1" }, { id = 10001 } } },
    { name = "Done", statuses = { { id = "3" } } },
  } } }) } })
  local cols = run(function(cb) jira.board_columns(PCFG, "7", cb) end)
  h.eq({ { name = "To Do", statuses = { "1", "10001" } }, { name = "Done", statuses = { "3" } } }, cols)
end

T["agile collect pages by startAt"] = function()
  local issue = h.fixture("issue.json")
  stub({
    { status = 200, body = vim.json.encode({ startAt = 0, total = 2, issues = { issue } }) },
    { status = 200, body = vim.json.encode({ startAt = 1, total = 2, issues = { issue } }) },
  })
  local issues = run(function(cb) jira.board_issues(PCFG, "7", "55", cb) end)
  h.eq(2, #issues)
  h.eq("https://example.atlassian.net/rest/agile/1.0/board/7/sprint/55/issue", sent[1].url)
  h.eq(0, sent[1].query.startAt)
  h.eq(1, sent[2].query.startAt)
end

T["zz restore transport"] = function()
  http.request = real_request
end


T["mapper: due date, Start date and sprints"] = function()
  local mapper = require("tracker.providers.jira.mapper")
  local i = mapper.issue({ id = "1", key = "ABC-1", fields = {
    summary = "x", duedate = "2026-10-31", customfield_10015 = "2026-10-01",
    customfield_10020 = { { id = 60, name = "#60", state = "active", startDate = "2026-10-13T06:00:00.000Z",
                            endDate = "2026-11-02T12:00:00.000Z", originBoardId = 7 } },
  } }, PCFG)
  h.eq({ "2026-10-01", "2026-10-31" }, { i.start_date, i.due_date })
  h.eq({ id = "60", name = "#60", state = "active", start_date = "2026-10-13T06:00:00.000Z",
         end_date = "2026-11-02T12:00:00.000Z", board_id = "7" }, i.sprints[1])
end


T["delete_comment: DELETE on the comment"] = function()
  stub({ { status = 204, body = "" } })
  local ok = run(function(cb) jira.delete_comment(PCFG, "ABC-1", "77", cb) end)
  h.eq(true, ok)
  h.eq("DELETE", sent[1].method)
  h.eq("https://example.atlassian.net/rest/api/3/issue/ABC-1/comment/77", sent[1].url)
end

T["clone: fields and ADF verbatim, a clones link, refused fields dropped, sub-tasks under the clone"] = function()
  local adf_doc = { type = "doc", version = 1, content = { { type = "panel", attrs = { panelType = "info" },
    content = { { type = "paragraph", content = { { type = "text", text = "kept as is" } } } } } } }
  local raw = { id = "10", key = "ABC-1", fields = {
    summary = "Orig", issuetype = { id = "3" }, project = { id = "100" }, description = adf_doc,
    priority = { id = "2" }, labels = { "x" }, parent = { key = "ABC-E" }, reporter = { accountId = "u9" },
    duedate = "2026-10-31", customfield_10016 = 5, customfield_10015 = "2026-10-01",
    subtasks = { { key = "ABC-2" } },
  } }
  local sub = { id = "11", key = "ABC-2", fields = {
    summary = "Sub", issuetype = { id = "5" }, project = { id = "100" }, parent = { key = "ABC-1" }, labels = {},
  } }
  stub({
    { status = 200, body = vim.json.encode(raw) },
    -- the start date isn't on the create screen: dropped, retried
    { status = 400, body = vim.json.encode({ errors = { customfield_10015 = "Field 'customfield_10015' cannot be set." } }) },
    { status = 201, body = vim.json.encode({ id = "20", key = "ABC-20" }) },
    { status = 200, body = vim.json.encode(sub) },
    { status = 201, body = vim.json.encode({ id = "21", key = "ABC-21" }) },
  })
  local res, err = run(function(cb) jira.clone_issue(PCFG, "ABC-1", { summary = "CLONE - Orig", link = true, subtasks = true }, cb) end)
  h.eq(nil, err)
  h.eq("ABC-20", res.key)
  h.eq({ "ABC-21" }, res.subtasks)
  h.eq({ "customfield_10015" }, res.dropped)
  local first = body(2)
  h.eq("CLONE - Orig", first.fields.summary)
  h.eq(adf_doc, first.fields.description)
  h.eq({ id = "3" }, first.fields.issuetype)
  h.eq({ key = "ABC-E" }, first.fields.parent)
  h.eq({ accountId = "u9" }, first.fields.reporter)
  h.eq(5, first.fields.customfield_10016)
  h.eq({ { add = { type = { name = "Cloners" }, outwardIssue = { key = "ABC-1" } } } }, first.update.issuelinks)
  h.eq(nil, body(3).fields.customfield_10015)
  h.eq("2026-10-31", body(3).fields.duedate)
  -- the sub-task: own summary, under the clone, no link
  local s = body(5)
  h.eq("Sub", s.fields.summary)
  h.eq({ key = "ABC-20" }, s.fields.parent)
  h.eq(nil, s.update)
end

T["clone: an error that isn't about a field we sent fails"] = function()
  stub({
    { status = 200, body = vim.json.encode({ key = "ABC-1", fields = { summary = "O", issuetype = { id = "3" }, project = { id = "1" } } }) },
    { status = 400, body = vim.json.encode({ errorMessages = { "You do not have permission to create issues in this project." } }) },
  })
  local res, err = run(function(cb) jira.clone_issue(PCFG, "ABC-1", { summary = "C" }, cb) end)
  h.eq(nil, res)
  h.truthy(err:find("permission", 1, true), err)
end

return T
