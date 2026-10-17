-- Several boards: branch keys per repository, the repository's main board
-- in the views, the default query, other boards' queries.

local h = require("helpers")
local fake = require("fake_provider")
local boards = require("tracker.boards")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
local config = require("tracker.config")
local api = require("tracker.api")
local window = require("tracker.ui.window")

local function wait_for(pred, what)
  if not vim.wait(8000, pred, 10) then error("timed out waiting for " .. (what or "condition"), 2) end
end
local function calls(kind)
  return vim.tbl_filter(function(c) return c[1] == kind end, fake.calls)
end

local GIT_ENV = { GIT_AUTHOR_NAME = "t", GIT_AUTHOR_EMAIL = "t@t", GIT_COMMITTER_NAME = "t", GIT_COMMITTER_EMAIL = "t@t" }

---A throw-away repository `<tmp>/<name>` on `branch` as the cwd, with
---`fields` merged into providers.fake; restores everything after.
local function in_repo(name, branch, fields, fn)
  return function()
    local cwd = vim.fn.getcwd()
    local pcfg = config.get().providers.fake
    local saved = vim.deepcopy(pcfg)
    local real_select = vim.ui.select
    local dir = vim.fn.tempname() .. "/" .. name
    vim.fn.mkdir(dir, "p")
    vim.system({ "git", "init", "-q", dir }):wait()
    vim.system({ "git", "-C", dir, "commit", "-q", "--allow-empty", "-m", "init" }, { env = GIT_ENV }):wait()
    vim.system({ "git", "-C", dir, "switch", "-q", "-c", branch }):wait()
    vim.fn.chdir(dir)
    for k, v in pairs(fields) do pcfg[k] = v end
    fake.reset()
    local ok, err = pcall(fn, dir)
    vim.fn.chdir(cwd)
    vim.ui.select = real_select
    config.get().providers.fake = saved
    pcall(window.close)
    if not ok then error(err, 0) end
  end
end

local BOARDS = {
  CVNT = { board = 142 },
  EP = { project = "EP", board = 147, queries = { { name = "mine", jql = "project = {project} AND assignee = me" } } },
  OPS = { project = "OPS", tags = { "OPS", "INFRA" } },
}

local T = {}

T["boards.get: project and tags default to the name / project"] = function()
  local pcfg = { boards = BOARDS }
  h.eq({ name = "CVNT", project = "CVNT", board = "142", tags = { "CVNT" } }, boards.get(pcfg, "CVNT"))
  h.eq({ "OPS", "INFRA" }, boards.get(pcfg, "OPS").tags)
  h.eq("OPS", boards.of_key("INFRA-3", boards.all(pcfg)).name)
  h.eq(nil, boards.get(pcfg, "NOPE"))
end

T["repos: a branch of either board of the repository opens its issue"] = in_repo("panel", "cvnt-4598-fix",
  { boards = BOARDS, repos = { panel = { "CVNT", "EP" } } }, function()
    h.eq({ "CVNT-4598", "CVNT" }, { api.current_issue_key() })
    h.eq({ "EP-4325", "EP" }, { api.current_issue_key({ branch = "ep-4325" }) })
    -- OPS isn't one of this repository's boards
    h.eq(nil, api.current_issue_key({ branch = "ops-1" }))
  end)

