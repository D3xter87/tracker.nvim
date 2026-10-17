-- Sprint management: dates, the form, the API's complete flow, the view.

local h = require("helpers")
local fake = require("fake_provider")
local date = require("tracker.util.date")
local form = require("tracker.ui.sprintform")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
local notes = {}
require("tracker.notify").set_sink(function(msg) table.insert(notes, msg) end)
local api = require("tracker.api")
local window = require("tracker.ui.window")

local BOARD = { board = "7" }

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
local function set_field(name, value)
  for lnum, l in ipairs(lines()) do
    if l:match("^" .. name .. ":") then
      vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { name .. ": " .. value })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
      return
    end
  end
  error("no field " .. name)
end
local function field(name)
  for _, l in ipairs(lines()) do
    local v = l:match("^" .. name .. ":%s*(.-)%s*$")
    if v then return v end
  end
end

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

-- region dates

T["date: ISO ↔ local, durations, DST-safe day arithmetic"] = function()
  local t = date.parse_iso("2026-10-13T06:31:52.786Z")
  h.eq(t, date.parse_iso(date.to_iso(t)) + 52 - 52) -- seconds survive the round trip
  h.eq(date.parse_iso("2026-10-13T08:31:52.000+02:00"), t)
  h.eq(date.parse_iso("2026-10-13T08:31:52.000+0200"), t)
  local s = date.parse("2026-10-19 09:00")
  h.eq("2026-10-19 09:00", date.format(s))
  -- across the October DST change the time of day stays
  h.eq("2026-11-02 09:00", date.format(date.add_days(s, 14)))
  h.eq("2w", date.duration_of(s, date.add_days(s, 14)))
  h.eq("10d", date.duration_of(s, date.add_days(s, 10)))
  h.eq("custom", date.duration_of(s, s + 3600))
  h.eq({ 21, 10, nil, nil }, { date.parse_duration("3w"), date.parse_duration("10 d"), date.parse_duration("custom"), date.parse_duration("0w") })
  h.eq({ nil, nil, nil }, { date.parse("2026-02-30"), date.parse("2026-10-19 25:00"), date.parse("soon") })
  h.eq(3, date.weeks_between(s, date.add_days(s, 20)))
end

-- endregion

-- region form

T["form: text ↔ fields, Goal takes every line after its label"] = function()
  local s = date.parse("2026-11-02 13:00")
  local txt = form.text({ name = "#61", goal = "1. a\n2. b", start = s, duration = "3w", finish = date.add_days(s, 21) })
  h.truthy(txt:find("Duration: 3w", 1, true) and txt:find("End:      2026-11-23 13:00", 1, true), txt)
  local f = assert(form.parse(txt))
  h.eq("#61", f.name)
  h.eq("1. a\n2. b", f.goal)
  h.eq(s, date.parse_iso(f.start_date))
  h.eq(date.add_days(s, 21), date.parse_iso(f.end_date))
end

T["form: validation — name, dates, end after start, dates to start"] = function()
  h.eq({ nil, "Name is empty" }, { form.parse("Name: \nStart: \nGoal:") })
  local f = assert(form.parse("Name: X\nStart:\nDuration: 2w\nEnd:\nGoal:"))
  h.eq({ false, false }, { f.start_date, f.end_date }) -- no dates (future sprint)
  h.truthy(select(2, form.parse("Name: X\nStart:\nGoal:", true)):find("needs dates", 1, true))
  h.truthy(select(2, form.parse("Name: X\nStart: 19.10.2026\nGoal:")):find("YYYY", 1, true))
  h.eq("End must be after Start", select(2, form.parse("Name: X\nStart: 2026-10-19 09:00\nEnd: 2026-10-18 09:00\nGoal:")))
  -- End left empty: Start + Duration
  f = assert(form.parse("Name: X\nStart: 2026-10-19 09:00\nDuration: 1w\nEnd:\nGoal:"))
  h.eq("2026-10-26 09:00", date.format(date.parse_iso(f.end_date)))
end

T["form: End follows Start / Duration, a hand-typed End makes Duration custom"] = ui_test(function()
  local s = date.parse("2026-10-19 09:00")
  local got
  form.open({ title = "t", draft = { name = "X", start = s, duration = "2w", finish = date.add_days(s, 14) } },
    function(fields, finish) got = fields finish(true) end)
  set_field("Duration", "3w")
  h.eq("2026-11-09 09:00", field("End"))
  set_field("Start", "2026-10-20 10:00")
  h.eq("2026-11-10 10:00", field("End"))
  set_field("End", "2026-11-12 10:00")
  h.eq("23d", field("Duration"))
  set_field("End", "2026-11-12 11:30")
  h.eq("custom", field("Duration"))
  set_field("End", "2026-10-27 10:00")
  h.eq("1w", field("Duration"))
  press("<C-s>")
  wait_for(function() return got end, "submit")
  h.eq("2026-10-27 10:00", date.format(date.parse_iso(got.end_date)))
end)

-- endregion

-- region API

T["next_sprint_name: the newest sprint's number + 1"] = function()
  h.eq("#61", api.next_sprint_name({ { id = "5", name = "#9 x" }, { id = "120", name = "#60 Spring cleanup" } }))
  h.eq("ABC Sprint 8", api.next_sprint_name({ { id = "1", name = "ABC Sprint 7" } }))
  h.eq("FAKE Sprint 1", api.next_sprint_name({}, "FAKE"))
end

