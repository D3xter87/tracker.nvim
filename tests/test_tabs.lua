-- Several providers in one tracker window: a tab each, switched with 1 / 2.
-- Two in-memory providers stand in for Jira and GitLab: `fake`, and a second
-- copy of the same module (`fakeb`, its own state) as the instance `other`.

local h = require("helpers")
local fake = require("fake_provider")

package.preload["fake_provider_b"] = function()
  return dofile(package.searchpath("fake_provider", package.path))
end
local other = require("fake_provider_b")

local providers = require("tracker.providers")
providers.register("fake", "fake_provider")
providers.register("fakeb", "fake_provider_b")

local tracker = require("tracker")
local api = require("tracker.api")
local window = require("tracker.ui.window")
local messages = {}

local function two_providers(extra)
  tracker.setup(vim.tbl_deep_extend("force", {
    providers = {
      fake = { base_url = "https://fake" },
      other = { type = "fakeb", base_url = "https://other", project = "OTHER", label = "Other" },
    },
  }, extra or {}))
  require("tracker.notify").set_sink(function(msg) table.insert(messages, msg) end)
end

---`other`'s issues are OTHER-1, OTHER-2: told apart from fake's at a glance.
local function reset()
  fake.reset()
  other.reset()
  for n, issue in ipairs(other.issues) do
    issue.key, issue.provider, issue.summary = "OTHER-" .. n, "other", "Other issue " .. n
  end
  messages = {}
end

local function wait_for(pred, what)
  if not vim.wait(3000, pred, 10) then
    error("timed out waiting for " .. (what or "condition") .. "\nmessages: " .. vim.inspect(messages), 2)
  end
end

local function text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end

local function has_map(lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
    if m.lhs == lhs then return m end
  end
end

local function press(lhs)
  local m = has_map(lhs)
  if not m then error("no mapping for " .. lhs) end
  return m.callback()
end

local function on_line(pattern)
  for lnum, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find(pattern) then
      vim.api.nvim_win_set_cursor(0, { lnum, l:find(pattern) - 1 })
      return lnum
    end
  end
  error("no line matching " .. pattern)
end

local function title() return vim.inspect(vim.api.nvim_win_get_config(0).title) end

local function ui_test(fn)
  return function()
    window.close_all()
    reset()
    two_providers()
    local ok, err = pcall(fn)
    window.close_all()
    if not ok then error(err, 0) end
  end
end

---The default list of the first provider, loaded.
local function open_list()
  tracker.search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "fake's list")
end

local T = {}

T["the window has a tab per provider, the first one shown"] = ui_test(function()
  open_list()
  h.eq({ order = { "fake", "other" }, active = "fake", labels = { fake = "fake", other = "Other" } }, window.tabs())
  h.truthy(title():find(" 1 fake ", 1, true), title())
  h.truthy(title():find(" 2 Other ", 1, true), title())
  h.truthy(title():find("TrackerTabActive", 1, true), title())
  h.truthy(has_map("1") and has_map("2"), "digit keys")
  h.eq(nil, has_map("3"))
end)

