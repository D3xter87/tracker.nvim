-- Backlog-style list: tree of sub-tasks, icons, epic chips, points, preview.

local h = require("helpers")
local fake = require("fake_provider")
local list = require("tracker.ui.list")
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

local TYPE = function(name, level) return { id = name, name = name, subtask = level < 0, level = level } end
local function issue(key, extra)
  return vim.tbl_extend("force", {
    provider = "fake", id = key, key = key, summary = key .. " summary", url = "https://fake/" .. key,
    status = { id = "1", name = "To Do", category = "todo" }, labels = {}, subtasks = {},
    type = TYPE("Zadanie", 0),
  }, extra or {})
end

local T = {}

T["tree: sub-tasks under parents in the parent's order, orphans stay top-level"] = function()
  local parent = issue("P-1", { subtasks = { { key = "P-3" }, { key = "P-2" } } })
  local nodes = list.build_tree({
    parent,
    issue("P-2", { type = TYPE("Podzadanie", -1), parent = { key = "P-1" } }),
    issue("X-1"),
    issue("P-3", { type = TYPE("Podzadanie", -1), parent = { key = "P-1" } }),
    issue("O-1", { type = TYPE("Podzadanie", -1), parent = { key = "GONE-1" } }),
  })
  h.eq({ "P-1", "X-1", "O-1" }, vim.tbl_map(function(n) return n.issue.key end, nodes))
  h.eq({ "P-3", "P-2" }, vim.tbl_map(function(n) return n.issue.key end, nodes[1].children))
end

T["tree: epic → story → sub-task, any depth"] = function()
  local nodes = list.build_tree({
    issue("S-1", { parent = { key = "E-1" }, subtasks = { { key = "T-1" } } }),
    issue("E-1", { type = TYPE("Epik", 1) }),
    issue("T-1", { type = TYPE("Podzadanie", -1), parent = { key = "S-1" } }),
    issue("S-2", { parent = { key = "E-1" } }),
  })
  h.eq(1, #nodes)
  h.eq("E-1", nodes[1].issue.key)
  h.eq({ "S-1", "S-2" }, vim.tbl_map(function(n) return n.issue.key end, nodes[1].children))
  h.eq("T-1", nodes[1].children[1].children[1].issue.key)
end

T["mine: children of listed issues are fetched, whoever they are assigned to"] = function()
  fake.reset()
  local other = { id = "u9", name = "Anna Nowak" }
  fake.issues = {
    issue("FAKE-1", { assignee = fake.me, subtasks = { { key = "FAKE-11" }, { key = "FAKE-12" } } }),
    issue("FAKE-E", { assignee = fake.me, type = TYPE("Epik", 1) }),
  }
  fake.hidden = {
    issue("FAKE-11", { type = TYPE("Podzadanie", -1), parent = { key = "FAKE-1" }, assignee = other }),
    issue("FAKE-12", { type = TYPE("Podzadanie", -1), parent = { key = "FAKE-1" } }),
    issue("FAKE-21", { parent = { key = "FAKE-E", type = TYPE("Epik", 1) }, assignee = other,
                       subtasks = { { key = "FAKE-31" } } }),
    issue("FAKE-31", { type = TYPE("Podzadanie", -1), parent = { key = "FAKE-21" }, assignee = other }),
  }
  local got
  require("tracker.api").search("kids", function(list) got = list end)
  wait_for(function() return got end, "search with children")
  h.eq({ "FAKE-1", "FAKE-E", "FAKE-11", "FAKE-12", "FAKE-21", "FAKE-31" }, vim.tbl_map(function(i) return i.key end, got))
  -- round 1 asks for the story with missing sub-tasks and the epic; round 2
  -- for the epic's story that has sub-tasks of its own
  h.eq({ "children", { "FAKE-1", "FAKE-E" } }, fake.calls[2])
  h.eq({ "children", { "FAKE-21" } }, fake.calls[3])

  require("tracker").search("kids")
  wait_for(function() return text():find("FAKE-31", 1, true) end, "list")
  local l1 = goto_line("FAKE%-1 ")
  local l11, r11 = goto_line("FAKE%-11 ")
  h.eq(l1 + 1, l11)
  h.truthy(r11:find("Anna Nowak", 1, true), r11)
  local le = goto_line("FAKE%-E ")
  local l21, r21 = goto_line("FAKE%-21 ")
  local l31, r31 = goto_line("FAKE%-31 ")
  h.eq({ le + 1, le + 2 }, { l21, l31 })
  -- indentation grows with depth
  h.truthy(#r31:match("^%s*") > #r21:match("^%s*"), r31)
  -- folding the epic hides both levels
  goto_line("FAKE%-E ")
  press("<Tab>")
  h.truthy(not text():find("FAKE-21", 1, true) and not text():find("FAKE-31", 1, true), "epic folded")
  window.close()
end

T["list: labels follow the summary as #tags, columns stay aligned"] = function()
  fake.reset()
  fake.issues[1].labels = { "backend", "hotfix" }
  local cols = vim.o.columns
  vim.o.columns = 200
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  local _, r1 = goto_line("FAKE%-1 ")
  local _, r2 = goto_line("FAKE%-2 ")
  h.truthy(r1:find("#backend #hotfix", 1, true), r1)
  h.truthy(not r2:find("#", 1, true), "no labels, no tags: " .. r2)
  -- the status column starts at the same display column on both rows
  h.eq(vim.fn.strdisplaywidth(r1:sub(1, r1:find("To Do", 1, true))),
    vim.fn.strdisplaywidth(r2:sub(1, r2:find("In Progress", 1, true))))
  window.close()
  -- narrow window: the tags are cut to a third of the column, the summary stays
  vim.o.columns = 80
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "narrow list")
  local _, narrow = goto_line("FAKE%-1 ")
  h.truthy(narrow:find("First issue", 1, true) and narrow:find("#ba", 1, true), narrow)
  window.close()
  vim.o.columns = cols
end

T["list: summaries carry no highlight (cursorline stays whole)"] = function()
  fake.reset()
  fake.issues[1].subtasks = { { key = "FAKE-9" } }
  table.insert(fake.issues, issue("FAKE-9", { type = TYPE("Podzadanie", -1), parent = { key = "FAKE-1" } }))
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-9", 1, true) end, "list")
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, require("tracker.ui.view").ns, 0, -1, { details = true })) do
    local def = vim.api.nvim_get_hl(0, { name = m[4].hl_group, link = false })
    h.truthy(m[4].hl_group ~= "Normal" and m[4].hl_group ~= "TrackerSubtask", m[4].hl_group)
    if not m[4].hl_group:match("^TrackerEpic") and m[4].hl_group ~= "TrackerFilter" then
      h.eq(nil, def.bg, m[4].hl_group .. " paints a background")
    end
  end
  window.close()