T["complete: open issues → a new sprint when none is planned, then close"] = function()
  fake.reset()
  fake.issues[1].status = { id = "3", name = "Done", category = "done" } -- last board column
  table.insert(fake.issues, { provider = "fake", id = "5", key = "FAKE-5", summary = "sub", labels = {}, subtasks = {},
    status = { id = "1", name = "To Do" }, type = { id = "s", name = "Sub-task", subtask = true }, parent = { key = "FAKE-2" } })
  local events = {}
  local au = vim.api.nvim_create_autocmd("User", {
    pattern = "TrackerSprint*", callback = function(ev) table.insert(events, ev.match) end,
  })
  local plan
  api.complete_plan(fake.sprint_data[2], function(p) plan = p end, BOARD)
  wait_for(function() return plan end, "plan")
  h.eq({ "FAKE-1" }, vim.tbl_map(function(i) return i.key end, plan.done))
  h.eq({ "FAKE-2" }, vim.tbl_map(function(i) return i.key end, plan.open)) -- the sub-task follows its parent
  h.eq(nil, plan.target)
  h.eq("#61", plan.new_name)

  local res
  api.complete_sprint(plan, function(r, err) res = r or err end, BOARD)
  wait_for(function() return res end, "complete")
  vim.api.nvim_del_autocmd(au)
  h.eq("#61", res.target.name)
  h.eq({ "FAKE-2" }, res.moved)
  local seen = vim.tbl_map(function(c) return c[1] end, vim.tbl_filter(function(c)
    return c[1] == "create_sprint" or c[1] == "sprint" or c[1] == "update_sprint"
  end, fake.calls))
  h.eq({ "create_sprint", "sprint", "update_sprint" }, seen)
  h.eq({ state = "closed" }, fake.calls[#fake.calls][3])
  h.eq("closed", fake.sprint_data[2].state)
  h.eq({ "TrackerSprintCreated", "TrackerSprintCompleted" }, events)
end

T["complete: a planned future sprint takes the open issues, nothing created"] = function()
  fake.reset()
  table.insert(fake.sprint_data, { id = "12", name = "#61 Next", state = "future" })
  local plan
  api.complete_plan(fake.sprint_data[2], function(p) plan = p end, BOARD)
  wait_for(function() return plan end, "plan")
  h.eq("#61 Next", plan.target.name)
  local res
  api.complete_sprint(plan, function(r) res = r end, BOARD)
  wait_for(function() return res end, "complete")
  h.eq({ "sprint", "12", { "FAKE-1", "FAKE-2" } }, vim.tbl_filter(function(c) return c[1] == "sprint" end, fake.calls)[1])
  h.eq(0, #vim.tbl_filter(function(c) return c[1] == "create_sprint" end, fake.calls))
end

T["start: needs both dates, sends state = active"] = function()
  fake.reset()
  local s = { id = "12", name = "#61", state = "future" }
  table.insert(fake.sprint_data, s)
  local err
  api.start_sprint(s, { name = "#61" }, function(_, e) err = e end, BOARD)
  wait_for(function() return err end, "refusal")
  local ok
  api.start_sprint(s, { start_date = "2026-10-19T09:00:00.000+02:00", end_date = "2026-11-09T09:00:00.000+01:00" },
    function(r) ok = r end, BOARD)
  wait_for(function() return ok end, "start")
  h.eq("active", ok.state)
  h.eq("active", fake.calls[#fake.calls][3].state)
end

-- endregion

-- region view

T["view: sections, closed folded, <CR> lists the sprint's issues"] = ui_test(function()
  fake.reset()
  require("tracker").sprints({ board_id = "7" })
  wait_for(function() return text():find("#60 Now", 1, true) end, "sprints")
  h.truthy(text():find("1. first", 1, true) and text():find("2. second", 1, true), "active goal in full")
  h.truthy(not text():find("#59 Old", 1, true), "closed folded")
  goto_line("Closed")
  press("<Tab>")
  local _, row = goto_line("#59 Old")
  h.truthy(row:find("old goal", 1, true) and not text():find("second line", 1, true), "closed: first goal line only")
  goto_line("#60 Now")
  press("<CR>")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "sprint issues")
  h.eq({ "board_issues", "11" }, fake.calls[#fake.calls])
end)

T["view: n prefills the next sprint after the active one; e / s / C go through the form"] = ui_test(function()
  fake.reset()
  require("tracker").sprints({ board_id = "7" })
  wait_for(function() return text():find("#60 Now", 1, true) end, "sprints")

  press("n")
  wait_for(function() return field("Name") end, "form")
  h.eq("#61", field("Name"))
  h.eq(date.format(date.parse_iso("2026-11-02T09:00:00.000Z")), field("Start"))
  h.eq("3w", field("Duration"))
  set_field("Name", "#61 Next")
  press("<C-s>")
  local function in_view() return vim.bo.filetype == "tracker_sprints" end
  wait_for(function() return in_view() and text():find("#61 Next", 1, true) end, "new sprint listed")
  local create = vim.tbl_filter(function(c) return c[1] == "create_sprint" end, fake.calls)[1]
  h.eq("7", create[2])
  h.eq("#61 Next", create[3].name)

  -- start it: from now, 3 weeks
  goto_line("#61 Next")
  press("s")
  wait_for(function() return field("Name") end, "start form")
  h.eq("3w", field("Duration"))
  press("<C-s>")
  wait_for(function() return fake.sprint_data[3].state == "active" end, "started")

  -- complete the old active one: its open issues go to the next future
  -- sprint — there is none now, so a new one is made
  wait_for(function() return in_view() and text():find("#61 Next", 1, true) end, "back in the view")
  goto_line("#60 Now")
  local prompt
  vim.ui.select = function(items, o, cb)
    prompt = o.prompt
    cb(items[1])
  end
  press("C")
  wait_for(function() return fake.sprint_data[2].state == "closed" end, "completed")
  h.truthy(prompt:find("2 open", 1, true) and prompt:find("#62 (new sprint)", 1, true), prompt)
end)

-- endregion

return T
