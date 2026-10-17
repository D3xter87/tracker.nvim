-- Multi-select picker: a small float with checkboxes.
--   j / k        move            <Space> / x   toggle the item
--   a            all / none      <CR>          confirm
--   q / <Esc>    cancel
-- vim.ui.select can only pick one item, filters need several.

local M = {}

local view = require("tracker.ui.view")

---@class TrackerMultiItem
---@field label string
---@field value any
---@field hl string|nil       highlight of the label (an epic chip, …)
---@field selected boolean|nil

---@param items TrackerMultiItem[]
---@param opts { prompt: string }
---@param on_done fun(values: any[]|nil)  nil = cancelled
function M.open(items, opts, on_done)
  if #items == 0 then return on_done({}) end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local width = 20
  for _, it in ipairs(items) do width = math.max(width, vim.fn.strdisplaywidth(it.label) + 6) end
  width = math.min(width, math.floor(vim.o.columns * 0.6))
  local height = math.min(#items, math.floor(vim.o.lines * 0.6))

  local function render()
    local b = view.builder()
    for _, it in ipairs(items) do
      b:add({ { it.selected and " [x] " or " [ ] ", it.selected and "TrackerFilter" or "TrackerMuted" },
              { it.label, it.hl } })
    end
    b:render(buf)
  end
  render()

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = require("tracker.config").get().ui.border,
    width = width, height = height, zindex = 65,
    row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    title = " " .. opts.prompt .. " ", title_pos = "center",
    footer = " <Space> toggle  a all/none  <CR> ok  q cancel ", footer_pos = "center",
  })
  vim.wo[win].cursorline = true

  local done = false
  local function finish(values)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    on_done(values)
  end
  local function toggle()
    local it = items[vim.api.nvim_win_get_cursor(win)[1]]
    if it then
      it.selected = not it.selected
      render()
    end
  end
  local map = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<Space>", toggle, map)
  vim.keymap.set("n", "x", toggle, map)
  vim.keymap.set("n", "a", function()
    local any = false
    for _, it in ipairs(items) do any = any or not it.selected end
    for _, it in ipairs(items) do it.selected = any end
    render()
  end, map)
  vim.keymap.set("n", "<CR>", function()
    local out = {}
    for _, it in ipairs(items) do
      if it.selected then table.insert(out, it.value) end
    end
    finish(out)
  end, map)
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function() finish(nil) end, map)
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function() if not done then done = true on_done(nil) end end,
  })
end

return M