end

T["icons: localized (Polish) types"] = function()
  local kinds = {}
  for _, t in ipairs({
    TYPE("Epik", 1), TYPE("Story", 0), TYPE("Zadanie", 0), TYPE("Podzadanie", -1),
    TYPE("Błąd w programie", 0), TYPE("Błąd weryfikacji", -1), TYPE("Weryfikacja", 0),
    TYPE("Eksperyment", 0), TYPE("Retrospective", 0), TYPE("Coś innego", 0),
  }) do
    table.insert(kinds, icons.kind(t))
  end
  h.eq({ "epic", "story", "task", "subtask", "bug", "bug", "test", "experiment", "retro", "task" }, kinds)
  local glyph, group = icons.priority({ priority_id = "1" })
  h.eq("\u{f102}", glyph)
  h.eq("TrackerPriority1", group)
  h.eq(" ", (icons.priority({})))
end

T["icons: epic chip uses Jira's palette with readable text"] = function()
  local group = icons.epic_hl(3) -- yellow #fac304 → dark text
  local def = vim.api.nvim_get_hl(0, { name = group })
  h.eq(0xfac304, def.bg)
  h.eq(0x172b4d, def.fg)
  h.eq(0xffffff, vim.api.nvim_get_hl(0, { name = icons.epic_hl(8) }).fg)
  h.eq("TrackerEpic", icons.epic_hl(nil))
end

