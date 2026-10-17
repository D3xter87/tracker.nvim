-- Public, stable Lua API — the integration surface for other plugins,
-- configs and scripts. The plugin's own UI goes through it too, so anything
-- the UI can do, a consumer can do, and every mutation emits its `User`
-- event (see tracker.events) no matter who triggered it.
--
-- Conventions:
--   * async functions take a callback `cb(result, err)` as their LAST
--     positional argument, followed by an optional `opts` table;
--     `opts.provider` selects a tracker (default: config.default_provider,
--     else the first configured one). cb always runs on the main loop.
--   * shapes are the ones documented in tracker.model; text is Markdown.
--   * soft dependency from another plugin:
--       local ok, tracker = pcall(require, "tracker.api")
--       if ok then tracker.get_issue("ABC-1", function(issue, err) ... end) end

local M = {}

local config = require("tracker.config")
local providers = require("tracker.providers")
local events = require("tracker.events")
local boards = require("tracker.boards")

local unpack = table.unpack or unpack

-- Keys seen recently (opened, listed), newest first — command completion.
local recent, recent_set = {}, {}
local RECENT_MAX = 100

local function remember(key)
  if not key then return end
  if recent_set[key] then
    for i, k in ipairs(recent) do
      if k == key then table.remove(recent, i) break end
    end
  end
  table.insert(recent, 1, key)
  recent_set[key] = true
  if #recent > RECENT_MAX then
    recent_set[table.remove(recent)] = nil
  end
end

---@return string[] issue keys seen this session, newest first
function M.recent_keys()
  return vim.deepcopy(recent)
end

-- region Provider context

---@class TrackerContext
---@field name string
---@field mod table   provider module
---@field cfg table   resolved provider config (as its board sees it, see tracker.boards)
---@field board_name string|nil

---`opts.board_name` picks one of `providers.<name>.boards`; otherwise the
---main board of the cwd's repository (`providers.<name>.repos`) applies.
---@param opts table|nil
---@return TrackerContext|nil, string|nil err
local function context(opts)
  local name = (opts and opts.provider) or config.get().default_provider or providers.configured()[1]
  if not name then
    return nil, "tracker: no provider configured — set providers.<name>.base_url in setup()"
  end
  local ok, mod = pcall(providers.get, name)
  if not ok then return nil, tostring(mod) end
  local cfg = config.provider(name)
  local board
  if opts and opts.board_name then
    board = boards.get(cfg, opts.board_name)
    if not board then return nil, ("tracker: no board %q in providers.%s.boards"):format(opts.board_name, name) end
    boards.overlay(cfg, board, nil)
  elseif cfg.boards and cfg.repos then
    local list, entry = boards.for_repo(cfg, boards.repo_root(opts and opts.cwd))
    board = entry and list[1]
    if board then boards.overlay(cfg, board, entry) end
  end
  return { name = name, mod = mod, cfg = cfg, board_name = board and board.name }
end

local function async_err(cb, err)
  vim.schedule(function() cb(nil, err) end)
end

---Run `mod[fn](cfg, ...)` with a capability check. The provider's callback is
---forwarded with the context appended: cb(result, err, meta, ctx).
local function call(opts, capability, fn, cb, ...)
  local ctx, err = context(opts)
  if not ctx then return async_err(cb, err) end
  if capability and not ctx.mod.capabilities[capability] then
    return async_err(cb, ("tracker: %s does not support %s"):format(ctx.name, capability))
  end
  local n = select("#", ...)
  local args = { ... }
  args[n + 1] = function(res, e, meta) cb(res, e, meta, ctx) end
  ctx.mod[fn](ctx.cfg, unpack(args, 1, n + 1))
end

---@return string[] configured provider names
function M.providers()
  return providers.configured()
end

---Provider name, capabilities and the bits of config a consumer may need.
---@param opts table|nil
---@return { name: string, capabilities: table, project: string?, base_url: string }|nil, string|nil
function M.provider_info(opts)
  local ctx, err = context(opts)
  if not ctx then return nil, err end
  return {
    name = ctx.name,
    capabilities = vim.deepcopy(ctx.mod.capabilities),
    project = ctx.cfg.project,
    base_url = ctx.cfg.base_url,
    board = ctx.cfg.board and tostring(ctx.cfg.board) or nil,
    board_name = ctx.board_name,
  }
end

---Boards the cwd's repository uses (its `providers.<name>.repos` entry),
---main one first; {} when the repository isn't listed.
---@param opts { provider: string?, cwd: string? }|nil
---@return TrackerBoardEntry[]
function M.repo_boards(opts)
  local ctx = context(opts)
  if not ctx or not ctx.cfg.boards or not ctx.cfg.repos then return {} end
  local list, entry = boards.for_repo(ctx.cfg, boards.repo_root(opts and opts.cwd))
  return entry and vim.deepcopy(list) or {}
end

---@param capability string  see providers.CAPABILITIES
---@param opts table|nil
---@return boolean
function M.has(capability, opts)
  local ctx = context(opts)
  return ctx ~= nil and ctx.mod.capabilities[capability] == true
end

-- endregion

-- region Sync helpers

