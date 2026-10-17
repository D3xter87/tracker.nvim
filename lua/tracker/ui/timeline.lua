-- Timeline: the project's epics as bars over time, like Jira's Timeline;
-- <Tab> unfolds an epic into its issues.
--
-- A bar spans Start date → Due date. A missing date is taken from the
-- issue's sprint (its newest one with dates) — for an epic from the span of
-- its issues — and the bar is drawn in TrackerBarDerived. Epic bars show
-- progress by the share of their issues: █ done  ▓ in progress  ░ to do.
--
-- `<` / `>` move a bar by a week (a count: 3>), `[` / `]` move only its end;
-- the change is saved once you stop (a derived bar gets real dates then).
-- `e` edits both dates in a popup.

local M = {}

local api = require("tracker.api")
local window = require("tracker.ui.window")
local view = require("tracker.ui.view")
local notify = require("tracker.notify")
local date = require("tracker.util.date")
local icons = require("tracker.ui.icons")
local highlights = require("tracker.ui.highlights")

local DAY = 86400
local LABEL_W = 38
local RIGHT_W = 11
local SAVE_DELAY = 800 -- ms after the last < > [ ]

---cpd = columns per day, page = days H / L scroll
M.SCALES = {
  { id = "days", cpd = 3, page = 7, before = 3 },
  { id = "weeks", cpd = 1, page = 28, before = 14 },
  { id = "months", cpd = 0.25, page = 91, before = 31 },
}
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local BAR = { done = "\u{2588}", in_progress = "\u{2593}", todo = "\u{2591}" }
local DOT = "\u{25cf}"
local FOLD = { open = "\u{f107}", closed = "\u{f105}" }

-- region Pure helpers (tested)

---Local noon of the day of `t`: day arithmetic without DST surprises.
local function noon(t)
  local d = os.date("*t", t)
  return os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
end

---Whole days from `a` to `b`.
function M.day_diff(a, b) return math.floor((noon(b) - noon(a)) / DAY + 0.5) end

---"YYYY-MM-DD" (local midnight) or an ISO timestamp → epoch.
local function when(s)
  if type(s) ~= "string" then return nil end
  if #s == 10 then return date.parse(s) end
  return date.parse_iso(s)
end

---Span of the newest sprint (with dates) an issue is in.
local function sprint_span(i)
  local best
  for _, s in ipairs(i.sprints or {}) do
    local t1, t2 = when(s.start_date), when(s.end_date)
    if t1 and t2 and (not best or t1 > best[1]) then best = { t1, t2 } end
  end
  if best then return best[1], best[2] end
end

---Bar of one issue: its own dates; holes filled from its sprint, else from
---`fs` / `fe` (an epic: the span of its issues).
---@return integer|nil start, integer|nil finish, boolean derived
function M.span(i, fs, fe)
  local s, e = when(i.start_date), when(i.due_date)
  if s and e then return math.min(s, e), math.max(s, e), false end
  local ss, se = sprint_span(i)
  ss, se = ss or fs, se or fe
  local derived = false
  if not s and ss then s, derived = ss, true end
  if not e and se then e, derived = se, true end
  -- one date only: a one-day mark
  s, e = s or e, e or s
  if s and e and e < s then s, e = e, s end
  return s, e, derived
end

---Bar of an epic: own dates, else the span of its issues.
---@param kids TrackerIssue[]
function M.epic_span(epic, kids)
  local ks, ke
  for _, k in ipairs(kids or {}) do
    local s, e = M.span(k)
    if s and (not ks or s < ks) then ks = s end
    if e and (not ke or e > ke) then ke = e end
  end
  return M.span(epic, ks, ke)
end

---Issues per status category.
---@return { done: integer, in_progress: integer, todo: integer }, integer total
function M.progress(kids)
  local n = { done = 0, in_progress = 0, todo = 0 }
  for _, k in ipairs(kids or {}) do
    local cat = k.status and k.status.category or "todo"
    n[cat] = (n[cat] or 0) + 1
  end
  return n, #(kids or {})
end

---Column of a day (may be < 0 or ≥ width).
local function col_of(origin, t, cpd) return math.floor(M.day_diff(origin, t) * cpd) end

