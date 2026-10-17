-- Field editing: `e` by column in lists, `e` by section and j/k in the
-- issue view, epic picker with "new epic", the field menu.

local h = require("helpers")
local fake = require("fake_provider")
local icons = require("tracker.ui.icons")

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
    if m.lhs == lhs then return m.callback() end
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
---Put the cursor on `needle` inside the line matching `pattern`.
local function goto_text(pattern, needle)
  local lnum, l = goto_line(pattern)
  local col = assert(l:find(needle, 1, true), needle .. " not on " .. l)
  vim.api.nvim_win_set_cursor(0, { lnum, col - 1 })
end
local function cursor_line() return vim.api.nvim_get_current_line() end

-- scripted vim.ui answers: select → index or predicate, input → string
local selects, inputs, prompts = {}, {}, {}
local real_select, real_input = vim.ui.select, vim.ui.input
local function stub_ui()
  vim.ui.select = function(items, opts, cb)
    table.insert(prompts, opts.prompt)
    local pick = table.remove(selects, 1)
    if type(pick) == "function" then
      for _, it in ipairs(items) do
        if pick(it, opts) then return cb(it) end
      end
      return cb(nil)
    end
    cb(items[pick or 1])
  end
  vim.ui.input = function(opts, cb)
    table.insert(prompts, opts.prompt .. "|" .. tostring(opts.default))
    cb(table.remove(inputs, 1))
  end
end

local TYPE = function(name, level) return { id = name, name = name, subtask = level < 0, level = level } end
local function issue(key, extra)
  return vim.tbl_extend("force", {
    provider = "fake", id = key, key = key, summary = key .. " summary", url = "https://fake/" .. key,
    status = { id = "1", name = "To Do", category = "todo" }, labels = {}, subtasks = {},
    type = TYPE("Zadanie", 0),
  }, extra or {})
end

local function last_update()
  for n = #fake.calls, 1, -1 do
    if fake.calls[n][1] == "update" then return fake.calls[n] end
  end
end

local T = {}

