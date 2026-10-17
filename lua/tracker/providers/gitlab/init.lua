-- GitLab provider: REST API v4 (gitlab.com and self-managed, Free and
-- Premium / Ultimate).
--
-- How GitLab's model lands on the tracker's:
--   project    the repository's own (`group/sub/project`, read from the git
--              remote — see `detect`), unless `project` names one
--   key        `#123` in that project, `group/project#123` elsewhere
--   status     GitLab only knows open / closed; the lists of the issue board
--              are the workflow: Open → the board's label lists → Closed. An
--              issue shows the right-most list whose label it carries, and a
--              transition swaps that label (and closes / reopens)
--   sprints    iterations (Premium, read-only through REST) or milestones,
--              see `sprints`
--   points     the issue weight (Premium)
--   text       GitLab Flavored Markdown, as it is
--
-- What a licence adds (weights, iterations, "blocks" links) is found out once
-- per project (`prepare`) and shows up in `capabilities`; `tier` skips the
-- probe.

local client = require("tracker.providers.gitlab.client")
local mapper = require("tracker.providers.gitlab.mapper")
local keys = require("tracker.providers.gitlab.keys")
local query = require("tracker.providers.gitlab.query")
local cache = require("tracker.state")
local files = require("tracker.util.files")

local M = { name = "gitlab", label = "GitLab", query_label = "Filter", keys = keys }

M.defaults = {
  base_url = nil,      -- "https://gitlab.com" or a self-managed instance
  hosts = nil,         -- more hosts its git remotes use (an ssh alias), e.g. { "git.corp.example" }
  token = nil,         -- default: netrc `password` / $TRACKER_<NAME>_TOKEN (scope: api)
  netrc_machine = nil, -- default: the base_url host
  auth = "bearer",     -- personal / project / group access tokens
  project = nil,       -- "group/project"; default: the repository's, from its git remote
  -- What the licence offers: "auto" finds out once per project, "free" /
  -- "premium" say so (no probe).
  tier = "auto",
  -- The issue board whose lists are the statuses and the board view's
  -- columns: its id, or "default" for the project's first board.
  board = "default",
  default_query = nil, -- a saved query's name or a raw filter; nil = the first of `queries`
  -- What plays the sprint: "iteration" (Premium; listed and filtered, but
  -- GitLab's REST API can't move issues between them), "milestone" (create,
  -- edit, close, move issues), "auto" (iterations when the licence has them,
  -- else milestones) or false (no sprint views: milestones are releases here).
  sprints = "auto",
  -- Branches of an issue. `patterns`: Lua patterns over the lower-cased
  -- branch, one capture = the issue number, first match wins (default:
  -- 123-fix, issue-123-fix, feature/123-fix, …); `ignore`: branches that never
  -- name an issue (release-2, 17-0-stable); `template`: the name `gb` creates
  -- ({id} {slug} {slug_camel} {type}). Set here it beats `git.branch`; the
  -- default below gives way to a `git.branch` of the user's.
  branch = { patterns = nil, ignore = nil, template = "{id}-{slug}" },
  workflow = {
    categories = {},   -- board list (label) → "todo" | "in_progress" | "done"; default "in_progress"
    closed_limit = 50, -- closed issues a board shows (the most recently updated)
  },
  -- Labels that mean a priority, highest first, e.g. { "priority::high",
  -- "priority::medium", "priority::low" }: shown and edited as the priority.
  priority_labels = nil,
  -- Saved filters (see query.lua for the syntax). `sprint = true` /
  -- `backlog = true`: the active sprint / what is in none.
  queries = {
    { name = "mine", query = "assignee=@me order=updated_at" },
    { name = "open", query = "order=updated_at" },
    { name = "created", query = "author=@me order=updated_at" },
    { name = "sprint", sprint = true },
    { name = "backlog", backlog = true },
  },
}

local function fail(cb, err) cb(nil, err) end

local function base(pcfg) return client.base_url(pcfg) end

---Project path and issue number of `key`, or an error for the callback.
---@return string|nil project, string|nil iid, string|nil err
local function locate(pcfg, key)
  local project, iid = keys.split(pcfg, key)
  if not iid then return nil, nil, ("gitlab: %s is no issue key (expected #123 or group/project#123)"):format(tostring(key)) end
  if not project then
    return nil, nil, ("gitlab: no project for %s — not in a repository of %s, and providers.%s.project is unset")
      :format(key, base(pcfg), pcfg.name or "gitlab")
  end
  return project, iid
end

---API path of an issue.
local function issue_path(project, iid)
  return client.project_path(project) .. "/issues/" .. iid
end

-- region Licence tier and capabilities

local TIER_TTL = 24 * 60 * 60 * 1000

