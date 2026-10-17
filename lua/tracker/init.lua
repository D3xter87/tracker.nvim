-- ============================================================================
-- tracker.nvim — issue tracker client for Neovim (Jira Cloud first)
-- ============================================================================
-- Entry points for views. The real work lives in:
--   tracker.api        public Lua API (stable; every mutation emits an event)
--   tracker.providers  one module per tracker, behind a shared interface
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
  require("tracker.ui.highlights").setup()
end

local function ready()
  require("tracker.ui.highlights").setup()
  return true
end

---Open an issue by key.
---@param key string
function M.issue(key)
  ready()
  require("tracker.ui.issue").open(key)
end

---Smart entry: `key` → that issue; no key → the current branch's issue (a
---key of one of the repository's boards, see tracker.boards), or the default
---query when the branch has none.
---@param key string|nil
function M.open(key)
  ready()
  key = (key and key ~= "") and key or require("tracker.api").current_issue_key()
  if key then return M.issue(key) end
  M.search()
end

---List view for a saved query name or raw query (JQL). nil = `default_query`,
---else the first saved query.
---@param query string|nil
function M.search(query)
  ready()
  require("tracker.ui.list").search(query)
end

---Pick a saved query (or type one), then list it.
function M.pick_query()
  ready()
  require("tracker.ui.list").pick_query(function(q) M.search(q) end)
end

---Board / active sprint view.
---@param opts { board_id: string?, project: string? }|nil
function M.board(opts)
  ready()
  require("tracker.ui.board").open(opts)
end

---Sprints of the board: create / edit / start / complete.
---@param opts { board_id: string? }|nil
function M.sprints(opts)
  ready()
  require("tracker.ui.sprints").open(opts)
end

---Timeline: epics (and their issues) as bars over time.
---@param opts { project: string? }|nil
function M.timeline(opts)
  ready()
  require("tracker.ui.timeline").open(opts)
end

---Create an issue (sub-task when `opts.parent` is a key), then open it.
---@param opts { project: string?, parent: string? }|nil
function M.create(opts)
  ready()
  require("tracker.ui.actions").create(opts, function(issue)
    require("tracker.ui.issue").open(issue.key)
  end)
end

---Open an issue (default: the current branch's) in the browser.
---@param key string|nil
function M.web(key)
  key = (key and key ~= "") and key or require("tracker.api").current_issue_key()
  if not key then
    return require("tracker.notify").error("tracker: no issue key given and none in the branch name")
  end
  require("tracker.ui.actions").web(key)
end

---Command-line completion helper: saved query names, the branch key and
---recently seen keys that start with `arg_lead`.
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
  if what ~= "keys" then
    for _, q in ipairs(api.queries({ all_boards = true })) do push(q.name) end
  end
  if what ~= "queries" then
    push(api.current_issue_key())
    for _, k in ipairs(api.recent_keys()) do push(k) end
  end
  return out
end

return setmetatable(M, {
  __index = function(_, k)
    if k == "api" then return require("tracker.api") end
    if k == "status" then return require("tracker.status") end
  end,
})
