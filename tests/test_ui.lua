-- API events + headless UI smoke tests against the in-memory fake provider.
-- Keymaps are invoked through their buffer-local callbacks, i.e. exactly
-- what pressing the key runs.

local h = require("helpers")
local fake = require("fake_provider")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({
  default_provider = "fake",
  providers = { fake = { base_url = "https://fake" } },
})
local messages = {}
require("tracker.notify").set_sink(function(msg) table.insert(messages, msg) end)

local api = require("tracker.api")
local window = require("tracker.ui.window")

local function wait_for(pred, what)
  local ok = vim.wait(3000, pred, 10)
  if not ok then error("timed out waiting for " .. (what or "condition") .. "\nmessages: " .. vim.inspect(messages), 2) end
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false), "\n")
end

local function press(lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
    if m.lhs == lhs then return m.callback() end
  end
  error("no mapping for " .. lhs)
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

local function capture(event)
  local got = {}
  vim.api.nvim_create_autocmd("User", { pattern = event, once = true, callback = function(ev) table.insert(got, ev.data) end })
  return got
end

-- vim.ui.select / input: take a scripted answer instead of prompting.
local answers = {}
vim.ui.select = function(items, opts, cb)
  local pick = table.remove(answers, 1)
  if type(pick) == "function" then
    for _, it in ipairs(items) do
      if pick(it, opts) then return cb(it) end
    end
    return cb(nil)
  end
  cb(items[pick or 1])
end

local T = {}

T["a1 api: transition by target status emits event"] = function()
  fake.reset()
  local got = capture("TrackerTransitioned")
  local done
  api.transition("FAKE-1", "done", function(t) done = t end)
  wait_for(function() return done end, "transition")
  h.eq("Finish", done.name)
  h.eq({ "transition", "FAKE-1", "21" }, fake.calls[1])
  h.eq("FAKE-1", got[1].key)
  h.eq("Done", got[1].status.name)
  h.eq("fake", got[1].provider)
end

T["a2 api: unknown transition lists the options"] = function()
  local err
  api.transition("FAKE-1", "nope", function(_, e) err = e end)
  wait_for(function() return err end)
  h.truthy(err:find("Start, Finish, Reopen", 1, true), err)
end

T["a3 api: assign me + create by type name"] = function()
  fake.reset()
  local got = capture("TrackerAssigned")
  local who
  api.assign("FAKE-2", "me", function(a) who = a end)
  wait_for(function() return who end)
  h.eq({ "assign", "FAKE-2", "u1" }, fake.calls[1])
  h.eq("Jan Kowalski", got[1].assignee.name)

  local created
  api.create({ summary = "New", type = "task" }, function(i) created = i end)
  wait_for(function() return created end)
  h.eq("FAKE-3", created.key)
  h.eq("t", fake.calls[2][2].type_id)
  h.eq("FAKE", fake.calls[2][2].project)
end

T["a4 api: saved queries expand {project}"] = function()
  h.eq({ { name = "all", jql = "project = FAKE" }, { name = "kids", jql = "assignee = me", children = true },
    { name = "both", sections = { "all", "backlog" } } }, api.queries())
  h.eq("project = FAKE", (api.resolve_query("all")))
  h.eq("status = Open", (api.resolve_query("status = Open")))
end

T["a5 api: backlog query uses the board backlog"] = function()
  fake.reset()
  local cfg = require("tracker.config").get()
  cfg.providers.fake.board = 7
  h.eq({ { name = "all", jql = "project = FAKE" }, { name = "sprint", sprint = true }, { name = "backlog", backlog = true },
    { name = "kids", jql = "assignee = me", children = true }, { name = "both", sections = { "all", "backlog" } } }, api.queries())
  local sprint
  api.search("sprint", function(list) sprint = list end)
  wait_for(function() return sprint end, "sprint")
  h.eq({ "FAKE-1", "FAKE-2" }, vim.tbl_map(function(i) return i.key end, sprint))
  local issues
  api.search("backlog", function(list) issues = list end)
  wait_for(function() return issues end, "backlog")
  h.eq({ "board_issues", "s1" }, fake.calls[1])
  h.eq({ "backlog", "7" }, fake.calls[2])
  h.eq("FAKE-2", issues[1].key)
  cfg.providers.fake.board = nil
end

T["a6 api: attachments download once, then come from the cache"] = function()
  fake.reset()
  fake.downloads = 0
  local att = { id = "a6-" .. tostring(vim.uv.hrtime()), filename = "x.png" }
  local p1, p2
  api.attachment_path(att, function(p) p1 = p end)
  api.attachment_path(att, function(p) p2 = p end) -- concurrent: shares the download
  wait_for(function() return p1 and p2 end)
  h.eq(p1, p2)
  local p3
  api.attachment_path(att, function(p) p3 = p end)
  wait_for(function() return p3 end)
  h.eq(1, fake.downloads)
  os.remove(p1)
end

T["b1 ui: list → status change → issue → comment → back"] = function()
  fake.reset()
  require("tracker").search("all")
  local list_buf = vim.api.nvim_get_current_buf()
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list rows")
  h.truthy(text():find("project = FAKE", 1, true))
  h.eq(" all (2) ", window.top().title)

  -- s on FAKE-1: pick "Start" (first) → list reloads with the new status
  on_line("FAKE%-1")
  answers = { 1 }
  press("s")
  wait_for(function() return text():match("FAKE%-1[^\n]*In Progress") end, "status refresh")

  -- <CR> opens the issue
  on_line("FAKE%-1")
  press("<CR>")
  wait_for(function() return text():find("## Comments (1)", 1, true) end, "issue view")
  local t = text()
  h.truthy(t:find("# FAKE-1  First issue", 1, true), t)
  h.truthy(t:find("Hello **world**", 1, true), t)
  h.truthy(t:find("first comment", 1, true), t)
  local issue_buf = vim.api.nvim_get_current_buf()

  -- c opens the editor; :write submits and returns to a refreshed issue
  press("c")
  vim.cmd("stopinsert")
  local ed = vim.api.nvim_get_current_buf()
  h.eq("acwrite", vim.bo[ed].buftype)
  vim.api.nvim_buf_set_lines(ed, 0, -1, false, { "second *comment*" })
  vim.cmd("write")
  wait_for(function()
    return vim.api.nvim_get_current_buf() == issue_buf and text():find("## Comments (2)", 1, true)
  end, "comment round trip")
  h.eq(false, vim.api.nvim_buf_is_valid(ed))
  h.truthy(text():find("second *comment*", 1, true))

  -- R on the first comment: reply with quote + mention
  on_line("first comment")
  press("R")
  vim.cmd("stopinsert")
  local reply = text()
  h.truthy(reply:find("> **Jan Kowalski** wrote:", 1, true), reply)
  h.truthy(reply:find("[@Jan Kowalski](mention:u1)", 1, true), reply)
  press("q") -- unmodified → cancel without asking

  -- <BS> back to the list, still there
  wait_for(function() return vim.api.nvim_get_current_buf() == issue_buf end)
  press("<BS>")
  h.eq(list_buf, vim.api.nvim_get_current_buf())
  press("q")
  h.eq(nil, window.win())
end

T["b2 ui: e on the description section edits the description only"] = function()
  fake.reset()
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("## Description", 1, true) end)
  on_line("^## Description")
  press("e")
  local ed = vim.api.nvim_get_current_buf()
  h.eq({ "Hello **world**", "", "[attachment: shot.png](adf:1)" }, vim.api.nvim_buf_get_lines(ed, 0, -1, false))
  vim.api.nvim_buf_set_lines(ed, 0, 1, false, { "Changed text" })
  vim.cmd("write")
  wait_for(function() return text():find("Changed text", 1, true) end, "description round trip")
  h.eq({ "update", "FAKE-1", { description = "Changed text\n\n[attachment: shot.png](adf:1)" } }, fake.calls[#fake.calls])
  window.close()
end

T["b3 ui: board columns and moving a card"] = function()
  fake.reset()
  require("tracker").board()
  wait_for(function() return text():find("DOING (1)", 1, true) end, "board")
  local t = text()
  h.truthy(t:find("Sprint 42", 1, true), t)
  h.truthy(t:find("TO DO (1)", 1, true), t)
  h.truthy(t:find("DONE (0)", 1, true), t)
  h.truthy(t:find("FAKE-1 JK First issue", 1, true), t)

  on_line("FAKE%-1")
  press(">")
  wait_for(function() return text():find("DOING (2)", 1, true) end, "card moved")
  h.truthy(vim.tbl_contains(fake.calls, function(c) return vim.deep_equal(c, { "transition", "FAKE-1", "11" }) end, { predicate = true }), vim.inspect(fake.calls))

  -- l moves the cursor into the next column; m filters to my issues
  on_line("FAKE%-1")
  press("m")
  h.truthy(text():find("[mine]", 1, true))
  h.truthy(not text():find("FAKE-2", 1, true), "FAKE-2 is not mine")
  window.close()
end

T["b4 ui: images via snacks, <CR> opens the attachment"] = function()
  fake.reset()
  local placed, opened = {}, nil
  package.loaded["snacks"] = { image = {
    supports_terminal = function() return true end,
    placement = {
      clean = function() end,
      new = function(buf, path, opts) table.insert(placed, { buf = buf, path = path, opts = opts }) end,
    },
  } }
  local real_open = vim.ui.open
  vim.ui.open = function(p) opened = p end

  require("tracker").issue("FAKE-1")
  wait_for(function() return #placed > 0 end, "image placement")
  local lnum = on_line("%[attachment: shot%.png%]")
  h.eq(lnum, placed[1].opts.range[1])
  h.eq(true, placed[1].opts.inline)
  h.truthy(placed[1].path:find("9%-shot%.png$"), placed[1].path)
  h.truthy(text():find("## Attachments (1)", 1, true))

  press("<CR>")
  wait_for(function() return opened end, "open attachment")
  h.eq(placed[1].path, opened)

  window.close()
  package.loaded["snacks"] = nil
  vim.ui.open = real_open
end

T["b4b ui: photos with an EXIF rotation are drawn upright"] = function()
  local images = require("tracker.ui.images")
  local png = vim.fn.tempname() .. ".png"
  local got
  images.upright(png, function(p) got = p end)
  h.eq(png, got) -- PNGs carry no EXIF rotation: as is
  if vim.fn.executable("magick") == 0 then return end
  -- 40x20 stored, tagged "rotate 90° clockwise to view" (as phones save
  -- them): a minimal EXIF segment (Orientation = 6) right after the SOI
  local jpg = vim.fn.tempname() .. ".jpg"
  vim.system({ "magick", "-size", "40x20", "xc:red", jpg }):wait()
  local f = assert(io.open(jpg, "rb"))
  local data = f:read("*a")
  f:close()
  local exif = "\255\225\0\34Exif\0\0II*\0\8\0\0\0\1\0\18\1\3\0\1\0\0\0\6\0\0\0\0\0\0\0"
  f = assert(io.open(jpg, "wb"))
  f:write(data:sub(1, 2) .. exif .. data:sub(3))
  f:close()
  got = nil
  images.upright(jpg, function(p) got = p end)
  wait_for(function() return got end, "upright copy")
  h.truthy(got:find("%.upright%.jpg$"), got)
  h.eq("20x40", vim.trim(vim.system({ "magick", "identify", "-format", "%wx%h", got }, { text = true }):wait().stdout))
end

T["b5 ui: no snacks → no images, nothing breaks"] = function()
  fake.reset()
  package.loaded["snacks"] = nil
  local images = require("tracker.ui.images")
  h.eq(nil, images.snacks())
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("## Attachments", 1, true) end)
  window.close()
end

T["b6 ui: editor popup submits with <C-s> like review.nvim"] = function()
  fake.reset()
  require("tracker").issue("FAKE-2")
  wait_for(function() return text():find("## Comments (0)", 1, true) end)
  local issue_win = vim.api.nvim_get_current_win()
  press("c")
  h.truthy(vim.api.nvim_get_current_win() ~= issue_win, "popup is its own window")
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "via ctrl-s" })
  press("<C-S>")
  wait_for(function() return vim.api.nvim_get_current_win() == issue_win and text():find("via ctrl-s", 1, true) end, "popup submit")
  window.close()