---Cells of a bar: { [col] = { char, hl } }, clipped to 0 .. width-1, with
---◀ / ▶ where it runs off the chart.
---@param parts { n: integer, char: string, hl: string }[]|nil  progress split (epics)
function M.bar_cells(origin, cpd, width, s, e, char, hl, parts)
  local c1 = col_of(origin, s, cpd)
  local c2 = math.floor((M.day_diff(origin, e) + 1) * cpd) - 1
  if c2 < c1 then c2 = c1 end
  local cells = {}
  if c2 < 0 then
    cells[0] = { "\u{25c0}", hl }
    return cells
  elseif c1 > width - 1 then
    cells[width - 1] = { "\u{25b6}", hl }
    return cells
  end
  local len = c2 - c1 + 1
  -- progress: the first n cells done, then in progress, then to do
  local bounds = {}
  if parts then
    local total = 0
    for _, p in ipairs(parts) do total = total + p.n end
    local acc = 0
    for _, p in ipairs(parts) do
      acc = acc + p.n
      table.insert(bounds, { upto = total > 0 and math.floor(len * acc / total + 0.5) or len, char = p.char, hl = p.hl })
    end
  end
  for c = math.max(c1, 0), math.min(c2, width - 1) do
    local k = c - c1
    local ch, h = char, hl
    for _, b in ipairs(bounds) do
      if k < b.upto then
        ch, h = b.char, b.hl or hl
        break
      end
    end
    cells[c] = { ch, h }
  end
  if c1 < 0 then cells[0] = { "\u{25c0}", hl } end
  if c2 > width - 1 then cells[width - 1] = { "\u{25b6}", hl } end
  return cells
end

---Default first day shown for a scale: a little before today, on a Monday
---(weeks) or the 1st (months).
function M.default_origin(scale, today)
  local t = date.add_days(today, -scale.before)
  local d = os.date("*t", t)
  if scale.id == "weeks" then
    t = date.add_days(t, -((d.wday + 5) % 7)) -- back to Monday
  elseif scale.id == "months" then
    t = os.time({ year = d.year, month = d.month, day = 1, hour = 12 })
  end
  return noon(t)
end

-- endregion

---Chunks for `width` cells: consecutive cells with the same hl merged.
local function chunks_of(cells, width)
  local out, buf, cur = {}, {}, false
  for c = 0, width - 1 do
    local cell = cells[c] or { " ", nil }
    if cur ~= false and cell[2] ~= cur then
      table.insert(out, { table.concat(buf), cur })
      buf = {}
    end
    cur = cell[2]
    table.insert(buf, cell[1])
  end
  if #buf > 0 then table.insert(out, { table.concat(buf), cur }) end
  return out
end

