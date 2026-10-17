-- Which providers a directory works with, and in what order.
--
-- Trackers that live with the code (GitLab, …) apply to a repository when
-- its git remote is on their host: their `detect` says so and tells what the
-- repository adds to the config (the project). A tracker without `detect`
-- (Jira) applies everywhere. With several providers each one is a tab of the
-- tracker window, in this order:
--
--   1. `repo_providers[<repository>]`, as listed — an explicit list wins;
--   2. otherwise every provider that applies: `default_provider` first, then
--      `provider_order`, then the registration order of the types (Jira,
--      GitLab, …) and the instance name.
--
-- A single configured provider is always the answer, as before.

local M = {}

local config = require("tracker.config")
local providers = require("tracker.providers")
local boards = require("tracker.boards")
local git = require("tracker.util.git")

---@class TrackerRepo
---@field root string
---@field host string|nil  host of the git remote (lower-case)
---@field path string|nil  path on that host, e.g. "group/sub/project"

---@type table<string, TrackerRepo>  git root → repository
local repos = {}

---The repository `cwd` is in, with where its remote (`git.remote`) points.
---Looked up once per repository.
---@param cwd string|nil
---@return TrackerRepo|nil
function M.repo(cwd)
  local root = boards.repo_root(cwd)
  if not root then return nil end
  if not repos[root] then
    local remote = config.git(root).remote or "origin"
    local info = git.remote_info(root, remote)
    repos[root] = { root = root, host = info and info.host or nil, path = info and info.path or nil }
  end
  return repos[root]
end

function M.invalidate()
  repos = {}
  boards.invalidate()
end

---Host of a URL, lower-case ("https://GitLab.com/x" → "gitlab.com").
---@param url string|nil
---@return string|nil
function M.host_of(url)
  local host = url and url:match("^%a[%w+.-]*://[^/]-@?([^/@:]+)") or nil
  return host and host:lower() or nil
end

---What the repository of `cwd` adds to an instance's config (e.g. its
---project), or nil when the provider isn't tied to repositories or this one
---isn't on its host.
---@param mod table   provider module
---@param pcfg table  resolved provider config
---@param cwd string|nil
---@return table|nil
function M.binding(mod, pcfg, cwd)
  if not mod.detect then return nil end
  local repo = M.repo(cwd)
  return repo and mod.detect(pcfg, repo) or nil
end

---Whether an instance has something to show in `cwd`.
local function applies(name, cwd)
  local ok, mod = pcall(providers.get, name)
  if not ok then return false end
  if not mod.detect then return true end
  local pcfg = config.provider(name)
  return pcfg.project ~= nil or M.binding(mod, pcfg, cwd) ~= nil
end

---`names` with `first` entries moved to the front, in their order.
local function promote(names, first)
  local out, seen = {}, {}
  for _, n in ipairs(first) do
    if not seen[n] and vim.tbl_contains(names, n) then
      seen[n] = true
      table.insert(out, n)
    end
  end
  for _, n in ipairs(names) do
    if not seen[n] then table.insert(out, n) end
  end
  return out
end

---The providers of `cwd`, in tab order. Second value: why (for
---:checkhealth).
---@param cwd string|nil
---@return string[] names, string reason
function M.active(cwd)
  local cfg = config.get()
  local names = providers.configured()
  local default = cfg.default_provider

  if cfg.repo_providers and next(cfg.repo_providers) then
    local entry = boards.repo_entry({ repos = cfg.repo_providers }, boards.repo_root(cwd))
    if entry then
      local listed = vim.tbl_filter(function(n) return vim.tbl_contains(names, n) end, entry)
      if #listed > 0 then return listed, "repo_providers" end
    end
  end

  local reason = "the only provider"
  if #names > 1 then
    local fit = vim.tbl_filter(function(n) return applies(n, cwd) end, names)
    if #fit > 0 then
      names, reason = fit, "every provider that applies here"
    else
      reason = "no provider applies here: all of them"
    end
  end

  local first = {}
  if default then table.insert(first, default) end
  vim.list_extend(first, cfg.provider_order or {})
  names = promote(names, first)
  -- a default that isn't configured (no base_url) still answers, as it always did
  if default and not vim.tbl_contains(providers.configured(), default) and pcall(providers.get, default) then
    table.insert(names, 1, default)
  end
  return names, reason
end

---The provider a call without one means.
---@param cwd string|nil
---@return string|nil
function M.primary(cwd)
  return (M.active(cwd))[1]
end

return M
