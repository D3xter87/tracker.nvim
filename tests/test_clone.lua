-- Deleting your own comment (D on it) and cloning an issue (C).

local h = require("helpers")
local fake = require("fake_provider")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
local notes = {}
require("tracker.notify").set_sink(function(msg) table.insert(notes, msg) end)
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
  error("no line " .. pattern .. " in\n" .. text())
end
local function ui_test(fn)
  return function()
    local real_select = vim.ui.select
    notes = {}
    local ok, err = pcall(fn)
    vim.ui.select = real_select
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

local T = {}

T["D on your comment: asks with its date and words, deletes it"] = ui_test(function()
  fake.reset()
  local prompt
  vim.ui.select = function(items, o, cb)
    prompt = o.prompt
    cb(items[1])
  end
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("first comment", 1, true) end, "issue")
  goto_line("first comment")
  press("D")
  wait_for(function() return #calls("delete_comment") == 1 end, "delete")
  h.eq({ "delete_comment", "FAKE-1", "c1" }, calls("delete_comment")[1])
  h.truthy(prompt:find("2026-10-16 10:00", 1, true) and prompt:find("first comment", 1, true), prompt)
  wait_for(function() return not text():find("first comment", 1, true) end, "reloaded without it")
  h.eq("FAKE-1", vim.api.nvim_win_get_config(0).title[1][1]:match("FAKE%-1"))
end)

T["D on someone else's comment: refused, nothing deleted, the issue stays"] = ui_test(function()
  fake.reset()
  table.insert(fake.comments["FAKE-1"], { id = "c9", author = { id = "u2", name = "Anna" }, body = "not yours",
                                          created = "2026-10-16T11:00:00.000+0200" })
  local asked = false
  vim.ui.select = function(_, _, cb)
    asked = true
    cb(nil)
  end
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("not yours", 1, true) end, "issue")
  goto_line("not yours")
  press("D")
  vim.wait(100)
  h.eq(false, asked)
  h.eq(0, #calls("delete_comment"))
  h.eq(0, #calls("delete"))
  h.truthy(vim.tbl_contains(notes, "only your own comments can be deleted"), vim.inspect(notes))
end)

T["C in a list: CLONE - summary in a popup, clone with link + sub-tasks, then it opens"] = ui_test(function()
  fake.reset()
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  goto_line("FAKE%-1 ")
  press("C")
  wait_for(function() return vim.bo.filetype == "tracker_edit" end, "popup")
  h.eq({ "CLONE - First issue" }, lines())
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Copy of the first" })
  press("<C-s>")
  wait_for(function() return #calls("clone") == 1 end, "clone")
  h.eq({ "clone", "FAKE-1", { summary = "Copy of the first", link = true, subtasks = true } }, calls("clone")[1])
  wait_for(function() return vim.bo.filetype == "tracker_issue" and text():find("Copy of the first", 1, true) end, "clone opened")
  -- fields Jira refused are reported
  h.truthy(vim.iter(notes):any(function(n) return n:find("not copied", 1, true) and n:find("customfield_10015", 1, true) end),
    vim.inspect(notes))
end)

T["C in the issue view clones it too"] = ui_test(function()
  fake.reset()
  require("tracker").issue("FAKE-2")
  wait_for(function() return text():find("Second issue", 1, true) end, "issue")
  press("C")
  wait_for(function() return vim.bo.filetype == "tracker_edit" end, "popup")
  h.eq({ "CLONE - Second issue" }, lines())
  press("<C-s>")
  wait_for(function() return #calls("clone") == 1 end, "clone")
  wait_for(function() return vim.bo.filetype == "tracker_issue" and text():find("FAKE%-3") end, "clone opened")
end)

return T