T["2 opens the other provider's list, 1 comes back to the first as it was"] = ui_test(function()
  open_list()
  on_line("FAKE%-2")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local first = vim.api.nvim_get_current_buf()
  press("2")
  wait_for(function() return text():find("OTHER-1", 1, true) end, "other's list")
  h.eq("other", window.tabs().active)
  h.eq("tracker_list", vim.bo.filetype)
  h.truthy(not text():find("FAKE-1", 1, true), "fake's issues stay on its tab")
  h.eq("search", other.calls[1][1])
  press("1")
  h.eq("fake", window.tabs().active)
  h.eq(first, vim.api.nvim_get_current_buf())
  h.eq(cursor, vim.api.nvim_win_get_cursor(0))
  -- and back: the tab is still there, nothing is loaded again
  local n = #other.calls
  press("2")
  h.truthy(text():find("OTHER-1", 1, true), "other's list again")
  h.eq(n, #other.calls)
end)

T["each tab keeps its own stack of views"] = ui_test(function()
  open_list()
  on_line("FAKE%-1")
  press("<CR>")
  wait_for(function() return vim.bo.filetype == "tracker_issue" and text():find("First issue", 1, true) end, "FAKE-1")
  h.eq(2, window.depth())
  press("2")
  wait_for(function() return text():find("OTHER-1", 1, true) end, "other's list")
  h.eq(1, window.depth())
  press("1")
  h.eq("tracker_issue", vim.bo.filetype)
  h.truthy(text():find("First issue", 1, true), "the issue is still open on tab 1")
  h.eq(2, window.depth())
end)

T["an action goes to the provider of the tab it was made on"] = ui_test(function()
  open_list()
  press("2")
  wait_for(function() return text():find("OTHER-1", 1, true) end, "other's list")
  other.issues[1].assignee = nil
  fake.calls, other.calls = {}, {}
  on_line("OTHER%-1")
  press("A")
  wait_for(function()
    return vim.tbl_contains(vim.tbl_map(function(c) return c[1] end, other.calls), "assign")
  end, "assign on other")
  h.eq({}, vim.tbl_filter(function(c) return c[1] == "assign" end, fake.calls))
  h.eq("other", api.provider_info().name)
  h.eq("OTHER", api.provider_info().project)
end)

T["a callback keeps the provider of its call when the tab changed meanwhile"] = ui_test(function()
  open_list()
  local seen
  -- asked on tab 1 …
  api.get_issue("FAKE-1", function(issue)
    seen = { issue and issue.key, api.provider_info().name }
    require("tracker.ui.issue").open("FAKE-2") -- … and what it opens belongs there
  end)
  press("2") -- … answered with tab 2 shown
  wait_for(function() return seen end, "the answer")
  h.eq({ "FAKE-1", "fake" }, seen)
  wait_for(function() return text():find("OTHER-1", 1, true) end, "other's list")
  h.eq("other", window.tabs().active)
  h.eq("tracker_list", vim.bo.filetype)
  press("1")
  wait_for(function() return vim.bo.filetype == "tracker_issue" and text():find("Second issue", 1, true) end, "FAKE-2 on tab 1")
end)

T["a repeated reload stays with its view's provider"] = ui_test(function()
  local sync = require("tracker.ui.sync")
  local delays = sync.delays
  sync.delays = { 30 }
  open_list()
  -- a change the next two listings don't show yet: the list reloads again
  fake.freeze(2)
  on_line("FAKE%-1")
  press("A")
  press("2")
  wait_for(function() return text():find("OTHER-1", 1, true) end, "other's list")
  local searches = #vim.tbl_filter(function(c) return c[1] == "search" end, other.calls)
  vim.wait(200, function() return false end, 10)
  sync.delays = delays
  h.eq(searches, #vim.tbl_filter(function(c) return c[1] == "search" end, other.calls), "the retry isn't other's")
  h.truthy(#vim.tbl_filter(function(c) return c[1] == "search" end, fake.calls) >= 2, "fake's list was reloaded")
end)

T["a digit inside a count belongs to the count"] = ui_test(function()
  open_list()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_feedkeys("31", "mtx", false)
  h.eq("fake", window.tabs().active)
  vim.api.nvim_feedkeys("2", "mtx", false)
  wait_for(function() return window.tabs().active == "other" end, "tab 2")
end)

T["an empty tab opens the kind of view the current one started with"] = ui_test(function()
  require("tracker.config").get().providers.fake.board = 7
  require("tracker.config").get().providers.other.board = 8
  tracker.board()
  wait_for(function() return vim.bo.filetype == "tracker_board" and text():find("FAKE-1", 1, true) end, "fake's board")
  press("2")
  wait_for(function() return vim.bo.filetype == "tracker_board" and text():find("OTHER-1", 1, true) end, "other's board")
  h.eq("other", window.tabs().active)
end)

T["… and the default list when the provider has no such view"] = ui_test(function()
  require("tracker.config").get().providers.fake.board = 7
  other.capabilities.boards = false
  tracker.board()
  wait_for(function() return vim.bo.filetype == "tracker_board" end, "fake's board")
  press("2")
  wait_for(function() return vim.bo.filetype == "tracker_list" and text():find("OTHER-1", 1, true) end, "other's list")
  other.capabilities.boards = true
  h.truthy(table.concat(messages, "\n"):find("no boards", 1, true), vim.inspect(messages))
end)

T["a key opens on its provider's tab, wherever the window is"] = ui_test(function()
  two_providers({ providers = { fake = { projects = { "FAKE" } }, other = { projects = { "OTHER" } } } })
  open_list()
  tracker.issue("other-2")
  wait_for(function() return vim.bo.filetype == "tracker_issue" and text():find("Other issue 2", 1, true) end, "OTHER-2")
  h.eq("other", window.tabs().active)
  h.eq(1, window.depth())
  press("1")
  h.eq("tracker_list", vim.bo.filetype)
  tracker.issue("other:OTHER-1")
  wait_for(function() return text():find("Other issue 1", 1, true) end, "OTHER-1")
  h.eq({ "other", 2 }, { window.tabs().active, window.depth() })
end)

T["the branch's issue opens on its provider's tab"] = ui_test(function()
  two_providers({
    ui = { issue_base = "search" },
    providers = { fake = { projects = { "FAKE" } }, other = { projects = { "OTHER" } } },
  })
  local real = require("tracker.util.git").current_branch
  require("tracker.util.git").current_branch = function() return "other-1-fix" end
  local ok, err = pcall(function()
    tracker.open()
    wait_for(function() return vim.bo.filetype == "tracker_issue" and text():find("Other issue 1", 1, true) end, "OTHER-1")
    h.eq({ "other", 2 }, { window.tabs().active, window.depth() })
  end)
  require("tracker.util.git").current_branch = real
  if not ok then error(err, 0) end
end)

T["… also when the window shows the other provider's tab"] = ui_test(function()
  two_providers({
    ui = { issue_base = false },
    providers = { fake = { projects = { "FAKE" } }, other = { projects = { "OTHER" } } },
  })
  open_list() -- tab 1 (fake) is shown, and the tracker window is the current one
  local real = require("tracker.util.git").current_branch
  require("tracker.util.git").current_branch = function() return "other-2-fix" end
  local ok, err = pcall(function()
    tracker.open()
    wait_for(function() return vim.bo.filetype == "tracker_issue" and text():find("Other issue 2", 1, true) end, "OTHER-2")
    h.eq("other", window.tabs().active)
    h.truthy(vim.tbl_contains(tracker.complete("OTHER", "keys"), "OTHER-2"), "the branch's key completes from any tab")
  end)
  require("tracker.util.git").current_branch = real
  if not ok then error(err, 0) end
end)

T["require('tracker').tab(n) is what the keys do; ui.tab_keys = false maps none"] = ui_test(function()
  two_providers({ ui = { tab_keys = false } })
  open_list()
  h.eq(nil, has_map("1"))
  h.eq(nil, has_map("2"))
  h.eq(true, tracker.tab(2))
  wait_for(function() return text():find("OTHER-1", 1, true) end, "other's list")
  h.eq(true, tracker.tab("fake"))
  h.eq("fake", window.tabs().active)
  h.eq(false, tracker.tab(3))
end)

T["ui.tab_keys names the keys"] = ui_test(function()
  two_providers({ ui = { tab_keys = { "<F7>", "<F8>" } } })
  open_list()
  h.eq(nil, has_map("1"))
  h.truthy(has_map("<F8>"), "the second tab's key")
end)

T["closing the window wipes the views of every tab"] = ui_test(function()
  open_list()
  local bufs = { vim.api.nvim_get_current_buf() }
  press("2")
  wait_for(function() return text():find("OTHER-1", 1, true) end, "other's list")
  table.insert(bufs, vim.api.nvim_get_current_buf())
  press("Q")
  h.eq(nil, window.win())
  h.eq({ false, false }, vim.tbl_map(vim.api.nvim_buf_is_valid, bufs))
end)

T["drafts and recent keys are per provider"] = ui_test(function()
  local drafts = require("tracker.ui.drafts")
  open_list()
  drafts.keeper("comment:X-1", "", "")("fake's draft")
  h.eq("fake's draft", drafts.get("comment:X-1"))
  h.truthy(vim.tbl_contains(api.recent_keys(), "FAKE-1"))
  press("2")
  wait_for(function() return text():find("OTHER-1", 1, true) end, "other's list")
  h.eq(nil, drafts.get("comment:X-1"))
  h.truthy(vim.tbl_contains(api.recent_keys(), "OTHER-1"))
  h.truthy(not vim.tbl_contains(api.recent_keys(), "FAKE-1"))
  drafts.clear()
end)

T["one provider: no tab bar, no tab keys"] = function()
  window.close_all()
  reset()
  tracker.setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
  tracker.search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  h.eq({ order = { "fake" }, active = "fake", labels = { fake = "fake" } }, window.tabs())
  h.eq("string", type(vim.api.nvim_win_get_config(0).title[1][1]))
  h.eq(1, #vim.api.nvim_win_get_config(0).title)
  h.eq(nil, has_map("1"))
  h.eq(false, tracker.tab(2))
  window.close_all()
end

return T
