-- One window, a stack of views. Opening an issue from a list pushes a view;
-- <BS> pops back to the list with its cursor where it was; q closes
-- everything. Each view owns a buffer (bufhidden=hide while it sits in the
-- stack, wiped when popped or closed). The window is a float, a split of the
-- current window or a new tab page (`ui.layout`); outside a float the title
-- goes to the winbar and the footer to the statusline.

local M = {}

local config = require("tracker.config")

---@class TrackerView
---@field buf integer
---@field title string
---@field footer string|nil
---@field win_opts table|nil           window-local options while shown
---@field on_resize fun(view: TrackerView)|nil
---@field on_return fun(view: TrackerView)|nil  called when uncovered by a pop
---@field cursor integer[]|nil          saved while covered

local S = { win = nil, layout = "float", stack = {}, closing = false }

local GROUP = "TrackerWindow"

local BASE_WIN_OPTS = {
  number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0",
  spell = false, list = false, cursorline = true, wrap = false, linebreak = false,
}

-- In a split / tab the window is an ordinary one: undo what the user's
-- options would add that `style = "minimal"` strips from a float.
local SPLIT_WIN_OPTS = { cursorcolumn = false, colorcolumn = "", statuscolumn = "" }

local LAYOUTS = { float = true, split = true, vsplit = true, tab = true }

local function layout()
  local l = config.get().ui.layout
  return LAYOUTS[l] and l or "float"
end

local function valid_win() return S.win ~= nil and vim.api.nvim_win_is_valid(S.win) end

local function geometry()
  local ui = config.get().ui
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.max(40, math.floor(vim.o.columns * ui.width))
  local height = math.max(10, math.floor(lines * ui.height))
  return {
    relative = "editor",
    width = math.min(width, vim.o.columns - 2),
    height = math.min(height, lines - 2),
    row = math.max(0, math.floor((lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  }
end

local function wipe(view)
  if view and view.buf and vim.api.nvim_buf_is_valid(view.buf) then
    pcall(require("tracker.ui.images").clear, view.buf) -- drop image placements
    pcall(vim.api.nvim_buf_delete, view.buf, { force = true })
  end
end

local function chrome(view)
  return {
    title = view.title or " Tracker ", title_pos = "center",
    footer = view.footer or "", footer_pos = "center",
  }
end

local function escape(text) return (text:gsub("%%", "%%%%")) end

-- Title / footer: the float's border, else winbar / statusline.
local function set_chrome(view)
  local c = chrome(view)
  if S.layout == "float" then
    vim.api.nvim_win_set_config(S.win, c)
  else
    vim.wo[S.win].winbar = "%=" .. escape(c.title) .. "%="
    vim.wo[S.win].statusline = "%=" .. escape(c.footer) .. "%="
  end
end

local function show(view)
  vim.api.nvim_win_set_buf(S.win, view.buf)
  set_chrome(view)
  local opts = vim.tbl_extend("force", BASE_WIN_OPTS,
    S.layout == "float" and {} or SPLIT_WIN_OPTS, view.win_opts or {})
  for k, v in pairs(opts) do
    vim.api.nvim_set_option_value(k, v, { win = S.win, scope = "local" })
  end
  if view.cursor then pcall(vim.api.nvim_win_set_cursor, S.win, view.cursor) end
end

local function open_win(view)
  S.layout = layout()
  if S.layout == "float" then
    local cfg = vim.tbl_extend("force", geometry(), chrome(view), {
      style = "minimal", border = config.get().ui.border,
    })
    S.win = vim.api.nvim_open_win(view.buf, true, cfg)
  elseif S.layout == "tab" then
    vim.cmd("tabnew")
    local scratch = vim.api.nvim_get_current_buf()
    S.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(S.win, view.buf)
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  else
    -- next to the current window, on the side 'splitbelow' / 'splitright' say
    local dir
    if S.layout == "split" then
      dir = vim.o.splitbelow and "below" or "above"
    else
      dir = vim.o.splitright and "right" or "left"
    end
    S.win = vim.api.nvim_open_win(view.buf, true, { split = dir, win = 0 })
  end
  local win = S.win

  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  local function resized()
    local top = S.stack[#S.stack]
    if top and top.on_resize then top.on_resize(top) end
  end
  if S.layout == "float" then
    vim.api.nvim_create_autocmd("VimResized", {
      group = group,
      callback = function()
        if not valid_win() then return end
        vim.api.nvim_win_set_config(S.win, geometry())
        resized()
      end,
    })
  else
    -- a split also changes size when other windows open, close or move
    vim.api.nvim_create_autocmd("WinResized", {
      group = group,
      callback = function()
        if valid_win() and vim.tbl_contains(vim.v.event.windows or {}, S.win) then resized() end
      end,
    })
  end
  -- `:q` / <C-w>c / :tabclose on the window: tear the stack down like `q` would.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(S.win),
    once = true,
    callback = function()
      -- a new window may already be open by then: leave that one alone
      vim.schedule(function()
        if S.win == win then M.close() end
      end)
    end,
  })
end

---@param view TrackerView
function M.push(view)
  if valid_win() then
    local top = S.stack[#S.stack]
    if top then top.cursor = vim.api.nvim_win_get_cursor(S.win) end
    table.insert(S.stack, view)
    show(view)
  else
    S.stack = { view }
    open_win(view)
    show(view)
  end
end

---Replace the top view (switching a list to another query).
---@param view TrackerView
function M.replace(view)
  local old = table.remove(S.stack)
  M.push(view)
  wipe(old)
end

---Back to the previous view; closes the window when the stack empties.
function M.pop()
  local top = table.remove(S.stack)
  local prev = S.stack[#S.stack]
  if not prev or not valid_win() then
    table.insert(S.stack, top)
    M.close()
    return
  end
  show(prev)
  wipe(top)
  if prev.on_return then prev.on_return(prev) end
end

function M.close()
  if S.closing then return end
  S.closing = true
  local stack = S.stack
  S.stack = {}
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
  -- the last window of the last tab can't close: wiping its buffer below
  -- leaves an empty one in it instead
  if valid_win() then pcall(vim.api.nvim_win_close, S.win, true) end
  S.win = nil
  for _, v in ipairs(stack) do wipe(v) end
  S.closing = false
end

---@return integer  views on the stack (0 = window closed)
function M.depth()
  return valid_win() and #S.stack or 0
end

---@return TrackerView|nil
function M.top()
  return S.stack[#S.stack]
end

---@return integer|nil
function M.win()
  return valid_win() and S.win or nil
end

---Update title/footer of `view` (only visible when it is on top).
---@param view TrackerView
function M.refresh_chrome(view)
  if valid_win() and S.stack[#S.stack] == view then set_chrome(view) end
end

---@param view TrackerView
---@return boolean
function M.is_top(view)
  return valid_win() and S.stack[#S.stack] == view
end

return M
