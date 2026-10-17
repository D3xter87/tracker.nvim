-- ============================================================================
-- tracker.nvim — issue tracker client for Neovim (Jira Cloud, GitLab)
-- ============================================================================
-- Entry points for views. The real work lives in:
--   tracker.api        public Lua API (stable; every mutation emits an event)
--   tracker.providers  one module per tracker, behind a shared interface
--   tracker.resolve    which providers a repository works with (the tabs)
--   tracker.ui.*       floating views (list, issue, board, editor)
--   tracker.status     current-branch issue for statuslines
--
-- The plugin ships no commands or keymaps and no site data: those belong to
-- the user's config (see |tracker-config|). Auth comes from netrc or env.
-- ============================================================================

local M = {}

---@param opts table|nil  see |tracker-config|
function M.setup(opts)
  require("tracker.config").setup(opts)
  require("tracker.resolve").invalidate()
  require("tracker.ui.highlights").setup()
end

local function ready()
  require("tracker.ui.highlights").setup()
  return true
end

---Run `fn` as an entry point of `provider`'s tab (nil = the tab shown, or
---the first provider when no tracker window is open): the views it opens go
---to that tab and bring it up, once the provider knows what it can do here.
---@param provider string|nil
---@param fn fun()
local function enter(provider, fn)
  ready()
  local api = require("tracker.api")
  local scope = require("tracker.ui.window").intend(provider)
  api.with_scope(scope, function() api.ready(fn) end)
end

---The issue of the current branch, asked of every provider of the directory
---(not just the one whose tab a tracker window shows).
local function branch_issue()
  local api = require("tracker.api")
  local scope = api.current_scope()
  return api.with_scope({ cwd = scope and scope.cwd or nil }, api.branch_issue)
end

---Open an issue by key: "ABC-12", "#34", or "<provider>:<key>" to say
---which tracker. With several providers the key's shape picks the tab.
---@param key string
function M.issue(key)
  local api = require("tracker.api")
  local provider, parsed = api.owner(key)
  enter(provider, function()
    require("tracker.ui.issue").open(parsed or key)
  end)
end

---Smart entry: `key` → that issue; no key → the current branch's issue (a
---key of one of the repository's boards, see tracker.boards) on top of the
---`ui.issue_base` view (its board / the default query), so back goes there;
---the default query when the branch has none.
---@param key string|nil
function M.open(key)
  if key and key ~= "" then return M.issue(key) end
  local found = branch_issue()
  if not found then return M.search() end
  enter(found.provider, function()
    local base = require("tracker.config").get().ui.issue_base
    if base == "board" then
      require("tracker.ui.board").open_at(found.key, found.board_name)
    elseif base == "search" then
      require("tracker.ui.list").search(nil, false, found.key)
    end
    require("tracker.ui.issue").open(found.key)
  end)
end

---List view for a saved query name or raw query (JQL, a GitLab filter).
---nil = `default_query`, else the first saved query.
---@param query string|nil
---@param opts { provider: string? }|nil
function M.search(query, opts)
  enter(opts and opts.provider, function()
    require("tracker.ui.list").search(query)
  end)
end

---Pick a saved query (or type one), then list it.
function M.pick_query()
  enter(nil, function()
    require("tracker.ui.list").pick_query(function(q) require("tracker.ui.list").search(q) end)
  end)
end

---Board / active sprint view.
---@param opts { board_id: string?, project: string?, provider: string? }|nil
function M.board(opts)
  enter(opts and opts.provider, function()
    require("tracker.ui.board").open(opts)
  end)
end

---Sprints of the board: create / edit / start / complete.
---@param opts { board_id: string?, provider: string? }|nil
function M.sprints(opts)
  enter(opts and opts.provider, function()
    require("tracker.ui.sprints").open(opts)
  end)
end

---Timeline: epics (and their issues) as bars over time.
---@param opts { project: string?, provider: string? }|nil
function M.timeline(opts)
  enter(opts and opts.provider, function()
    require("tracker.ui.timeline").open(opts)
  end)
end

---Create an issue (sub-task when `opts.parent` is a key), then open it.
---@param opts { project: string?, parent: string?, provider: string? }|nil
function M.create(opts)
  enter(opts and opts.provider, function()
    require("tracker.ui.actions").create(opts, function(issue)
      require("tracker.ui.issue").open(issue.key)
    end)
  end)
end

---Switch the tracker window to another provider's tab: its number (1 = the
---first) or its name. What the keys of `ui.tab_keys` do.
---@param target integer|string
---@return boolean  false: no such tab, or no tracker window
function M.tab(target)
  ready()
  return require("tracker.ui.window").switch_tab(target)
end

---Open an issue (default: the current branch's) in the browser.
---@param key string|nil
function M.web(key)
  local api = require("tracker.api")
  local provider
  if key and key ~= "" then
    local owner, parsed = api.owner(key)
    provider, key = owner, parsed or key
  else
    local found = branch_issue()
    key, provider = found and found.key, found and found.provider
  end
  if not key then
    return require("tracker.notify").error("tracker: no issue key given and none in the branch name")
  end
  local scope = api.current_scope()
  if provider then scope = { provider = provider, cwd = scope and scope.cwd or nil } end
  api.with_scope(scope, function() require("tracker.ui.actions").web(key) end)
end

---Command-line completion helper: saved query names, the branch key and
---recently seen keys that start with `arg_lead` — of every provider of the
---directory.
---@param arg_lead string
---@param what "keys"|"queries"|nil  nil = both
---@return string[]
function M.complete(arg_lead, what)
  local api = require("tracker.api")
  local out, seen = {}, {}
  local function push(s)
    if s and not seen[s] and (arg_lead == "" or s:lower():find(arg_lead:lower(), 1, true) == 1) then
      seen[s] = true
      table.insert(out, s)
    end
  end
  local names = api.active_providers()
  if #names == 0 then names = { false } end
  if what ~= "queries" then push((branch_issue() or {}).key) end
  for _, name in ipairs(names) do
    local opts = name and { provider = name } or nil
    if what ~= "keys" then
      for _, q in ipairs(api.queries(vim.tbl_extend("force", opts or {}, { all_boards = true }))) do push(q.name) end
    end
    if what ~= "queries" then
      for _, k in ipairs(api.recent_keys(opts)) do push(k) end
    end
  end
  return out
end

return setmetatable(M, {
  __index = function(_, k)
    if k == "api" then return require("tracker.api") end
    if k == "status" then return require("tracker.status") end
  end,
})
