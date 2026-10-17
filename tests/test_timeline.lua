-- Timeline: spans, bars, the API's data, the view's editing keys.

local h = require("helpers")
local fake = require("fake_provider")
local tl = require("tracker.ui.timeline")
local date = require("tracker.util.date")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
require("tracker.notify").set_sink(function() end)
local api = require("tracker.api")
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
    local ok, err = pcall(fn)
    pcall(window.close)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
    end
    if not ok then error(err, 0) end
  end
end

local TYPE = function(name, level) return { id = name, name = name, subtask = level < 0, level = level } end
local function issue(key, extra)
  return vim.tbl_extend("force", {
    provider = "fake", id = key, key = key, summary = key .. " summary", labels = {}, subtasks = {},
    status = { id = "1", name = "To Do", category = "todo" }, type = TYPE("Zadanie", 0),
  }, extra or {})
end
local function day(s) return date.parse(s) end
local SPRINT = { id = "60", name = "#60", start_date = "2026-10-13T06:00:00.000Z", end_date = "2026-11-02T12:00:00.000Z" }
local OLD = { id = "59", name = "#59", start_date = "2026-09-21T09:00:00.000Z", end_date = "2026-10-12T12:00:00.000Z" }

local T = {}

-- region pure

T["span: own dates, else the newest sprint, else the fallback; derived flagged"] = function()
  local s, e, d = tl.span(issue("A", { start_date = "2026-10-01", due_date = "2026-10-20" }))
  h.eq({ day("2026-10-01"), day("2026-10-20"), false }, { s, e, d })
  s, e, d = tl.span(issue("B", { sprints = { OLD, SPRINT } }))
  h.eq({ date.parse_iso(SPRINT.start_date), date.parse_iso(SPRINT.end_date), true }, { s, e, d })
  -- only a due date, no sprint: a one-day mark, not derived
  s, e, d = tl.span(issue("C", { due_date = "2026-10-20" }))
  h.eq({ day("2026-10-20"), day("2026-10-20"), false }, { s, e, d })
  -- only a due date with a sprint: start from the sprint
  s, e, d = tl.span(issue("D", { due_date = "2026-10-30", sprints = { SPRINT } }))
  h.eq({ date.parse_iso(SPRINT.start_date), day("2026-10-30"), true }, { s, e, d })
  h.eq({ nil, nil, false }, { tl.span(issue("E")) })
end

T["epic_span: own dates win, else the span of its issues"] = function()
  local kids = { issue("A", { start_date = "2026-10-05", due_date = "2026-10-10" }), issue("B", { sprints = { SPRINT } }) }
  local s, e, d = tl.epic_span(issue("E"), kids)
  h.eq({ day("2026-10-05"), date.parse_iso(SPRINT.end_date), true }, { s, e, d })
  s, e, d = tl.epic_span(issue("E", { start_date = "2026-09-01", due_date = "2026-12-01" }), kids)
  h.eq({ day("2026-09-01"), day("2026-12-01"), false }, { s, e, d })
end

T["progress and bar cells: split by status, clipped with ◀ ▶"] = function()
  local n, total = tl.progress({ issue("A", { status = { category = "done" } }), issue("B"), issue("C"), issue("D", { status = { category = "in_progress" } }) })
  h.eq({ { done = 1, in_progress = 1, todo = 2 }, 4 }, { n, total })
  local origin = day("2026-10-01") + 12 * 3600
  -- 8 days at 1 col/day, 1 / 1 / 2 split → 2 / 2 / 4 cells
  local cells = tl.bar_cells(origin, 1, 40, day("2026-10-03"), day("2026-10-10"), "x", "H",
    { { n = 1, char = "D" }, { n = 1, char = "P" }, { n = 2, char = "T" } })
  local s = ""
  for c = 2, 9 do s = s .. cells[c][1] end
  h.eq("DDPPTTTT", s)
  h.eq(nil, cells[1])
  -- runs off both edges
  cells = tl.bar_cells(origin, 1, 10, day("2026-09-20"), day("2026-10-30"), "x", "H")
  h.eq({ "\u{25c0}", "x", "\u{25b6}" }, { cells[0][1], cells[5][1], cells[9][1] })
  -- entirely before the chart: just the arrow
  cells = tl.bar_cells(origin, 1, 10, day("2026-09-01"), day("2026-09-05"), "x", "H")
  h.eq({ "\u{25c0}" }, { cells[0][1] })
  h.eq(nil, cells[1])