local function tier_key(pcfg)
  return ("gitlab:tier:%s:%s"):format(base(pcfg), tostring(pcfg.project))
end

---@return "free"|"premium"
local function tier(pcfg)
  if pcfg.tier == "free" or pcfg.tier == "premium" then return pcfg.tier end
  return cache.get(tier_key(pcfg)) or "free"
end

---What plays the sprint for this instance, see `defaults.sprints`.
---@return "iteration"|"milestone"|nil
local function sprint_mode(pcfg)
  local mode = pcfg.sprints
  if mode == false then return nil end
  if mode == "milestone" then return "milestone" end
  local premium = tier(pcfg) == "premium"
  if mode == "iteration" then return premium and "iteration" or nil end
  return premium and "iteration" or "milestone"
end

local BASE = {
  comments = true, edit_comments = true, delete_comments = true, transitions = true, assign = true,
  edit = true, create = true, labels = true, attachments = true, upload = true, links = true,
  clone = true, delete = true, dates = true, boards = true, rank = true,
}

function M.capabilities(pcfg)
  local caps = vim.deepcopy(BASE)
  if tier(pcfg) == "premium" then caps.story_points = true end
  local mode = sprint_mode(pcfg)
  if mode then caps.sprints, caps.backlog = true, true end
  -- REST can set an issue's milestone, not its iteration
  if mode == "milestone" then caps.sprint_move, caps.sprint_manage = true, true end
  if pcfg.priority_labels and #pcfg.priority_labels > 0 then caps.priority = true end
  return caps
end

local probing = {} ---@type table<string, function[]>  tier key → waiting callbacks

---Find out the licence tier of the project, once a day: a Premium instance
---answers issues with a `weight` field (Free leaves it out); a project
---without issues is asked for its iterations, which only Premium has.
function M.prepare(pcfg, cb)
  if pcfg.tier ~= "auto" or not pcfg.project then return cb() end
  local ck = tier_key(pcfg)
  if cache.get(ck) then return cb() end
  if probing[ck] then return table.insert(probing[ck], cb) end
  probing[ck] = { cb }
  local function done(found)
    if found then cache.set(ck, found, TIER_TTL) end
    local waiting = probing[ck]
    probing[ck] = nil
    for _, w in ipairs(waiting) do w() end
  end
  local path = client.project_path(pcfg.project)
  client.request(pcfg, "GET", path .. "/issues", { query = { per_page = 1, state = "all" } }, function(data, _, _, _, raw)
    if not data then return done(nil) end -- no answer: ask again next time
    if raw and raw:find('"weight":', 1, true) then return done("premium") end
    if #data > 0 then return done("free") end
    client.request(pcfg, "GET", path .. "/iterations", { query = { per_page = 1 } }, function(iterations)
      done(iterations and "premium" or "free")
    end)
  end)
end

-- endregion

-- region Repository → project

local function host_of(url)
  local host = url and url:match("^%a[%w+.-]*://[^/]-@?([^/@:]+)") or nil
  return host and host:lower() or nil
end

