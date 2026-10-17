-- Sprints of a board: active, future and (folded) closed ones, each with its
-- dates and goal. From here: open a sprint's issues, create / edit a sprint,
-- start a future one, complete the active one (its open issues go to the
-- next future sprint — created when there is none).

local M = {}

local api = require("tracker.api")
local config = require("tracker.config")
local window = require("tracker.ui.window")
local view = require("tracker.ui.view")
local notify = require("tracker.notify")
local date = require("tracker.util.date")
local sprintform = require("tracker.ui.sprintform")

local SECTIONS = {
  { id = "active", label = "Active", glyph = "\u{f04b}", hl = "TrackerStatusProgress" },
  { id = "future", label = "Future", glyph = "\u{f017}", hl = "TrackerStatusTodo" },
  { id = "closed", label = "Closed", glyph = "\u{f00c}", hl = "TrackerStatusDone" },
}

local function day(ts)
  local t = date.parse_iso(ts)
  return t and os.date("%Y-%m-%d", t) or "—"
end

local function days_between(t1, t2) return math.floor((t2 - t1) / 86400 + 0.5) end

---What the right-hand column says about a sprint.
local function when(s)
  local t1, t2 = date.parse_iso(s.start_date), date.parse_iso(s.end_date)
  if s.state == "active" and t2 then
    local left = days_between(os.time(), t2)
    return left >= 0 and (left .. " d left") or (("ended %d d ago"):format(-left))
  elseif s.state == "closed" then
    return s.complete_date and ("closed " .. day(s.complete_date)) or "closed"
  elseif t1 and t2 then
    return date.duration_of(t1, t2) ~= "custom" and date.duration_of(t1, t2) or (days_between(t1, t2) .. " d")
  end
  return "no dates"
end