---Issue key of the current (or given) git branch, e.g. `abc-123-feat` →
---ABC-123. With `providers.<name>.boards` only the tags of the repository's
---boards count (see tracker.boards), else `providers.<name>.projects` when
---set. Second value: the board the key belongs to.
---@param opts { provider: string?, branch: string?, cwd: string? }|nil
---@return string|nil key, string|nil board_name
function M.current_issue_key(opts)
  opts = opts or {}
  local git = require("tracker.util.git")
  local branch = opts.branch or git.current_branch(opts.cwd)
  local pattern = config.get().issue_key_pattern
  local ctx = context(opts)
  if not ctx or not ctx.cfg.boards then
    return git.issue_key(branch, pattern, ctx and ctx.cfg.projects or nil)
  end
  local list = boards.for_repo(ctx.cfg, ctx.cfg.repos and boards.repo_root(opts.cwd) or nil)
  local tags = {}
  for _, b in ipairs(list) do vim.list_extend(tags, b.tags) end
  if #tags == 0 then return nil end -- an empty list would let any key through
  local key = git.issue_key(branch, pattern, tags)
  local board = key and boards.of_key(key, list)
  return key, board and board.name
end

---@param key string
---@param opts table|nil
---@return string|nil
function M.web_url(key, opts)
  local ctx = context(opts)
  if not ctx or not key then return nil end
  return ctx.mod.web_url(ctx.cfg, key)
end

---@class TrackerQuery
---@field name string
---@field jql string|nil        a search; or
---@field sprint boolean|nil    the active sprint(s) of the provider's `board`
---@field backlog boolean|nil   the backlog of the provider's `board`
---@field children boolean|nil  (jql) also list all children of listed issues
---@field board_name string|nil  a query of another board ("EP/sprint")
---@field sprints boolean|nil    every active sprint of the boards, one section each
---@field backlogs boolean|nil   the backlog of each board, one section each
---@field sections string[]|nil  names of saved queries, listed one after another

---`jql` with {project} expanded; nil when it needs a project and there is none.
local function expand_project(jql, cfg)
  if not jql:find("{project}", 1, true) then return jql end
  if not cfg.project then return nil end
  return (jql:gsub("{project}", function() return cfg.project end))
end

---Boards `sprints` / `backlogs` cover: the cwd repository's boards that have
---an id, else the provider's `board`.
---@return { name: string, board: string, opts: table|nil }[]
local function board_targets(ctx, opts)
  local out = {}
  for _, b in ipairs(M.repo_boards(opts)) do
    if b.board then
      table.insert(out, { name = b.name, board = b.board, opts = vim.tbl_extend("force", opts or {}, { board_name = b.name }) })
    end
  end
  if #out == 0 and ctx.cfg.board then
    table.insert(out, { name = ctx.cfg.project or ("#" .. tostring(ctx.cfg.board)), board = tostring(ctx.cfg.board), opts = opts })
  end
  return out
end

---Saved searches with `{project}` expanded. Entries that can't run with the
---current config (a {project} query without `project`, a backlog without
---`board`) are left out. `opts.all_boards` adds those of the repository's
---other boards (every board outside a listed repository), named
---"<BOARD>/<name>".
---@param opts table|nil
---@return TrackerQuery[]
function M.queries(opts)
  local ctx = context(opts)
  if not ctx then return {} end
  local out = {}
  for _, q in ipairs(ctx.cfg.queries or {}) do
    if q.backlog or q.sprint then
      local cap = q.sprint and "sprints" or "backlog"
      if ctx.cfg.board and ctx.mod.capabilities[cap] then
        table.insert(out, { name = q.name, backlog = q.backlog or nil, sprint = q.sprint or nil })
      end
    elseif q.sprints or q.backlogs then
      local cap = q.sprints and "sprints" or "backlog"
      if ctx.mod.capabilities[cap] and #board_targets(ctx, opts) > 0 then
        table.insert(out, { name = q.name, sprints = q.sprints or nil, backlogs = q.backlogs or nil })
      end
    elseif q.sections then
      table.insert(out, { name = q.name, sections = vim.deepcopy(q.sections) })
    elseif q.jql then
      local jql = expand_project(q.jql, ctx.cfg)
      if jql then table.insert(out, { name = q.name, jql = jql, children = q.children or nil }) end
    end
  end
  if opts and opts.all_boards and ctx.cfg.boards then
    local list = boards.for_repo(ctx.cfg, ctx.cfg.repos and boards.repo_root(opts.cwd) or nil)
    for _, b in ipairs(list) do
      -- only boards with queries of their own: the shared ones are here already
      if b.name ~= ctx.board_name and b.queries then
        local sub = vim.tbl_extend("force", opts, { all_boards = false, board_name = b.name })
        for _, q in ipairs(M.queries(sub)) do
          q.name, q.board_name = b.name .. "/" .. q.name, b.name
          table.insert(out, q)
        end
      end
    end
  end
  return out
end

