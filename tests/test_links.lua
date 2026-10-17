-- Issue links: mapping, the provider's requests, the Links section, the
-- "blocked" sign.

local h = require("helpers")
local fake = require("fake_provider")
local http = require("tracker.http.client")
local jira = require("tracker.providers.jira")
local mapper = require("tracker.providers.jira.mapper")
local icons = require("tracker.ui.icons")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
local notes = {}
require("tracker.notify").set_sink(function(msg) table.insert(notes, msg) end)
local api = require("tracker.api")
local window = require("tracker.ui.window")

local PCFG = {
  base_url = "https://example.atlassian.net", login = "me@x.pl", token = "tok",
  fields = { story_points = "customfield_10016", epic_color = "customfield_10013",
             start_date = "customfield_10015", sprint = "customfield_10020" },
}

local function wait_for(pred, what)
  if not vim.wait(3000, pred, 10) then error("timed out waiting for " .. (what or "condition"), 2) end
end
local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function text() return table.concat(lines(), "\n") end
local function press(lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
    if vim.keycode(m.lhs) == vim.keycode(lhs) then return m.callback() end
  end
  error("no mapping for " .. lhs)
end
local function goto_line(pattern)
  for lnum, l in ipairs(lines()) do
    if l:find(pattern) then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      return lnum, l
    end
  end
  error("no line " .. pattern .. " in\n" .. text())
end
local function ui_test(fn)
  return function()
    local real_select, real_input = vim.ui.select, vim.ui.input
    notes = {}
    local ok, err = pcall(fn)
    vim.ui.select, vim.ui.input = real_select, real_input
    pcall(window.close)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
    end
    if not ok then error(err, 0) end
  end
end
local function calls(kind)
  return vim.tbl_filter(function(c) return c[1] == kind end, fake.calls)
end
local function raw_link(id, dir, key, cat)
  return { id = id, type = { name = "Blocks", inward = "is blocked by", outward = "blocks" },
    [dir == "outward" and "outwardIssue" or "inwardIssue"] = { key = key, fields = {
      summary = key .. " s", status = { id = "1", name = "X", statusCategory = { key = cat or "new" } },
      issuetype = { id = "1", name = "Task" } } } }
end

local T = {}

T["mapper: links read from the issue's side; open 'is blocked by' = blocked"] = function()
  local i = mapper.issue({ key = "ABC-1", fields = { summary = "x", issuelinks = {
    raw_link("1", "outward", "ABC-2"), raw_link("2", "inward", "ABC-3"),
  } } }, PCFG)
  h.eq({ "blocks", "is blocked by" }, vim.tbl_map(function(l) return l.label end, i.links))
  h.eq({ "outward", "inward" }, vim.tbl_map(function(l) return l.direction end, i.links))
  h.eq("ABC-3", i.links[2].issue.key)
  h.eq(true, i.blocked)
  -- the blocker is done: not blocked any more
  i = mapper.issue({ key = "ABC-1", fields = { summary = "x", issuelinks = { raw_link("2", "inward", "ABC-3", "done") } } }, PCFG)
  h.eq(nil, i.blocked)
end

T["provider: add_link edits the issue (its side), delete_link removes by id"] = function()
  local real = http.request
  local sent = {}
  http.request = function(opts, cb)
    table.insert(sent, opts)
    vim.schedule(function() cb({ ok = true, status = 204, body = "", headers = {} }) end)
  end
  local done = 0
  jira.add_link(PCFG, "ABC-1", { type = "Blocks", direction = "inward", key = "ABC-9" }, function() done = done + 1 end)
  jira.delete_link(PCFG, "77", function() done = done + 1 end)
  wait_for(function() return done == 2 end, "requests")
  http.request = real
  h.eq("PUT", sent[1].method)
  h.eq("https://example.atlassian.net/rest/api/3/issue/ABC-1", sent[1].url)
  h.eq({ update = { issuelinks = { { add = { type = { name = "Blocks" }, inwardIssue = { key = "ABC-9" } } } } } },
    vim.json.decode(sent[1].body))
  h.eq({ "DELETE", "https://example.atlassian.net/rest/api/3/issueLink/77" }, { sent[2].method, sent[2].url })
end

T["api: no link to itself"] = function()
  local err
  api.link("FAKE-1", { type = "Blocks", direction = "outward", key = "FAKE-1" }, function(_, e) err = e end)
  wait_for(function() return err end, "refusal")
  h.truthy(err:find("itself", 1, true), err)
end

T["issue view: e on Links → relation → issue; grouped by relation; D removes"] = ui_test(function()
  fake.reset()
  local answers = {
    function(items) for _, it in ipairs(items) do if it.label == "is blocked by" then return it end end end,
    function(items) return items[1] end, -- "Search (key or text)…" (or the recent key)
  }
  vim.ui.select = function(items, _, cb)
    local pick = table.remove(answers, 1)
    cb(pick and pick(items) or items[1])
  end
  vim.ui.input = function(_, cb) cb("fake-2") end
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("## Links (0)", 1, true) end, "issue")
  goto_line("## Links")
  press("e")
  wait_for(function() return #calls("link") == 1 end, "link")
  h.eq({ "link", "FAKE-1", { type = "Blocks", direction = "inward", key = "FAKE-2" } }, calls("link")[1])
  wait_for(function() return text():find("## Links (1)", 1, true) end, "reloaded")
  local lgroup = goto_line("^is blocked by$")
  local lrow, row = goto_line("FAKE%-2 %[")
  h.eq(lgroup + 1, lrow)
  h.truthy(row:find("Second issue", 1, true), row)

  -- D on the link: asks, removes
  local prompt
  vim.ui.select = function(items, o, cb)
    prompt = o.prompt
    cb(items[1])
  end
  press("D")
  wait_for(function() return #calls("unlink") == 1 end, "unlink")
  h.eq("Remove the link: FAKE-1 is blocked by FAKE-2?", prompt)
  wait_for(function() return text():find("## Links (0)", 1, true) end, "gone")
  h.eq(0, #calls("delete")) -- the issue itself stays
end)

T["list + board: a blocked issue carries the ban sign"] = ui_test(function()
  fake.reset()
  fake.issues[2].blocked = true
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  local _, r2 = goto_line("FAKE%-2 ")
  local _, r1 = goto_line("FAKE%-1 ")
  h.truthy(r2:find(icons.glyph.blocked, 1, true), r2)
  h.truthy(not r1:find(icons.glyph.blocked, 1, true), r1)
  -- the columns still line up
  h.eq(vim.fn.strdisplaywidth(r1), vim.fn.strdisplaywidth(r2))
  window.close()
  require("tracker").board({ board_id = "7" })
  wait_for(function() return text():find("FAKE-2", 1, true) end, "board")
  local _, card = goto_line("FAKE%-2")
  h.truthy(card:find("FAKE-2 " .. icons.glyph.blocked, 1, true), card)
end)

return T