local function show(project)
  local buf = view.new_buf("tracker_timeline")
  local v = {
    buf = buf,
    title = " Timeline — " .. project .. " ",
    footer = view.footer({
      { "<CR>", "open" }, { "<Tab>", "issues" }, { "</>", "move" }, { "[/]", "end" }, { "e", "dates" },
      { "H/L", "scroll" }, { "t", "today" }, { "+/-", "zoom" }, { "d", "done" }, { "?", "help" },
    }),
    win_opts = { cursorline = true, wrap = false },
  }
  local st = {
    data = nil, scale = 2, origin = nil, open = {}, rows = {}, details = {},
    done_days = nil, dirty = {}, timer = nil, first_row = nil,
  }
  local today = os.time()
  st.origin = M.default_origin(M.SCALES[st.scale], today)

  local function scale() return M.SCALES[st.scale] end

  local function width()
    local win = window.win(v)
    local w = win and vim.api.nvim_win_get_width(win) or vim.o.columns
    return math.max(20, w - LABEL_W - RIGHT_W - 1)
  end

  local function header(b, W)
    local sc = scale()
    local top, ticks, months = {}, {}, {}
    local last_month
    for c = 0, W - 1 do
      local t = date.add_days(st.origin, math.floor(c / sc.cpd))
      local d = os.date("*t", t)
      -- a month label where the month starts (and at the left edge)
      if d.month ~= last_month then
        last_month = d.month
        table.insert(months, { col = c, label = MONTHS[d.month] .. ((d.month == 1 or c == 0) and (" " .. d.year) or "") })
      end
      if math.floor(c / sc.cpd) ~= math.floor((c - 1) / sc.cpd) or c == 0 then
        if sc.id == "days" then
          local weekend = d.wday == 1 or d.wday == 7
          local num = ("%2d"):format(d.day)
          for k = 1, 2 do ticks[c + k - 1] = { num:sub(k, k), weekend and "TrackerWeekend" or "TrackerMuted" } end
        elseif sc.id == "weeks" and d.wday == 2 then
          local num = tostring(d.day)
          for k = 1, #num do
            if c + k - 1 < W then ticks[c + k - 1] = { num:sub(k, k), "TrackerMuted" } end
          end
        end
      end
    end
    -- each label up to the next one; the left edge's only when it fits whole
    for n, m in ipairs(months) do
      local room = (months[n + 1] and months[n + 1].col or W) - m.col - 1
      local label = m.label
      if #label > room then label = label:match("%d%d%d%d$") or label:sub(1, 3) end -- "Jan 2027" → "2027"
      if n > 1 or #label <= room then
        for k = 1, math.min(#label, room) do top[m.col + k - 1] = { label:sub(k, k), "TrackerTitle" } end
      end
    end
    local tc = col_of(st.origin, today, sc.cpd)
    if tc >= 0 and tc < W then
      if sc.id == "days" then -- today's number in red instead of a marker over it
        for k = 0, 1 do
          if ticks[tc + k] then ticks[tc + k][2] = "TrackerToday" end
        end
      else
        ticks[tc] = { "\u{25bc}", "TrackerToday" }
      end
    end
    local pad = { string.rep(" ", LABEL_W), nil }
    b:add(vim.list_extend({ pad }, chunks_of(top, W)))
    b:add(vim.list_extend({ pad }, chunks_of(ticks, W)))
  end

  local function today_line(cells, W)
    local tc = col_of(st.origin, today, scale().cpd)
    if tc >= 0 and tc < W and not cells[tc] then cells[tc] = { "\u{2502}", "TrackerToday" } end
  end

  local function render()
    local data = st.data
    if not data then return end
    local W, cpd = width(), scale().cpd
    local b = view.builder()
    st.rows, st.first_row = {}, nil
    b:add("")
    header(b, W)

    for _, epic in ipairs(data.epics) do
      local kids = data.children[epic.key] or {}
      local open = st.open[epic.key]
      local ehl = icons.epic_fg_hl(epic.color)
      local s, e, derived = M.epic_span(epic, kids)
      local n, total = M.progress(kids)
      local cells = {}
      if s then
        local hl = derived and "TrackerBarDerived" or ehl
        local parts
        if total > 0 then
          parts = {
            { n = n.done, char = BAR.done }, { n = n.in_progress, char = BAR.in_progress }, { n = n.todo, char = BAR.todo },
          }
        end
        local cat = epic.status and epic.status.category or "todo"
        cells = M.bar_cells(st.origin, cpd, W, s, e, BAR[cat] or BAR.todo, hl, parts)
      else
        local txt = "  no dates"
        for k = 1, math.min(#txt, W) do cells[k - 1] = { txt:sub(k, k), "TrackerMuted" } end
      end
      today_line(cells, W)
      local label = " " .. (#kids > 0 and (open and FOLD.open or FOLD.closed) or " ") .. " "
      local pct = total > 0 and ("%4d%%"):format(math.floor(100 * n.done / total + 0.5))
        or ((epic.status and epic.status.category == "done") and "  100%" or "")
      local row = { { label, "TrackerMuted" }, { DOT .. " ", ehl }, { epic.key .. " ", "TrackerKey" },
                    { view.pad(epic.summary, LABEL_W - 1 - vim.fn.strdisplaywidth(label .. DOT .. " " .. epic.key .. " ")) .. " " } }
      vim.list_extend(row, chunks_of(cells, W))
      table.insert(row, { " " .. pct, "TrackerPoints" })
      local lnum = b:add(row)
      st.rows[lnum] = { issue = epic, epic = epic.key }
      st.first_row = st.first_row or lnum

      if open then
        for _, k in ipairs(kids) do
          local ks, ke, kd = M.span(k)
          local kcells = {}
          if ks then
            local hl = kd and "TrackerBarDerived" or highlights.status(k.status)
            local cat = k.status and k.status.category or "todo"
            kcells = M.bar_cells(st.origin, cpd, W, ks, ke, BAR[cat] or BAR.todo, hl)
          end
          today_line(kcells, W)
          local head = "      " .. k.key .. " "
          local krow = { { head, "TrackerKey" }, { view.pad(k.summary, LABEL_W - 1 - vim.fn.strdisplaywidth(head)) .. " " } }
          vim.list_extend(krow, chunks_of(kcells, W))
          table.insert(krow, { " " .. vim.fn.strcharpart(view.status_name(k.status and k.status.name or ""), 0, RIGHT_W),
                               highlights.status(k.status) })
          local kl = b:add(krow)
          st.rows[kl] = { issue = k, epic = epic.key, child = true }
        end
      end
    end
    if #data.epics == 0 then b:add({ { "  no epics", "TrackerMuted" } }) end
    b:render(buf)
  end

  local function current() return st.rows[vim.api.nvim_win_get_cursor(0)[1]] end

  ---Re-render keeping the cursor on the same issue.
  local function rerender()
    local r = window.is_top(v) and current()
    render()
    if not window.is_top(v) then return end
    for l, row in pairs(st.rows) do
      if r and row.issue.key == r.issue.key then
        return pcall(vim.api.nvim_win_set_cursor, window.win(), { l, 0 })
      end
    end
  end

  local function load()
    if not st.data then view.message(buf, "Loading timeline…") end
    api.timeline(function(data, err)
      if not vim.api.nvim_buf_is_valid(buf) then return end
      if not data then return view.message(buf, err or "error", "TrackerError") end
      st.data = data
      local had = window.is_top(v) and current()
      rerender()
      if not had and window.is_top(v) and st.first_row then
        pcall(vim.api.nvim_win_set_cursor, window.win(), { st.first_row, 0 })
      end
    end, { project = project, done_days = st.done_days })
  end

  -- region Editing dates

  local function save()
    if st.timer then st.timer:stop() end
    for key, i in pairs(st.dirty) do
      st.dirty[key] = nil
      api.update(key, { start_date = i.start_date or false, due_date = i.due_date or false }, function(ok, err)
        if not ok then
          notify.error(err)
          return load()
        end
        notify.send("actions", ("%s: %s → %s"):format(key, i.start_date or "—", i.due_date or "—"))
      end)
    end
  end

  local function later_save()
    st.timer = st.timer or vim.uv.new_timer()
    st.timer:stop()
    st.timer:start(SAVE_DELAY, 0, vim.schedule_wrap(save))
  end

  local function row_span(r)
    if r.child then return M.span(r.issue) end
    return M.epic_span(r.issue, st.data.children[r.issue.key])
  end

  ---< > (both ends) and [ ] (end only), by a week × count.
  local function shift(both, dir)
    return function()
      local r = current()
      if not r then return end
      local s, e = row_span(r)
      if not s then return notify.error("tracker: " .. r.issue.key .. " has no dates yet — set them with e") end
      local days = 7 * vim.v.count1 * dir
      if both then s = date.add_days(s, days) end
      e = date.add_days(e, days)
      if e < s then return end
      r.issue.start_date, r.issue.due_date = os.date("%Y-%m-%d", s), os.date("%Y-%m-%d", e)
      st.dirty[r.issue.key] = r.issue
      rerender()
      later_save()
    end
  end

  local function edit_dates()
    local r = current()
    if not r then return end
    local i = r.issue
    local text = ("Start: %s\nDue:   %s"):format(i.start_date or "", i.due_date or "")
    require("tracker.ui.editor").open({
      title = i.key .. " dates",
      text = text,
      hint = "<C-s>/<CR>: save  YYYY-MM-DD, empty clears  <Esc>/q: cancel",
      on_submit = function(txt, finish)
        local vals = {}
        for _, l in ipairs(vim.split(txt, "\n", { plain = true })) do
          local name, val = l:match("^(%a+):%s*(.-)%s*$")
          if name then vals[name:lower()] = val end
        end
        local out = {}
        for _, f in ipairs({ { "start", "start_date" }, { "due", "due_date" } }) do
          local val = vals[f[1]] or ""
          if val == "" then
            out[f[2]] = false
          else
            local t = date.parse(val)
            if not t then
              notify.error(("tracker: %s: use YYYY-MM-DD"):format(f[1]))
              return finish(false)
            end
            out[f[2]] = os.date("%Y-%m-%d", t)
          end
        end
        if out.start_date and out.due_date and out.due_date < out.start_date then
          notify.error("tracker: Due is before Start")
          return finish(false)
        end
        api.update(i.key, out, function(ok, err)
          if not ok then
            notify.error(err)
            return finish(false)
          end
          finish(true)
          i.start_date, i.due_date = out.start_date or nil, out.due_date or nil
          rerender()
        end)
      end,
    })
  end

  -- endregion

  local function jump(dir)
    return function()
      local lnums = vim.tbl_keys(st.rows)
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
      if not st.rows[row] then row = lnums[1] end
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      view.scroll("zz")
    end
  end

  local function toggle()
    local r = current()
    if not r then return end
    st.open[r.epic] = not st.open[r.epic]
    render()
    for l, row in pairs(st.rows) do
      if row.issue.key == r.epic then pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 }) end
    end
  end

  local function all(open)
    return function()
      for _, e in ipairs(st.data and st.data.epics or {}) do st.open[e.key] = open or nil end
      rerender()
    end
  end

  local function scroll(dir)
    return function()
      st.origin = noon(date.add_days(st.origin, dir * scale().page * vim.v.count1))
      rerender()
    end
  end

  local function zoom(dir)
    return function()
      local nxt = st.scale + dir
      if not M.SCALES[nxt] then return end
      st.scale = nxt
      st.origin = M.default_origin(scale(), today)
      rerender()
      notify.send("actions", "timeline: " .. scale().id)
    end
  end

  local function on_issue(fn)
    return function()
      local r = current()
      if r then fn(r.issue, r) end
    end
  end

  view.map(buf, "Timeline", {
    { { "<CR>", "l" }, on_issue(function(i) require("tracker.ui.issue").open(i.key) end), desc = "open issue" },
    { "K", on_issue(function(i) require("tracker.ui.preview").toggle(i, st.details) end), desc = "preview" },
    { "j", jump(1), desc = "next row" },
    { "k", jump(-1), desc = "previous row" },
    { { "<Tab>", "za" }, toggle, desc = "unfold / fold the epic's issues" },
    { "zR", all(true), desc = "unfold all epics" },
    { "zM", all(false), desc = "fold all epics" },
    { ">", shift(true, 1), desc = "move the bar a week later (count: weeks)" },
    { "<", shift(true, -1), desc = "move the bar a week earlier" },
    { "]", shift(false, 1), desc = "end a week later" },
    { "[", shift(false, -1), desc = "end a week earlier" },
    { "e", edit_dates, desc = "edit start / due date" },
    { "L", scroll(1), desc = "scroll later" },
    { "H", scroll(-1), desc = "scroll earlier" },
    { "t", function()
        st.origin = M.default_origin(scale(), today)
        rerender()
      end, desc = "back to today" },
    { { "+", "=" }, zoom(-1), desc = "zoom in (months → weeks → days)" },
    { "-", zoom(1), desc = "zoom out" },
    { "d", function()
        st.done_days = not st.done_days and 90 or nil
        notify.send("actions", st.done_days and "timeline: with epics done in the last 90 days" or "timeline: open epics")
        load()
      end, desc = "toggle epics done in the last 90 days" },
    { { "o", "gx" }, on_issue(function(i) require("tracker.ui.actions").web(i.key) end), desc = "open in browser" },
    { "y", on_issue(function(i) require("tracker.ui.actions").copy(i.key) end), desc = "copy key" },
    { "r", function()
        save()
        load()
      end, desc = "refresh" },
  })

  -- unsaved moves go out when the view goes away
  vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
    buffer = buf,
    callback = function()
      if next(st.dirty) then save() end
    end,
  })

  v.on_resize = rerender
  v.on_return = load
  window.push(v)
  load()
end

---Open the timeline of `opts.project`, else the provider's project.
---@param opts { project: string? }|nil
function M.open(opts)
  opts = opts or {}
  local info, err = api.provider_info()
  if not info then return notify.error(err) end
  if not info.capabilities.timeline then
    return notify.error(("tracker: %s has no timeline"):format(info.name))
  end
  local project = opts.project or info.project
  if not project then return notify.error("tracker: no project — set providers." .. info.name .. ".project") end
  show(project)
end

return M