T["list: tree rows, fold, epic chip, points, preview"] = function()
  fake.reset()
  fake.issues[1].parent = { key = "FAKE-E", summary = "Stability", type = TYPE("Epik", 1) }
  fake.issues[1].story_points = 3
  fake.issues[1].priority_id = "2"
  fake.issues[1].subtasks = { { key = "FAKE-9" } }
  table.insert(fake.issues, issue("FAKE-9", {
    type = TYPE("Podzadanie", -1), parent = { key = "FAKE-1", summary = "First issue" }, story_points = 0.5,
  }))
  require("tracker").search("all")
  wait_for(function() return text():find("Stability", 1, true) end, "epic chip")

  local l1, row1 = goto_line("FAKE%-1 ")
  local l9, row9 = goto_line("FAKE%-9 ")
  h.eq(l1 + 1, l9) -- sub-task right under its parent
  h.truthy(row1:find(icons.glyph.fold_open, 1, true), row1)
  h.truthy(row1:find(icons.glyph.story, 1, true) or row1:find(icons.glyph.task, 1, true), row1)
  h.truthy(row1:find("\u{f106}", 1, true), "high priority icon: " .. row1)
  h.truthy(row1:find("Stability", 1, true) and row1:find("0/3 ", 1, true), row1)
  h.truthy(row9:find("0.5", 1, true), row9)
  h.truthy(not row9:find("Stability", 1, true), "sub-tasks show no epic")

  -- the chip carries the epic colour (index 8)
  local ns = require("tracker.ui.view").ns
  local found = false
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, { l1 - 1, 0 }, { l1 - 1, -1 }, { details = true })) do
    if m[4].hl_group == "TrackerEpic5244aa" then found = true end
  end
  h.truthy(found, "epic chip highlight")

  -- fold from the child row folds the parent and lands on it
  goto_line("FAKE%-9 ")
  press("<Tab>")
  h.truthy(not text():find("FAKE-9", 1, true), "folded")
  local _, folded = goto_line("FAKE%-1 ")
  h.truthy(folded:find("[+1]", 1, true) and folded:find(icons.glyph.fold_closed, 1, true), folded)
  press("zR")
  h.truthy(text():find("FAKE-9", 1, true), "unfolded")

  -- K previews the description in a float; moving the cursor closes it
  goto_line("FAKE%-1 ")
  local list_win = vim.api.nvim_get_current_win()
  press("K")
  local preview
  wait_for(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= "" and w ~= list_win and cfg.zindex == 70 then
        local t = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
        if t:find("Hello **world**", 1, true) then preview = w return true end
      end
    end
  end, "preview with description")
  local ptext = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false), "\n")
  h.truthy(ptext:find("Assignee", 1, true) and ptext:find("Jan Kowalski", 1, true), ptext)
  goto_line("FAKE%-2 ")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
  wait_for(function() return not vim.api.nvim_win_is_valid(preview) end, "preview closes")
  window.close()
end

T["list: parent row shows sub-task sum / own estimate, flags an overrun"] = function()
  fake.reset()
  fake.issues[1].story_points = 1
  fake.issues[1].subtasks = { { key = "FAKE-8" }, { key = "FAKE-9" } }
  table.insert(fake.issues, issue("FAKE-8", {
    type = TYPE("Podzadanie", -1), parent = { key = "FAKE-1" }, story_points = 2,
    status = { id = "3", name = "Done", category = "done" },
  }))
  table.insert(fake.issues, issue("FAKE-9", { type = TYPE("Podzadanie", -1), parent = { key = "FAKE-1" }, story_points = 0.5 }))
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-9", 1, true) end, "list")
  local l1, parent = goto_line("FAKE%-1 ")
  h.truthy(parent:find(" 2/1 ", 1, true), parent)
  local ns = require("tracker.ui.view").ns
  local over = false
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, { l1 - 1, 0 }, { l1 - 1, -1 }, { details = true })) do
    if m[4].hl_group == "TrackerPointsOver" then over = true end
  end
  h.truthy(over, "closed 2 > estimate 1 is flagged; the open 0.5 does not count")
  local _, other = goto_line("FAKE%-2 ")
  h.truthy(not other:find("/", 1, true), "no sum without sub-tasks: " .. other)
  window.close()
  -- equal sum: not flagged
  fake.reset()
  fake.issues[1].story_points = 2
  fake.issues[1].subtasks = { { key = "FAKE-8" } }
  table.insert(fake.issues, issue("FAKE-8", { type = TYPE("Podzadanie", -1), parent = { key = "FAKE-1" }, story_points = 2,
    status = { id = "3", name = "Rejected", category = "done" } }))
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-8", 1, true) end, "list")
  local l2, row = goto_line("FAKE%-1 ")
  h.truthy(row:find(" 2/2 ", 1, true), row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, { l2 - 1, 0 }, { l2 - 1, -1 }, { details = true })) do
    h.truthy(m[4].hl_group ~= "TrackerPointsOver", "2/2 is fine")
  end
  window.close()
end