---A saved query by name ("<BOARD>/<name>" for another board's), or the text
---itself as a raw query.
---@param query string|nil  nil = `default_query` (a saved name or JQL), else the first saved query
---@param opts table|nil
---@return string|nil jql, string|nil label, TrackerQuery|nil entry
function M.resolve_query(query, opts)
  local saved = M.queries(vim.tbl_extend("force", opts or {}, { all_boards = true }))
  if not query or query == "" then
    local ctx = context(opts)
    local default = ctx and ctx.cfg.default_query
    if default then
      for _, q in ipairs(saved) do
        if q.name == default then return q.jql, q.name, q end
      end
      local jql = expand_project(default, ctx.cfg)
      if jql then return jql, jql, { name = jql, jql = jql } end
    end
    if saved[1] and not saved[1].board_name then return saved[1].jql, saved[1].name, saved[1] end
    return nil
  end
  for _, q in ipairs(saved) do
    if q.name == query then return q.jql, q.name, q end
  end
  return query, query, { name = query, jql = query }
end

-- endregion

-- region Reads

function M.myself(cb, opts)
  call(opts, nil, "myself", cb)
end

---@class TrackerSection
---@field title string
---@field issues TrackerIssue[]

---Run `jobs` (each `fun(done(sections, err))`) at once; cb(their sections
---in job order), or the first error once all are done.
local function gather(jobs, cb)
  if #jobs == 0 then return vim.schedule(function() cb({}) end) end
  local results, pending, failed = {}, #jobs, nil
  for n, job in ipairs(jobs) do
    job(function(secs, err)
      results[n] = secs or {}
      if not secs and err then failed = failed or err end
      pending = pending - 1
      if pending > 0 then return end
      if failed then return cb(nil, failed) end
      local out = {}
      for k = 1, #jobs do vim.list_extend(out, results[k]) end
      cb(out)
    end)
  end
end

---A saved query by name; unlike resolve_query no raw-JQL fallback.
local function saved_entry(name, opts)
  for _, q in ipairs(M.queries(vim.tbl_extend("force", opts or {}, { all_boards = true }))) do
    if q.name == name then return q end
  end
  return nil
end

---Sections of a saved query: `sections` → those of the named queries in
---turn (unknown names skipped); `sprints` → one per active sprint of each
---board; `backlogs` → one per board's backlog; anything else → one, titled
---by its name.
---@param cb fun(sections: TrackerSection[]|nil, err: string|nil)
local function collect(entry, opts, depth, cb)
  local ctx, err = context(opts)
  if not ctx then return async_err(cb, err) end
  if entry.sections then
    if depth > 3 then return async_err(cb, "tracker: query " .. entry.name .. " nests too deep") end
    local jobs = {}
    for _, name in ipairs(entry.sections) do
      local sub = saved_entry(name, opts)
      if sub then table.insert(jobs, function(done) collect(sub, opts, depth + 1, done) end) end
    end
    return gather(jobs, cb)
  end
  if entry.sprints or entry.backlogs then
    local jobs = {}
    for _, t in ipairs(board_targets(ctx, opts)) do
      local tctx = context(t.opts)
      table.insert(jobs, function(done)
        if entry.backlogs then
          return tctx.mod.backlog(tctx.cfg, t.board, function(issues, berr)
            if not issues then return done(nil, berr) end
            done({ { title = t.name .. " · backlog", issues = issues } })
          end)
        end
        -- Kanban boards answer the sprint endpoint with an error: no section.
        tctx.mod.active_sprints(tctx.cfg, t.board, function(sprints)
          gather(vim.tbl_map(function(s)
            return function(sdone)
              tctx.mod.board_issues(tctx.cfg, t.board, s.id, function(issues, ierr)
                if not issues then return sdone(nil, ierr) end
                sdone({ { title = t.name .. " · " .. s.name, issues = issues } })
              end)
            end
          end, sprints or {}), done)
        end)
      end)
    end
    return gather(jobs, cb)
  end
  M.search(entry.name, function(issues, serr)
    if not issues then return cb(nil, serr) end
    cb({ { title = entry.name, issues = issues } })
  end, opts)
end

---@param query string|nil  saved query name or raw query (JQL for Jira)
---@param cb fun(issues: TrackerIssue[]|nil, err: string|nil, meta: { truncated: boolean }|nil)
---@param opts { provider: string?, limit: integer? }|nil
function M.search(query, cb, opts)
  local q, _, entry = M.resolve_query(query, opts)
  if entry and entry.board_name then
    opts = vim.tbl_extend("force", opts or {}, { board_name = entry.board_name })
  end
  if entry and (entry.sections or entry.sprints or entry.backlogs) then
    -- meta.sections keeps the parts; the list itself is their union
    return collect(entry, opts, 0, function(sections, err)
      if not sections then return cb(nil, err) end
      local all, seen = {}, {}
      for _, s in ipairs(sections) do
        for _, i in ipairs(s.issues) do
          remember(i.key)
          if not seen[i.key] then
            seen[i.key] = true
            table.insert(all, i)
          end
        end
      end
      cb(all, nil, { truncated = false, sections = sections })
    end)
  end
  if entry and (entry.backlog or entry.sprint) then
    local ctx = context(opts)
    local board = tostring(ctx.cfg.board)
    local function done(issues, err)
      for _, issue in ipairs(issues or {}) do remember(issue.key) end
      cb(issues, err, issues and { truncated = false } or nil)
    end
    if entry.backlog then return M.backlog(board, done, opts) end
    -- Active sprint(s) of the board, each in the board's own (rank) order.
    return ctx.mod.active_sprints(ctx.cfg, board, function(sprints, serr)
      if not sprints then return done(nil, serr) end
      local all, i = {}, 0
      local function next_sprint()
        i = i + 1
        if not sprints[i] then return done(all) end
        ctx.mod.board_issues(ctx.cfg, board, sprints[i].id, function(issues, ierr)
          if not issues then return done(nil, ierr) end
          vim.list_extend(all, issues)
          next_sprint()
        end)
      end
      next_sprint()
    end)
  end
  if not q then return async_err(cb, "tracker: no query given and no saved queries configured") end
  call(opts, nil, "search", function(issues, err, meta)
    if not issues then return cb(nil, err, meta) end
    local function done(list)
      for _, issue in ipairs(list) do remember(issue.key) end
      cb(list, nil, meta)
    end
    if entry and entry.children and M.has("children", opts) then
      return M.with_children(issues, function(list) done(list) end, opts)
    end
    done(issues)
  end, q, { limit = (opts and opts.limit) or config.get().limit })
end

---`issues` plus every child of them that is missing, whoever it is assigned
---to: sub-tasks of stories / tasks, issues of epics and, one level further,
---the sub-tasks of those (epic → story → sub-task). Children are appended;
---list views nest them under their parents. A failed child fetch keeps the
---list as it was.
---@param issues TrackerIssue[]
---@param cb fun(issues: TrackerIssue[])
function M.with_children(issues, cb, opts)
  local ctx = context(opts)
  if not ctx or not ctx.mod.capabilities.children then
    return vim.schedule(function() cb(issues) end)
  end
  local have, out = {}, vim.list_extend({}, issues)
  for _, i in ipairs(issues) do have[i.key] = true end

  ---Parents worth asking about: epics always, others when they report
  ---sub-tasks the list doesn't have yet.
  local function parents_of(list)
    local keys = {}
    for _, i in ipairs(list) do
      local level = i.type and i.type.level or 0
      if level >= 1 then
        table.insert(keys, i.key)
      elseif level == 0 then
        for _, ref in ipairs(i.subtasks or {}) do
          if not have[ref.key] then
            table.insert(keys, i.key)
            break
          end
        end
      end
    end
    return keys
  end

  local function round(list, depth)
    local keys = parents_of(list)
    if #keys == 0 or depth > 2 then return cb(out) end
    ctx.mod.children(ctx.cfg, keys, function(children)
      local new = {}
      for _, c in ipairs(children or {}) do
        if not have[c.key] then
          have[c.key] = true
          table.insert(out, c)
          table.insert(new, c)
        end
      end
      round(new, depth + 1)
    end)
  end
  round(issues, 1)
end

---@param cb fun(issue: TrackerIssue|nil, err: string|nil)
function M.get_issue(key, cb, opts)
  call(opts, nil, "get_issue", function(issue, err)
    if issue then remember(issue.key) end
    cb(issue, err)
  end, key)
end

---@param cb fun(comments: TrackerComment[]|nil, err: string|nil)
function M.get_comments(key, cb, opts)
  call(opts, "comments", "get_comments", cb, key)
end

---@param cb fun(transitions: TrackerTransition[]|nil, err: string|nil)
function M.transitions(key, cb, opts)
  call(opts, "transitions", "get_transitions", cb, key)
end

---@param cb fun(users: TrackerUser[]|nil, err: string|nil)
function M.assignable_users(key, text, cb, opts)
  call(opts, "assign", "assignable_users", cb, key, text)
end

---@param cb fun(types: TrackerIssueType[]|nil, err: string|nil)
function M.issue_types(project, cb, opts)
  call(opts, "create", "issue_types", cb, project)
end

---@param cb fun(boards: TrackerBoard[]|nil, err: string|nil)
function M.boards(project, cb, opts)
  call(opts, "boards", "boards", cb, project)
end

---Everything a board view needs in one call.
---@param board_id string
---@param cb fun(board: { name: string?, columns: TrackerColumn[], sprint: TrackerSprint?, issues: TrackerIssue[] }|nil, err: string|nil)
function M.board(board_id, cb, opts)
  local ctx, err = context(opts)
  if not ctx then return async_err(cb, err) end
  if not ctx.mod.capabilities.boards then
    return async_err(cb, ("tracker: %s does not support boards"):format(ctx.name))
  end
  local mod, cfg = ctx.mod, ctx.cfg
  mod.board_columns(cfg, board_id, function(columns, cerr, meta)
    if not columns then return cb(nil, cerr) end
    local function load(sprint)
      mod.board_issues(cfg, board_id, sprint and sprint.id or nil, function(issues, ierr)
        if not issues then return cb(nil, ierr) end
        for _, issue in ipairs(issues) do remember(issue.key) end
        cb({ name = meta and meta.name, columns = columns, sprint = sprint, issues = issues })
      end)
    end
    if not mod.capabilities.sprints then return load(nil) end
    -- Kanban boards answer the sprint endpoint with an error: treat that as
    -- "no sprint" rather than a failure.
    mod.active_sprints(cfg, board_id, function(sprints)
      load(sprints and sprints[1] or nil)
    end)
  end)
end

---@param cb fun(issues: TrackerIssue[]|nil, err: string|nil)
function M.backlog(board_id, cb, opts)
  call(opts, "backlog", "backlog", cb, board_id)
end

---@param cb fun(priorities: { id: string, name: string }[]|nil, err: string|nil)
function M.priorities(cb, opts)
  call(opts, "priority", "priorities", cb)
end

---Open epics of `project` (default: the provider's), newest first.
---@param cb fun(epics: TrackerEpic[]|nil, err: string|nil)
function M.epic_list(project, cb, opts)
  local ctx, err = context(opts)
  if not ctx then return async_err(cb, err) end
  project = project or ctx.cfg.project
  if not project then return async_err(cb, "tracker: no project given and providers." .. ctx.name .. ".project unset") end
  call(opts, "epic_link", "epic_list", cb, project)
end

---Epics with their colour, for list views.
---@param keys string[]
---@param cb fun(epics: table<string, TrackerEpic>|nil, err: string|nil)
function M.epics(keys, cb, opts)
  if #keys == 0 then return vim.schedule(function() cb({}) end) end
  call(opts, "epics", "epics", cb, keys)
end

---@class TrackerTimeline
---@field epics TrackerIssue[]                    rank order; `color` = epic colour index
---@field children table<string, TrackerIssue[]>  epic key → its issues, rank order

---What the timeline shows: the project's epics (open, plus those finished in
---the last `opts.done_days`) with dates, sprints and colour, and their
---child issues.
---@param cb fun(timeline: TrackerTimeline|nil, err: string|nil)
---@param opts { project: string?, done_days: integer?, provider: string? }|nil
function M.timeline(cb, opts)
  local ctx, err = context(opts)
  if not ctx then return async_err(cb, err) end
  local mod = ctx.mod
  if not mod.capabilities.timeline then
    return async_err(cb, ("tracker: %s has no timeline"):format(ctx.name))
  end
  local project = (opts and opts.project) or ctx.cfg.project
  if not project then return async_err(cb, "tracker: no project given and providers." .. ctx.name .. ".project unset") end
  mod.epic_issues(ctx.cfg, project, { done_days = opts and opts.done_days }, function(epics, eerr)
    if not epics then return cb(nil, eerr) end
    local keys = vim.tbl_map(function(e) return e.key end, epics)
    if #keys == 0 then return cb({ epics = {}, children = {} }) end
    local pending, colors, kids, failed = 2, nil, nil, nil
    local function step()
      pending = pending - 1
      if pending > 0 then return end
      if not kids then return cb(nil, failed) end
      for _, e in ipairs(epics) do
        local c = colors and colors[e.key]
        e.color = c and c.color or nil
      end
      local by = {}
      for _, i in ipairs(kids) do
        local p = i.parent and i.parent.key
        if p then
          by[p] = by[p] or {}
          table.insert(by[p], i)
        end
      end
      cb({ epics = epics, children = by })
    end
    mod.epics(ctx.cfg, keys, function(c)
      colors = c -- no colour is no reason to fail
      step()
    end)
    mod.children(ctx.cfg, keys, function(c, cerr)
      kids, failed = c, cerr
      step()
    end)
  end)
end

local downloads = {} ---@type table<string, function[]>  path → waiting callbacks

---Local copy of an attachment, downloaded once into
---stdpath("cache")/tracker/<provider>/ and reused afterwards.
---@param attachment TrackerAttachment|{ url: string }
---@param cb fun(path: string|nil, err: string|nil)
function M.attachment_path(attachment, cb, opts)
  local ctx, err = context(opts)
  if not ctx then return async_err(cb, err) end
  if not ctx.mod.capabilities.attachments then
    return async_err(cb, ("tracker: %s does not support attachments"):format(ctx.name))
  end
  local name
  if attachment.id then
    name = attachment.id .. "-" .. (attachment.filename or "file")
  else
    -- external URL: stable name from its hash, keep the extension
    local ext = (attachment.url or ""):match("%.(%w+)$") or (attachment.url or ""):match("%.(%w+)%?") or "bin"
    name = "url-" .. vim.fn.sha256(attachment.url or ""):sub(1, 16) .. "." .. ext
  end
  name = name:gsub('[\\/:*?"<>|%c]', "_")
  local path = vim.fs.joinpath(vim.fn.stdpath("cache"), "tracker", ctx.name, name)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  if stat and stat.size > 0 then
    vim.schedule(function() cb(path) end)
    return
  end
  -- The same image can be asked for twice at once (description + comment):
  -- one download, every caller answered.
  if downloads[path] then
    table.insert(downloads[path], cb)
    return
  end
  downloads[path] = { cb }
  ctx.mod.download_attachment(ctx.cfg, attachment, path, function(p, derr)
    local waiting = downloads[path]
    downloads[path] = nil
    for _, w in ipairs(waiting) do w(p, derr) end
  end)
end

-- endregion

-- region Mutations (each emits its event on success)

---@param target string  transition id, transition name, or target status name
---@param cb fun(transition: TrackerTransition|nil, err: string|nil)
function M.transition(key, target, cb, opts)
  M.transitions(key, function(list, err, _, ctx)
    if not list then return cb(nil, err) end
    local wanted = tostring(target):lower()
    local found
    for _, t in ipairs(list) do
      if t.id == tostring(target) or t.name:lower() == wanted then found = t break end
    end
    if not found then
      for _, t in ipairs(list) do
        if t.to and t.to.name:lower() == wanted then found = t break end
      end
    end
    if not found then
      -- without a leading emoji / symbol: "IN_PROGRESS" finds "👨🏻‍💻 IN_PROGRESS"
      local function bare(s) return (s:lower():gsub("^[^%w]+", "")) end
      for _, t in ipairs(list) do
        if bare(t.name) == bare(wanted) or (t.to and bare(t.to.name) == bare(wanted)) then found = t break end
      end
    end
    if not found then
      local names = vim.tbl_map(function(t) return t.name end, list)
      return cb(nil, ("tracker: %s has no transition %q (available: %s)"):format(key, target, table.concat(names, ", ")))
    end
    call(opts, "transitions", "transition", function(ok, terr)
      if not ok then return cb(nil, terr) end
      events.emit(events.TRANSITIONED, { provider = ctx.name, key = key, transition = found, status = found.to })
      cb(found)
    end, key, found.id)
  end, opts)
end

---@param user string|TrackerUser|nil  user id, a user table, "me", or nil to unassign
---@param cb fun(assignee: TrackerUser|false|nil, err: string|nil)  false = unassigned
function M.assign(key, user, cb, opts)
  local function run(u)
    local id = type(u) == "table" and u.id or u
    call(opts, "assign", "assign", function(ok, err, _, ctx)
      if not ok then return cb(nil, err) end
      local assignee = type(u) == "table" and u or (u and { id = u, name = u }) or nil
      events.emit(events.ASSIGNED, { provider = ctx.name, key = key, assignee = assignee })
      cb(assignee or false)
    end, key, id)
  end
  if user == "me" then
    M.myself(function(me, err)
      if not me then return cb(nil, err) end
      run(me)
    end, opts)
  else
    run(user)
  end
end

---@param cb fun(comment: TrackerComment|nil, err: string|nil)
function M.comment(key, markdown, cb, opts)
  if not markdown or vim.trim(markdown) == "" then return async_err(cb, "tracker: empty comment") end
  call(opts, "comments", "add_comment", function(c, err, _, ctx)
    if not c then return cb(nil, err) end
    events.emit(events.COMMENT_ADDED, { provider = ctx.name, key = key, comment = c })
    cb(c)
  end, key, markdown)
end

---@param cb fun(comment: TrackerComment|nil, err: string|nil)
function M.edit_comment(key, id, markdown, cb, opts)
  if not markdown or vim.trim(markdown) == "" then return async_err(cb, "tracker: empty comment") end
  call(opts, "edit_comments", "edit_comment", function(c, err, _, ctx)
    if not c then return cb(nil, err) end
    events.emit(events.COMMENT_EDITED, { provider = ctx.name, key = key, comment = c })
    cb(c)
  end, key, id, markdown)
end

---Delete a comment (Jira lets you delete your own; others need a permission).
function M.delete_comment(key, id, cb, opts)
  call(opts, "delete_comments", "delete_comment", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.COMMENT_DELETED, { provider = ctx.name, key = key, comment_id = id })
    cb(true)
  end, key, id)
