-- Git helpers: the issue key a branch belongs to, the branches of an issue,
-- what a merge brought in.

local M = {}

---`git <args>` in `cwd`, waited for.
---@param args string[]
---@param cwd string|nil
---@return integer code  -1 when git couldn't run
---@return string out    trimmed stdout (with stderr when it failed)
function M.run(args, cwd)
  local ok, res = pcall(function()
    return vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait(10000)
  end)
  if not ok or not res then return -1, "" end
  local out = vim.trim(res.stdout or "")
  if res.code ~= 0 and res.stderr and res.stderr ~= "" then out = vim.trim(out .. "\n" .. res.stderr) end
  return res.code, out
end

---Lines of a successful `git <args>`; {} on a failure.
local function lines(args, cwd)
  local code, out = M.run(args, cwd)
  if code ~= 0 or out == "" then return {} end
  return vim.split(out, "\n", { plain = true })
end

---@param cwd string|nil
---@return string|nil branch  nil outside a repo or on a detached HEAD
function M.current_branch(cwd)
  local ok, res = pcall(function()
    return vim.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, { cwd = cwd, text = true }):wait(2000)
  end)
  if not ok or not res or res.code ~= 0 then return nil end
  local branch = vim.trim(res.stdout or "")
  if branch == "" or branch == "HEAD" then return nil end
  return branch
end

---Top directory of the repository `cwd` is in.
---@return string|nil
function M.root(cwd)
  local ok, res = pcall(function()
    return vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd, text = true }):wait(2000)
  end)
  if not ok or not res or res.code ~= 0 then return nil end
  local root = vim.trim(res.stdout or "")
  return root ~= "" and root or nil
end

---A command's program, runnable by vim.system. On Windows `bash` / `sh`
---become Git for Windows' own when they aren't on PATH (Neovim usually only
---has Git\cmd there) or are WSL's launcher, which can't run Windows paths.
---@param prog string
---@return string
function M.program(prog)
  if vim.fn.has("win32") == 0 or (prog ~= "bash" and prog ~= "sh") then return prog end
  local found = vim.fn.exepath(prog):lower():gsub("\\", "/")
  if found ~= "" and not found:find("/windows/system32/", 1, true) and not found:find("/windowsapps/", 1, true) then
    return prog
  end
  local ok, res = pcall(function()
    return vim.system({ "git", "--exec-path" }, { text = true }):wait(2000)
  end)
  if not ok or not res or res.code ~= 0 then return prog end
  -- <Git>/mingw64/libexec/git-core → <Git>
  local top = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.trim(res.stdout or "")))))
  for _, dir in ipairs({ "/bin/", "/usr/bin/" }) do
    local exe = top .. dir .. prog .. ".exe"
    if vim.fn.executable(exe) == 1 then return exe end
  end
  return prog
end

local ASCII = {
  ["ą"] = "a", ["ć"] = "c", ["ę"] = "e", ["ł"] = "l", ["ń"] = "n", ["ó"] = "o", ["ś"] = "s", ["ź"] = "z", ["ż"] = "z",
  ["Ą"] = "a", ["Ć"] = "c", ["Ę"] = "e", ["Ł"] = "l", ["Ń"] = "n", ["Ó"] = "o", ["Ś"] = "s", ["Ź"] = "z", ["Ż"] = "z",
}