T["navigation: list j/k skip non-rows and centre, l opens, h goes back only when it can"] = function()
  fake.reset()
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  local list_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- the subtitle line
  press("j")
  h.truthy(vim.api.nvim_get_current_line():find("FAKE-1", 1, true), "j from the header lands on the first issue")
  press("j")
  h.truthy(vim.api.nvim_get_current_line():find("FAKE-2", 1, true), "next issue")
  press("j") -- past the last row: stays
  h.truthy(vim.api.nvim_get_current_line():find("FAKE-2", 1, true), "stays on the last issue")
  press("k")
  h.truthy(vim.api.nvim_get_current_line():find("FAKE-1", 1, true), "previous issue")

  -- h on the first view: nothing happens, the window stays
  press("h")
  h.eq(list_buf, vim.api.nvim_get_current_buf())
  h.truthy(window.win() ~= nil, "h never closes the window")

  -- l opens the detail view, h comes back
  press("l")
  wait_for(function() return text():find("## Description", 1, true) end, "issue view via l")
  press("h")
  h.eq(list_buf, vim.api.nvim_get_current_buf())
  window.close()

  -- the board keeps h / l for its columns
  require("tracker").board()
  wait_for(function() return text():find("FAKE-1", 1, true) end, "board")
  local hdesc
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
    if m.lhs == "h" then hdesc = m.desc end
  end
  h.truthy(hdesc and hdesc:find("column", 1, true), "board h: " .. tostring(hdesc))
  window.close()
end

T["navigation: q / <Esc> go back, close only from the first view; Q closes all"] = function()
  fake.reset()
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  local list_buf = vim.api.nvim_get_current_buf()
  for _, back in ipairs({ "q", "<Esc>", "<BS>", "<C-O>" }) do
    goto_line("FAKE%-1 ")
    press("<CR>")
    wait_for(function() return text():find("## Description", 1, true) end, "issue view")
    press(back)
    h.eq(list_buf, vim.api.nvim_get_current_buf())
    h.truthy(window.win() ~= nil, back .. " keeps the window open")
  end
  goto_line("FAKE%-1 ")
  press("<CR>")
  wait_for(function() return text():find("## Description", 1, true) end, "issue view")
  press("Q")
  h.eq(nil, window.win())
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  press("q")
  h.eq(nil, window.win())
end


T["list: fit = right-hand columns follow the longest summary; fill = to the edge"] = function()
  fake.reset()
  local cols = vim.o.columns
  vim.o.columns = 260
  local ui = require("tracker.config").get().ui
  local function status_col()
    local _, r = goto_line("FAKE%-1 ")
    return vim.fn.strdisplaywidth(r:sub(1, r:find("To Do", 1, true)))
  end
  ui.list_width = "fit"
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  local fit = status_col()
  local _, r2 = goto_line("FAKE%-2 ")
  h.eq(fit, vim.fn.strdisplaywidth(r2:sub(1, r2:find("In Progress", 1, true))))
  window.close()
  ui.list_width = "fill"
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  local fill = status_col()
  window.close()
  ui.list_width = "fit"
  vim.o.columns = cols
  h.truthy(fit < 100, "fit: status at column " .. fit)
  h.truthy(fill > 150, "fill: status at column " .. fill)
end


T["list: a story in two sections sums the sub-tasks the whole list knows"] = function()
  -- "both" = all + backlog; the backlog lists the story without its closed
  -- sub-task (Jira's backlog has no resolved issues). Its sum is the same in
  -- both sections — one story, one progress.
  fake.reset()
  local cfg = require("tracker.config").get()
  cfg.providers.fake.board = 7
  fake.issues[1].story_points = 5
  fake.issues[1].subtasks = { { key = "FAKE-8" }, { key = "FAKE-9" } }
  table.insert(fake.issues, issue("FAKE-8", {
    type = TYPE("Podzadanie", -1), parent = { key = "FAKE-1" }, story_points = 2,
    status = { id = "3", name = "Done", category = "done" },
  }))
  table.insert(fake.issues, issue("FAKE-9", { type = TYPE("Podzadanie", -1), parent = { key = "FAKE-1" }, story_points = 1 }))
  fake.backlog_keys = { "FAKE-1", "FAKE-9" }
  require("tracker").search("both")
  wait_for(function() return text():find("backlog", 1, true) and select(2, text():gsub("FAKE%-1 ", "")) == 2 end, "both sections")
  local rows = vim.tbl_filter(function(l) return l:find("FAKE%-1 ") end, lines())
  h.eq(2, #rows, text())
  for _, row in ipairs(rows) do h.truthy(row:find(" 2/5 ", 1, true), row) end
  window.close()
  cfg.providers.fake.board = nil
end

return T