end

T["b7 ui: editor returns to the tracker even after a picker opened from it"] = function()
  fake.reset()
  require("tracker").issue("FAKE-2")
  wait_for(function() return text():find("## Comments (0)", 1, true) end)
  local issue_win = vim.api.nvim_get_current_win()
  press("c")
  vim.cmd("stopinsert")
  local popup = vim.api.nvim_get_current_win()
  -- a picker / chooser over the popup: closing it leaves `prevwin` invalid
  local picker = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true,
    { relative = "editor", row = 1, col = 1, width = 10, height = 1, zindex = 70 })
  vim.api.nvim_win_close(picker, true)
  vim.api.nvim_set_current_win(popup)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "after a picker" })
  press("<C-S>")
  wait_for(function() return vim.api.nvim_get_current_win() == issue_win and text():find("after a picker", 1, true) end,
    "back in the tracker window")
  window.close()
end

T["b8 ui: layout split / vsplit / tab — ordinary window, title in the winbar"] = function()
  local ui = require("tracker.config").get().ui
  for _, layout in ipairs({ "split", "vsplit", "tab" }) do
    fake.reset()
    ui.layout = layout
    local tabs, wins = #vim.api.nvim_list_tabpages(), #vim.api.nvim_tabpage_list_wins(0)
    require("tracker").issue("FAKE-1")
    wait_for(function() return text():find("## Description", 1, true) end, layout .. " issue view")
    local win = window.win()
    h.eq(win, vim.api.nvim_get_current_win())
    h.eq("", vim.api.nvim_win_get_config(win).relative, layout .. ": not a float")
    h.truthy(vim.wo[win].winbar:find("FAKE-1", 1, true), vim.wo[win].winbar)
    if layout == "tab" then
      h.eq(tabs + 1, #vim.api.nvim_list_tabpages())
      h.eq(1, #vim.api.nvim_tabpage_list_wins(0), "no scratch window left in the tab")
    else
      h.eq(tabs, #vim.api.nvim_list_tabpages())
      h.eq(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
    end
    press("q")
    h.eq(nil, window.win())
    h.eq(tabs, #vim.api.nvim_list_tabpages(), layout .. ": tab closed")
    h.eq(wins, #vim.api.nvim_tabpage_list_wins(0), layout .. ": window closed")
  end
  ui.layout = "float"
end

T["b9 ui: the list reloads again until Jira's index shows the change"] = function()
  fake.reset()
  local sync = require("tracker.ui.sync")
  local delays = sync.delays
  sync.delays = { 20, 20, 20, 20 }
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list rows")
  local searches = function()
    return #vim.tbl_filter(function(c) return c[1] == "search" end, fake.calls)
  end
  local before = searches()

  -- the index answers the next two listings with the state from before
  fake.freeze(2)
  on_line("FAKE%-1")
  answers = { 1 }
  press("s")
  wait_for(function() return text():match("FAKE%-1[^\n]*In Progress") end, "status shown after the index caught up")
  h.eq(before + 3, searches(), "two stale reloads, then the fresh one")
  h.eq(" all (2) ", window.top().title, "not syncing any more")
  -- nothing marked: a plain refresh reloads once
  press("r")
  wait_for(function() return searches() == before + 4 end, "refresh")
  vim.wait(100)
  h.eq(before + 4, searches(), "no repeat without a pending change")

  -- the index never catches up: gives up after the delays, says so
  fake.freeze(10)
  messages = {}
  on_line("FAKE%-1")
  answers = { 2 }
  press("s")
  wait_for(function()
    return vim.tbl_contains(messages, function(m) return m:find("hasn't caught up with FAKE-1", 1, true) end, { predicate = true })
  end, "gave up")
  h.eq(before + 4 + 5, searches(), "the reload plus one per delay")
  window.close()
  sync.delays = delays
end

T["b10 ui: the board reloads again until the moved card shows up"] = function()
  fake.reset()
  local sync = require("tracker.ui.sync")
  local delays = sync.delays
  sync.delays = { 20, 20, 20, 20 }
  require("tracker").board()
  wait_for(function() return text():find("DOING (1)", 1, true) end, "board")
  local loads = function()
    return #vim.tbl_filter(function(c) return c[1] == "board_issues" end, fake.calls)
  end
  local before = loads()
  fake.freeze(1)
  on_line("FAKE%-1")
  press(">")
  wait_for(function() return text():find("DOING (2)", 1, true) end, "card moved once the index caught up")
  h.eq(before + 2, loads(), "one stale reload, then the fresh one")
  vim.wait(100)
  h.eq(before + 2, loads())
  window.close()
  sync.delays = delays
end

T["b11 ui: Q closes the window from free mode and from the help float"] = function()
  fake.reset()
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-1", 1, true) end, "list")
  on_line("FAKE%-1")
  press("<CR>")
  wait_for(function() return text():find("First issue", 1, true) end, "issue")
  press("v")
  press("Q")
  h.eq(0, window.depth())

  require("tracker").issue("FAKE-1")
  press("?")
  local help = vim.api.nvim_get_current_win()
  press("Q")
  h.eq(0, window.depth())
  h.eq(false, vim.api.nvim_win_is_valid(help))
end

T["b12 ui: layout tab — one tracker tab per project tab, each with its own stack and cwd"] = function()
  local ui = require("tracker.config").get().ui
  fake.reset()
  ui.layout = "tab"
  local home = vim.api.nvim_get_current_tabpage()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.cmd.tcd(vim.fn.fnameescape(dir))

  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("First issue", 1, true) end, "first tracker tab")
  local first = window.win()
  local first_tab = vim.api.nvim_get_current_tabpage()
  h.eq(vim.fs.normalize(dir), vim.fs.normalize(vim.fn.getcwd()), "the tracker tab keeps the project tab's cwd")

  -- back in the project tab: a second tracker is a second tab, the first untouched
  vim.api.nvim_set_current_tabpage(home)
  require("tracker").issue("FAKE-2")
  wait_for(function() return text():find("Second issue", 1, true) end, "second tracker tab")
  local second = window.win()
  h.truthy(first ~= second, "a window of its own")
  h.truthy(vim.api.nvim_win_get_tabpage(second) ~= first_tab, "a tab of its own")
  h.eq({ first, second }, window.list())
  h.truthy(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(first), 0, 1, false)[1]:find("FAKE-1", 1, true),
    "the first tracker still shows its issue")

  -- inside a tracker tab, views stack as before; q pops only there
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("First issue", 1, true) end, "issue pushed in the second tab")
  h.eq(2, window.depth(), "two views here")
  vim.api.nvim_set_current_win(first)
  h.eq(1, window.depth(), "one view in the first tab")
  vim.api.nvim_set_current_win(second)
  press("q")
  h.eq(1, window.depth())
  h.truthy(text():find("Second issue", 1, true), "back to the second tab's own issue")

  -- closing one leaves the other (its tab is the one to land on)
  press("q")
  h.eq({ first }, window.list())
  h.eq(first, window.win(), "the remaining tracker tab is the next one over")
  vim.api.nvim_set_current_win(first)
  press("q")
  h.eq({}, window.list())
  h.eq(home, vim.api.nvim_get_current_tabpage())
  vim.cmd.tcd(vim.fn.fnameescape(vim.fn.getcwd(-1, -1)))
  ui.layout = "float"
end

T["b14 ui: ui.redraw auto = full inside tmux on Windows; a scroll of a view redraws it"] = function()
  local view = require("tracker.ui.view")
  local ui = require("tracker.config").get().ui
  local tmux = vim.env.TMUX
  ui.redraw = "auto"
  vim.env.TMUX = nil
  h.eq("window", view.redraw_mode(), "no tmux: window")
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  h.eq(vim.fn.has("win32") == 1 and "full" or "window", view.redraw_mode(), "tmux: full on Windows only")
  ui.redraw = "full"
  h.eq("full", view.redraw_mode(), "an explicit mode wins")
  ui.redraw = false
  h.eq(false, view.redraw_mode())
  ui.redraw = "auto"
  vim.env.TMUX = tmux

  -- every view watches its scrolls: the autocmd goes with the buffer
  fake.reset()
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("## Description", 1, true) end, "issue")
  local buf = vim.api.nvim_get_current_buf()
  h.eq(1, #vim.api.nvim_get_autocmds({ group = "TrackerRedraw" .. buf, event = "WinScrolled" }), "WinScrolled watched")
  press("q")
  h.eq(false, pcall(vim.api.nvim_get_autocmds, { group = "TrackerRedraw" .. buf }), "gone with the buffer")
end

T["b13 ui: a float is one per tab page: reused from any window of its tab, new in another tab"] = function()
  fake.reset()
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("First issue", 1, true) end, "issue")
  local first = window.win()
  local below = vim.fn.win_getid(vim.fn.winnr("#")) -- the window the float opened over
  if below == 0 or below == first then below = vim.api.nvim_tabpage_list_wins(0)[1] end
  vim.api.nvim_set_current_win(below)
  require("tracker").issue("FAKE-2")
  wait_for(function() return text():find("Second issue", 1, true) end, "second issue")
  h.eq(first, vim.api.nvim_get_current_win(), "pushed on the tab's float and focused")
  h.eq(2, window.depth())

  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("First issue", 1, true) end, "issue in the new tab")
  local second = window.win()
  h.truthy(second ~= first, "a float of its own in the other tab")
  h.eq(1, window.depth())
  h.eq({ first, second }, window.list(), "both open")
  press("q")
  h.eq({ first }, window.list())
  vim.cmd("tabclose")
  h.truthy(tab ~= vim.api.nvim_get_current_tabpage())
  window.close_all()
  h.eq({}, window.list())
end

return T