---A summary as a branch-safe slug: lower-case ascii, words joined by "-",
---at most `max` characters, cut at a word boundary ("Login form: ACME &
---Partners" → "login-form-acme-partners").
---@param s string
---@param max integer|nil  default 40
---@return string
function M.slug(s, max)
  max = max or 40
  -- two-byte UTF-8 letters: Polish ones to ascii, the rest dropped
  s = (s or ""):gsub("[\195-\197][\128-\191]", function(c) return ASCII[c] or "" end)
  s = s:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if #s > max then
    s = s:sub(1, max)
    s = s:match("^(.*)%-[^%-]*$") or s
  end
  return s
end

---Branch name for an issue from a template ({key} {key_lower} {slug} {type}).
---@param template string
---@param issue { key: string, summary: string?, type: { name: string? }? }
---@return string
function M.branch_name(template, issue)
  local vals = {
    key = issue.key,
    key_lower = issue.key:lower(),
    slug = M.slug(issue.summary or ""),
    type = M.slug(issue.type and issue.type.name or "", 20),
  }
  local out = template:gsub("{([%w_]+)}", function(k) return vals[k] end)
  return (out:gsub("%-+$", ""))
end

---Extract an issue key from a branch name. The branch is upper-cased first so
---`abc-123-feat` and `feature/ABC-123` both give ABC-123. With a project
---list, only keys of those projects count — this keeps `release-2` from
---reading as an issue.
---@param branch string|nil
---@param pattern string        Lua pattern, see config.issue_key_pattern
---@param projects string[]|nil allowed project keys
---@return string|nil
function M.issue_key(branch, pattern, projects)
  if not branch or branch == "" then return nil end
  local upper = branch:upper()
  local allowed
  if projects and #projects > 0 then
    allowed = {}
    for _, p in ipairs(projects) do allowed[p:upper()] = true end
  end
  for key in upper:gmatch(pattern) do
    local project = key:match("^(.-)%-%d+$")
    if not allowed or allowed[project] then
      return key
    end
  end
  return nil
end

---Whether `branch` names issue `key` anywhere (`feature/ABC-1-x`, `abc-1`;
---`abc-12` is not ABC-1).
---@param branch string|nil
---@param key string
---@param pattern string  see config.issue_key_pattern
---@return boolean
function M.has_key(branch, key, pattern)
  for k in (branch or ""):upper():gmatch(pattern) do
    if k == key:upper() then return true end
  end
  return false
end

---Whether the repository has a remote called `remote`.
function M.has_remote(root, remote)
  return vim.tbl_contains(lines({ "remote" }, root), remote)
end

---@class TrackerBranchRef
---@field name string        without "<remote>/"
---@field has_local boolean
---@field has_remote boolean  <remote>/<name> exists

---The local and `remote` branches of issue `key`: `preferred` (the
---configured name) first, then local ones, then by name.
---@param root string
---@param key string
---@param pattern string
---@param preferred string|nil
---@param remote string
---@return TrackerBranchRef[]
function M.issue_branches(root, key, pattern, preferred, remote)
  local by_name, list = {}, {}
  local prefix = "refs/remotes/" .. remote .. "/"
  for _, ref in ipairs(lines({ "for-each-ref", "--format=%(refname)", "refs/heads", prefix }, root)) do
    local name, remote_ref = ref:match("^refs/heads/(.+)$"), false
    if not name and vim.startswith(ref, prefix) then name, remote_ref = ref:sub(#prefix + 1), true end
    if name and name ~= "HEAD" and M.has_key(name, key, pattern) then
      local b = by_name[name]
      if not b then
        b = { name = name, has_local = false, has_remote = false }
        by_name[name] = b
        table.insert(list, b)
      end
      if remote_ref then b.has_remote = true else b.has_local = true end
    end
  end
  table.sort(list, function(a, b)
    if (a.name == preferred) ~= (b.name == preferred) then return a.name == preferred end
    if a.has_local ~= b.has_local then return a.has_local end
    return a.name < b.name
  end)
  return list
end

---The branch <remote>/HEAD points at: the remote's default branch.
---@return string|nil
function M.remote_head(root, remote)
  local code, out = M.run({ "symbolic-ref", "--short", "refs/remotes/" .. remote .. "/HEAD" }, root)
  return code == 0 and vim.startswith(out, remote .. "/") and out:sub(#remote + 2) or nil
end

---Full hash of a commit-ish, nil when it doesn't name a commit.
---@return string|nil
function M.rev(root, ref)
  local code, out = M.run({ "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }, root)
  return code == 0 and out ~= "" and out or nil
end

---@return string|nil
function M.short(root, hash)
  local code, out = M.run({ "rev-parse", "--short", hash }, root)
  return code == 0 and out or nil
end

---Whether commit `a` is reachable from `b`.
function M.is_ancestor(root, a, b)
  return (M.run({ "merge-base", "--is-ancestor", a, b }, root)) == 0
end

---Whether `commit` lies on the first-parent line of `head` (committed or
---fast-forwarded there, not brought in by a merge).
function M.on_first_parent(root, commit, head)
  return vim.tbl_contains(lines({ "rev-list", "--first-parent", "--max-count=5000", head }, root), commit)
end

---Uncommitted changes to tracked files.
function M.dirty(root)
  local code, out = M.run({ "status", "--porcelain", "--untracked-files=no" }, root)
  return code == 0 and out ~= ""
end

---Commits of HEAD its upstream lacks; nil without an upstream.
---@return integer|nil
function M.unpushed(root)
  local code, out = M.run({ "rev-list", "--count", "@{u}..HEAD" }, root)
  return code == 0 and tonumber(out) or nil
end

---Subjects (newest first, merges left out) of `include` minus `exclude`
---(revisions, or `--` options such as `--branches`).
---@param include string
---@param exclude string[]
---@return string[]
function M.subjects(root, include, exclude)
  local args = { "log", "--no-merges", "--format=%s", include }
  if #exclude > 0 then
    table.insert(args, "--not")
    vim.list_extend(args, exclude)
  end
  return lines(args, root)
end

---Subjects of the commits HEAD (branch `branch`) has and no other local or
---remote branch: what merging it would bring in.
---@return string[]
function M.own_subjects(root, branch, remote)
  return M.subjects(root, "HEAD", {
    "--exclude=refs/heads/" .. branch, "--exclude=refs/remotes/" .. remote .. "/" .. branch, "--branches", "--remotes",
  })
end

---Subjects `tip` brought into HEAD by the oldest merge that took it in; {}
---when a fast-forward did (or it isn't in HEAD).
---@param exclude string[]  more revisions to leave out
---@return string[]
function M.merged_subjects(root, tip, exclude)
  local merges = lines({ "rev-list", "--merges", "--ancestry-path", "--reverse", tip .. "..HEAD" }, root)
  if not merges[1] then return {} end
  return M.subjects(root, tip, vim.list_extend({ merges[1] .. "^1" }, exclude))
end

---Web address of `remote` (`git@host:g/p.git`, `ssh://git@host:22/g/p` and
---`https://user@host/g/p.git` → `https://host/g/p`).
---@return string|nil
function M.web_url(root, remote)
  local code, url = M.run({ "remote", "get-url", remote }, root)
  if code ~= 0 or url == "" then return nil end
  url = url:gsub("%.git$", ""):gsub("/$", "")
  local host, path = url:match("^%w+://[^/]-@?([^/@:]+)[:%d]*/(.+)$")
  if not host then host, path = url:match("^[^@/]+@([^:/]+):(.+)$") end
  if not host then return nil end
  return "https://" .. host .. "/" .. path
end
return M