end

---Link types of the provider ({ id, name, inward, outward }).
function M.link_types(cb, opts)
  call(opts, "links", "link_types", cb)
end

---Link `key` to another issue, read from `key`'s side.
---@param link { type: string, direction: "outward"|"inward", key: string }
---  type = link type name; "outward" → key blocks other, "inward" → key is blocked by other
function M.link(key, link, cb, opts)
  if link.key == key then return async_err(cb, "tracker: an issue can't link to itself") end
  call(opts, "links", "add_link", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.LINKED, { provider = ctx.name, key = key, link = link })
    cb(true)
  end, key, link)
end

---Remove a link (its id from issue.links).
function M.unlink(key, link_id, cb, opts)
  call(opts, "links", "delete_link", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.UNLINKED, { provider = ctx.name, key = key, link_id = link_id })
    cb(true)
  end, link_id)
end

---Add a web link (URL + title) to an issue, e.g. its merge request.
function M.add_web_link(key, url, title, cb, opts)
  call(opts, "remote_links", "add_remote_link", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.ISSUE_UPDATED, { provider = ctx.name, key = key, fields = { "remotelinks" } })
    cb(true)
  end, key, { url = url, title = title })
end

---Upload local files to an issue as attachments.
---@param paths string[]
---@param cb fun(atts: TrackerAttachment[]|nil, err: string|nil)
function M.upload(key, paths, cb, opts)
  if #paths == 0 then return async_err(cb, "tracker: no files") end
  call(opts, "upload", "upload_attachments", function(atts, err, _, ctx)
    if not atts then return cb(nil, err) end
    events.emit(events.ATTACHED, { provider = ctx.name, key = key, attachments = atts })
    cb(atts)
  end, key, paths)