---@param board_id string
local function show(board_id)
  local buf = view.new_buf("tracker_sprints")
  local v = {
    buf = buf,
    title = " Sprints — board " .. board_id .. " ",
    footer = view.footer({
      { "<CR>", "issues" }, { "K", "details" }, { "n", "new" }, { "e", "edit" }, { "s", "start" },
      { "C", "complete" }, { "<Tab>", "fold" }, { "r", "refresh" }, { "?", "help" },
    }),
    win_opts = { cursorline = true, wrap = false },
  }
  local st = { sprints = nil, rows = {}, headers = {}, collapsed = { closed = true } }
  local opts = { board = board_id }

  local function render()
    local b = view.builder()
    st.rows, st.headers = {}, {}
    local by_state = { active = {}, future = {}, closed = {} }
    for _, s in ipairs(st.sprints) do
      table.insert(by_state[s.state] or by_state.future, s)
    end
    -- newest closed first
    table.sort(by_state.closed, function(a, c) return (tonumber(a.id) or 0) > (tonumber(c.id) or 0) end)
    local names = vim.tbl_map(function(s) return s.name end, st.sprints)
    local name_w = math.max(12, view.width_of(names, 36))

    for _, sec in ipairs(SECTIONS) do
      local list = by_state[sec.id]
      local folded = st.collapsed[sec.id]
      b:add("")
      local lnum = b:add({
        { " " .. (folded and "\u{f105}" or "\u{f107}") .. " ", "TrackerMuted" },
        { sec.label, "TrackerTitle" },
        { ("  %d"):format(#list), "TrackerMuted" },
      })
      st.headers[lnum] = sec.id
      if not folded then
        if #list == 0 then b:add({ { "     none", "TrackerMuted" } }) end
        for _, s in ipairs(list) do
          local goal = vim.split(s.goal or "", "\n", { plain = true })
          local row = b:add({
            { "   " .. sec.glyph .. " ", sec.hl },
            { view.pad(s.name, name_w), "TrackerKey" },
            { ("  %s → %s  "):format(day(s.start_date), day(s.end_date)), "TrackerMuted" },
            { view.pad(when(s), 17), sec.id == "active" and "TrackerPoints" or "TrackerMuted" },
            { sec.id == "closed" and ("  " .. goal[1]) or "", "TrackerMuted" },
          })
          st.rows[row] = s
          -- the goal of what is running / coming, in full
          if sec.id ~= "closed" then
            for _, g in ipairs(goal) do
              if g ~= "" then b:add({ { "       " .. g, "TrackerMuted" } }) end
            end
          end
        end
      end
    end
    b:render(buf)
  end

  local function first_row()
    local lnums = vim.tbl_keys(st.rows)
    table.sort(lnums)
    return lnums[1]
  end

  local function load(keep_cursor)
    if not st.sprints then view.message(buf, "Loading sprints…") end
    api.sprints(function(sprints, err)
      if not vim.api.nvim_buf_is_valid(buf) then return end
      if not sprints then return view.message(buf, err or "error", "TrackerError") end
      st.sprints = sprints
      local pos = keep_cursor and window.is_top(v) and vim.api.nvim_win_get_cursor(window.win())
      render()
      if window.is_top(v) then
        local row = pos and pos[1] or first_row()
        if row then pcall(vim.api.nvim_win_set_cursor, window.win(), { row, 0 }) end
      end
    end, opts)
  end

  local function current()
    return st.rows[vim.api.nvim_win_get_cursor(0)[1]]
  end

  local function on_sprint(fn)
    return function()
      local s = current()
      if s then fn(s) end
    end
  end

  local function jump(dir)
    return function()
      local lnums = vim.list_extend(vim.tbl_keys(st.rows), vim.tbl_keys(st.headers))
      if #lnums == 0 then return end
      table.sort(lnums)
      local row = vim.api.nvim_win_get_cursor(0)[1]
      for _ = 1, vim.v.count1 do
        local target
        if dir > 0 then
          for _, l in ipairs(lnums) do
            if l > row then target = l break end
          end
        else
          for n = #lnums, 1, -1 do
            if lnums[n] < row then target = lnums[n] break end
          end
        end
        if not target then break end
        row = target
      end
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      view.scroll("zz")
    end
  end

  local function fold()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local sec = st.headers[row]
    if not sec then
      local s = st.rows[row]
      sec = s and s.state
      -- step up to the header so the cursor stays on something visible
      for l = row, 1, -1 do
        if st.headers[l] == sec then row = l break end
      end
    end
    if not sec then return end
    st.collapsed[sec] = not st.collapsed[sec]
    render()
    for l, id in pairs(st.headers) do
      if id == sec then pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 }) end
    end
  end

  ---The board's usual sprint length in weeks (newest sprint with dates).
  local function usual_duration()
    local list = vim.deepcopy(st.sprints or {})
    table.sort(list, function(a, c) return (tonumber(a.id) or 0) > (tonumber(c.id) or 0) end)
    for _, s in ipairs(list) do
      local w = date.weeks_between(date.parse_iso(s.start_date), date.parse_iso(s.end_date))
      if w then return w .. "w" end
    end
    return "2w"
  end

  local function draft_of(s)
    local t1, t2 = date.parse_iso(s.start_date), date.parse_iso(s.end_date)
    return { name = s.name, goal = s.goal, start = t1, finish = t2, duration = t1 and t2 and date.duration_of(t1, t2) or usual_duration() }
  end

  local function new_sprint()
    -- like Jira: the next number, starting where the last open sprint ends
    local start
    for _, s in ipairs(st.sprints or {}) do
      local t2 = s.state ~= "closed" and date.parse_iso(s.end_date)
      if t2 and (not start or t2 > start) then start = t2 end
    end
    local duration = usual_duration()
    local draft = {
      name = api.next_sprint_name(st.sprints or {}, (api.provider_info() or {}).project),
      start = start, duration = duration,
      finish = start and date.add_days(start, date.parse_duration(duration)),
    }
    sprintform.open({ title = "New sprint", draft = draft }, function(fields, finish)
      api.create_sprint(fields, function(sprint, err)
        if not sprint then
          notify.error(err)
          return finish(false)
        end
        finish(true)
        notify.send("actions", "created sprint " .. sprint.name)
        load(true)
      end, opts)
    end)
  end

  local function edit(s)
    if s.state == "closed" then return notify.error("tracker: a closed sprint can't be edited") end
    sprintform.open({ title = "Edit " .. s.name, draft = draft_of(s) }, function(fields, finish)
      -- an active sprint can't lose its dates
      if s.state == "active" and not fields.start_date then
        notify.error("sprint: an active sprint needs its dates")
        return finish(false)
      end
      api.update_sprint(s, fields, function(sprint, err)
        if not sprint then
          notify.error(err)
          return finish(false)
        end
        finish(true)
        notify.send("actions", "updated sprint " .. sprint.name)
        load(true)
      end, opts)
    end)
  end

  local function start(s)
    if s.state ~= "future" then return notify.error("tracker: only a future sprint can be started") end
    -- Jira's start dialog: from now, for the planned (or usual) length
    local d = draft_of(s)
    if d.duration == "custom" then d.duration = usual_duration() end
    d.start = os.time() - os.time() % 60
    d.finish = date.add_days(d.start, date.parse_duration(d.duration))
    sprintform.open({ title = "Start " .. s.name, draft = d, require_dates = true }, function(fields, finish)
      api.start_sprint(s, fields, function(sprint, err)
        if not sprint then
          notify.error(err)
          return finish(false)
        end
        finish(true)
        notify.send("actions", "started sprint " .. sprint.name)
        load(true)
      end, opts)
    end)
  end

  local function complete(s)
    if s.state ~= "active" then return notify.error("tracker: only the active sprint can be completed") end
    api.complete_plan(s, function(plan, err)
      if not plan then return notify.error(err) end
      local where = plan.target and plan.target.name or (plan.new_name .. " (new sprint)")
      local prompt = ("Complete %s? %d done, %d open%s"):format(
        s.name, #plan.done, #plan.open, #plan.open > 0 and (" → " .. where) or "")
      vim.ui.select({ "Complete", "Cancel" }, { prompt = prompt }, function(choice)
        if choice ~= "Complete" then return end
        api.complete_sprint(plan, function(res, cerr)
          if not res then
            notify.error(cerr)
            return load(true)
          end
          notify.send("actions", ("completed %s%s"):format(s.name,
            #res.moved > 0 and (": %d open → %s"):format(#res.moved, res.target.name) or ""))
          load(true)
        end, opts)
      end)
    end, opts)
  end

  local function issues(s)
    require("tracker.ui.list").open({
      title = s.name,
      subtitle = ("%s → %s  %s"):format(day(s.start_date), day(s.end_date), when(s)),
      load = function(cb) api.sprint_issues(s, cb, opts) end,
    })
  end

  local function details(s)
    local b = view.builder()
    b:add({ { s.name, "TrackerTitle" }, { "  " .. s.state, "TrackerMuted" } })
    b:add({ { ("%s → %s"):format(date.format(date.parse_iso(s.start_date)), date.format(date.parse_iso(s.end_date))), "TrackerMuted" },
            { "  " .. when(s), "TrackerPoints" } })
    b:add("")
    for _, l in ipairs(vim.split(s.goal ~= nil and s.goal ~= "" and s.goal or "(no goal)", "\n", { plain = true })) do b:add(l) end
    local fbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[fbuf].bufhidden = "wipe"
    b:render(fbuf)
    local w = 30
    for _, l in ipairs(b.lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
    w = math.min(w + 2, math.floor(vim.o.columns * 0.8))
    local h = math.min(#b.lines, math.floor(vim.o.lines * 0.6))
    local fwin = vim.api.nvim_open_win(fbuf, true, {
      relative = "editor", style = "minimal", border = config.get().ui.border,
      width = w, height = h, zindex = 60,
      row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
      title = " Sprint ", title_pos = "center",
    })
    vim.wo[fwin].wrap = true
    for _, lhs in ipairs({ "q", "<Esc>", "K" }) do
      vim.keymap.set("n", lhs, function() pcall(vim.api.nvim_win_close, fwin, true) end, { buffer = fbuf, nowait = true })
    end
    view.map_close(fbuf, function() pcall(vim.api.nvim_win_close, fwin, true) end)
  end

  view.map(buf, "Sprints", {
    { { "<CR>", "l" }, on_sprint(issues), desc = "the sprint's issues" },
    { "K", on_sprint(details), desc = "details: dates, full goal" },
    { "j", jump(1), desc = "next sprint / section" },
    { "k", jump(-1), desc = "previous sprint / section" },
    { { "<Tab>", "za" }, fold, desc = "fold / unfold the section" },
    { "n", new_sprint, desc = "new sprint (name, dates, goal)" },
    { "e", on_sprint(edit), desc = "edit name / dates / goal (active, future)" },
    { "s", on_sprint(start), desc = "start a future sprint" },
    { "C", on_sprint(complete), desc = "complete the active sprint (open issues → next sprint)" },
    { "y", on_sprint(function(s) view.yank(s.name, "sprint name") end), desc = "copy the name" },
    { "r", function() load(true) end, desc = "refresh" },
  })

  v.on_return = function() load(true) end
  window.push(v)
  load(false)
end

---Open the sprints of `opts.board_id`, else the provider's `board`.
---@param opts { board_id: string? }|nil
function M.open(opts)
  opts = opts or {}
  local info, err = api.provider_info()
  if not info then return notify.error(err) end
  if not info.capabilities.sprint_manage then
    return notify.error(("tracker: %s has no sprints to manage"):format(info.name))
  end
  local board_id = opts.board_id or info.board
  if not board_id then
    return notify.error("tracker: no board — set providers." .. info.name .. ".board or pass a board id")
  end
  show(tostring(board_id))
end

return M
