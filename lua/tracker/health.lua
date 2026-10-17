-- :checkhealth tracker

local M = {}

local health = vim.health

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
    health.warn("no provider configured", { "setup({ providers = { jira = { base_url = \"https://<site>.atlassian.net\" } } })" })
    return
  end

  local config = require("tracker.config")
  local auth = require("tracker.http.auth")
  for _, name in ipairs(configured) do
    health.start("tracker.nvim: " .. name)
    local pcfg = config.provider(name)
    health.info("base_url: " .. pcfg.base_url)
    if pcfg.project then health.info("project: " .. pcfg.project) end
    if pcfg.boards then
      local boards = require("tracker.boards")
      for _, b in ipairs(boards.all(pcfg)) do
        health.info(("board %s: project %s, board %s, branch tags %s"):format(
          b.name, b.project, b.board or "-", table.concat(b.tags, ", ")))
      end
      for repo, names in pairs(pcfg.repos or {}) do
        for _, n in ipairs(type(names) == "string" and { names } or names) do
          if not boards.get(pcfg, n) then
            health.warn(("repos[%q] names board %q, which isn't in providers.%s.boards"):format(repo, n, name))
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
      local done, me, merr = false, nil, nil
      require("tracker.api").myself(function(user, e)
        done, me, merr = true, user, e
      end, { provider = name })
      vim.wait(15000, function() return done end, 50)
      if not done then
        health.error("no answer from " .. pcfg.base_url .. " within 15 s")
      elseif me then
        health.ok(("authenticated as %s (%s)"):format(me.name, me.id))
      else
        health.error("authentication failed: " .. tostring(merr))
      end
    end
  end
end

return M