end

function M.delete_attachment(key, id, cb, opts)
  call(opts, "upload", "delete_attachment", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.ATTACHMENT_DELETED, { provider = ctx.name, key = key, attachment_id = id })
    cb(true)
  end, id)
end

---Clone `key` under a new summary: fields and description as they are;
---`opts.link` ("clones" link to the original), `opts.subtasks` (the
---sub-tasks too). Emits TrackerIssueCreated for the clone (+ clone_of) and
---each cloned sub-task.
---@param opts { summary: string, link: boolean?, subtasks: boolean? }
---@param cb fun(res: { id: string, key: string, url: string, subtasks: string[], dropped: string[], failed: string[] }|nil, err: string|nil)
function M.clone(key, opts, cb, popts)
  if not opts.summary or vim.trim(opts.summary) == "" then return async_err(cb, "tracker: empty summary") end
  call(popts, "clone", "clone_issue", function(res, err, _, ctx)
    if not res then return cb(nil, err) end
    remember(res.key)
    events.emit(events.ISSUE_CREATED, { provider = ctx.name, key = res.key, clone_of = key,
                                        issue = { id = res.id, key = res.key, url = res.url } })
    for _, sk in ipairs(res.subtasks) do
      events.emit(events.ISSUE_CREATED, { provider = ctx.name, key = sk, clone_of = key, parent = res.key, issue = { key = sk } })
    end
    cb(res)
  end, key, opts)
