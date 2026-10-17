-- Board view: the active sprint (or a kanban board) as side-by-side columns
-- taken from the board's own column → status mapping. `<` / `>` move the card
-- under the cursor one column left / right via a matching transition.

local M = {}

local api = require("tracker.api")
local config = require("tracker.config")
local window = require("tracker.ui.window")
local view = require("tracker.ui.view")
local actions = require("tracker.ui.actions")
local notify = require("tracker.notify")
local model = require("tracker.model")
local icons = require("tracker.ui.icons")
local sync = require("tracker.ui.sync")

---Byte column (0-based) of display column `vcol` (1-based) in `line`.
local function byte_col(line, vcol)
  local n, width = 0, 0
  while width < vcol - 1 do
    local ch = vim.fn.strcharpart(line, n, 1)
    if ch == "" then break end
    width = width + vim.fn.strdisplaywidth(ch)
    n = n + 1
  end
  return #vim.fn.strcharpart(line, 0, n)
end

---@param board TrackerBoard
---@param focus string|nil  key of the card the cursor starts on (also when a
---                         view covers the board: back there, it's on it)
local function show(board, focus)
  local buf = view.new_buf("tracker_board")
  local v = {
    buf = buf,
    title = " " .. board.name .. " ",
    footer = view.footer({
      { "<CR>", "open" }, { "h/l", "column" }, { "</>", "move" }, { "s", "status" },
      { "a", "assign" }, { "m", "mine" }, { "B", "backlog" }, { "S", "sprints" }, { "r", "refresh" }, { "?", "help" },
    }),
    win_opts = { cursorline = true, wrap = false },
  }
  local st = { data = nil, me = nil, mine = false, grid = {}, x = {}, columns = {}, first_row = nil,
    sync = sync.attach(buf) } -- reloads after an action until Jira shows it

  local function render()
    local data = st.data
    if not data then return end
    local win = window.win(v)
    local width = win and vim.api.nvim_win_get_width(win) or vim.o.columns

    -- Columns from the board config, plus a catch-all for statuses no column
    -- maps (they'd otherwise silently vanish).
    local columns, col_of = {}, {}
    for idx, c in ipairs(data.columns) do
      table.insert(columns, { name = c.name, statuses = c.statuses, issues = {} })
      for _, id in ipairs(c.statuses) do col_of[id] = idx end
    end
    local other = { name = "Other", statuses = {}, issues = {} }
    for _, i in ipairs(data.issues) do
      local keep = not st.mine or (st.me and i.assignee and i.assignee.id == st.me.id)
      if keep then
        local idx = i.status and i.status.id and col_of[i.status.id]
        table.insert(idx and columns[idx].issues or other.issues, i)
      end
    end
    if #other.issues > 0 then table.insert(columns, other) end
    st.columns = columns

    -- Empty columns shrink to a short header (they stay a target for `>`);
    -- columns with cards share the rest. st.x[ci] = first display column.
    local function header(c) return (" %s (%d)"):format(view.status_name(c.name):upper(), #c.issues) end
    local widths, used, wide = {}, 0, 0
    for ci, c in ipairs(columns) do
      if #c.issues == 0 then
        widths[ci] = math.min(14, math.max(8, vim.fn.strdisplaywidth(header(c)) + 1))
        used = used + widths[ci]
      else
        wide = wide + 1
      end
    end
    local share = math.max(config.get().ui.board_min_column, math.floor((width - 1 - used) / math.max(1, wide)))
    st.x = {}
    local x = 1
    for ci = 1, #columns do
      widths[ci] = widths[ci] or share
      st.x[ci] = x
      x = x + widths[ci]
    end

    local b = view.builder()
    local s = data.sprint
    if s then
      b:add({ { " " .. s.name, "TrackerTitle" },
              { ("  %s → %s"):format(model.short_date(s.start_date), model.short_date(s.end_date)), "TrackerMuted" },
              { st.mine and "  [mine]" or "", "TrackerFilter" } })
      if s.goal and s.goal ~= "" then b:add({ { " " .. s.goal:gsub("\n", " "), "TrackerMuted" } }) end
    else
      b:add({ { " " .. board.name .. " (no active sprint)", "TrackerTitle" }, { st.mine and "  [mine]" or "", "TrackerFilter" } })
    end
    b:add("")

    local head, sep = {}, {}
    for ci, c in ipairs(columns) do
      table.insert(head, { view.pad(header(c), widths[ci]), "TrackerColumn" })
      table.insert(sep, { " " .. string.rep("─", widths[ci] - 2) .. " ", "TrackerSeparator" })
    end
    b:add(head)
    b:add(sep)

    local rows = 0
    for _, c in ipairs(columns) do rows = math.max(rows, #c.issues) end
    st.grid, st.first_row = {}, nil
    for r = 1, rows do
      local chunks, cells = {}, {}
      for ci, c in ipairs(columns) do
        local i = c.issues[r]
        if i then
          local initials = i.assignee and view.initials(i.assignee.name) or "--"
          local block = i.blocked and (icons.glyph.blocked .. " ") or ""
          local head_text = " " .. i.key .. " "
          local rest = view.pad(initials .. " " .. i.summary, widths[ci] - vim.fn.strdisplaywidth(head_text .. block))
          table.insert(chunks, { head_text, "TrackerKey" })
          table.insert(chunks, { block, "TrackerBlocked" })
          table.insert(chunks, { rest:sub(1, #initials), "TrackerUser" })
          table.insert(chunks, { rest:sub(#initials + 1) })
          cells[ci] = i
        else
          table.insert(chunks, { string.rep(" ", widths[ci]) })
        end
      end
      local lnum = b:add(chunks)
      st.grid[lnum] = cells
      st.first_row = st.first_row or lnum
    end
    if rows == 0 then b:add({ { "  no issues", "TrackerMuted" } }) end
    b:render(buf)
  end

  ---Column index under the cursor (by display column).
  local function column_at_cursor()
    local vc, ci = vim.fn.virtcol("."), 1
    for i, x in ipairs(st.x or {}) do
      if x <= vc then ci = i end
    end
    return ci
  end

  local function cell_under_cursor()
    local cells = st.grid[vim.api.nvim_win_get_cursor(0)[1]]
    if not cells then return nil end
    local ci = column_at_cursor()
    return cells[ci], ci
  end

  local function goto_column(ci)
    ci = math.max(1, math.min(#st.columns, ci))
    vim.cmd(("normal! %d|"):format(st.x[ci] + 1))
  end

  ---Cursor position of `key`'s card.
  local function card_pos(key)
    for lnum, cells in pairs(st.grid) do
      for ci, i in pairs(cells) do
        if i.key == key then
          local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
          return { lnum, byte_col(line, st.x[ci] + 1) }
        end
      end
    end
  end

  local function load()
    sync.cancel(st.sync)
    -- a reload keeps the cards (and the cursor on its card) until it's done
    if not st.data then view.message(buf, "Loading board…") end
    local pending, failed = 2, nil
    local function step(err)
      failed = failed or err
      pending = pending - 1
      if pending > 0 or not vim.api.nvim_buf_is_valid(buf) then return end
      if not st.data then return view.message(buf, failed or "error", "TrackerError") end
      local keep = window.is_top(v) and vim.api.nvim_win_get_cursor(window.win())
      render()
      if focus then
        local pos = card_pos(focus)
        focus = nil
        if pos and not window.is_top(v) then
          v.cursor = pos -- restored when the view on top pops
          return
        end
        keep = pos or keep
      end
      if window.is_top(v) then
        local pos = keep and st.grid[keep[1]] and keep or (st.first_row and { st.first_row, 1 })
        if pos then pcall(vim.api.nvim_win_set_cursor, window.win(), pos) end
      end
    end
    api.board(board.id, function(data, err)
      st.data = data
      if data and data.name then board.name = data.name end
      -- An action's change not on the board yet (Jira's index still
      -- behind): drawn as it is, and loaded again in a moment.
      local settled = not data or sync.check(st.sync, { data.issues }, load)
      v.title = " " .. board.name .. (settled and "" or " · syncing…") .. " "
      window.refresh_chrome(v)
      step(err)
    end)
    api.myself(function(me)
      st.me = me
      step(nil)
    end)
  end

  local function on_card(fn)
    return function()
      local i, ci = cell_under_cursor()
      if i then fn(i, ci) end
    end
  end

  local function move(dir)
    return on_card(function(i, ci)
      local target = st.columns[ci + dir]
      if not target or target.name == "Other" and #target.statuses == 0 then return end
      actions.move_to_column(i.key, target, load)
    end)
  end

  view.map(buf, board.name, {
    { "<CR>", on_card(function(i) require("tracker.ui.issue").open(i.key) end), desc = "open issue" },
    { "l", function() goto_column(column_at_cursor() + 1) end, desc = "next column" },
    { "h", function() goto_column(column_at_cursor() - 1) end, desc = "previous column" },
    { ">", move(1), desc = "move card to the next column" },
    { "<", move(-1), desc = "move card to the previous column" },
    { "s", on_card(function(i) actions.transition(i.key, load) end), desc = "change status" },
    { "a", on_card(function(i) actions.assign(i.key, load) end), desc = "assign" },
    { "A", on_card(function(i) actions.toggle_me(i, load) end), desc = "assign to me / unassign me (toggle)" },
    { "c", on_card(function(i) actions.comment(i.key) end), desc = "add comment" },
    { { "o", "gx" }, on_card(function(i) actions.web(i.key) end), desc = "open in browser" },
    { "y", on_card(function(i) actions.copy(i.key) end), desc = "copy key" },
    { "m", function()
        st.mine = not st.mine
        render()
      end, desc = "toggle: only my issues" },
    { "B", function()
        require("tracker.ui.list").open({
          title = board.name .. " — backlog",
          subtitle = "board " .. board.id .. " backlog",
          load = function(cb) api.backlog(board.id, cb) end,
        })
      end, desc = "backlog" },
    { "S", function() require("tracker.ui.sprints").open({ board_id = board.id }) end,
      desc = "sprints: new / edit / start / complete" },
    { "r", load, desc = "refresh" },
  })

  v.on_resize = render
  v.on_return = load
  window.push(v)
  load()
end

---Open a board: `opts.board_id`, else a pick among the repository's boards
---when it uses several (`providers.<name>.repos`), else its board /
---`providers.<name>.board`, else a pick among the project's boards.
---@param opts { board_id: string?, project: string? }|nil
function M.open(opts)
  opts = opts or {}
  local info, err = api.provider_info()
  if not info then return notify.error(err) end
  if not info.capabilities.boards then
    return notify.error(("tracker: %s has no boards"):format(info.name))
  end
  if not opts.board_id and not opts.project then
    local mine = vim.tbl_filter(function(b) return b.board ~= nil end, api.repo_boards())
    if #mine > 1 then
      return vim.ui.select(mine, {
        prompt = "Board",
        format_item = function(b) return ("%s  (%s, #%s)"):format(b.name, b.project, b.board) end,
      }, function(b)
        if b then show({ id = b.board, name = b.name }) end
      end)
    end
  end
  local board_id = opts.board_id or info.board
  if board_id then
    return show({ id = board_id, name = "Board " .. board_id })
  end
  local project = opts.project or info.project
  api.boards(project, function(boards, berr)
    if not boards then return notify.error(berr) end
    if #boards == 0 then return notify.error("tracker: no boards" .. (project and (" for " .. project) or "")) end
    if #boards == 1 then return show(boards[1]) end
    vim.ui.select(boards, {
      prompt = "Board",
      format_item = function(b) return ("%s  (%s, #%s)"):format(b.name, b.type or "?", b.id) end,
    }, function(b)
      if b then show(b) end
    end)
  end)
end

---Board of `key` with the cursor on its card (also once the issue, opened
---on top next, is closed). The board: `board_name`'s (one of
---`providers.<name>.boards`, see api.current_issue_key), else the main one.
---No board id → false, nothing opened.
---@param key string
---@param board_name string|nil
---@return boolean
function M.open_at(key, board_name)
  local info = api.provider_info(board_name and { board_name = board_name } or nil)
  if not (info and info.capabilities.boards and info.board) then return false end
  show({ id = info.board, name = board_name or info.board_name or ("Board " .. info.board) }, key:upper())
  return true
end

return M