T["repos: the views use the repository's main board"] = in_repo("panel", "main",
  { boards = BOARDS, repos = { panel = { "EP", "CVNT" } } }, function()
    local info = api.provider_info()
    h.eq({ "EP", "147", "EP" }, { info.project, info.board, info.board_name })
    -- EP's own queries replace the provider's; CVNT has none of its own, so
    -- nothing of it is listed
    local names = vim.tbl_map(function(q) return q.name end, api.queries({ all_boards = true }))
    h.eq({ "mine" }, names)
    h.eq("project = EP AND assignee = me", (api.resolve_query()))
    h.eq(2, #api.repo_boards())
  end)

T["another board's own queries are listed as <BOARD>/<name>"] = in_repo("panel", "main",
  { boards = BOARDS, repos = { panel = { "CVNT", "EP" } } }, function()
    local names = vim.tbl_map(function(q) return q.name end, api.queries({ all_boards = true }))
    h.eq({ "all", "sprint", "backlog", "kids", "EP/mine" }, names)
    h.eq("project = CVNT", (api.resolve_query()))
    local jql, label, entry = api.resolve_query("EP/mine")
    h.eq({ "project = EP AND assignee = me", "EP/mine", "EP" }, { jql, label, entry.board_name })
  end)

local SECTIONED = {
  { name = "everything", sections = { "mine", "sprints", "backlogs", "nope" } },
  { name = "mine", jql = "assignee = me" },
  { name = "sprints", sprints = true },
  { name = "backlogs", backlogs = true },
}

local function search(name)
  local res
  api.search(name, function(issues, err, meta) res = { issues = issues, err = err, meta = meta } end)
  wait_for(function() return res end, "search " .. name)
  h.eq(nil, res.err)
  return res
end

local function titles(res)
  return vim.tbl_map(function(s) return s.title end, res.meta.sections)
end

T["sprints / backlogs / sections: one section per sprint / board, in order"] = in_repo("panel", "main",
  { boards = { CVNT = { board = 142 }, EP = { board = 147 }, OPS = {} }, repos = { panel = { "CVNT", "EP", "OPS" } },
    queries = SECTIONED }, function()
    local _, label = api.resolve_query()
    h.eq("everything", label)
    local res = search("everything")
    -- OPS has no board id: no sprint, no backlog; "nope" isn't a saved query
    h.eq({ "mine", "CVNT · Sprint 42", "EP · Sprint 42", "CVNT · backlog", "EP · backlog" }, titles(res))
    h.eq({ "FAKE-1", "FAKE-2" }, vim.tbl_map(function(i) return i.key end, res.issues)) -- union, once each
    h.eq({ { "backlog", "142" }, { "backlog", "147" } }, calls("backlog"))
    h.eq({ "CVNT · Sprint 42", "EP · Sprint 42" }, titles(search("sprints")))
  end)

T["sprints outside a listed repository: the provider's board"] = in_repo("other", "main",
  { boards = BOARDS, repos = { panel = { "CVNT" } }, board = 7, queries = SECTIONED }, function()
    h.eq({ "FAKE · Sprint 42" }, titles(search("sprints")))
    h.eq({ "FAKE · backlog" }, titles(search("backlogs")))
  end)

T["list view: a header per section, an empty one says so"] = in_repo("panel", "main",
  { boards = { CVNT = { board = 142 }, EP = { board = 147 } }, repos = { panel = { "CVNT", "EP" } },
    queries = SECTIONED }, function()
    local real = fake.backlog
    fake.backlog = function(_, board, cb)
      vim.schedule(function() cb(board == "147" and {} or { vim.deepcopy(fake.issues[2]) }) end)
    end
    local ok, err = pcall(function()
      require("tracker").search()
      local function text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end
      wait_for(function() return text():find("EP · backlog", 1, true) end, "sections")
      local t = text()
      h.truthy(t:find("mine + sprints + backlogs + nope", 1, true), t)
      local order = vim.tbl_map(function(s) return (t:find(s, 1, true)) end,
        { "mine", "CVNT · Sprint 42", "EP · Sprint 42", "CVNT · backlog", "EP · backlog" })
      for n = 2, #order do h.truthy(order[n] > order[n - 1], t) end
      h.truthy(t:match("EP · backlog[^\n]*0 issues\n%s+no issues"), t)

      -- [[ / ]] jump between the headers; each header is a band
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local headers = {}
      for lnum, l in ipairs(lines) do
        if l:find("%d+ issues?") then table.insert(headers, lnum) end
      end
      h.eq(5, #headers)
      local function press(lhs)
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
          if vim.keycode(m.lhs) == vim.keycode(lhs) then return m.callback() end
        end
        error("no mapping for " .. lhs)
      end
      local function row() return vim.api.nvim_win_get_cursor(0)[1] end
      vim.api.nvim_win_set_cursor(0, { headers[1] + 1, 0 })
      press("]]")
      h.eq(headers[2], row())
      press("]]")
      press("]]")
      h.eq(headers[4], row())
      vim.api.nvim_win_set_cursor(0, { headers[4] + 1, 0 })
      press("[[") -- inside a section: its own header first
      h.eq(headers[4], row())
      press("[[")
      h.eq(headers[3], row())
      local ns = require("tracker.ui.view").ns
      local bands = 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
        if m[4].line_hl_group == "TrackerSection" then bands = bands + 1 end
      end
      h.eq(5, bands)
    end)
    fake.backlog = real
    if not ok then error(err, 0) end
  end)

T["another board's sprint / backlog query runs on that board"] = in_repo("panel", "main",
  { boards = BOARDS, repos = { panel = { "CVNT", "EP" } } }, function()
    -- EP has its own queries (no backlog); CVNT inherits the provider's
    local done
    api.search("backlog", function(issues) done = issues end)
    wait_for(function() return done end, "backlog")
    h.eq({ "backlog", "142" }, calls("backlog")[1])
  end)

T["no key of the repository's boards: open() lists the default query"] = in_repo("backend", "main",
  { boards = BOARDS, repos = { backend = { "EP", default_query = "assignee = me ORDER BY updated" } } }, function()
    h.eq(nil, api.current_issue_key({ branch = "cvnt-1" }))
    require("tracker").open()
    wait_for(function() return #calls("search") > 0 end, "search")
    h.eq("assignee = me ORDER BY updated", calls("search")[1][2])
  end)

T["default_query by a saved query's name; a path as the repos key"] = in_repo("api", "ep-7",
  { boards = BOARDS, default_query = "kids" }, function()
    config.get().providers.fake.repos = { [boards.repo_root()] = { "CVNT" } }
    h.eq(nil, api.current_issue_key())
    local _, label = api.resolve_query()
    h.eq("kids", label)
  end)

T["a repository not in repos: every board's keys, the provider's own views"] = in_repo("other", "ops-12",
  { boards = BOARDS, repos = { panel = { "CVNT" } } }, function()
    h.eq({ "OPS-12", "OPS" }, { api.current_issue_key() })
    h.eq({ "INFRA-2", "OPS" }, { api.current_issue_key({ branch = "infra-2" }) })
    local info = api.provider_info()
    h.eq({ "FAKE", nil }, { info.project, info.board_name })
    h.eq(0, #api.repo_boards())
  end)

T["board view: a pick among the repository's boards with an id"] = in_repo("panel", "main",
  { boards = BOARDS, repos = { panel = { "CVNT", "EP", "OPS" } } }, function()
    local items
    vim.ui.select = function(list, _, cb)
      items = vim.tbl_map(function(b) return b.name end, list)
      cb(nil)
    end
    require("tracker").board()
    h.eq({ "CVNT", "EP" }, items)
  end)

T["no boards: branch keys as before"] = function()
  h.eq("ABC-1", api.current_issue_key({ branch = "abc-1" }))
end

return T
