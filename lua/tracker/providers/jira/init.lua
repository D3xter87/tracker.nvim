-- Jira Cloud provider: REST API v3 + Agile API 1.0.
--
-- Endpoints worth knowing (they moved recently):
--   search      POST /rest/api/3/search/jql       paged by nextPageToken; the
--                                                 old /search is gone
--   createmeta  GET  /rest/api/3/issue/createmeta/{project}/issuetypes
--   users       by accountId only (GDPR); assignee search via
--               /user/assignable/search?issueKey=
-- Rich text (description, comments) is ADF — see adf.lua.

local client = require("tracker.providers.jira.client")
local mapper = require("tracker.providers.jira.mapper")
local adf = require("tracker.providers.jira.adf")
local cache = require("tracker.state")

local M = { name = "jira" }

M.capabilities = {
  comments = true, edit_comments = true, transitions = true, assign = true,
  edit = true, create = true, subtasks = true, boards = true, sprints = true,
  backlog = true, attachments = true, epics = true, children = true,
  priority = true, story_points = true, labels = true, epic_link = true, reporter = true,
  rank = true, sprint_move = true, sprint_manage = true, archive = true, delete = true, dates = true, timeline = true,
  delete_comments = true, clone = true, links = true, upload = true, remote_links = true,
}

M.defaults = {
  base_url = nil,      -- "https://<site>.atlassian.net"
  login = nil,         -- account e-mail; default: netrc `login`
  token = nil,         -- default: netrc `password` / $TRACKER_JIRA_TOKEN
  netrc_machine = nil, -- default: the base_url host
  auth = "basic",      -- "basic" (Cloud: e-mail + API token) | "bearer"
  project = nil,       -- default project key: {project} in JQL, create, board
  projects = nil,      -- project keys recognised in branch names (default: any)
  board = nil,         -- board id for :board(); default: pick from the project
  -- Name of a saved query or raw JQL for the default list (no key in the
  -- branch); nil = the first of `queries`.
  default_query = nil,
  -- Several boards, by name: { project (default: the name), board (id),
  -- tags (issue-key prefixes in branch names; default: { project }),
  -- queries (replace the ones below), default_query }. See tracker.boards.
  boards = nil,        -- e.g. { CVNT = { board = 142 }, EP = { board = 147 } }
  -- Boards a git repository uses, main one first: a directory name or a path
  -- (with a slash) → board names (+ default_query). There the branch's key
  -- must belong to one of them, and the views use the main one.
  repos = nil,         -- e.g. { panel = { "CVNT", "EP" } }
  -- Site-specific custom fields. Detected when nil: story points = the
  -- board's estimation field (with `board`), else a field named "Story
  -- Points" / "Story point estimate"; epic colour = the "Epic Color" field;
  -- start date = the timeline's "Start date" (any UI language); sprint = the
  -- "Sprint" field.
  fields = {
    story_points = nil, -- e.g. "customfield_10016"
    epic_color = nil,   -- e.g. "customfield_10013"
    start_date = nil,   -- e.g. "customfield_10015"
    sprint = nil,       -- e.g. "customfield_10020"
  },
  -- Saved searches. `{project}` expands to `project`. The first entry is the
  -- default list view. Instead of `jql`, `sprint = true` / `backlog = true`
  -- list the active sprint / backlog of `board` exactly as Jira's board shows
  -- them: the same issues (the board's filter applies) in the same order
  -- (rank). A JQL like `sprint in openSprints()` can't do that.
  -- `sprints = true` / `backlogs = true` do the same for every board of the
  -- repository (see tracker.boards), one section per sprint / board, and
  -- `sections = { "mine", "sprints" }` lists saved queries one after another.
  queries = {
    -- children = true: also list every child of a listed issue (sub-tasks of
    -- your stories, issues of your epics) whoever they are assigned to.
    -- statusCategory, not resolution: many workflows close issues without
    -- setting Resolution, so `resolution = Unresolved` keeps finished ones.
    { name = "mine", jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC", children = true },
    { name = "sprint", sprint = true },
    { name = "backlog", backlog = true },
  },
}

local API = "/rest/api/3"
local AGILE = "/rest/agile/1.0"

local LIST_FIELDS = {
  "summary", "status", "issuetype", "priority", "assignee", "updated", "parent", "labels", "subtasks",
  "duedate", "issuelinks",
}
local DETAIL_FIELDS = {
  "summary", "status", "issuetype", "priority", "assignee", "reporter", "labels",
  "created", "updated", "parent", "subtasks", "description", "attachment", "duedate", "issuelinks",
}

local function enc(s) return require("tracker.http.client").uri_encode(s) end

local function fail(cb, err) cb(nil, err) end

---@param md string|nil
---@return table|userdata ADF doc, or JSON null for an empty text
---@param stash table[]|nil  nodes stashed when the text was read
local function doc_or_null(md, stash)
  if not md or vim.trim(md) == "" then return vim.NIL end
  return adf.from_markdown(md, stash)
end

local function stash_of(pcfg, key, what)
  return cache.get(mapper.stash_key(pcfg, key, what))
end

-- region Custom fields

local FIELDS_TTL = 24 * 60 * 60 * 1000
local SP_NAMES = { ["story points"] = 1, ["story point estimate"] = 2 } -- lower = preferred

---Resolve the site's custom field ids once a day: story points, epic
---colour, start date and sprint (see M.defaults.fields). Never fails: an
---unknown field is nil.
---@param cb fun(fields: { story_points: string?, epic_color: string?, start_date: string?, sprint: string? })
function M.fields(pcfg, cb)
  local f = pcfg.fields or {}
  local ck = ("jira:fields:%s:%s"):format(client.base_url(pcfg), tostring(pcfg.board))
  local hit = cache.get(ck)
  if hit then
    vim.schedule(function() cb(hit) end)
    return
  end
  local result = { story_points = f.story_points, epic_color = f.epic_color, start_date = f.start_date, sprint = f.sprint }
  if result.story_points and result.epic_color and result.start_date and result.sprint then -- all configured
    vim.schedule(function() cb(result) end)
    return
  end
  local by_name, by_name_rank
  local pending = 1
  local function finish()
    pending = pending - 1
    if pending > 0 then return end
    result.story_points = result.story_points or by_name
    cache.set(ck, result, FIELDS_TTL)
    cb(result)
  end
  if pcfg.board and not result.story_points then
    pending = pending + 1
    client.request(pcfg, "GET", AGILE .. "/board/" .. enc(tostring(pcfg.board)) .. "/configuration", nil, function(data)
      local est = data and data.estimation
      if est and est.type == "field" and est.field then result.story_points = est.field.fieldId end
      finish()
    end)
  end
  client.request(pcfg, "GET", API .. "/field", nil, function(data)
    for _, fd in ipairs(data or {}) do
      local custom = fd.schema and fd.schema.custom or ""
      if not result.epic_color and custom == "com.pyxis.greenhopper.jira:gh-epic-color" then
        result.epic_color = fd.id
      end
      if not result.sprint and custom == "com.pyxis.greenhopper.jira:gh-sprint" then result.sprint = fd.id end
      -- the timeline's "Start date" (localized name, e.g. "Data rozpoczęcia")
      if not result.start_date and fd.untranslatedName == "Start date" and fd.schema and fd.schema.type == "date" then
        result.start_date = fd.id
      end
      local rank = SP_NAMES[(fd.name or ""):lower()]
      if rank and (not by_name_rank or rank < by_name_rank) then by_name, by_name_rank = fd.id, rank end
    end
    finish()
  end)
end

---Run `fn` with a copy of pcfg whose `fields` are resolved.
local function with_fields(pcfg, fn)
  M.fields(pcfg, function(f)
    fn(vim.tbl_deep_extend("force", pcfg, { fields = f }))
  end)
end

---`fields` plus the site's custom fields an issue maps (story points,
---start date, sprint).
local function with_story_points(pcfg, fields)
  local out = vim.deepcopy(fields)
  local cf = pcfg.fields or {}
  for _, id in pairs({ cf.story_points, cf.start_date, cf.sprint }) do -- pairs: any of them may be nil
    if id then table.insert(out, id) end
  end
  return out
end

-- endregion

-- region Epics

local EPIC_TTL = 30 * 60 * 1000

---"ghx-label-8" / "color_8" → 8
local function color_index(v)
  if type(v) == "table" then v = v.key or v.value end
  return type(v) == "string" and tonumber(v:match("(%d+)$")) or nil
end

---Epics by key with their colour: { [key] = { key, summary, color = 1..14 } }.
---One search for the uncached ones; sites without an "Epic Color" field
---(team-managed) ask the Agile epic endpoint per epic instead.
---@param keys string[]
---@param cb fun(epics: table<string, TrackerEpic>|nil, err: string|nil)
function M.epics(pcfg, keys, cb)
  with_fields(pcfg, function(p)
    local out, missing = {}, {}
    local base = client.base_url(p)
    for _, k in ipairs(keys) do
      local hit = cache.get("jira:epic:" .. base .. ":" .. k)
      if hit then out[k] = hit else table.insert(missing, k) end
    end
    if #missing == 0 then
      vim.schedule(function() cb(out) end)
      return
    end
    local function store(e)
      cache.set("jira:epic:" .. base .. ":" .. e.key, e, EPIC_TTL)
      out[e.key] = e
    end
    local fields = { "summary" }
    if p.fields.epic_color then table.insert(fields, p.fields.epic_color) end
    local body = { jql = "key in (" .. table.concat(vim.list_slice(missing, 1, 100), ",") .. ")", fields = fields, maxResults = 100 }
    client.request(p, "POST", API .. "/search/jql", { body = body }, function(data, err)
      if not data then return cb(out, err) end
      local need_agile = {}
      for _, raw in ipairs(data.issues or {}) do
        local e = { key = raw.key, summary = raw.fields.summary or "",
                    color = p.fields.epic_color and color_index(raw.fields[p.fields.epic_color]) or nil }
        store(e)
        if not e.color then table.insert(need_agile, e) end
      end
      if #need_agile == 0 then return cb(out) end
      local pending = #need_agile
      for _, e in ipairs(need_agile) do
        client.request(p, "GET", AGILE .. "/epic/" .. enc(e.key), nil, function(ep)
          if ep then e.color = color_index(ep.color) end
          pending = pending - 1
          if pending == 0 then cb(out) end
        end)
      end
    end)
  end)
end

-- endregion

function M.web_url(pcfg, key)
  return client.base_url(pcfg) .. "/browse/" .. key
end

function M.myself(pcfg, cb)
  local ck = "jira:myself:" .. client.base_url(pcfg)
  local hit = cache.get(ck)
  if hit then
    vim.schedule(function() cb(hit) end)
    return
  end
  client.request(pcfg, "GET", API .. "/myself", nil, function(data, err)
    if not data then return fail(cb, err) end
    local user = mapper.user(data)
    cache.set(ck, user, 30 * 60 * 1000)
    cb(user)
  end)
end

---@param opts { limit: integer? }|nil
function M.search(pcfg0, jql, opts, cb)
  with_fields(pcfg0, function(pcfg) M._search(pcfg, jql, opts, cb) end)
end

function M._search(pcfg, jql, opts, cb)
  local limit = (opts and opts.limit) or 200
  local out = {}
  local function page(token)
    local body = {
      jql = jql,
      fields = with_story_points(pcfg, LIST_FIELDS),
      maxResults = math.min(100, limit - #out),
      nextPageToken = token,
    }
    client.request(pcfg, "POST", API .. "/search/jql", { body = body }, function(data, err)
      if not data then return fail(cb, err) end
      for _, raw in ipairs(data.issues or {}) do
        table.insert(out, mapper.issue(raw, pcfg))
      end
      local more = data.nextPageToken and data.isLast ~= true
      if more and #out < limit then
        page(data.nextPageToken)
      else
        cb(out, nil, { truncated = more and true or false })
      end
    end)
  end
  page(nil)
end

---Issues whose parent is one of `keys` (sub-tasks of stories / tasks,
---children of epics), in rank order. Chunked: JQL `in (...)` lists stay
---short.
---@param keys string[]
---@param cb fun(issues: TrackerIssue[]|nil, err: string|nil)
function M.children(pcfg0, keys, cb)
  with_fields(pcfg0, function(pcfg)
    local out, i = {}, 0
    local function next_chunk()
      local chunk = vim.list_slice(keys, i + 1, i + 50)
      i = i + 50
      if #chunk == 0 then return cb(out) end
      M._search(pcfg, "parent in (" .. table.concat(chunk, ",") .. ") ORDER BY Rank ASC", { limit = 500 },
        function(issues, err)
          if not issues then return cb(nil, err) end
          vim.list_extend(out, issues)
          next_chunk()
        end)
    end
    next_chunk()
  end)
end

function M.get_issue(pcfg0, key, cb)
  with_fields(pcfg0, function(pcfg)
    client.request(pcfg, "GET", API .. "/issue/" .. enc(key),
      { query = { fields = table.concat(with_story_points(pcfg, DETAIL_FIELDS), ",") } },
      function(data, err)
        if not data then return fail(cb, err) end
        local issue = mapper.issue(data, pcfg)
        issue.description = issue.description or ""
        cb(issue)
      end)
  end)
end

function M.get_comments(pcfg, key, cb)
  client.collect(pcfg, API .. "/issue/" .. enc(key) .. "/comment", { orderBy = "created" }, "comments", 500,
    function(items, err)
      if not items then return fail(cb, err) end
      cb(vim.tbl_map(function(c) return mapper.comment(c, pcfg, key) end, items))
    end)
end

function M.add_comment(pcfg, key, markdown, cb)
  M.resolve_uploads(pcfg, key, markdown, nil, function(md, stash, uerr)
    if not md then return fail(cb, uerr) end
    client.request(pcfg, "POST", API .. "/issue/" .. enc(key) .. "/comment",
      { body = { body = adf.from_markdown(md, stash) } },
      function(data, err)
        if not data then return fail(cb, err) end
        cb(mapper.comment(data, pcfg, key))
      end)
  end)
end

function M.edit_comment(pcfg, key, id, markdown, cb)
  local stash = stash_of(pcfg, key, "comment:" .. tostring(id))
  M.resolve_uploads(pcfg, key, markdown, stash, function(md, st, uerr)
    if not md then return fail(cb, uerr) end
    client.request(pcfg, "PUT", API .. "/issue/" .. enc(key) .. "/comment/" .. enc(id),
      { body = { body = adf.from_markdown(md, st) } },
      function(data, err)
        if not data then return fail(cb, err) end
        cb(mapper.comment(data, pcfg, key))
      end)
  end)
end

function M.delete_comment(pcfg, key, id, cb)
  client.request(pcfg, "DELETE", API .. "/issue/" .. enc(key) .. "/comment/" .. enc(id), nil, function(data, err)
    if not data then return fail(cb, err) end
    cb(true)
  end)
end

-- region Uploads

---Upload files to an issue (one multipart request).
---@param paths string[]
---@param cb fun(atts: TrackerAttachment[]|nil, err: string|nil)  in the order of `paths`
function M.upload_attachments(pcfg, key, paths, cb)
  local form = {}
  for _, p in ipairs(paths) do
    -- quoted: curl -F would read ; or , in a path as options
    table.insert(form, { "file", '@"' .. p:gsub('"', '\\"') .. '"' })
  end
  client.request(pcfg, "POST", API .. "/issue/" .. enc(key) .. "/attachments", { form = form, timeout = 300 },
    function(data, err)
      if not data then return fail(cb, err) end
      local by_name = {}
      for _, a in ipairs(data) do by_name[a.filename] = by_name[a.filename] or a end
      local out = {}
      for n, p in ipairs(paths) do
        local a = by_name[vim.fs.basename(p)] or data[n]
        if a then
          table.insert(out, { id = tostring(a.id), filename = a.filename, mime = a.mimeType, size = a.size,
                              created = a.created, author = mapper.user(a.author) })
        end
      end
      cb(out)
    end)
end

function M.delete_attachment(pcfg, id, cb)
  client.request(pcfg, "DELETE", API .. "/attachment/" .. enc(id), nil, function(data, err)
    if not data then return fail(cb, err) end
    cb(true)
  end)
end

---Media file id of an attachment — what an ADF media node points at. Jira
---only tells it through the redirect of the attachment's content.
function M.media_id(pcfg, attachment_id, cb)
  client.location(pcfg, API .. "/attachment/content/" .. enc(attachment_id), function(loc, err)
    local id = loc and loc:match("/file/([%x%-]+)/")
    if not id then return fail(cb, err or ("jira: no media id in " .. tostring(loc))) end
    cb(id)
  end)
end

---Width / height of a PNG (its IHDR chunk); nil for anything else.
local function png_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local head = f:read(24)
  f:close()
  if not head or #head < 24 or head:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
  local function u32(s) return s:byte(1) * 16777216 + s:byte(2) * 65536 + s:byte(3) * 256 + s:byte(4) end
  return u32(head:sub(17, 20)), u32(head:sub(21, 24))
end

-- `![name](upload:<path>)` (an image) / `[attachment: name](upload:<path>)`
-- on a line of its own: a local file the editor put there to be uploaded.
local UPLOAD_LINE = "^%s*(!?)%[[^%]]*%]%(upload:(.-)%)%s*$"

---@return boolean
function M.has_uploads(md)
  for _, l in ipairs(vim.split(md or "", "\n", { plain = true })) do
    if l:match(UPLOAD_LINE) then return true end
  end
  return false
end

---Upload the files a Markdown text points at with `(upload:…)` lines and
---turn each line into a stashed media node — an image inline
---(mediaSingle), another file as a file card (mediaGroup) — like Jira's
---editor does. cb(markdown, stash) ready for adf.from_markdown.
function M.resolve_uploads(pcfg, key, md, stash, cb)
  local lines = vim.split(md or "", "\n", { plain = true })
  local todo = {}
  for n, l in ipairs(lines) do
    local bang, path = l:match(UPLOAD_LINE)
    if path then table.insert(todo, { n = n, path = path, image = bang == "!" }) end
  end
  if #todo == 0 then return vim.schedule(function() cb(md, stash) end) end
  for _, t in ipairs(todo) do
    if not vim.uv.fs_stat(t.path) then
      return vim.schedule(function() cb(nil, nil, "tracker: file not found: " .. t.path) end)
    end
  end
  local out_stash = vim.deepcopy(stash or {})
  M.upload_attachments(pcfg, key, vim.tbl_map(function(t) return t.path end, todo), function(atts, err)
    if not atts then return cb(nil, nil, err) end
    local i = 0
    local function next_one()
      i = i + 1
      local t, att = todo[i], atts[i]
      if not t then return cb(table.concat(lines, "\n"), out_stash) end
      if not att then return cb(nil, nil, "jira: upload of " .. t.path .. " not confirmed") end
      M.media_id(pcfg, att.id, function(uuid, merr)
        if not uuid then return cb(nil, nil, merr) end
        local media = { type = "media", attrs = { type = "file", id = uuid, collection = "", alt = att.filename } }
        local w, h = png_size(t.path)
        if w then media.attrs.width, media.attrs.height = w, h end
        local node = t.image and { type = "mediaSingle", attrs = { layout = "center" }, content = { media } }
          or { type = "mediaGroup", content = { media } }
        table.insert(out_stash, node)
        lines[t.n] = ("[attachment: %s](adf:%d)"):format(att.filename, #out_stash)
        next_one()
      end)
    end
    next_one()
  end)
end

-- endregion

-- region Links

---Link types of the site ({ id, name, inward, outward }), cached for an hour.
function M.link_types(pcfg, cb)
  local ck = "jira:linktypes:" .. client.base_url(pcfg)
  local hit = cache.get(ck)
  if hit then return vim.schedule(function() cb(hit) end) end
  client.request(pcfg, "GET", API .. "/issueLinkType", nil, function(data, err)
    if not data then return fail(cb, err) end
    local out = {}
    for _, t in ipairs(data.issueLinkTypes or {}) do
      table.insert(out, { id = tostring(t.id), name = t.name, inward = t.inward, outward = t.outward })
    end
    cache.set(ck, out, 60 * 60 * 1000)
    cb(out)
  end)
end

---Link `key` to another issue, read from `key`'s side: direction "outward"
---= key <outward> other ("ABC-1 blocks ABC-2"), "inward" = key <inward>
---other ("ABC-1 is blocked by ABC-2"). Done as an edit of `key` — the
---same reading Jira uses when it lists the links of an issue.
---@param link { type: string, direction: "outward"|"inward", key: string }
function M.add_link(pcfg, key, link, cb)
  local side = link.direction == "inward" and "inwardIssue" or "outwardIssue"
  local add = { type = { name = link.type }, [side] = { key = link.key } }
  client.request(pcfg, "PUT", API .. "/issue/" .. enc(key), { body = { update = { issuelinks = { { add = add } } } } },
    function(data, err)
      if not data then return fail(cb, err) end
      cb(true)
    end)
end

function M.delete_link(pcfg, id, cb)
  client.request(pcfg, "DELETE", API .. "/issueLink/" .. enc(id), nil, function(data, err)
    if not data then return fail(cb, err) end
    cb(true)
  end)
end

-- endregion

---Web link (remote link) on an issue: a URL with a title.
---@param link { url: string, title: string }
function M.add_remote_link(pcfg, key, link, cb)
  client.request(pcfg, "POST", API .. "/issue/" .. enc(key) .. "/remotelink",
    { body = { object = { url = link.url, title = link.title } } },
    function(data, err)
      if not data then return fail(cb, err) end
      cb(true)
    end)
end

-- region Clone

local CLONE_FIELDS = {
  "summary", "issuetype", "project", "description", "priority", "labels", "parent", "reporter", "duedate", "subtasks",
}

---Create-request fields copying a raw issue verbatim — the description
---stays ADF, so panels, tables, mentions and images come over unchanged.
local function clone_fields(pcfg, raw)
  local f = raw.fields or {}
  local out = {
    project = f.project and { id = f.project.id } or nil,
    issuetype = f.issuetype and { id = f.issuetype.id } or nil,
    summary = f.summary,
    description = f.description,
    priority = f.priority and { id = f.priority.id } or nil,
    labels = f.labels,
    parent = f.parent and { key = f.parent.key } or nil,
    reporter = f.reporter and { accountId = f.reporter.accountId } or nil,
    duedate = f.duedate,
  }
  local cf = pcfg.fields or {}
  for _, id in pairs({ cf.story_points, cf.start_date }) do
    if f[id] ~= nil then out[id] = f[id] end
  end
  return out
end

---POST /issue. A field Jira refuses (not on the create screen, no such link
---type, …) is dropped and the create retried, until it goes through or the
---error isn't about a field we sent. cb(created, err, dropped field names)
local function create_raw(pcfg, body, cb, dropped)
  dropped = dropped or {}
  client.request(pcfg, "POST", API .. "/issue", { body = body }, function(data, err, _, errbody)
    if data then return cb(data, nil, dropped) end
    local refused = errbody and type(errbody.errors) == "table" and errbody.errors or {}
    local any = false
    for name in pairs(refused) do
      if body.fields[name] ~= nil then
        body.fields[name] = nil
        any = true
        table.insert(dropped, name)
      elseif body.update and body.update[name] ~= nil then
        body.update[name] = nil
        any = true
        table.insert(dropped, name)
      end
    end
    if not any then return cb(nil, err, dropped) end
    create_raw(pcfg, body, cb, dropped)
  end)
end

local function clone_query(pcfg)
  return { fields = table.concat(with_story_points(pcfg, CLONE_FIELDS), ",") }
end

---Clone an issue: same type, description (as is), priority, labels, story
---points, dates, epic / parent and reporter, under `opts.summary`.
---`opts.link` links it "clones" → the original; `opts.subtasks` clones the
---sub-tasks too (under the clone, their own summaries).
---@param opts { summary: string, link: boolean?, subtasks: boolean? }
---@param cb fun(res: { id: string, key: string, url: string, subtasks: string[], dropped: string[], failed: string[] }|nil, err: string|nil)
function M.clone_issue(pcfg0, key, opts, cb)
  with_fields(pcfg0, function(pcfg)
    client.request(pcfg, "GET", API .. "/issue/" .. enc(key), { query = clone_query(pcfg) }, function(raw, err)
      if not raw then return fail(cb, err) end
      local body = { fields = clone_fields(pcfg, raw) }
      body.fields.summary = opts.summary
      if opts.link then
        -- from the new issue: it "clones" (outward) the original
        body.update = { issuelinks = { { add = { type = { name = "Cloners" }, outwardIssue = { key = key } } } } }
      end
      create_raw(pcfg, body, function(created, cerr, dropped)
        if not created then return fail(cb, cerr) end
        local res = { id = tostring(created.id), key = created.key, url = M.web_url(pcfg, created.key),
                      subtasks = {}, dropped = dropped, failed = {} }
        local subs = opts.subtasks and (raw.fields.subtasks or {}) or {}
        local n = 0
        local function next_sub()
          n = n + 1
          local s = subs[n]
          if not s then return cb(res) end
          client.request(pcfg, "GET", API .. "/issue/" .. enc(s.key), { query = clone_query(pcfg) }, function(sraw, serr)
            if not sraw then
              table.insert(res.failed, s.key .. ": " .. tostring(serr))
              return next_sub()
            end
            local sbody = { fields = clone_fields(pcfg, sraw) }
            sbody.fields.parent = { key = created.key }
            create_raw(pcfg, sbody, function(sub, suberr)
              if sub then
                table.insert(res.subtasks, sub.key)
              else
                table.insert(res.failed, s.key .. ": " .. tostring(suberr))
              end
              next_sub()
            end)
          end)
        end
        next_sub()
      end)
    end)
  end)
end

-- endregion

function M.get_transitions(pcfg, key, cb)
  client.request(pcfg, "GET", API .. "/issue/" .. enc(key) .. "/transitions", nil, function(data, err)
    if not data then return fail(cb, err) end
    cb(vim.tbl_map(mapper.transition, data.transitions or {}))
  end)
end

function M.transition(pcfg, key, transition_id, cb)
  client.request(pcfg, "POST", API .. "/issue/" .. enc(key) .. "/transitions",
    { body = { transition = { id = tostring(transition_id) } } },
    function(data, err)
      if not data then return fail(cb, err) end
      cb(true)
    end)
end

-- One call with a big page: this endpoint ignores `startAt` past the first
-- page, and its default page (50) cut real projects short (over 200 people
-- on one site). App accounts (integrations such as a GitLab bot) and deactivated
-- users are not people you assign work to.
function M.assignable_users(pcfg, key, text, cb)
  local query = { issueKey = key, maxResults = 1000 }
  if text and text ~= "" then query.query = text end
  client.request(pcfg, "GET", API .. "/user/assignable/search", { query = query }, function(data, err)
    if not data then return fail(cb, err) end
    local users = {}
    for _, u in ipairs(data) do
      if u.accountType ~= "app" and u.active ~= false then table.insert(users, mapper.user(u)) end
    end
    table.sort(users, function(a, b) return vim.stricmp(a.name, b.name) < 0 end)
    cb(users)
  end)
end

function M.assign(pcfg, key, user_id, cb)
  client.request(pcfg, "PUT", API .. "/issue/" .. enc(key) .. "/assignee",
    { body = { accountId = user_id or vim.NIL } },
    function(data, err)
      if not data then return fail(cb, err) end
      cb(true)
    end)
end

---@param fields { summary: string?, description: string?, priority_id: string?,
---  story_points: number|false|nil, labels: string[]?, parent: string|false|nil, reporter_id: string?,
---  start_date: string|false|nil, due_date: string|false|nil }   dates "YYYY-MM-DD"
---  `false` clears a field (story points, epic / parent, dates).
function M.update_issue(pcfg0, key, fields, cb)
  if fields.description and M.has_uploads(fields.description) then
    -- upload first, then send the description pointing at the files
    return with_fields(pcfg0, function(pcfg)
      M.resolve_uploads(pcfg, key, fields.description, stash_of(pcfg, key, "description"), function(md, stash, uerr)
        if not md then return fail(cb, uerr) end
        local rest = vim.deepcopy(fields)
        rest.description = nil
        rest._description_doc = doc_or_null(md, stash)
        M.update_issue(pcfg0, key, rest, cb)
      end)
    end)
  end
  with_fields(pcfg0, function(pcfg)
    local f = {}
    if fields.summary then f.summary = fields.summary end
    if fields.description then
      f.description = doc_or_null(fields.description, stash_of(pcfg, key, "description"))
    end
    if fields._description_doc then f.description = fields._description_doc end
    if fields.priority_id then f.priority = { id = tostring(fields.priority_id) } end
    if fields.labels then f.labels = fields.labels end
    if fields.reporter_id then f.reporter = { accountId = fields.reporter_id } end
    if fields.parent ~= nil then
      f.parent = fields.parent and { key = fields.parent } or vim.NIL
    end
    if fields.story_points ~= nil then
      local sp = pcfg.fields.story_points
      if not sp then return fail(cb, "jira: no story points field on this site (set providers.jira.fields.story_points)") end
      f[sp] = fields.story_points or vim.NIL
    end
    if fields.due_date ~= nil then f.duedate = fields.due_date or vim.NIL end
    if fields.start_date ~= nil then
      local sd = pcfg.fields.start_date
      if not sd then return fail(cb, "jira: no Start date field on this site (set providers.jira.fields.start_date)") end
      f[sd] = fields.start_date or vim.NIL
    end
    if vim.tbl_isempty(f) then
      vim.schedule(function() cb(true) end)
      return
    end
    client.request(pcfg, "PUT", API .. "/issue/" .. enc(key), { body = { fields = f } }, function(data, err)
      if not data then return fail(cb, err) end
      cb(true)
    end)
  end)
end

---Priorities of the site: { { id, name } } in Jira's order.
function M.priorities(pcfg, cb)
  local ck = "jira:priorities:" .. client.base_url(pcfg)
  local hit = cache.get(ck)
  if hit then return vim.schedule(function() cb(hit) end) end
  client.request(pcfg, "GET", API .. "/priority/search", { query = { maxResults = 100 } }, function(data, err)
    if not data then return fail(cb, err) end
    local out = {}
    for _, p in ipairs(data.values or {}) do table.insert(out, { id = tostring(p.id), name = p.name or "?" }) end
    cache.set(ck, out, 60 * 60 * 1000)
    cb(out)
  end)
end

---Open epics of a project, newest first, with their colour.
---@param cb fun(epics: TrackerEpic[]|nil, err: string|nil)
function M.epic_list(pcfg0, project, cb)
  with_fields(pcfg0, function(pcfg)
    M.issue_types(pcfg, project, function(types, terr)
      if not types then return fail(cb, terr) end
      local ids = {}
      for _, t in ipairs(types) do
        if (t.level or 0) >= 1 then table.insert(ids, t.id) end
      end
      if #ids == 0 then return cb({}) end
      local fields = { "summary" }
      if pcfg.fields.epic_color then table.insert(fields, pcfg.fields.epic_color) end
      local body = {
        jql = ("project = %s AND issuetype in (%s) AND statusCategory != Done ORDER BY created DESC")
          :format(project, table.concat(ids, ",")),
        fields = fields, maxResults = 200,
      }
      client.request(pcfg, "POST", API .. "/search/jql", { body = body }, function(data, err)
        if not data then return fail(cb, err) end
        local out = {}
        for _, raw in ipairs(data.issues or {}) do
          table.insert(out, {
            key = raw.key, summary = raw.fields.summary or "",
            color = pcfg.fields.epic_color and color_index(raw.fields[pcfg.fields.epic_color]) or nil,
          })
        end
        cb(out)
      end)
    end)
  end)
end

---Epics of a project as full issues (dates, sprints, status) in rank order —
---the timeline's rows. `opts.done_days` also brings epics finished in the
---last N days.
---@param opts { done_days: integer? }|nil
---@param cb fun(epics: TrackerIssue[]|nil, err: string|nil)
function M.epic_issues(pcfg0, project, opts, cb)
  with_fields(pcfg0, function(pcfg)
    M.issue_types(pcfg, project, function(types, terr)
      if not types then return fail(cb, terr) end
      local ids = {}
      for _, t in ipairs(types) do
        if (t.level or 0) >= 1 then table.insert(ids, t.id) end
      end
      if #ids == 0 then return cb({}) end
      local open = "statusCategory != Done"
      if opts and opts.done_days then
        open = ("(%s OR resolutiondate >= -%dd)"):format(open, opts.done_days)
      end
      M._search(pcfg, ("project = %s AND issuetype in (%s) AND %s ORDER BY Rank ASC")
        :format(project, table.concat(ids, ","), open), { limit = 500 }, cb)
    end)
  end)
end

---@param attachment TrackerAttachment  (or { url = "https://..." } for external media)
function M.download_attachment(pcfg, attachment, path, cb)
  local target = attachment.id and (API .. "/attachment/content/" .. enc(attachment.id)) or attachment.url
  if not target then
    vim.schedule(function() cb(nil, "attachment has no id or url") end)
    return
  end
  client.download(pcfg, target, path, cb)
end

function M.issue_types(pcfg, project, cb)
  local ck = "jira:types:" .. client.base_url(pcfg) .. ":" .. project
  local hit = cache.get(ck)
  if hit then
    vim.schedule(function() cb(hit) end)
    return
  end
  client.request(pcfg, "GET", API .. "/issue/createmeta/" .. enc(project) .. "/issuetypes",
    { query = { maxResults = 100 } },
    function(data, err)
      if not data then return fail(cb, err) end
      local types = vim.tbl_map(mapper.issue_type, data.issueTypes or data.values or {})
      cache.set(ck, types, 60 * 60 * 1000)
      cb(types)
    end)
end

---@param fields { project: string, type_id: string, summary: string, description: string?, parent: string? }
function M.create_issue(pcfg, fields, cb)
  local f = {
    project = { key = fields.project },
    issuetype = { id = tostring(fields.type_id) },
    summary = fields.summary,
  }
  -- Files to upload need the issue to exist: create it without them, then
  -- upload and send the full description.
  local uploads = M.has_uploads(fields.description)
  if fields.description and vim.trim(fields.description) ~= "" and not uploads then
    f.description = adf.from_markdown(fields.description)
  end
  if fields.parent then f.parent = { key = fields.parent } end
  client.request(pcfg, "POST", API .. "/issue", { body = { fields = f } }, function(data, err)
    if not data then return fail(cb, err) end
    local created = { id = tostring(data.id), key = data.key, url = M.web_url(pcfg, data.key) }
    if not uploads then return cb(created) end
    M.update_issue(pcfg, data.key, { description = fields.description }, function(ok, uerr)
      if not ok then created.warning = "created, but the files didn't make it: " .. tostring(uerr) end
      cb(created)
    end)
  end)
end

function M.boards(pcfg, project, cb)
  local query = project and { projectKeyOrId = project } or nil
  client.collect(pcfg, AGILE .. "/board", query, "values", 200, function(items, err)
    if not items then return fail(cb, err) end
    cb(vim.tbl_map(function(b)
      return { id = tostring(b.id), name = b.name or "?", type = b.type }
    end, items))
  end)
end

function M.board_columns(pcfg, board_id, cb)
  local ck = "jira:columns:" .. client.base_url(pcfg) .. ":" .. board_id
  local hit = cache.get(ck)
  if hit then
    vim.schedule(function() cb(hit.cols, nil, { name = hit.name }) end)
    return
  end
  client.request(pcfg, "GET", AGILE .. "/board/" .. enc(board_id) .. "/configuration", nil, function(data, err)
    if not data then return fail(cb, err) end
    local cols = {}
    for _, c in ipairs((data.columnConfig or {}).columns or {}) do
      local ids = {}
      for _, s in ipairs(c.statuses or {}) do table.insert(ids, tostring(s.id)) end
      -- Columns with no status mapped are display-only ("Backlog" on some
      -- kanban boards); they would always be empty.
      if #ids > 0 then table.insert(cols, { name = c.name or "?", statuses = ids }) end
    end
    cache.set(ck, { cols = cols, name = data.name }, 10 * 60 * 1000)
    cb(cols, nil, { name = data.name })
  end)
end

function M.active_sprints(pcfg, board_id, cb)
  client.request(pcfg, "GET", AGILE .. "/board/" .. enc(board_id) .. "/sprint", { query = { state = "active" } },
    function(data, err)
      if not data then return fail(cb, err) end
      cb(vim.tbl_map(mapper.sprint, data.values or {}))
    end)
end

local function board_fields(pcfg)
  return table.concat(with_story_points(pcfg, LIST_FIELDS), ",")
end

---@param sprint_id string|nil  nil = the board's own issue set (kanban)
function M.board_issues(pcfg0, board_id, sprint_id, cb)
  with_fields(pcfg0, function(pcfg) M._board_issues(pcfg, board_id, sprint_id, cb) end)
end

function M._board_issues(pcfg, board_id, sprint_id, cb)
  local path, query
  if sprint_id then
    path = AGILE .. "/board/" .. enc(board_id) .. "/sprint/" .. enc(sprint_id) .. "/issue"
    query = { fields = board_fields(pcfg) }
  else
    -- Kanban: everything still open plus what closed in the last two weeks,
    -- otherwise the Done column grows forever.
    path = AGILE .. "/board/" .. enc(board_id) .. "/issue"
    query = { fields = board_fields(pcfg), jql = "resolution = Unresolved OR resolutiondate >= -14d" }
  end
  client.collect(pcfg, path, query, "issues", 500, function(items, err)
    if not items then return fail(cb, err) end
    cb(vim.tbl_map(function(raw) return mapper.issue(raw, pcfg) end, items))
  end)
end

function M.backlog(pcfg0, board_id, cb)
  with_fields(pcfg0, function(pcfg)
    client.collect(pcfg, AGILE .. "/board/" .. enc(board_id) .. "/backlog", { fields = board_fields(pcfg) }, "issues", 500,
      function(items, err)
        if not items then return fail(cb, err) end
        cb(vim.tbl_map(function(raw) return mapper.issue(raw, pcfg) end, items))
      end)
  end)
end

-- region Planning: rank, sprint / backlog, archive, delete

---Agile endpoints answer partial failures with 207 + per-issue entries.
local function agile_errors(data)
  local errs = {}
  for _, e in ipairs((data and data.entries) or {}) do
    if e.status and e.status >= 300 then
      table.insert(errs, (e.issueKey or e.issueId or "?") .. ": " .. table.concat(e.errors or { "failed" }, "; "))
    end
  end
  return #errs > 0 and table.concat(errs, " | ") or nil
end

---Re-rank `keys` (kept in this order) right after / before `target`, as
---dragging in the backlog does. At most 50 issues per call (Jira's limit).
---@param where { after: string?, before: string? }
function M.rank(pcfg, keys, where, cb)
  local body = { issues = vim.list_slice(keys, 1, 50) }
  if where.after then body.rankAfterIssue = where.after else body.rankBeforeIssue = where.before end
  client.request(pcfg, "PUT", AGILE .. "/issue/rank", { body = body }, function(data, err)
    if not data then return fail(cb, err) end
    local partial = agile_errors(data)
    if partial then return fail(cb, "rank: " .. partial) end
    cb(true)
  end)
end

---Active and future sprints of a board (move targets).
function M.open_sprints(pcfg, board_id, cb)
  client.request(pcfg, "GET", AGILE .. "/board/" .. enc(board_id) .. "/sprint", { query = { state = "active,future" } },
    function(data, err)
      if not data then return fail(cb, err) end
      cb(vim.tbl_map(mapper.sprint, data.values or {}))
    end)
end

function M.move_to_sprint(pcfg, sprint_id, keys, cb)
  client.request(pcfg, "POST", AGILE .. "/sprint/" .. enc(sprint_id) .. "/issue", { body = { issues = keys } },
    function(data, err)
      if not data then return fail(cb, err) end
      cb(true)
    end)
end

function M.move_to_backlog(pcfg, keys, cb)
  client.request(pcfg, "POST", AGILE .. "/backlog/issue", { body = { issues = keys } }, function(data, err)
    if not data then return fail(cb, err) end
    cb(true)
  end)
end

-- region Sprints

---Every sprint of a board, closed ones too, in the board's order (closed →
---active → future).
function M.sprints(pcfg, board_id, cb)
  client.collect(pcfg, AGILE .. "/board/" .. enc(board_id) .. "/sprint", {}, "values", 5000, function(items, err)
    if not items then return fail(cb, err) end
    cb(vim.tbl_map(mapper.sprint, items))
  end)
end

---TrackerSprintFields → Jira body (false → null clears a date).
local function sprint_body(f)
  local function val(v) if v == false then return vim.NIL end return v end
  return {
    name = f.name, goal = f.goal, state = f.state,
    startDate = val(f.start_date), endDate = val(f.end_date),
  }
end

function M.create_sprint(pcfg, board_id, fields, cb)
  local body = sprint_body(fields)
  body.state = nil -- new sprints are always future
  body.originBoardId = tonumber(board_id) or board_id
  client.request(pcfg, "POST", AGILE .. "/sprint", { body = body }, function(data, err)
    if not data then return fail(cb, err) end
    cb(mapper.sprint(data))
  end)
end

---Partial update. `state = "active"` starts a future sprint (needs both
---dates), `state = "closed"` completes the active one.
function M.update_sprint(pcfg, sprint_id, fields, cb)
  client.request(pcfg, "POST", AGILE .. "/sprint/" .. enc(sprint_id), { body = sprint_body(fields) }, function(data, err)
    if not data then return fail(cb, err) end
    cb(mapper.sprint(data))
  end)
end

-- endregion

---Archive issues (Jira Cloud Premium / Enterprise only; other plans answer
---with an error, which is passed on as is).
function M.archive(pcfg, keys, cb)
  client.request(pcfg, "PUT", API .. "/issue/archive", { body = { issueIdsOrKeys = keys } }, function(data, err)
    if not data then return fail(cb, err) end
    local errs = data.errors and data.errors.issueIsSubtask or nil
    if data.numberOfIssuesUpdated == 0 then
      return fail(cb, "archive: nothing archived" .. (errs and (" (" .. vim.inspect(errs) .. ")") or ""))
    end
    cb(true)
  end)
end

---Delete an issue for good; its sub-tasks with it when `with_subtasks`.
function M.delete_issue(pcfg, key, with_subtasks, cb)
  client.request(pcfg, "DELETE", API .. "/issue/" .. enc(key),
    { query = with_subtasks and { deleteSubtasks = "true" } or nil },
    function(data, err)
      if not data then return fail(cb, err) end
      cb(true)
    end)
end

-- endregion

return M