end

---@param fields { summary: string?, description: string?, priority_id: string?, story_points: number|false|nil,
---  labels: string[]?, parent: string|false|nil, reporter_id: string? }  false clears a field
---@param cb fun(ok: boolean|nil, err: string|nil)
function M.update(key, fields, cb, opts)
  call(opts, "edit", "update_issue", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.ISSUE_UPDATED, { provider = ctx.name, key = key, fields = vim.tbl_keys(fields) })
    cb(true)
  end, key, fields)
end

---@param fields { project: string?, type: string?, type_id: string?, summary: string, description: string?, parent: string? }
---  `type` is an issue type name ("Task"); `project` defaults to the provider's.
---@param cb fun(issue: { id: string, key: string, url: string }|nil, err: string|nil)
function M.create(fields, cb, opts)
  local ctx, err = context(opts)
  if not ctx then return async_err(cb, err) end
  local project = fields.project or ctx.cfg.project
  if not project then return async_err(cb, "tracker: no project given and providers." .. ctx.name .. ".project unset") end
  if not fields.summary or vim.trim(fields.summary) == "" then return async_err(cb, "tracker: empty summary") end

  local function run(type_id)
    local f = vim.tbl_extend("force", fields, { project = project, type_id = type_id })
    call(opts, "create", "create_issue", function(issue, cerr)
      if not issue then return cb(nil, cerr) end
      remember(issue.key)
      events.emit(events.ISSUE_CREATED, { provider = ctx.name, key = issue.key, issue = issue })
      cb(issue)
    end, f)
  end

  if fields.type_id then return run(fields.type_id) end
  M.issue_types(project, function(types, terr)
    if not types then return cb(nil, terr) end
    local wanted = (fields.type or (fields.parent and "sub-task") or "task"):lower()
    for _, t in ipairs(types) do
      if t.name:lower() == wanted then return run(t.id) end
    end
    if fields.parent then
      for _, t in ipairs(types) do
        if t.subtask then return run(t.id) end
      end
    end
    cb(nil, ("tracker: project %s has no issue type %q"):format(project, wanted))
  end, opts)
