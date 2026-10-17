-- Quick filters (f) and grouping (F) in lists.

local h = require("helpers")
local fake = require("fake_provider")
local lf = require("tracker.ui.listfilter")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
require("tracker.notify").set_sink(function() end)
local window = require("tracker.ui.window")

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
  error("no line " .. pattern)
end

local TYPE = function(name, level) return { id = name, name = name, subtask = level < 0, level = level } end
local EPIC = TYPE("Epik", 1)
local function issue(key, extra)
  return vim.tbl_extend("force", {
    provider = "fake", id = key, key = key, summary = key .. " summary", url = "https://fake/" .. key,
    status = { id = "1", name = "To Do", category = "todo" }, labels = {}, subtasks = {}, type = TYPE("Zadanie", 0),
  }, extra or {})
end

local ANNA = { id = "u2", name = "Anna Nowak" }
local function sample()
  return {
    issue("A-1", { parent = { key = "E-1", type = EPIC }, assignee = ANNA, labels = { "be" }, story_points = 3 }),
    issue("A-2", { parent = { key = "E-2", type = EPIC }, story_points = 5,
                   status = { id = "3", name = "Done", category = "done" } }),
    issue("A-3", {}),
    issue("A-4", { type = TYPE("Podzadanie", -1), parent = { key = "A-1" }, story_points = 1 }),
  }
end

-- Runs a UI test with vim.ui.select stubbed; always restores it and closes
-- every float, so a failure does not leak into the next test.
local function ui_test(fn)
  return function()
    local real_select = vim.ui.select
    local ok, err = pcall(fn)
    vim.ui.select = real_select
    pcall(window.close)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
    end
    if not ok then error(err, 0) end
  end
end

local T = {}

T["epic_of: own parent, or the parent's for a sub-task"] = function()
  local list = sample()
  local by_key = {}
  for _, i in ipairs(list) do by_key[i.key] = i end
  h.eq("E-1", lf.epic_of(list[1], by_key))
  h.eq(nil, lf.epic_of(list[3], by_key))
  h.eq("E-1", lf.epic_of(list[4], by_key))
end

