-- Quick preview of an issue under the cursor (`K` in lists): a float next to
-- the row with what the row doesn't show — reporter, labels, sub-tasks,
-- dates and the description (images included when snacks draws them).
--
-- Behaves like LSP hover: `K` opens it, `K` again moves into it (to scroll a
-- long description), moving the cursor in the list or q / <Esc> inside closes
-- it. Details are fetched once per list load (`cache`).

local M = {}

local api = require("tracker.api")
local config = require("tracker.config")
local view = require("tracker.ui.view")
local hl = require("tracker.ui.highlights")
local icons = require("tracker.ui.icons")
local model = require("tracker.model")

local state = { win = nil, buf = nil, key = nil, group = nil }

local function valid() return state.win and vim.api.nvim_win_is_valid(state.win) end

function M.close()
  if state.group then pcall(vim.api.nvim_del_augroup_by_id, state.group) end
  if state.buf then pcall(require("tracker.ui.images").clear, state.buf) end
  if valid() then pcall(vim.api.nvim_win_close, state.win, true) end
  state.win, state.buf, state.key, state.group = nil, nil, nil, nil
end

local function field(b, label, chunks)
  local line = { { view.pad(label, 10), "TrackerField" } }
  vim.list_extend(line, chunks)
  b:add(line)
end

---@param i TrackerIssue  full issue (get_issue)
---@param width integer
local function content(i, width)
  local b = view.builder()
  local icon, icon_hl = icons.type(i.type)
  local prio, prio_hl = icons.priority(i)
  field(b, "Status", { { view.status_name(i.status and i.status.name), hl.status(i.status) } })
  field(b, "Type", { { icon .. " ", icon_hl }, { i.type and i.type.name or "?" } })
  field(b, "Priority", { { prio .. " ", prio_hl }, { i.priority or "-" } })
  field(b, "Assignee", { { i.assignee and i.assignee.name or "Unassigned", "TrackerUser" } })
  field(b, "Reporter", { { i.reporter and i.reporter.name or "-", "TrackerUser" } })
  field(b, "Points", { { type(i.story_points) == "number" and tostring(i.story_points) or "-", "TrackerPoints" } })
  if i.parent then
    field(b, "Parent", { { i.parent.key, "TrackerKey" }, { " " .. i.parent.summary } })
  end
  if #(i.labels or {}) > 0 then field(b, "Labels", { { table.concat(i.labels, ", "), "TrackerLabel" } }) end
  if #(i.subtasks or {}) > 0 then
    local done = 0
    for _, s in ipairs(i.subtasks) do
      if s.status and s.status.category == "done" then done = done + 1 end
    end
    field(b, "Sub-tasks", { { ("%d/%d done"):format(done, #i.subtasks) } })
  end
  if #(i.attachments or {}) > 0 then field(b, "Files", { { tostring(#i.attachments) } }) end
  field(b, "Updated", { { model.short_time(i.updated), "TrackerMuted" } })
  b:add({ { string.rep("─", width - 2), "TrackerSeparator" } })
  if i.description and vim.trim(i.description) ~= "" then
    b:add_lines(vim.split(i.description, "\n", { plain = true }))
  else
    b:add({ { "No description", "TrackerMuted" } })
  end
  return b
end

---@param issue TrackerIssue        the list row (summary, key)
---@param cache table<string, TrackerIssue>  full issues fetched this load
function M.toggle(issue, cache)
  if valid() then
    if state.key == issue.key and vim.api.nvim_get_current_win() ~= state.win then
      vim.api.nvim_set_current_win(state.win) -- second K: step inside
      return
    end
    M.close()
    if state.key == issue.key then return end
  end

  local list_win = vim.api.nvim_get_current_win()
  local width = math.min(100, math.floor(vim.o.columns * 0.6))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "tracker_issue"
  pcall(vim.treesitter.start, buf, "markdown")
  view.message(buf, "Loading " .. issue.key .. "…")

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor", row = 1, col = 0, width = width, height = 3,
    style = "minimal", border = config.get().ui.border, zindex = 70,
    title = " " .. issue.key .. ": " .. view.pad(issue.summary, math.min(#issue.summary, width - 14)) .. " ",
    title_pos = "left",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  state.win, state.buf, state.key = win, buf, issue.key

  for _, lhs in ipairs({ "q", "<Esc>", "K" }) do
    vim.keymap.set("n", lhs, function()
      M.close()
      if vim.api.nvim_win_is_valid(list_win) then vim.api.nvim_set_current_win(list_win) end
    end, { buffer = buf, nowait = true })
  end

  -- Close when the list cursor moves or the list goes away.
  state.group = vim.api.nvim_create_augroup("TrackerPreview", { clear = true })
  local list_buf = vim.api.nvim_win_get_buf(list_win)
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "BufWipeout" }, {
    group = state.group,
    buffer = list_buf,
    callback = function(ev)
      if ev.event == "BufLeave" and vim.api.nvim_get_current_win() == state.win then return end
      vim.schedule(function()
        if vim.api.nvim_get_current_win() ~= state.win then M.close() end
      end)
    end,
  })

  local function show(full)
    if not (state.buf == buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then return end
    local b = content(full, width)
    b:render(buf)
    view.refresh_markdown(buf)
    local max_h = math.max(5, math.min(math.floor(vim.o.lines * 0.6), vim.o.lines - vim.fn.screenrow() - 4))
    vim.api.nvim_win_set_height(win, math.min(#b.lines, max_h))
    require("tracker.ui.images").render(buf, full.attachments, width - 4)
    -- inside the preview (second K): gx / <CR> open an attachment or link
    for _, lhs in ipairs({ "gx", "<CR>" }) do
      vim.keymap.set("n", lhs, function() require("tracker.ui.images").open_at_cursor(full.attachments) end,
        { buffer = buf, nowait = true })
    end
  end

  if cache[issue.key] then return show(cache[issue.key]) end
  api.get_issue(issue.key, function(full, err)
    if not full then
      if state.buf == buf and vim.api.nvim_buf_is_valid(buf) then view.message(buf, err or "error", "TrackerError") end
      return
    end
    cache[issue.key] = full
    show(full)
  end)
end

return M
