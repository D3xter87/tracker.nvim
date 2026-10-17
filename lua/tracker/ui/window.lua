-- A tracker window holds a stack of views. Opening an issue from a list
-- pushes a view; <BS> pops back to the list with its cursor where it was; q
-- closes everything. Each view owns a buffer (bufhidden=hide while it sits
-- in the stack, wiped when popped or closed). The window is a float, a
-- split of the current window or a new tab page (`ui.layout`); outside a
-- float the title goes to the winbar and the footer to the statusline.
--
-- There can be several such windows at once — one tracker tab per project
-- tab, say — each with its own stack (an INSTANCE). A call names the
-- instance by one of its views (`is_top(v)`, `win(v)`, `pop(v)`) or means
-- the current one: the instance of the current window, else the one in the
-- current tab page. Opening a view from a window that belongs to no
-- instance (no tracker in this tab page) starts a new one.

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
---@field _inst TrackerInstance|nil     the instance it was pushed on

---@class TrackerInstance
---@field win integer
---@field layout string
---@field stack TrackerView[]
---@field closing boolean
---@field group integer                 its augroup

---@type table<integer, TrackerInstance>  win → instance
local instances = {}

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

local function valid(inst)
  return inst ~= nil and inst.win ~= nil and vim.api.nvim_win_is_valid(inst.win)
end

---The instance a call without a view means: the current window's, else the
---one in the current tab page.
---@return TrackerInstance|nil
local function current()
  local inst = instances[vim.api.nvim_get_current_win()]
  if valid(inst) then return inst end
  local tab = vim.api.nvim_get_current_tabpage()
  for _, i in pairs(instances) do
    if valid(i) and vim.api.nvim_win_get_tabpage(i.win) == tab then return i end
  end
  return nil
end

---The instance `view` sits on (nil once it is closed).
---@param view TrackerView|nil
---@return TrackerInstance|nil
local function of(view)
  local inst = view and view._inst
  return valid(inst) and inst or nil
end

---`view`'s instance, else the current one.
local function resolve(view)
  if view then return of(view) end
  return current()
end

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
local function set_chrome(inst, view)
  local c = chrome(view)
  if inst.layout == "float" then
    vim.api.nvim_win_set_config(inst.win, c)
  else
    vim.wo[inst.win].winbar = "%=" .. escape(c.title) .. "%="
    vim.wo[inst.win].statusline = "%=" .. escape(c.footer) .. "%="
  end
end

local function show(inst, view)
  vim.api.nvim_win_set_buf(inst.win, view.buf)
  set_chrome(inst, view)
  local opts = vim.tbl_extend("force", BASE_WIN_OPTS,
    inst.layout == "float" and {} or SPLIT_WIN_OPTS, view.win_opts or {})
  for k, v in pairs(opts) do
    vim.api.nvim_set_option_value(k, v, { win = inst.win, scope = "local" })
  end
  if view.cursor then pcall(vim.api.nvim_win_set_cursor, inst.win, view.cursor) end
end

local close_instance

---@param inst TrackerInstance
local function open_win(inst, view)
  inst.layout = layout()
  if inst.layout == "float" then
    local cfg = vim.tbl_extend("force", geometry(), chrome(view), {
      style = "minimal", border = config.get().ui.border,
    })
    inst.win = vim.api.nvim_open_win(view.buf, true, cfg)
  elseif inst.layout == "tab" then
    -- the new tab page inherits a tab-local directory (:tcd) of this one, so
    -- the tracker keeps resolving the same repository
    vim.cmd("tabnew")
    local scratch = vim.api.nvim_get_current_buf()
    inst.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(inst.win, view.buf)
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  else
    -- next to the current window, on the side 'splitbelow' / 'splitright' say
    local dir
    if inst.layout == "split" then
      dir = vim.o.splitbelow and "below" or "above"
    else
      dir = vim.o.splitright and "right" or "left"
    end
    inst.win = vim.api.nvim_open_win(view.buf, true, { split = dir, win = 0 })
  end
  local win = inst.win
  instances[win] = inst

  inst.group = vim.api.nvim_create_augroup("TrackerWindow" .. win, { clear = true })
  local function resized()
    local top = inst.stack[#inst.stack]
    if top and top.on_resize then top.on_resize(top) end
  end
  if inst.layout == "float" then
    vim.api.nvim_create_autocmd("VimResized", {
      group = inst.group,
      callback = function()
        if not valid(inst) then return end
        vim.api.nvim_win_set_config(inst.win, geometry())
        resized()
      end,
    })
  else
    -- a split also changes size when other windows open, close or move
    vim.api.nvim_create_autocmd("WinResized", {
      group = inst.group,
      callback = function()
        if valid(inst) and vim.tbl_contains(vim.v.event.windows or {}, inst.win) then resized() end
      end,
    })
  end
  -- `:q` / <C-w>c / :tabclose on the window: tear the stack down like `q` would.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = inst.group,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        if instances[win] == inst then close_instance(inst) end
      end)
    end,
  })