T["apply: OR within a category, AND across, NONE = without"] = function()
  local keys = function(l) return vim.tbl_map(function(i) return i.key end, l) end
  local list = sample()
  h.eq({ "A-1", "A-2", "A-4" }, keys(lf.apply(list, { epic = { ["E-1"] = true, ["E-2"] = true } })))
  h.eq({ "A-3" }, keys(lf.apply(list, { epic = { [lf.NONE] = true } })))
  h.eq({ "A-1" }, keys(lf.apply(list, { epic = { ["E-1"] = true }, assignee = { u2 = true } })))
  h.eq({ "A-1" }, keys(lf.apply(list, { label = { be = true } })))
  h.eq({ "A-2" }, keys(lf.apply(list, { status = { Done = true } })))
  h.eq(4, #lf.apply(list, { epic = {} })) -- empty category = inactive
end

T["candidates: values in order of appearance, NONE last, current selection kept"] = function()
  local items = lf.candidates(sample(), "epic", { epic = { ["E-2"] = true } }, { ["E-1"] = { key = "E-1", summary = "One", color = 4 } })
  h.eq({ "E-1", "E-2", lf.NONE }, vim.tbl_map(function(i) return i.value end, items))
  h.eq("E-1  One", items[1].label)
  h.eq({ false, true, false }, vim.tbl_map(function(i) return i.selected end, items))
  h.eq("No epic", items[3].label)
end

T["groups + points: closed / total over non-sub-tasks"] = function()
  local groups = lf.groups(sample(), "epic")
  h.eq({ "E-1", "E-2", lf.NONE }, vim.tbl_map(function(g) return g.value end, groups))
  h.eq({ "A-1", "A-4" }, vim.tbl_map(function(i) return i.key end, groups[1].issues))
  h.eq({ 0, 3, 2 }, { lf.points(groups[1].issues) })
  h.eq({ 5, 5, 1 }, { lf.points(groups[2].issues) })
end

T["ui: f → Epic (multi-select) filters the list, f → Clear restores it"] = ui_test(function()
  fake.reset()
  fake.issues = sample()
  local picks = {}
  vim.ui.select = function(items, _, cb)
    local pick = table.remove(picks, 1)
    for _, it in ipairs(items) do
      if pick(it) then return cb(it) end
    end
    cb(nil)
  end
  require("tracker").search("all")
  wait_for(function() return text():find("A-4", 1, true) end, "list")

  picks = { function(i) return i.cat and i.cat.id == "epic" end }
  press("f")
  -- the multi-select float: tick E-2 and "No epic"
  wait_for(function() return text():find("[ ]", 1, true) end, "multiselect")
  goto_line("E%-2")
  press("<Space>")
  goto_line("No epic")
  press("x")
  press("<CR>")
  wait_for(function() return text():find("filters:", 1, true) end, "filtered")
  h.truthy(text():find("A-2", 1, true) and text():find("A-3", 1, true), text())
  h.truthy(not text():find("A-1 ", 1, true), "E-1's issue filtered out")
  h.truthy(text():find("(2 of 4", 1, true), text())

  picks = { function(i) return i.clear end }
  press("f")
  wait_for(function() return text():find("A-1 ", 1, true) end, "cleared")
  h.truthy(not text():find("filters:", 1, true))

  -- <Esc> clears the quick filters too, the window stays
  picks = { function(i) return i.cat and i.cat.id == "epic" end }
  press("f")
  wait_for(function() return text():find("[ ]", 1, true) end, "multiselect")
  goto_line("E%-2")
  press("<Space>")
  press("<CR>")
  wait_for(function() return text():find("filters:", 1, true) end, "filtered again")
  h.truthy(not text():find("A-1 ", 1, true), "E-1's issue filtered out")
  press("<Esc>")
  h.truthy(window.win() ~= nil, "window stays")
  h.truthy(not text():find("filters:", 1, true), "filters cleared")
  h.truthy(text():find("A-1 ", 1, true), "A-1 back")
end)

T["ui: f → Open a whole epic… lists the epic's children in rank order"] = ui_test(function()
  fake.reset()
  vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do
      if it.epic or it.key == "FAKE-F" then return cb(it) end
    end
    cb(nil)
  end
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  local n = #fake.calls
  press("f")
  wait_for(function() return fake.calls[#fake.calls][1] == "search" and #fake.calls > n end, "epic search")
  local call = fake.calls[#fake.calls]
  h.eq("parent = FAKE-F ORDER BY Rank ASC", type(call[2]) == "table" and call[2].jql or call[2])
  wait_for(function() return vim.api.nvim_win_get_config(0).title and vim.inspect(vim.api.nvim_win_get_config(0).title):find("FAKE-F", 1, true) end, "epic list title")
end)

T["ui: F → by epic: headers with counts / points, <Tab> folds a group, j stops on headers"] = ui_test(function()
  fake.reset()
  fake.issues = sample()
  vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do
      if it.id == "epic" then return cb(it) end
    end
  end
  require("tracker").search("all")
  wait_for(function() return text():find("A-4", 1, true) end, "list")
  press("F")
  wait_for(function() return text():find("No epic", 1, true) end, "grouped")
  local hdr = goto_line("E%-1%s")
  local _, hl = goto_line("E%-1%s")
  h.truthy(hl:find("2 issues", 1, true) and hl:find("0/3 pts", 1, true), hl)
  local a1 = goto_line("A%-1 ")
  h.truthy(a1 > hdr, "A-1 under its epic header")
  -- j from the header goes to the first issue, k back to the header
  vim.api.nvim_win_set_cursor(0, { hdr, 0 })
  press("j")
  h.eq(a1, vim.api.nvim_win_get_cursor(0)[1])
  press("k")
  h.eq(hdr, vim.api.nvim_win_get_cursor(0)[1])
  -- fold the group
  press("<Tab>")
  h.truthy(not text():find("A-1 ", 1, true), "group folded")
  h.truthy(text():find("A-2", 1, true), "other groups untouched")
end)

return T