end

T["default_origin: weeks start on a Monday before today, months on the 1st"] = function()
  local today = day("2026-10-17") -- a Saturday
  h.eq("2026-09-28", os.date("%Y-%m-%d", tl.default_origin(tl.SCALES[2], today)))
  h.eq("2026-09-01", os.date("%Y-%m-%d", tl.default_origin(tl.SCALES[3], today)))
end

-- endregion

-- region API + view

local function seed()
  fake.reset()
  fake.epic_rows = {
    issue("E-1", { type = TYPE("Epik", 1), summary = "Dated", start_date = "2026-10-05", due_date = "2026-10-25" }),
    issue("E-2", { type = TYPE("Epik", 1), summary = "From sprints" }),
  }
  fake.epic_data["E-1"] = { key = "E-1", summary = "Dated", color = 4 }
  fake.hidden = {
    issue("A-1", { parent = { key = "E-1" }, status = { id = "3", name = "Done", category = "done" }, start_date = "2026-10-05", due_date = "2026-10-09" }),
    issue("A-2", { parent = { key = "E-1" }, sprints = { SPRINT } }),
    issue("B-1", { parent = { key = "E-2" }, sprints = { SPRINT } }),
  }
end

T["api.timeline: epics with colour, children by epic, done_days passed on"] = function()
  seed()
  local got
  api.timeline(function(t) got = t end, { done_days = 90 })
  wait_for(function() return got end, "timeline")
  h.eq({ "E-1", "E-2" }, vim.tbl_map(function(e) return e.key end, got.epics))
  h.eq(4, got.epics[1].color)
  h.eq({ "A-1", "A-2" }, vim.tbl_map(function(i) return i.key end, got.children["E-1"]))
  h.eq({ "epic_issues", "FAKE", { done_days = 90 } }, fake.calls[1])
end

T["view: epic rows with progress, <Tab> shows the issues, > moves a bar a week"] = ui_test(function()
  seed()
  require("tracker").timeline()
  wait_for(function() return text():find("E-2", 1, true) end, "timeline")
  local _, row = goto_line("E%-1 ")
  h.truthy(row:find("50%", 1, true), row) -- 1 of 2 issues done
  h.truthy(not text():find("A-1", 1, true), "folded")
  press("<Tab>")
  h.truthy(text():find("A-1", 1, true) and text():find("A-2", 1, true), "unfolded")

  -- > > : two weeks later, saved once after the pause
  goto_line("E%-1 ")
  press(">")
  press(">")
  wait_for(function()
    for _, c in ipairs(fake.calls) do
      if c[1] == "update" then return true end
    end
  end, "saved")
  local updates = vim.tbl_filter(function(c) return c[1] == "update" end, fake.calls)
  h.eq(1, #updates)
  h.eq({ "E-1", { start_date = "2026-10-19", due_date = "2026-11-08" } }, { updates[1][2], updates[1][3] })

  -- ] on a derived bar (sprint only): real dates from the sprint, end + 1 week
  goto_line("A%-2 ")
  press("]")
  wait_for(function() return #vim.tbl_filter(function(c) return c[1] == "update" end, fake.calls) == 2 end, "second save")
  local u = vim.tbl_filter(function(c) return c[1] == "update" end, fake.calls)[2]
  h.eq("A-2", u[2])
  h.eq(os.date("%Y-%m-%d", date.parse_iso(SPRINT.start_date)), u[3].start_date)
  h.eq(os.date("%Y-%m-%d", date.add_days(date.parse_iso(SPRINT.end_date), 7)), u[3].due_date)
end)

T["view: e edits both dates in a popup, empty clears"] = ui_test(function()
  seed()
  require("tracker").timeline()
  wait_for(function() return text():find("E-1", 1, true) end, "timeline")
  goto_line("E%-1 ")
  press("e")
  wait_for(function() return vim.bo.filetype == "tracker_edit" end, "form")
  h.eq({ "Start: 2026-10-05", "Due:   2026-10-25" }, lines())
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Start:", "Due: 2026-11-30" })
  press("<C-s>")
  wait_for(function() return fake.calls[#fake.calls][1] == "update" end, "update")
  h.eq({ start_date = false, due_date = "2026-11-30" }, fake.calls[#fake.calls][3])
end)

-- endregion

return T
