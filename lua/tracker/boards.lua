-- Several boards per provider, and which of them a git repository uses.
--
--   providers.<name>.boards = { CVNT = { board = 142 }, EP = { project = "EP", board = 147 } }
--   providers.<name>.repos  = { panel = { "CVNT", "EP" } }
--
-- A board's `tags` (default: its project) are the issue-key prefixes it owns
-- in branch names: in `panel`, cvnt-4598 opens CVNT-4598 and ep-4325 opens
-- EP-4325. The repository's first board is its main one — project, board,
-- queries and default_query of the views come from it. The branch only picks
-- which issue opens. A repository missing from `repos` recognises the keys of
-- every board and keeps the provider's own project / board / queries.

local M = {}

local git = require("tracker.util.git")

---@type table<string, string|false>  cwd → git root (false = not in a repo)
local roots = {}

---Git root of `cwd` (default: Neovim's), looked up once per directory.
---@param cwd string|nil
---@return string|nil
function M.repo_root(cwd)
  cwd = vim.fs.normalize(cwd or vim.fn.getcwd())
  if roots[cwd] == nil then roots[cwd] = git.root(cwd) or false end
  return roots[cwd] or nil
end

function M.invalidate()
  roots = {}
end

---@class TrackerBoardEntry
---@field name string
---@field project string
---@field board string|nil       board id
---@field tags string[]          issue-key prefixes in branch names
---@field queries table[]|nil    replaces the provider's saved queries
---@field default_query string|nil

---@param pcfg table  resolved provider config
---@param name string
---@return TrackerBoardEntry|nil
function M.get(pcfg, name)
  local b = pcfg.boards and pcfg.boards[name]
  if type(b) ~= "table" then return nil end
  local project = b.project or name
  return {
    name = name,
    project = project,
    board = b.board and tostring(b.board) or nil,
    tags = b.tags or { project },
    queries = b.queries,
    default_query = b.default_query,
  }
end

---Every configured board, by name.
---@return TrackerBoardEntry[]
function M.all(pcfg)
  local names = vim.tbl_keys(pcfg.boards or {})
  table.sort(names)
  local out = {}
  for _, n in ipairs(names) do table.insert(out, M.get(pcfg, n)) end
  return out
end

local function norm(p)
  if p:sub(1, 1) == "~" then p = vim.fn.expand(p) end
  p = vim.fs.normalize(p):gsub("/+$", "")
  if vim.fn.has("win32") == 1 then p = p:lower() end
  return p
end

---The `repos` entry of the repository at `root`: a key without a slash is
---the repository's directory name, one with a slash its path. A string value
---is one board.
---@param root string|nil
---@return table|nil
function M.repo_entry(pcfg, root)
  if not root or not pcfg.repos then return nil end
  local base, path = norm(vim.fs.basename(root)), norm(root)
  for k, v in pairs(pcfg.repos) do
    local is_path = k:find("[/\\]") ~= nil
    if norm(k) == (is_path and path or base) then
      return type(v) == "string" and { v } or v
    end
  end
  return nil
end

---Boards of the repository at `root`: those of its `repos` entry (main one
---first, unknown names skipped), else every board. Second value: the entry.
---@return TrackerBoardEntry[], table|nil
function M.for_repo(pcfg, root)
  local entry = M.repo_entry(pcfg, root)
  if not entry then return M.all(pcfg), nil end
  local out = {}
  for _, n in ipairs(entry) do
    local b = M.get(pcfg, n)
    if b then table.insert(out, b) end
  end
  return out, entry
end

---The board whose tags own `key`'s project prefix.
---@param key string|nil
---@param boards TrackerBoardEntry[]
---@return TrackerBoardEntry|nil
function M.of_key(key, boards)
  local prefix = key and key:match("^(.-)%-%d+$")
  if not prefix then return nil end
  for _, b in ipairs(boards) do
    for _, t in ipairs(b.tags) do
      if t:upper() == prefix:upper() then return b end
    end
  end
  return nil
end

---`pcfg` (a fresh copy from config.provider) as `board` sees it: its
---project, board id and queries. default_query: the repository entry's, then
---the board's, then the provider's.
---@param board TrackerBoardEntry
---@param entry table|nil  repos entry
---@return table pcfg
function M.overlay(pcfg, board, entry)
  pcfg.project = board.project
  pcfg.board = board.board
  if board.queries then pcfg.queries = vim.deepcopy(board.queries) end
  pcfg.default_query = (entry and entry.default_query) or board.default_query or pcfg.default_query
  pcfg.board_name = board.name
  return pcfg
end

return M