---The repository lives on this instance when its remote's host is the
---base_url's (or one of `hosts`); its path there is the project.
---@param repo TrackerRepo
---@return { project: string }|nil
function M.detect(pcfg, repo)
  if not repo.host or not repo.path then return nil end
  local known = {}
  local own = host_of(pcfg.base_url)
  if own then known[own] = true end
  for _, h in ipairs(pcfg.hosts or {}) do known[h:lower()] = true end
  if not known[repo.host] then return nil end
  local path = repo.path
  -- an instance under a sub-path (https://host/gitlab): the path starts with it
  local sub = base(pcfg):match("^%a[%w+.-]*://[^/]+/(.+)$")
  if sub and path:sub(1, #sub + 1) == sub .. "/" then path = path:sub(#sub + 2) end
  return { project = path }
end

-- endregion

-- region Board lists (the workflow)

local BOARD_TTL = 5 * 60 * 1000

---@class TrackerGitlabBoard
---@field id string|nil
---@field name string|nil
---@field lists string[]        labels of its label lists, left to right
---@field skipped string[]      lists that aren't label lists (assignee, milestone, …)
---@field hide_open boolean
---@field hide_closed boolean

---@return TrackerGitlabBoard
local function board_of(raw)
  local out = { id = raw and tostring(raw.id) or nil, name = raw and raw.name or nil, lists = {}, skipped = {},
                hide_open = raw and raw.hide_backlog_list == true, hide_closed = raw and raw.hide_closed_list == true }
  local lists = vim.deepcopy(raw and raw.lists or {})
  table.sort(lists, function(a, b) return (a.position or 0) < (b.position or 0) end)
  for _, l in ipairs(lists) do
    if type(l.label) == "table" and l.label.name then
      table.insert(out.lists, l.label.name)
    else
      table.insert(out.skipped, l.list_type or "?")
    end
  end
  return out
end

---The board `board_id` ("default" / nil: the project's first), cached a few
---minutes. Never fails: a project without boards (or without access to
---them) has no lists, so issues are just open or closed.
---@param cb fun(board: TrackerGitlabBoard)
local function board_info(pcfg, board_id, cb)
  if not pcfg.project then return vim.schedule(function() cb(board_of(nil)) end) end
  board_id = board_id and tostring(board_id) or "default"
  local ck = ("gitlab:board:%s:%s:%s"):format(base(pcfg), pcfg.project, board_id)
  local hit = cache.get(ck)
  if hit then return vim.schedule(function() cb(hit) end) end
  local function done(raw)
    local board = board_of(raw)
    cache.set(ck, board, BOARD_TTL)
    cb(board)
  end
  local path = client.project_path(pcfg.project) .. "/boards"
  if board_id == "default" then
    client.request(pcfg, "GET", path, { query = { per_page = 1 } }, function(data) done(data and data[1] or nil) end)
  else
    client.request(pcfg, "GET", path .. "/" .. board_id, nil, function(data) done(data) end)
  end
end

---The lists of the provider's board: what statuses are read from.
---@param cb fun(lists: string[], board: TrackerGitlabBoard)
local function with_lists(pcfg, cb)
  board_info(pcfg, pcfg.board, function(board) cb(board.lists, board) end)
end

M._board_info = board_info

-- endregion

-- region Reads

function M.web_url(pcfg, key)
  local project, iid = keys.split(pcfg, key)
  if not project or not iid then return base(pcfg) end
  return ("%s/%s/-/issues/%s"):format(base(pcfg), project, iid)
end

function M.myself(pcfg, cb)
  local ck = "gitlab:myself:" .. base(pcfg) .. ":" .. tostring(pcfg.name)
  local hit = cache.get(ck)
  if hit then return vim.schedule(function() cb(hit) end) end
  client.request(pcfg, "GET", "/user", nil, function(data, err)
    if not data then return fail(cb, err) end
    local user = mapper.user(data)
    cache.set(ck, user, 30 * 60 * 1000)
    cb(user)
  end)
end

---@param user TrackerUser
function M.mention(_, user)
  return "@" .. (user.username or user.name or "?")
end

---Issues of a list endpoint, mapped (statuses from the provider's board).
local function list_issues(pcfg, path, params, limit, cb)
  with_lists(pcfg, function(lists)
    client.paged(pcfg, path, params, limit, function(items, err, meta)
      if not items then return fail(cb, err) end
      cb(vim.tbl_map(function(raw) return mapper.issue(raw, pcfg, lists) end, items), nil, meta)
    end)
  end)
end

---@param text string  a filter line, see query.lua
---@param opts { limit: integer? }|nil
function M.search(pcfg, text, opts, cb)
  local q = query.parse(text)
  local path
  if q.group then
    path = "/groups/" .. require("tracker.http.client").uri_encode(q.group) .. "/issues"
  else
    local project = q.project or pcfg.project
    path = project and (client.project_path(project) .. "/issues") or "/issues"
  end
  list_issues(pcfg, path, q.params, (opts and opts.limit) or 200, cb)
end

---Free-text search of the project, most recently updated first.
---@param opts { limit: integer?, project: string? }|nil
function M.search_text(pcfg, text, opts, cb)
  opts = opts or {}
  local project = opts.project or pcfg.project
  local path = project and (client.project_path(project) .. "/issues") or "/issues"
  list_issues(pcfg, path, { search = text, order_by = "updated_at", scope = "all" }, opts.limit or 30, cb)
end

function M.get_issue(pcfg, key, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  with_lists(pcfg, function(lists)
    local issue, links, pending, failed = nil, nil, 2, nil
    local function step()
      pending = pending - 1
      if pending > 0 then return end
      if not issue then return fail(cb, failed) end
      issue.links = links or {}
      for _, l in ipairs(issue.links) do
        local open = not (l.issue.status and l.issue.status.category == "done")
        if l.type == "blocks" and l.direction == "inward" and open then issue.blocked = true end
      end
      cb(issue)
    end
    client.request(pcfg, "GET", issue_path(project, iid), nil, function(raw, err)
      if raw then issue = mapper.issue(raw, pcfg, lists) else failed = err end
      step()
    end)
    -- links are a detail: without them (no access, an older instance) the issue still shows
    client.request(pcfg, "GET", issue_path(project, iid) .. "/links", nil, function(list)
      links = vim.tbl_map(function(raw) return mapper.link(raw, pcfg, lists) end, list or {})
      step()
    end)
  end)
end

function M.get_comments(pcfg, key, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  client.paged(pcfg, issue_path(project, iid) .. "/notes",
    { sort = "asc", order_by = "created_at", activity_filter = "only_comments" }, 500, function(items, err)
      if not items then return fail(cb, err) end
      local out = {}
      for _, note in ipairs(items) do
        -- "changed the description", "added label …": the activity log, not comments
        if not note.system then table.insert(out, mapper.comment(note)) end
      end
      cb(out)
    end)
end

-- endregion

-- region Markdown out: uploads and alerts

-- Callout panels of the editor (see ui/editor.lua) → GitLab's alert types.
local ALERTS = { INFO = "NOTE", SUCCESS = "TIP", ERROR = "CAUTION" }

---@param md string
---@return string
local function alerts(md)
  return (("\n" .. md):gsub("(\n[%s>]*%[!)(%u+)(%])", function(a, kind, b)
    return a .. (ALERTS[kind] or kind) .. b
  end):sub(2))
end

M._alerts = alerts

---Upload one file to the project; cb({ markdown, url, filename }).
local function upload_file(pcfg, project, path, cb)
  -- quoted: curl -F would read ; or , in a path as options
  local form = { { "file", '@"' .. path:gsub('"', '\\"') .. '"' } }
  client.request(pcfg, "POST", client.project_path(project) .. "/uploads", { form = form, timeout = 300 }, function(data, err)
    if not data then return fail(cb, err) end
    cb({ markdown = data.markdown, url = data.url, filename = data.alt or vim.fs.basename(path) })
  end)
end

---Upload `paths` one after another; cb(uploads in that order).
local function upload_all(pcfg, project, paths, cb)
  local out, i = {}, 0
  local function next_one()
    i = i + 1
    if not paths[i] then return cb(out) end
    upload_file(pcfg, project, paths[i], function(up, err)
      if not up then return fail(cb, err) end
      table.insert(out, up)
      next_one()
    end)
  end
  next_one()
end

---Markdown ready to send: the files its `(upload:…)` lines point at are
---uploaded to the project and the lines become GitLab's own links to them;
---callouts become GitLab alerts.
---@param cb fun(md: string|nil, err: string|nil)
local function outgoing(pcfg, project, md, cb)
  md = md or ""
  local lines = vim.split(md, "\n", { plain = true })
  local todo = files.scan_uploads(lines)
  local stray = files.upload_error(md)
  if stray then return vim.schedule(function() cb(nil, stray) end) end
  if #todo == 0 then return vim.schedule(function() cb(alerts(md)) end) end
  for _, t in ipairs(todo) do
    if not vim.uv.fs_stat(t.path) then
      return vim.schedule(function() cb(nil, "tracker: file not found: " .. t.path) end)
    end
  end
  upload_all(pcfg, project, vim.tbl_map(function(t) return t.path end, todo), function(ups, err)
    if not ups then return cb(nil, err) end
    for n, t in ipairs(todo) do
      lines[t.n] = t.prefix .. (ups[n].markdown or ("[%s](%s)"):format(ups[n].filename, ups[n].url))
    end
    cb(alerts(table.concat(lines, "\n")))
  end)
end

M._outgoing = outgoing

-- endregion

-- region Comments

function M.add_comment(pcfg, key, markdown, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  outgoing(pcfg, project, markdown, function(md, uerr)
    if not md then return fail(cb, uerr) end
    client.request(pcfg, "POST", issue_path(project, iid) .. "/notes", { body = { body = md } }, function(data, err)
      if not data then return fail(cb, err) end
      cb(mapper.comment(data))
    end)
  end)
end

function M.edit_comment(pcfg, key, id, markdown, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  outgoing(pcfg, project, markdown, function(md, uerr)
    if not md then return fail(cb, uerr) end
    client.request(pcfg, "PUT", issue_path(project, iid) .. "/notes/" .. id, { body = { body = md } }, function(data, err)
      if not data then return fail(cb, err) end
      cb(mapper.comment(data))
    end)
  end)
end

function M.delete_comment(pcfg, key, id, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  client.request(pcfg, "DELETE", issue_path(project, iid) .. "/notes/" .. id, nil, function(data, err)
    if not data then return fail(cb, err) end
    cb(true)
  end)
end

-- endregion

-- region Attachments

---Upload files and post them as a comment: GitLab keeps uploads with the
---project, a comment is what ties them to the issue.
---@param paths string[]
function M.upload_attachments(pcfg, key, paths, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  upload_all(pcfg, project, paths, function(ups, err)
    if not ups then return fail(cb, err) end
    local body = table.concat(vim.tbl_map(function(u) return u.markdown or u.url end, ups), "\n\n")
    client.request(pcfg, "POST", issue_path(project, iid) .. "/notes", { body = { body = body } }, function(data, nerr)
      if not data then return fail(cb, nerr) end
      local out = {}
      mapper.uploads(body, out, {})
      cb(out)
    end)
  end)
end

---Delete an uploaded file (needs the Maintainer role); `id` =
---"<secret>/<file name>". The text that linked it keeps a dead link.
function M.delete_attachment(pcfg, key, id, cb)
  local project, _, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  client.request(pcfg, "DELETE", client.project_path(project) .. "/uploads/" .. id, nil, function(data, err)
    if not data then return fail(cb, err) end
    cb(true)
  end)
end

---@param attachment TrackerAttachment|{ url: string }
function M.download_attachment(pcfg, attachment, path, cb)
  local project = attachment.project or pcfg.project
  local id = attachment.id
  if not id and attachment.url then
    -- an upload linked by its full address on this instance
    local b = base(pcfg)
    if attachment.url:sub(1, #b + 1) == b .. "/" then
      local p, rest = attachment.url:sub(#b + 2):match("^(.-)/uploads/(%x+/[^?#]+)")
      if p then project, id = (p:gsub("/%-$", "")), rest end
    end
  end
  if id and project then
    return client.download(pcfg, client.project_path(project) .. "/uploads/" .. id, path, cb)
  end
  if attachment.url then return client.download(pcfg, attachment.url, path, cb) end
  vim.schedule(function() cb(nil, "gitlab: nothing to download") end)
end

-- endregion

-- region Links

function M.link_types(pcfg, cb)
  local out = { { id = "relates_to", name = "relates_to", inward = "relates to", outward = "relates to" } }
  if tier(pcfg) == "premium" then
    table.insert(out, { id = "blocks", name = "blocks", inward = "is blocked by", outward = "blocks" })
  end
  vim.schedule(function() cb(out) end)
end

---@param link { type: string, direction: "outward"|"inward", key: string }
function M.add_link(pcfg, key, link, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  local other_project, other_iid, oerr = locate(pcfg, link.key)
  if not other_project then return vim.schedule(function() fail(cb, oerr) end) end
  local kind = "relates_to"
  if link.type == "blocks" then kind = link.direction == "inward" and "is_blocked_by" or "blocks" end
  client.request(pcfg, "POST", issue_path(project, iid) .. "/links",
    { body = { target_project_id = other_project, target_issue_iid = tonumber(other_iid), link_type = kind } },
    function(data, err)
      if not data then return fail(cb, err) end
      cb(true)
    end)
end

function M.delete_link(pcfg, key, link_id, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  client.request(pcfg, "DELETE", issue_path(project, iid) .. "/links/" .. link_id, nil, function(data, err)
    if not data then return fail(cb, err) end
    cb(true)
  end)
end

-- endregion

-- region Status (open / the board's lists / closed)

---The statuses an issue can move to: every other one of Open, the board's
---lists and Closed.
function M.get_transitions(pcfg, key, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  with_lists(pcfg, function(lists)
    client.request(pcfg, "GET", issue_path(project, iid), nil, function(raw, err)
      if not raw then return fail(cb, err) end
      local current = mapper.status(raw, lists, pcfg)
      local out = {}
      local function add(status, name)
        if status.id ~= current.id then table.insert(out, { id = status.id, name = name, to = status }) end
      end
      add(mapper.OPEN, raw.state == "closed" and "Reopen" or "Open")
      for _, l in ipairs(lists) do add(mapper.list_status(l, pcfg), l) end
      add(mapper.CLOSED, "Close")
      cb(out)
    end)
  end)
end

---@param id string  "open" | "closed" | "label:<list label>"
function M.transition(pcfg, key, id, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  with_lists(pcfg, function(lists)
    client.request(pcfg, "GET", issue_path(project, iid), nil, function(raw, err)
      if not raw then return fail(cb, err) end
      local body = {}
      if id == "closed" then
        body.state_event = "close"
      else
        if raw.state == "closed" then body.state_event = "reopen" end
        local target = id:match("^label:(.+)$")
        local has, drop = {}, {}
        for _, l in ipairs(raw.labels or {}) do has[l] = true end
        for _, l in ipairs(lists) do
          if has[l] and l ~= target then table.insert(drop, l) end
        end
        if #drop > 0 then body.remove_labels = table.concat(drop, ",") end
        if target and not has[target] then body.add_labels = target end
      end
      if vim.tbl_isempty(body) then return cb(true) end
      client.request(pcfg, "PUT", issue_path(project, iid), { body = body }, function(data, uerr)
        if not data then return fail(cb, uerr) end
        cb(true)
      end)
    end)
  end)
end

-- endregion

-- region Edits

function M.assignable_users(pcfg, key, text, cb)
  local project, _, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  local q = {}
  if text and text ~= "" then q.query = text end
  client.paged(pcfg, client.project_path(project) .. "/members/all", q, 300, function(items, err)
    if not items then return fail(cb, err) end
    local out = {}
    for _, u in ipairs(items) do
      if u.state == nil or u.state == "active" then table.insert(out, mapper.user(u)) end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    cb(out)
  end)
end

---@param user_id string|nil  nil unassigns
function M.assign(pcfg, key, user_id, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  -- 0 = nobody (GitLab's own way to clear the assignees)
  local ids = { user_id and tonumber(user_id) or 0 }
  client.request(pcfg, "PUT", issue_path(project, iid), { body = { assignee_ids = ids } }, function(data, err)
    if not data then return fail(cb, err) end
    cb(true)
  end)
end

function M.priorities(pcfg, cb)
  local out = {}
  for n, name in ipairs(pcfg.priority_labels or {}) do table.insert(out, { id = tostring(n), name = name }) end
  vim.schedule(function() cb(out) end)
end

---@param fields table  see providers/init.lua update_issue
function M.update_issue(pcfg, key, fields, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  local body = {}
  if fields.summary then body.title = fields.summary end
  if fields.labels then body.labels = table.concat(fields.labels, ",") end
  if fields.story_points ~= nil then body.weight = fields.story_points or vim.NIL end
  if fields.due_date ~= nil then body.due_date = fields.due_date or "" end
  if fields.start_date ~= nil then body.start_date = fields.start_date or "" end
  if fields.priority_id then
    local wanted = (pcfg.priority_labels or {})[tonumber(fields.priority_id)]
    local drop = vim.tbl_filter(function(l) return l ~= wanted end, pcfg.priority_labels or {})
    if #drop > 0 then body.remove_labels = table.concat(drop, ",") end
    if wanted then body.add_labels = wanted end
  end
  local function send()
    if vim.tbl_isempty(body) then return cb(true) end
    client.request(pcfg, "PUT", issue_path(project, iid), { body = body }, function(data, err)
      if not data then return fail(cb, err) end
      cb(true)
    end)
  end
  if fields.description == nil then return send() end
  outgoing(pcfg, project, fields.description, function(md, uerr)
    if not md then return fail(cb, uerr) end
    body.description = md
    send()
  end)
end

function M.issue_types(_, _, cb)
  vim.schedule(function()
    cb({ mapper.issue_type("issue"), mapper.issue_type("incident") })
  end)
end

---@param fields { project: string, type_id: string?, summary: string, description: string? }
function M.create_issue(pcfg, fields, cb)
  local project = fields.project or pcfg.project
  if not project then return vim.schedule(function() fail(cb, "gitlab: no project to create the issue in") end) end
  if fields.parent then
    return vim.schedule(function() fail(cb, "gitlab: sub-tasks (tasks) can't be created through the REST API yet") end)
  end
  outgoing(pcfg, project, fields.description, function(md, uerr)
    if not md then return fail(cb, uerr) end
    local body = { title = fields.summary, description = md ~= "" and md or nil }
    if fields.type_id and fields.type_id ~= "issue" then body.issue_type = fields.type_id end
    client.request(pcfg, "POST", client.project_path(project) .. "/issues", { body = body }, function(raw, err)
      if not raw then return fail(cb, err) end
      local scoped = vim.tbl_extend("force", pcfg, { project = pcfg.project or project })
      cb({ id = tostring(raw.id), key = keys.make(scoped, project, raw.iid), url = raw.web_url })
    end)
  end)
end

function M.delete_issue(pcfg, key, _, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  client.request(pcfg, "DELETE", issue_path(project, iid), nil, function(data, err)
    if not data then return fail(cb, err) end
    cb(true)
  end)
end

---A copy under a new title: description, labels, assignees, milestone,
---weight and due date as they are; `opts.link` relates it to the original.
---@param opts { summary: string, link: boolean? }
function M.clone_issue(pcfg, key, opts, cb)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return vim.schedule(function() fail(cb, kerr) end) end
  client.request(pcfg, "GET", issue_path(project, iid), nil, function(raw, err)
    if not raw then return fail(cb, err) end
    local body = {
      title = opts.summary,
      description = raw.description,
      labels = table.concat(raw.labels or {}, ","),
      assignee_ids = vim.tbl_map(function(u) return u.id end, raw.assignees or {}),
      milestone_id = raw.milestone and raw.milestone.id or nil,
      weight = raw.weight,
      due_date = raw.due_date,
    }
    if raw.issue_type and raw.issue_type ~= "issue" then body.issue_type = raw.issue_type end
    if #body.assignee_ids == 0 then body.assignee_ids = nil end
    client.request(pcfg, "POST", client.project_path(project) .. "/issues", { body = body }, function(new, cerr)
      if not new then return fail(cb, cerr) end
      local res = { id = tostring(new.id), key = keys.make(pcfg, project, new.iid), url = new.web_url,
                    subtasks = {}, dropped = {}, failed = {} }
      if not opts.link then return cb(res) end
      client.request(pcfg, "POST", issue_path(project, tostring(new.iid)) .. "/links",
        { body = { target_project_id = project, target_issue_iid = tonumber(iid), link_type = "relates_to" } },
        function() cb(res) end) -- the copy exists either way
    end)
  end)
end

-- endregion

-- region Boards

function M.boards(pcfg, project, cb)
  project = project or pcfg.project
  if not project then return vim.schedule(function() fail(cb, "gitlab: no project") end) end
  client.paged(pcfg, client.project_path(project) .. "/boards", nil, 100, function(items, err)
    if not items then return fail(cb, err) end
    cb(vim.tbl_map(function(b) return { id = tostring(b.id), name = b.name or ("Board " .. b.id), type = "kanban" } end, items))
  end)
end

---Columns: Open, the board's label lists, Closed (minus the two the board
---hides).
function M.board_columns(pcfg, board_id, cb)
  board_info(pcfg, board_id, function(board)
    local columns = {}
    if not board.hide_open then table.insert(columns, { name = mapper.OPEN.name, statuses = { mapper.OPEN.id } }) end
    for _, l in ipairs(board.lists) do table.insert(columns, { name = l, statuses = { "label:" .. l } }) end
    if not board.hide_closed then table.insert(columns, { name = mapper.CLOSED.name, statuses = { mapper.CLOSED.id } }) end
    cb(columns, nil, { name = board.name })
  end)
end

-- Sprints: iterations or milestones, see `defaults.sprints`.

---@param cb fun(sprints: TrackerSprint[]|nil, err: string|nil)
local function all_sprints(pcfg, cb)
  local mode = sprint_mode(pcfg)
  if not mode or not pcfg.project then return vim.schedule(function() cb({}) end) end
  local path = client.project_path(pcfg.project) .. (mode == "iteration" and "/iterations" or "/milestones")
  local q = { state = "all" }
  if mode == "milestone" then q.include_ancestors = "true" end
  client.paged(pcfg, path, q, 200, function(items, err)
    if not items then return fail(cb, err) end
    local out = vim.tbl_map(function(raw) return mapper.sprint(raw, mode) end, items)
    -- oldest first, undated ones last: the order a sprint list reads in
    table.sort(out, function(a, b)
      local sa, sb = a.start_date or a.end_date or "9999", b.start_date or b.end_date or "9999"
      if sa ~= sb then return sa < sb end
      return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    cb(out)
  end)
end

function M.sprints(pcfg, _, cb) all_sprints(pcfg, cb) end

local function sprints_in(pcfg, states, cb)
  all_sprints(pcfg, function(list, err)
    if not list then return fail(cb, err) end
    cb(vim.tbl_filter(function(s) return states[s.state] == true end, list))
  end)
end

function M.active_sprints(pcfg, _, cb) sprints_in(pcfg, { active = true }, cb) end

function M.open_sprints(pcfg, _, cb) sprints_in(pcfg, { active = true, future = true }, cb) end

---Issues of a board: a sprint's (open and closed), else every open issue
---plus the latest closed ones; in the board's own order.
function M.board_issues(pcfg, board_id, sprint_id, cb)
  if not pcfg.project then return vim.schedule(function() fail(cb, "gitlab: no project") end) end
  local path = client.project_path(pcfg.project) .. "/issues"
  board_info(pcfg, board_id, function(board)
    local function map(items) return vim.tbl_map(function(raw) return mapper.issue(raw, pcfg, board.lists) end, items) end
    local order = { order_by = "relative_position", sort = "asc" }
    if sprint_id then
      all_sprints(pcfg, function(list, serr)
        if not list then return fail(cb, serr) end
        local sprint
        for _, s in ipairs(list) do
          if s.id == tostring(sprint_id) then sprint = s end
        end
        if not sprint then return fail(cb, "gitlab: no sprint " .. tostring(sprint_id)) end
        local q = vim.tbl_extend("force", order, sprint.kind == "iteration" and { iteration_id = sprint.id } or { milestone = sprint.name })
        client.paged(pcfg, path, q, 500, function(items, err)
          if not items then return fail(cb, err) end
          cb(map(items))
        end)
      end)
      return
    end
    client.paged(pcfg, path, vim.tbl_extend("force", order, { state = "opened" }), 500, function(open, err)
      if not open then return fail(cb, err) end
      local limit = type(pcfg.workflow) == "table" and pcfg.workflow.closed_limit or 50
      if board.hide_closed or limit <= 0 then return cb(map(open)) end
      client.paged(pcfg, path, { state = "closed", order_by = "updated_at", sort = "desc" }, limit, function(closed)
        cb(vim.list_extend(map(open), map(closed or {})))
      end)
    end)
  end)
end

---Open issues in no sprint.
function M.backlog(pcfg, _, cb)
  if not pcfg.project then return vim.schedule(function() fail(cb, "gitlab: no project") end) end
  local q = { state = "opened", order_by = "relative_position", sort = "asc" }
  if sprint_mode(pcfg) == "iteration" then q.iteration_id = "None" else q.milestone = "None" end
  list_issues(pcfg, client.project_path(pcfg.project) .. "/issues", q, 500, cb)
end

---Run `fn(key, done(ok, err))` for each key in turn; cb(true) or the first error.
local function each(keys_, fn, cb)
  local i = 0
  local function next_one()
    i = i + 1
    if not keys_[i] then return cb(true) end
    fn(keys_[i], function(ok, err)
      if not ok then return fail(cb, err) end
      next_one()
    end)
  end
  next_one()
end

local function set_milestone(pcfg, key, milestone_id, done)
  local project, iid, kerr = locate(pcfg, key)
  if not project then return done(nil, kerr) end
  client.request(pcfg, "PUT", issue_path(project, iid), { body = { milestone_id = milestone_id } }, function(data, err)
    done(data ~= nil, err)
  end)
end

function M.move_to_sprint(pcfg, sprint_id, keys_, cb)
  each(keys_, function(key, done) set_milestone(pcfg, key, tonumber(sprint_id), done) end, cb)
end

function M.move_to_backlog(pcfg, keys_, cb)
  each(keys_, function(key, done) set_milestone(pcfg, key, 0, done) end, cb) -- 0 = no milestone
end

local function day(ts) return type(ts) == "string" and ts:sub(1, 10) or nil end

---@param fields TrackerSprintFields
local function milestone_body(fields)
  local body = {}
  if fields.name then body.title = fields.name end
  if fields.goal ~= nil then body.description = fields.goal or "" end
  if fields.start_date ~= nil then body.start_date = day(fields.start_date) or "" end
  if fields.end_date ~= nil then body.due_date = day(fields.end_date) or "" end
  if fields.state == "closed" then body.state_event = "close" end
  if fields.state == "active" then body.state_event = "activate" end
  return body
end

function M.create_sprint(pcfg, _, fields, cb)
  client.request(pcfg, "POST", client.project_path(pcfg.project) .. "/milestones", { body = milestone_body(fields) },
    function(raw, err)
      if not raw then return fail(cb, err) end
      cb(mapper.sprint(raw, "milestone"))
    end)
end

function M.update_sprint(pcfg, sprint_id, fields, cb)
  client.request(pcfg, "PUT", client.project_path(pcfg.project) .. "/milestones/" .. sprint_id,
    { body = milestone_body(fields) }, function(raw, err)
      if not raw then return fail(cb, err) end
      cb(mapper.sprint(raw, "milestone"))
    end)
end

---Re-rank `keys` (in this order) right after / before another issue, as a
---drag on the board would.
---@param where { after: string?, before: string? }
function M.rank(pcfg, keys_, where, cb)
  local target = where.after or where.before
  local ids = {} ---@type table<string, integer>  key → global id
  local function id_of(key, done)
    if ids[key] then return done(ids[key]) end
    local project, iid, kerr = locate(pcfg, key)
    if not project then return done(nil, kerr) end
    client.request(pcfg, "GET", issue_path(project, iid), nil, function(raw, err)
      ids[key] = raw and raw.id or nil
      done(ids[key], err)
    end)
  end
  -- the first goes next to the target; each following one right after its predecessor
  local anchor, param = target, where.after and "move_before_id" or "move_after_id"
  each(keys_, function(key, done)
    id_of(anchor, function(anchor_id, aerr)
      if not anchor_id then return done(nil, aerr) end
      local project, iid, kerr = locate(pcfg, key)
      if not project then return done(nil, kerr) end
      -- reorder names the NEIGHBOURS: move_before_id = the issue that ends up before this one
      client.request(pcfg, "PUT", issue_path(project, iid) .. "/reorder", { body = { [param] = anchor_id } }, function(data, err)
        if not data then return done(nil, err) end
        anchor, param = key, "move_before_id"
        done(true)
      end)
    end)
  end, cb)
end

-- endregion

return M