T["list: e = title, S = story points, E = field menu"] = function()
  stub_ui()
  fake.reset()
  fake.issues[1].parent = { key = "FAKE-E", summary = "Stability", type = { name = "Epik", level = 1 } }
  fake.issues[1].story_points = 3
  fake.issues[1].priority_id = "3"
  require("tracker").search("all")
  wait_for(function() return text():find("Stability", 1, true) end, "list with epic")

  -- e: the summary, wherever the cursor is on the row
  goto_text("FAKE%-2 ", "FAKE-2")
  inputs = { "Renamed second" }
  press("e")
  wait_for(function() return text():find("Renamed second", 1, true) end, "summary update")
  h.eq({ "update", "FAKE-2", { summary = "Renamed second" } }, last_update())
  h.truthy(prompts[#prompts]:find("Second issue", 1, true), "prefilled with the old summary")

  -- S: story points straight away
  goto_line("FAKE%-1 ")
  inputs = { "5,5" }
  press("S")
  wait_for(function() local u = last_update() return u and u[3].story_points end, "points update")
  h.eq({ "update", "FAKE-1", { story_points = 5.5 } }, last_update())
  h.truthy(prompts[#prompts]:find("|3$"), "prefilled with the current points: " .. prompts[#prompts])

  -- E: menu → priority
  goto_line("FAKE%-1 ")
  selects = { function(f) return f == "priority" end, function(p) return p.id == "1" end }
  press("E")
  wait_for(function() local u = last_update() return u and u[3].priority_id end, "priority update")
  h.eq({ "update", "FAKE-1", { priority_id = "1" } }, last_update())

  -- E: menu → epic
  wait_for(function() return text():find("\u{f102}", 1, true) end, "list refreshed")
  goto_line("FAKE%-1 ")
  selects = { function(f) return f == "epic" end, function(i) return i.epic and i.epic.key == "FAKE-F" end }
  press("E")
  wait_for(function() local u = last_update() return u and u[3].parent end, "epic update")
  h.eq({ "update", "FAKE-1", { parent = "FAKE-F" } }, last_update())
  window.close()
end

T["A toggles: mine → unassigned, otherwise → me"] = function()
  stub_ui()
  fake.reset() -- FAKE-1 is assigned to me (u1), FAKE-2 to nobody
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  local function last_assign()
    for n = #fake.calls, 1, -1 do
      if fake.calls[n][1] == "assign" then return fake.calls[n] end
    end
  end
  goto_line("FAKE%-1 ")
  press("A")
  wait_for(function() return last_assign() end, "unassign")
  h.eq({ "assign", "FAKE-1", nil }, last_assign())
  goto_line("FAKE%-2 ")
  press("A")
  wait_for(function() local c = last_assign() return c and c[2] == "FAKE-2" end, "assign me")
  h.eq({ "assign", "FAKE-2", "u1" }, last_assign())
  window.close()
end

T["epic picker: + New epic creates one and links the issue"] = function()
  stub_ui()
  fake.reset()
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  goto_line("FAKE%-2 ")
  selects = { function(f) return f == "epic" end, function(i) return i.new end }
  press("E")
  -- the new-epic popup
  wait_for(function() return vim.bo.buftype == "acwrite" end, "epic editor")
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Brand new epic", "", "why" })
  press("<C-S>")
  wait_for(function() local u = last_update() return u and u[3].parent end, "link to the new epic")
  local create
  for _, c in ipairs(fake.calls) do
    if c[1] == "create" then create = c[2] end
  end
  h.eq({ project = "FAKE", type_id = "ep", summary = "Brand new epic", description = "why" },
    { project = create.project, type_id = create.type_id, summary = create.summary, description = create.description })
  h.eq({ "update", "FAKE-2", { parent = "FAKE-3" } }, last_update())
  window.close()
end

T["issue view: j/k jump between sections, e edits the one under the cursor"] = function()
  stub_ui()
  fake.reset()
  fake.issues[1].story_points = 2
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("## Comments", 1, true) end, "issue view")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("j")
  h.truthy(cursor_line():find("^Status"), cursor_line())
  press("j")
  h.truthy(cursor_line():find("^Type"), cursor_line())
  press("j")
  press("j")
  h.truthy(cursor_line():find("^Assignee"), cursor_line())
  press("k")
  h.truthy(cursor_line():find("^Priority"), cursor_line())

  -- j walks to the description header, then to the sub-tasks section
  goto_line("^Updated")
  press("j")
  h.truthy(cursor_line():find("^## Description"), cursor_line())
  press("j")
  h.truthy(cursor_line():find("^## Sub%-tasks"), cursor_line())
  -- inside the description, k goes back to its start
  goto_line("Hello")
  press("k")
  h.truthy(cursor_line():find("^## Description"), cursor_line())
  -- every jump centres the section (zz): the cursor line sits mid-window
  local mid = math.floor((vim.api.nvim_win_get_height(0) + 1) / 2)
  h.truthy(math.abs(vim.fn.winline() - mid) <= 1, ("winline %d, middle %d"):format(vim.fn.winline(), mid))

  -- e on Story points
  goto_line("^Story points")
  inputs = { "8" }
  press("e")
  wait_for(function() return text():find("Story points%s+8") end, "points re-render")
  h.eq({ "update", "FAKE-1", { story_points = 8 } }, last_update())

  -- e on Labels: comma separated, empty entries dropped
  goto_line("^Labels")
  inputs = { "a, b,,c" }
  press("e")
  wait_for(function() local u = last_update() return u and u[3].labels end, "labels update")
  h.eq({ "a", "b", "c" }, last_update()[3].labels)

  -- e on the title renames
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  inputs = { "New title" }
  press("e")
  wait_for(function() return text():find("# FAKE-1  New title", 1, true) end, "title update")

  -- e on the Type line: not editable, nothing sent
  local before = #fake.calls
  goto_line("^Type")
  press("e")
  h.eq(before, #fake.calls)

  -- e on someone's comment vs. the comments header
  goto_line("^## Comments")
  press("e")
  h.eq("acwrite", vim.bo.buftype) -- new comment popup
  press("q")
  window.close()
  vim.ui.select, vim.ui.input = real_select, real_input
end

T["editor: <C-/> inserts panels / code blocks, wraps a selection"] = function()
  stub_ui()
  local editor = require("tracker.ui.editor")
  local buf, win = editor.open({ title = "t", text = "", on_submit = function(_, finish) finish(true) end })
  vim.cmd("stopinsert")
  selects = { function(b) return b.label == "Info panel" end }
  press("<C-_>")
  h.eq({ "> [!INFO]", "> " }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  h.eq({ 2, 2 }, vim.api.nvim_win_get_cursor(win))
  vim.cmd("stopinsert")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  selects = { function(b) return b.code end }
  inputs = { "lua" }
  press("<C-/>")
  h.eq({ "text", "", "```lua", "", "```" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  vim.cmd("stopinsert")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "", "b" })
  selects = { function(b) return b.label == "Success panel" end }
  editor.insert_block(buf, win, 1, 3)
  h.eq({ "> [!SUCCESS]", "> a", ">", "> b" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  vim.bo[buf].modified = false
  pcall(vim.api.nvim_win_close, win, true)
end

T["editor drafts: comments / edits / description kept on close, never asks"] = function()
  stub_ui()
  fake.reset()
  local actions = require("tracker.ui.actions")
  local drafts = require("tracker.ui.drafts")
  drafts.clear()
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function() error("asked") end
  local function set(t) vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(t, "\n", { plain = true })) end
  local function title() return vim.api.nvim_win_get_config(0).title[1][1] end
  local function close()
    vim.cmd("stopinsert")
    press("q")
  end

  -- new comment: closed → draft, back on the next c
  actions.comment("FAKE-1")
  set("half a thought")
  close()
  h.eq(false, vim.bo.filetype == "tracker_edit")
  actions.comment("FAKE-1")
  h.eq("half a thought", text())
  h.truthy(title():find("(draft)", 1, true), title())
  close()
  h.eq("half a thought", drafts.get("comment:FAKE-1")) -- unchanged: kept as it was

  -- reply: the quote goes after the draft; closed unchanged, the draft keeps no quote
  actions.reply("FAKE-1", fake.comments["FAKE-1"][1])
  h.truthy(text():find("^half a thought\n\n> %*%*"), text())
  close()
  h.eq("half a thought", drafts.get("comment:FAKE-1"))

  -- submitted: the draft is gone
  actions.comment("FAKE-1")
  press("<CR>")
  wait_for(function() return vim.bo.filetype ~= "tracker_edit" end, "comment added")
  h.eq(nil, drafts.get("comment:FAKE-1"))
  actions.comment("FAKE-1")
  h.eq("", text())
  close()
  h.eq(nil, drafts.get("comment:FAKE-1"))

  -- editing a comment: own draft; back to the server's text drops it
  local c = fake.comments["FAKE-1"][1]
  actions.edit_comment("FAKE-1", c)
  set("edited")
  close()
  h.eq("edited", drafts.get("comment:FAKE-1:" .. c.id))
  actions.edit_comment("FAKE-1", c)
  h.eq("edited", text())
  set(c.body)
  close()
  h.eq(nil, drafts.get("comment:FAKE-1:" .. c.id))

  -- the description, closed with :q! too
  require("tracker.ui.fields").description({ key = "FAKE-1", description = "old" })
  set("new text")
  vim.cmd("stopinsert")
  vim.cmd("quit!")
  h.eq("new text", drafts.get("description:FAKE-1"))

  -- any other popup: closed without asking, nothing kept
  require("tracker.ui.editor").open({ title = "t", text = "x", on_submit = function() end })
  set("changed")
  close()
  h.eq(false, vim.bo.filetype == "tracker_edit")

  vim.fn.confirm = real_confirm
  drafts.clear()
end

T["issue view: V copies the section's content, v = free mode until <Esc> / q"] = function()
  stub_ui()
  fake.reset()
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("first comment", 1, true) end, "issue view")

  -- V on a comment: its Markdown body, headers left out; still in section mode
  goto_line("first comment")
  press("V")
  h.eq("first comment", vim.fn.getreg('"'))
  goto_line("^Status")
  press("V")
  h.eq("To Do", vim.fn.getreg('"'))
  goto_line("^## Description")
  press("V")
  h.eq("Hello **world**\n\n[attachment: shot.png](adf:1)", vim.fn.getreg('"'))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("V")
  h.eq("First issue", vim.fn.getreg('"'))

  -- v: plain motions; j moves one line, no section mapping left
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("v")
  local function mapped(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      if m.lhs == lhs then return m end
    end
  end
  h.eq(nil, mapped("j"))
  h.eq(nil, mapped("e"))
  h.truthy(require("tracker.ui.window").top().footer:find("FREE", 1, true))
  vim.cmd("normal! j")
  h.eq(2, vim.api.nvim_win_get_cursor(0)[1])
  -- q leaves free mode (does not close the window), keys come back
  press("q")
  h.truthy(require("tracker.ui.window").win() ~= nil, "window stays")
  h.truthy(mapped("j") and mapped("j").desc:find("section", 1, true), "j jumps sections again")
  h.truthy(not require("tracker.ui.window").top().footer:find("FREE", 1, true))
  -- and <Esc> works too
  press("v")
  press("<Esc>")
  h.truthy(mapped("e"), "e is back")
  window.close()
end

local function calls_of(kind)
  return vim.tbl_filter(function(c) return c[1] == kind end, fake.calls)
end

T["list: m marks, p / P re-rank below / above the cursor, <Esc> clears marks"] = function()
  stub_ui()
  fake.reset()
  table.insert(fake.issues, issue("FAKE-3", {}))
  table.insert(fake.issues, issue("FAKE-4", {}))
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-4", 1, true) end, "list")
  goto_line("FAKE%-1 ")
  press("m")
  goto_line("FAKE%-3 ")
  press("m")
  local _, row1 = goto_line("FAKE%-1 ")
  h.truthy(row1:find("●", 1, true), "marked row shows ●: " .. row1)
  -- p below FAKE-4: both marked keys, in list order
  goto_line("FAKE%-4 ")
  press("p")
  wait_for(function() return #calls_of("rank") == 1 end, "rank")
  h.eq({ "rank", { "FAKE-1", "FAKE-3" }, { after = "FAKE-4" } }, calls_of("rank")[1])
  wait_for(function()
    local ls = lines()
    local a, b = nil, nil
    for n, l in ipairs(ls) do
      if l:find("FAKE%-4 ") then a = n end
      if l:find("FAKE%-1 ") then b = n end
    end
    return a and b and b > a
  end, "list re-ordered")
  h.truthy(not text():find("●", 1, true), "marks cleared after the move")

  -- P above, single mark
  goto_line("FAKE%-2 ")
  press("m")
  goto_line("FAKE%-4 ")
  press("P")
  wait_for(function() return #calls_of("rank") == 2 end, "rank above")
  h.eq({ "rank", { "FAKE-2" }, { before = "FAKE-4" } }, calls_of("rank")[2])

  -- p without marks: nothing sent
  wait_for(function() return not text():find("●", 1, true) end)
  goto_line("FAKE%-4 ")
  press("p")
  h.eq(2, #calls_of("rank"))

  -- <Esc> with marks clears them, the window stays
  goto_line("FAKE%-4 ")
  press("m")
  press("<Esc>")
  h.truthy(window.win() ~= nil, "window stays")
  h.truthy(not text():find("●", 1, true), "marks cleared")

  -- <Esc> with a / filter clears it, the window stays
  inputs = { "fake-3" }
  press("/")
  wait_for(function() return text():find("filter: ", 1, true) end, "filtered")
  h.truthy(not text():find("FAKE-4", 1, true), "FAKE-4 filtered out")
  press("<Esc>")
  h.truthy(window.win() ~= nil, "window stays")
  h.truthy(not text():find("filter: ", 1, true), "filter cleared")
  h.truthy(text():find("FAKE-4", 1, true), "FAKE-4 back")

  -- filter, mark a hit, <Esc>: the filter goes first, the mark stays
  inputs = { "fake-3" }
  press("/")
  wait_for(function() return text():find("filter: ", 1, true) end, "filtered")
  goto_line("FAKE%-3 ")
  press("m")
  press("<Esc>")
  h.truthy(not text():find("filter: ", 1, true), "filter cleared")
  h.truthy(text():find("●", 1, true), "mark kept")
  press("<Esc>")
  h.truthy(window.win() ~= nil, "window stays")
  h.truthy(not text():find("●", 1, true), "marks cleared")
  window.close()
end

T["list: p shows the new order at once, even while the search still returns the old one"] = function()
  stub_ui()
  fake.reset()
  fake.stale_rank = true
  table.insert(fake.issues, issue("FAKE-3", {}))
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-3", 1, true) end, "list")
  goto_line("FAKE%-1 ")
  press("m")
  goto_line("FAKE%-3 ")
  press("p")
  wait_for(function() return #calls_of("rank") == 1 end, "rank")
  wait_for(function()
    local at = {}
    for n, l in ipairs(lines()) do
      for k = 1, 3 do
        if l:find("FAKE%-" .. k .. " ") then at[k] = n end
      end
    end
    return at[1] and at[2] and at[3] and at[2] < at[3] and at[3] < at[1]
  end, "FAKE-2, FAKE-3, FAKE-1")
  h.truthy(cursor_line():find("FAKE-1 ", 1, true), "cursor follows the moved issue: " .. cursor_line())
  window.close()
end

T["list: p reorders every section of a sectioned list, the one without the target untouched"] = function()
  stub_ui()
  fake.reset()
  fake.stale_rank = true
  local cfg = require("tracker.config").get()
  cfg.providers.fake.board = 7
  table.insert(fake.issues, issue("FAKE-3", {}))
  fake.backlog_keys = { "FAKE-2", "FAKE-1" } -- the backlog section: no FAKE-3
  require("tracker").search("both")
  wait_for(function() return text():find("backlog", 1, true) and text():find("FAKE-3", 1, true) end, "sections")
  goto_line("FAKE%-1 ")
  press("m")
  goto_line("FAKE%-3 ")
  press("p")
  wait_for(function() return #calls_of("rank") == 1 end, "rank")
  local function order(from)
    local out = {}
    for n, l in ipairs(lines()) do
      if n >= from then
        local k = l:match("FAKE%-(%d) ")
        if k then table.insert(out, tonumber(k)) end
      end
    end
    return out
  end
  wait_for(function() return vim.deep_equal({ 2, 3, 1, 1, 2 }, order(1)) end,
    "all: FAKE-2, FAKE-3, FAKE-1; backlog as it was")
  h.truthy(cursor_line():find("FAKE-1 ", 1, true), "cursor follows the moved issue: " .. cursor_line())
  window.close()
  cfg.providers.fake.board = nil
end

T["list: M moves to sprint / backlog / epic, L labels, d archives, D deletes (asking first)"] = function()
  stub_ui()
  fake.reset()
  local cfg = require("tracker.config").get()
  cfg.providers.fake.board = 7 -- sprint / backlog moves need a board
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")

  goto_line("FAKE%-1 ")
  press("m")
  goto_line("FAKE%-2 ")
  press("m")
  selects = { function(i) return i.label == "Sprint…" end, function(s) return s.id == "s2" end }
  press("M")
  wait_for(function() return #calls_of("sprint") == 1 end, "move to sprint")
  h.eq({ "sprint", "s2", { "FAKE-1", "FAKE-2" } }, calls_of("sprint")[1])

  wait_for(function() return not text():find("●", 1, true) end, "marks cleared")
  goto_line("FAKE%-2 ")
  selects = { function(i) return i.label == "Backlog" end }
  press("M")
  wait_for(function() return #calls_of("to_backlog") == 1 end, "to backlog")
  h.eq({ "to_backlog", { "FAKE-2" } }, calls_of("to_backlog")[1])

  goto_line("FAKE%-2 ")
  selects = { function(i) return i.label == "Epic…" end, function(i) return i.epic and i.epic.key == "FAKE-E" end }
  press("M")
  wait_for(function() local u = last_update() return u and u[3].parent end, "epic")
  h.eq({ "update", "FAKE-2", { parent = "FAKE-E" } }, last_update())

  goto_line("FAKE%-1 ")
  inputs = { "x, y" }
  press("L")
  wait_for(function() local u = last_update() return u and u[3].labels end, "labels")
  h.eq({ "x", "y" }, last_update()[3].labels)

  -- d: cancelled → nothing; confirmed → archive
  goto_line("FAKE%-2 ")
  selects = { 2 } -- "Cancel"
  press("d")
  h.eq(0, #calls_of("archive"))
  selects = { 1 }
  press("d")
  wait_for(function() return #calls_of("archive") == 1 end, "archive")
  h.eq({ "archive", { "FAKE-2" } }, calls_of("archive")[1])

  -- D: the question names the issue and warns it can't be undone
  goto_line("FAKE%-2 ")
  selects = { 1 }
  press("D")
  wait_for(function() return #calls_of("delete") == 1 end, "delete")
  h.eq({ "delete", "FAKE-2", false }, calls_of("delete")[1])
  h.truthy(prompts[#prompts]:find("FAKE-2", 1, true) and prompts[#prompts]:find("undone", 1, true), prompts[#prompts])
  wait_for(function() return not text():find("FAKE-2", 1, true) end, "gone from the list")
  window.close()
  cfg.providers.fake.board = nil
end

T["issue view: D deletes (with sub-tasks) and goes back to the list"] = function()
  stub_ui()
  fake.reset()
  fake.issues[1].subtasks = { { key = "FAKE-9" } }
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-1", 1, true) end, "list")
  local list_buf = vim.api.nvim_get_current_buf()
  goto_line("FAKE%-1 ")
  press("l")
  wait_for(function() return text():find("## Description", 1, true) end, "issue view")
  selects = { 1 }
  press("D")
  wait_for(function() return #calls_of("delete") == 1 end, "delete")
  h.eq({ "delete", "FAKE-1", true }, calls_of("delete")[1])
  h.truthy(prompts[#prompts]:find("sub-task", 1, true), "warns about sub-tasks: " .. prompts[#prompts])
  wait_for(function() return vim.api.nvim_get_current_buf() == list_buf end, "back to the list")
  window.close()
end

T["issue view: comments newest first"] = function()
  stub_ui()
  fake.reset()
  table.insert(fake.comments["FAKE-1"], { id = "c9", author = fake.me, body = "newer comment", created = "2026-10-17T10:00:00.000+0200" })
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("newer comment", 1, true) end, "comments")
  local newer = goto_line("newer comment")
  local older = goto_line("first comment")
  h.truthy(newer < older, ("newest first: %d < %d"):format(newer, older))
  window.close()
end

T["issue view: sub-task and epic lines are their own sections"] = function()
  stub_ui()
  fake.reset()
  fake.issues[1].subtasks = { { key = "FAKE-2", summary = "Second issue", type = { name = "Podzadanie", level = -1, subtask = true } } }
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("## Sub%-tasks %(1%)") end, "issue view")
  local _, epic = goto_line("^Epic")
  h.truthy(epic:find("-", 1, true), epic)
  goto_line("FAKE%-2 ")
  inputs = { "Sub renamed" }
  press("e")
  wait_for(function() local u = last_update() return u and u[2] == "FAKE-2" end, "sub-task rename")
  h.eq({ "update", "FAKE-2", { summary = "Sub renamed" } }, last_update())
  h.truthy(icons.glyph.subtask ~= nil)
  window.close()
  vim.ui.select, vim.ui.input = real_select, real_input
end

return T