end

local function push_on(inst, view)
  local top = inst.stack[#inst.stack]
  if top then top.cursor = vim.api.nvim_win_get_cursor(inst.win) end
  table.insert(inst.stack, view)
  view._inst = inst
  show(inst, view)
  -- opened from another window of the tab page: bring the tracker into focus
  if vim.api.nvim_get_current_win() ~= inst.win then pcall(vim.api.nvim_set_current_win, inst.win) end
end

---Push `view` on the current instance; none in this tab page: open one.
---@param view TrackerView
function M.push(view)
  local inst = current()
  if inst then return push_on(inst, view) end
  inst = { stack = { view }, closing = false }
  view._inst = inst
  open_win(inst, view)
  show(inst, view)
end

---Replace the top view of the current instance (switching a list to another
---query).
---@param view TrackerView
function M.replace(view)
  local inst = current()
  if not inst then return M.push(view) end
  local old = table.remove(inst.stack)
  push_on(inst, view)
  wipe(old)
end

---Back to the previous view; closes the window when the stack empties.
---With `view`: only when it is the top one (an issue archived from its
---view goes back; the callback may come late).
---@param view TrackerView|nil
function M.pop(view)
  local inst = resolve(view)
  if not inst then return end
  if view and inst.stack[#inst.stack] ~= view then return end
  local top = table.remove(inst.stack)
  local prev = inst.stack[#inst.stack]
  if not prev then
    table.insert(inst.stack, top)
    close_instance(inst)
    return
  end
  show(inst, prev)
  wipe(top)
  if prev.on_return then prev.on_return(prev) end
end

close_instance = function(inst)
  if inst.closing then return end
  inst.closing = true
  local stack = inst.stack
  inst.stack = {}
  if inst.win then instances[inst.win] = nil end
  if inst.group then pcall(vim.api.nvim_del_augroup_by_id, inst.group) end
  -- the last window of the last tab can't close: wiping its buffer below
  -- leaves an empty one in it instead
  if valid(inst) then pcall(vim.api.nvim_win_close, inst.win, true) end
  inst.win = nil
  for _, v in ipairs(stack) do wipe(v) end
  inst.closing = false
end

---Close the instance of `view`, else the current one.
---@param view TrackerView|nil
function M.close(view)
  local inst = resolve(view)
  if inst then close_instance(inst) end
end

---Close every tracker window.
function M.close_all()
  for _, inst in pairs(instances) do close_instance(inst) end
  instances = {}
end

---@param view TrackerView|nil
---@return integer  views on the stack (0 = no window)
function M.depth(view)
  local inst = resolve(view)
  return inst and #inst.stack or 0
end

---@param view TrackerView|nil  an instance's view; nil = the current instance
---@return TrackerView|nil
function M.top(view)
  local inst = resolve(view)
  return inst and inst.stack[#inst.stack] or nil
end

---The window of `view`'s instance (nil once closed), else of the current one.
---@param view TrackerView|nil
---@return integer|nil
function M.win(view)
  local inst = resolve(view)
  return inst and inst.win or nil
end

---The window whose stack holds `buf` (the view may be covered), if any.
---@param buf integer
---@return integer|nil
function M.win_of_buf(buf)
  for _, inst in pairs(instances) do
    if valid(inst) then
      for _, v in ipairs(inst.stack) do
        if v.buf == buf then return inst.win end
      end
    end
  end
  return nil
end

---Update title/footer of `view` (only visible when it is on top).
---@param view TrackerView
function M.refresh_chrome(view)
  local inst = of(view)
  if inst and inst.stack[#inst.stack] == view then set_chrome(inst, view) end
end

---@param view TrackerView
---@return boolean
function M.is_top(view)
  local inst = of(view)
  return inst ~= nil and inst.stack[#inst.stack] == view
end

---Windows of the open instances.
---@return integer[]
function M.list()
  local out = {}
  for win, inst in pairs(instances) do
    if valid(inst) then table.insert(out, win) end
  end
  table.sort(out)
  return out
end

return M
