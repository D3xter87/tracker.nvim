-- GitLab issue keys and the branches that name them.
--
-- An issue is `#123` inside the provider's project (the repository's own)
-- and `group/project#123` anywhere else — GitLab's own reference forms. A
-- bare `123` and an issue URL are read as keys too.
--
-- Branches: GitLab's "Create branch" names them `123-fix-login`; teams also
-- use `issue-123`, `issue-123-fix-login`, `feature/123-fix`. The patterns
-- are `providers.<name>.branch.patterns` (Lua patterns over the lower-cased
-- branch, one capture: the issue number; first match wins) minus
-- `branch.ignore` — `release-2` and `17-0-stable` are no issues.

local M = {}

M.PATTERNS = {
  "^(%d+)[-_]",                      -- 123-fix-login (GitLab's and GitHub's default)
  "^(%d+)$",                         -- 123
  "^issue[-_/]?(%d+)",               -- issue-123, issue-123-fix-login, issue/123
  "^%a[%w_.-]*/(%d+)[-_]",           -- feature/123-fix-login
  "^%a[%w_.-]*/(%d+)$",              -- feature/123
  "^%a[%w_.-]*/issue[-_/]?(%d+)",    -- feature/issue-123-fix
}

M.IGNORE = {
  "^release[-_/]", "^v?%d+%.%d", "^%d+[-_]%d+[-_]stable", "^%d%d%d%d[-_]%d%d",
  "^dependabot/", "^renovate/",
}

---Project path and number of a key ("#12" → the provider's project, "12").
---@param pcfg table
---@param key string
---@return string|nil project, string|nil iid
function M.split(pcfg, key)
  local project, iid = tostring(key or ""):match("^(.-)#(%d+)$")
  if not iid then return nil end
  if project == "" then project = pcfg.project end
  return project, iid
end

---A key as short as it can be: `#12` in the provider's project.
---@param pcfg table
---@param project string|nil
---@param iid string|integer
---@return string
function M.make(pcfg, project, iid)
  if not project or project == "" or project == pcfg.project then return "#" .. tostring(iid) end
  return project .. "#" .. tostring(iid)
end

---@return string|nil
function M.parse(pcfg, text)
  text = vim.trim(text or "")
  local iid = text:match("^#?(%d+)$")
  if iid then return "#" .. iid end
  local project, n = text:match("^([%w_.-][%w_./-]*)#(%d+)$")
  if project then return M.make(pcfg, project, n) end
  -- an issue URL of this instance: <base>/<project>/-/issues/<n> (older: /issues/<n>)
  local base = (pcfg.base_url or ""):gsub("/+$", "")
  if base ~= "" and text:sub(1, #base + 1) == base .. "/" then
    local rest = text:sub(#base + 2):gsub("[?#].*$", "")
    project, n = rest:match("^(.-)/%-/issues/(%d+)")
    if not project then project, n = rest:match("^(.-)/issues/(%d+)") end
    if project then return M.make(pcfg, project, n) end
  end
  return nil
end

function M.normalize(pcfg, text)
  return M.parse(pcfg, text) or vim.trim(text)
end

function M.project(pcfg, key)
  return (M.split(pcfg, key)) or pcfg.project
end

function M.normalize_project(_, text)
  return vim.trim(text)
end

---The first `#12` / `group/project#12` in a line.
function M.find(pcfg, text)
  for word in (text or ""):gmatch("[%w_./-]*#%d+") do
    local key = M.parse(pcfg, word)
    if key then return key end
  end
  return nil
end

---The issue number a branch names, by the provider's patterns.
---@return string|nil iid
function M.branch_iid(pcfg, branch)
  if not branch or branch == "" then return nil end
  local cfg = type(pcfg.branch) == "table" and pcfg.branch or {}
  local name = branch:lower()
  for _, p in ipairs(cfg.ignore or M.IGNORE) do
    if name:find(p) then return nil end
  end
  for _, p in ipairs(cfg.patterns or M.PATTERNS) do
    local s, e, iid = name:find(p)
    -- the number must end where the match does: `issue-12ab` is no issue 12
    if s and iid and not (name:sub(e, e):match("%d") and name:sub(e + 1, e + 1):match("%a")) then
      return iid
    end
  end
  return nil
end

function M.from_branch(pcfg, branch)
  if not pcfg.project then return nil end -- no repository of this instance: no issues to name
  local iid = M.branch_iid(pcfg, branch)
  return iid and ("#" .. iid) or nil
end

function M.in_branch(pcfg, branch, key)
  local project, iid = M.split(pcfg, key)
  if not iid or (project and pcfg.project and project ~= pcfg.project) then return false end
  return M.branch_iid(pcfg, branch) == iid
end

function M.branch_vars(pcfg, issue)
  local _, iid = M.split(pcfg, issue.key)
  iid = iid or issue.key
  return { key = iid, key_lower = iid, id = iid }
end

---Keys are unique within a project.
function M.scope(pcfg)
  return pcfg.project or ""
end

function M.restricted()
  return true
end

return M