end

-- endregion

-- region Planning (each emits its event on success)

---Re-rank `keys` (in this order) right after / before another issue.
---@param where { after: string? , before: string? }
---@param cb fun(ok: boolean|nil, err: string|nil)
function M.rank(keys, where, cb, opts)
  if #keys == 0 then return async_err(cb, "tracker: nothing to move") end
  call(opts, "rank", "rank", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.RANKED, { provider = ctx.name, key = keys[1], keys = keys, after = where.after, before = where.before })
    cb(true)
  end, keys, where)
end

---Active and future sprints of the provider's board (`opts.board` overrides).
---@param cb fun(sprints: TrackerSprint[]|nil, err: string|nil)
function M.open_sprints(cb, opts)
  local ctx, err = context(opts)
  if not ctx then return async_err(cb, err) end
  local board = (opts and opts.board) or ctx.cfg.board
  if not board then return async_err(cb, "tracker: no board — set providers." .. ctx.name .. ".board") end
  call(opts, "sprint_move", "open_sprints", cb, tostring(board))
end

---@param sprint TrackerSprint
function M.move_to_sprint(sprint, keys, cb, opts)
  call(opts, "sprint_move", "move_to_sprint", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.MOVED, { provider = ctx.name, key = keys[1], keys = keys, sprint = sprint })
    cb(true)
  end, sprint.id, keys)
end

function M.move_to_backlog(keys, cb, opts)
  call(opts, "sprint_move", "move_to_backlog", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.MOVED, { provider = ctx.name, key = keys[1], keys = keys, backlog = true })
    cb(true)
  end, keys)
end

function M.archive(keys, cb, opts)
  call(opts, "archive", "archive", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.ARCHIVED, { provider = ctx.name, key = keys[1], keys = keys })
    cb(true)
  end, keys)
end

---Delete an issue for good (sub-tasks too with `with_subtasks`).
function M.delete(key, with_subtasks, cb, opts)
  call(opts, "delete", "delete_issue", function(ok, err, _, ctx)
    if not ok then return cb(nil, err) end
    events.emit(events.DELETED, { provider = ctx.name, key = key, with_subtasks = with_subtasks })
    cb(true)
  end, key, with_subtasks)
end

-- endregion

-- region Sprints (create / edit / start / complete)

---The board the sprint calls work on: `opts.board`, else the provider's.
local function board_ctx(opts, capability)
  local ctx, err = context(opts)
  if not ctx then return nil, err end
  if not ctx.mod.capabilities[capability] then
    return nil, ("tracker: %s does not support %s"):format(ctx.name, capability)
  end
  local board = (opts and opts.board) or ctx.cfg.board
  if not board then return nil, "tracker: no board — set providers." .. ctx.name .. ".board" end
  return ctx, nil, tostring(board)
end

