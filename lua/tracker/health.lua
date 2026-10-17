-- :checkhealth tracker

local M = {}

local health = vim.health

---Wait for an async call: `fn(done)`; nil when it never answered.
local function await(fn, ms)
  local done, res = false, nil
  fn(function(...)
    done, res = true, { ... }
  end)
  vim.wait(ms or 15000, function() return done end, 50)
  return done and res or nil
end

function M.check()
  health.start("tracker.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    local v = vim.version()
    health.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  else
    health.error("Neovim 0.10+ required (vim.system, vim.base64)")
  end

  if vim.fn.executable("curl") == 1 then
    health.ok("curl: " .. vim.fn.exepath("curl"))
  else
    health.error("curl not found on PATH")
  end

  local providers = require("tracker.providers")
  local configured = providers.configured()
  if #configured == 0 then
    health.warn("no provider configured", {
      'setup({ providers = { jira = { base_url = "https://<site>.atlassian.net" } } })',
      'setup({ providers = { gitlab = { base_url = "https://gitlab.com" } } })',
    })
    return
  end

  local config = require("tracker.config")
  local auth = require("tracker.http.auth")
  local api = require("tracker.api")
  local resolve = require("tracker.resolve")
  local keyrules = require("tracker.keys")

  -- Which of them this directory works with: the tabs of the tracker window.
  local active, reason = resolve.active()
  local repo = resolve.repo()
  if repo then
    health.info(("repository: %s%s"):format(repo.root, repo.host and (" → " .. repo.host .. ":" .. repo.path) or " (no remote)"))
  else
    health.info("not in a git repository")
  end
  local tabs = {}
  for n, name in ipairs(active) do table.insert(tabs, ("%d %s"):format(n, name)) end
  health.info(("providers here (%s): %s"):format(reason, table.concat(tabs, ", ")))
  if #active > 1 then
    for _, name in ipairs(active) do
      local pcfg = config.provider(name)
      if not keyrules.rules(providers.get(name)).restricted(pcfg) then
        health.warn(("%s reads any WORD-123 in a branch name as its issue, so next to another provider its branches aren't recognised")
          :format(name), { ("set providers.%s.projects (or boards) to the project keys that are its own"):format(name) })
      end
    end
  end

  for _, name in ipairs(configured) do
    health.start("tracker.nvim: " .. name)
    local pcfg = config.provider(name)
    local info = api.provider_info({ provider = name })
    if pcfg.type ~= name then health.info("type: " .. pcfg.type) end
    health.info("base_url: " .. pcfg.base_url)
    if info and info.project then
      health.info("project: " .. info.project .. (pcfg.project and "" or " (from the git remote)"))
    elseif providers.get(name).detect then
      health.info("project: none here (the repository isn't on this instance)")
    end
    if pcfg.boards then
      local boards = require("tracker.boards")
      for _, b in ipairs(boards.all(pcfg)) do
        health.info(("board %s: project %s, board %s, branch tags %s"):format(
          b.name, b.project, b.board or "-", table.concat(b.tags, ", ")))
      end
      for repo_name, names in pairs(pcfg.repos or {}) do
        for _, n in ipairs(type(names) == "string" and { names } or names) do
          if not boards.get(pcfg, n) then
            health.warn(("repos[%q] names board %q, which isn't in providers.%s.boards"):format(repo_name, n, name))
          end
        end
      end
      local root = boards.repo_root()
      local list, entry = boards.for_repo(pcfg, root)
      if entry then
        health.info(("this repository (%s) uses: %s"):format(vim.fs.basename(root),
          table.concat(vim.tbl_map(function(b) return b.name end, list), ", ")))
      end
    end

    local creds, err = auth.credentials(name, pcfg)
    if not creds then
      health.error(err)
    else
      health.ok(("token from %s%s"):format(creds.source, creds.login and (", login " .. creds.login) or ""))
      local res = await(function(done) api.myself(done, { provider = name }) end)
      if not res then
        health.error("no answer from " .. pcfg.base_url .. " within 15 s")
      elseif res[1] then
        health.ok(("authenticated as %s (%s)"):format(res[1].name, res[1].id))
        -- what the provider can do here, once it has looked (a licence tier, …)
        if await(function(done) api.ready(done, { provider = name }) end) then
          local caps = vim.tbl_keys((api.provider_info({ provider = name }) or {}).capabilities or {})
          table.sort(caps)
          health.info("capabilities: " .. table.concat(caps, ", "))
        end
      else
        health.error("authentication failed: " .. tostring(res[2]))
      end
    end
  end
end

return M