---Every sprint of the board (closed, active, future — the board's order).
---@param cb fun(sprints: TrackerSprint[]|nil, err: string|nil)
function M.sprints(cb, opts)
  local ctx, err, board = board_ctx(opts, "sprint_manage")
  if not ctx then return async_err(cb, err) end
  ctx.mod.sprints(ctx.cfg, board, cb)
end

---Issues of one sprint, in the board's (rank) order.
---@param sprint TrackerSprint
function M.sprint_issues(sprint, cb, opts)
  local ctx, err, board = board_ctx(opts, "sprints")
  if not ctx then return async_err(cb, err) end
  ctx.mod.board_issues(ctx.cfg, sprint.board_id or board, sprint.id, function(issues, ierr)
    if not issues then return cb(nil, ierr) end
    for _, i in ipairs(issues) do remember(i.key) end
    cb(issues)
  end)
end

---@param fields TrackerSprintFields
---@param cb fun(sprint: TrackerSprint|nil, err: string|nil)
function M.create_sprint(fields, cb, opts)
  local ctx, err, board = board_ctx(opts, "sprint_manage")
  if not ctx then return async_err(cb, err) end
  ctx.mod.create_sprint(ctx.cfg, board, fields, function(sprint, cerr)
    if not sprint then return cb(nil, cerr) end
    events.emit(events.SPRINT_CREATED, { provider = ctx.name, sprint = sprint })
    cb(sprint)
  end)
end

---Edit name / goal / dates of an active or future sprint.
---@param sprint TrackerSprint
---@param fields TrackerSprintFields
function M.update_sprint(sprint, fields, cb, opts)
  local ctx, err = board_ctx(opts, "sprint_manage")
  if not ctx then return async_err(cb, err) end
  ctx.mod.update_sprint(ctx.cfg, sprint.id, fields, function(updated, uerr)
    if not updated then return cb(nil, uerr) end
    events.emit(events.SPRINT_UPDATED, { provider = ctx.name, sprint = updated })
    cb(updated)
  end)
end

---Start a future sprint; `fields` must carry both dates (plus any edits).
---@param sprint TrackerSprint
---@param fields TrackerSprintFields
function M.start_sprint(sprint, fields, cb, opts)
  local ctx, err = board_ctx(opts, "sprint_manage")
  if not ctx then return async_err(cb, err) end
  if not fields.start_date or not fields.end_date then
    return async_err(cb, "tracker: a sprint needs a start and an end date to start")
  end
  local body = vim.tbl_extend("force", fields, { state = "active" })
  ctx.mod.update_sprint(ctx.cfg, sprint.id, body, function(started, serr)
    if not started then return cb(nil, serr) end
    events.emit(events.SPRINT_STARTED, { provider = ctx.name, sprint = started })
    cb(started)
  end)
end

---Name for a sprint created after `sprints`: the newest one's number + 1
---("#60 Spring cleanup" → "#61", "ABC Sprint 7" → "ABC Sprint 8"),
---else "<project> Sprint N".
---@param sprints TrackerSprint[]
---@param project string|nil
---@return string
function M.next_sprint_name(sprints, project)
  local newest
  for _, s in ipairs(sprints) do
    if not newest or (tonumber(s.id) or 0) > (tonumber(newest.id) or 0) then newest = s end
  end
  if newest then
    local n = newest.name:match("^#(%d+)")
    if n then return "#" .. (tonumber(n) + 1) end
    local prefix, m = newest.name:match("^(.-)(%d+)%s*$")
    if m then return prefix .. (tonumber(m) + 1) end
  end
  return ("%s Sprint %d"):format(project or "Sprint", #sprints + 1)
end

---@class TrackerCompletePlan
---@field sprint TrackerSprint
---@field done TrackerIssue[]       in the board's last column
---@field open TrackerIssue[]       everything else (sub-tasks excluded: they follow their parent)
---@field target TrackerSprint|nil  first future sprint, nil = create `new_name`
---@field new_name string|nil

---What completing `sprint` would do — no changes yet. "Done" means the
---board's last column, as Jira counts it (status category when the board
---has no columns).
---@param sprint TrackerSprint
---@param cb fun(plan: TrackerCompletePlan|nil, err: string|nil)
function M.complete_plan(sprint, cb, opts)
  local ctx, err, board = board_ctx(opts, "sprint_manage")
  if not ctx then return async_err(cb, err) end
  local mod, cfg = ctx.mod, ctx.cfg
  mod.board_columns(cfg, board, function(columns)
    local last = columns and columns[#columns]
    local done_ids = {}
    for _, id in ipairs(last and last.statuses or {}) do done_ids[id] = true end
    local function is_done(i)
      if last then return i.status and done_ids[i.status.id] or false end
      return i.status and i.status.category == "done" or false
    end
    mod.board_issues(cfg, board, sprint.id, function(issues, ierr)
      if not issues then return cb(nil, ierr) end
      mod.sprints(cfg, board, function(sprints, serr)
        if not sprints then return cb(nil, serr) end
        local plan = { sprint = sprint, done = {}, open = {} }
        for _, i in ipairs(issues) do
          local sub = i.type and (i.type.subtask or (i.type.level or 0) < 0)
          if not sub then table.insert(is_done(i) and plan.done or plan.open, i) end
        end
        for _, s in ipairs(sprints) do
          if s.state == "future" and s.id ~= sprint.id then
            plan.target = s
            break
          end
        end
        if not plan.target then plan.new_name = M.next_sprint_name(sprints, cfg.project) end
        cb(plan)
      end)
    end)
  end)
end

---Complete the sprint of `plan` (from complete_plan): its open issues go to
---the next future sprint — created when there is none — then it closes.
---@param plan TrackerCompletePlan
---@param cb fun(result: { sprint: TrackerSprint, target: TrackerSprint|nil, moved: string[] }|nil, err: string|nil)
function M.complete_sprint(plan, cb, opts)
  local ctx, err, board = board_ctx(opts, "sprint_manage")
  if not ctx then return async_err(cb, err) end
  local mod, cfg = ctx.mod, ctx.cfg
  local keys = vim.tbl_map(function(i) return i.key end, plan.open)

  local function close(target)
    mod.update_sprint(cfg, plan.sprint.id, { state = "closed" }, function(closed, cerr)
      if not closed then return cb(nil, cerr) end
      events.emit(events.SPRINT_COMPLETED, { provider = ctx.name, sprint = closed, moved = keys, target = target })
      cb({ sprint = closed, target = target, moved = keys })
    end)
  end
  -- Jira moves at most 50 issues per call.
  local function move(target, from)
    if from > #keys then return close(target) end
    mod.move_to_sprint(cfg, target.id, vim.list_slice(keys, from, from + 49), function(ok, merr)
      if not ok then return cb(nil, merr) end
      move(target, from + 50)
    end)
  end

  if #keys == 0 then return close(nil) end
  if plan.target then return move(plan.target, 1) end
  mod.create_sprint(cfg, board, { name = plan.new_name }, function(created, cerr)
    if not created then return cb(nil, cerr) end
    events.emit(events.SPRINT_CREATED, { provider = ctx.name, sprint = created })
    move(created, 1)
  end)
end

-- endregion

return M
