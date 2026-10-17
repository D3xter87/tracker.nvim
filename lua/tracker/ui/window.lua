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
--
-- With several providers (see tracker.resolve) an instance has one TAB per
-- provider, each with a stack of its own: `1` / `2` … switch between them
-- and every tab keeps its query, its cursor and the issue it had open. A
-- view belongs to the tab of the provider it was made for (the API scope at
-- that moment), so a view that arrives late — the issue a `create` opens
-- once the tracker answered — lands on its own tab even when another one is
-- shown by then. An empty tab opens the same kind of view the current one
-- started with (list → list, board → board).

local M = {}

local config = require("tracker.config")
local api = require("tracker.api")

---@class TrackerView
---@field buf integer
---@field title string
---@field footer string|nil
---@field win_opts table|nil           window-local options while shown
---@field on_resize fun(view: TrackerView)|nil
---@field on_return fun(view: TrackerView)|nil  called when uncovered by a pop
---@field reopen fun()|nil              opens this kind of view anew (a base view: for an empty tab)
---@field cursor integer[]|nil          saved while covered
---@field provider string|nil           the provider it was made for
---@field _inst TrackerInstance|nil     the instance it was pushed on
---@field _tab TrackerTab|nil           its tab
---@field _returned boolean|nil         uncovered while its tab was hidden: on_return is due

---@class TrackerTab
---@field name string                   provider (instance) name
---@field stack TrackerView[]

---@class TrackerInstance
---@field win integer
---@field layout string
---@field tabs table<string, TrackerTab>
---@field order string[]                tab order (provider names)
---@field labels table<string, string>  provider → what its tab shows
---@field active string                 the tab shown
---@field pending string|nil            the tab the next view was asked for (shown once it arrives)
---@field cwd string|nil                directory its providers are resolved from
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

---The stack shown.
---@param inst TrackerInstance
---@return TrackerView[]
local function stack_of(inst)
  local tab = inst.tabs[inst.active]
  return tab and tab.stack or {}
end

---The scope of a tab: what its views' API calls mean.
---@return TrackerScope
local function scope_of(inst, name)
  return { provider = name ~= "" and name or nil, cwd = inst.cwd }
end

---@return TrackerTab
local function ensure_tab(inst, name)
  local tab = inst.tabs[name]
  if not tab then
    tab = { name = name, stack = {} }
    inst.tabs[name] = tab
    if not vim.tbl_contains(inst.order, name) then table.insert(inst.order, name) end
    local info = name ~= "" and api.provider_info({ provider = name, cwd = inst.cwd }) or nil
    inst.labels[name] = info and info.label or name
  end
  return tab
end

-- A call from a tracker view means that view's provider: the window of an
-- instance, or a float over it (an editor, a preview, a picker).
api.set_scope_source(function()
  local win = vim.api.nvim_get_current_win()
  local inst = instances[win]
  if not valid(inst) then
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    inst = (ok and cfg.relative ~= "") and current() or nil
  end
  if not inst then return nil end
  return scope_of(inst, inst.active)
end)

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

---The tab bar (" 1 Jira  2 GitLab "), as { text, highlight } chunks; nil
---with a single provider.
local function tab_chunks(inst)
  if #inst.order < 2 then return nil end
  local out = {}
  for n, name in ipairs(inst.order) do
    table.insert(out, {
      (" %d %s "):format(n, inst.labels[name] or name),
      name == inst.active and "TrackerTabActive" or "TrackerTab",
    })
  end
  return out
end

local function chrome(inst, view)
  local title = view.title or " Tracker "
  local tabs = tab_chunks(inst)
  if tabs then
    table.insert(tabs, { title, "FloatTitle" })
    title = tabs
  end
  return {
    title = title, title_pos = "center",
    footer = view.footer or "", footer_pos = "center",
  }
end

local function escape(text) return (text:gsub("%%", "%%%%")) end

-- Title / footer: the float's border, else winbar / statusline.
local function set_chrome(inst, view)
  local c = chrome(inst, view)
  if inst.layout == "float" then
    vim.api.nvim_win_set_config(inst.win, c)
  else
    local bar = ""
    for _, chunk in ipairs(tab_chunks(inst) or {}) do
      bar = bar .. "%#" .. chunk[2] .. "#" .. escape(chunk[1])
    end
    if bar ~= "" then bar = bar .. "%* " end
    vim.wo[inst.win].winbar = "%=" .. bar .. escape(view.title or " Tracker ") .. "%="
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
    local cfg = vim.tbl_extend("force", geometry(), chrome(inst, view), {
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
    local stack = stack_of(inst)
    local top = stack[#stack]
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

---Show `name`'s tab (one that has views): its top view, where it was.
local function activate(inst, name)
  local from = stack_of(inst)
  if from[#from] and inst.active ~= name then from[#from].cursor = vim.api.nvim_win_get_cursor(inst.win) end
  inst.active, inst.pending = name, nil
  local stack = stack_of(inst)
  local top = stack[#stack]
  if not top then return end
  show(inst, top)
  if top._returned then
    top._returned = nil
    if top.on_return then api.with_scope(scope_of(inst, name), top.on_return, top) end
  end
end

---`view` on top of `tab`: shown when that is the tab on screen (or the one
---the user asked for), kept for later otherwise.
local function push_on(inst, tab, view)
  view._inst, view._tab, view.provider = inst, tab, tab.name
  if tab.name ~= inst.active then
    table.insert(tab.stack, view)
    if inst.pending ~= tab.name then return end -- its tab is hidden: there when the user comes back
    activate(inst, tab.name)
  else
    local top = tab.stack[#tab.stack]
    if top then top.cursor = vim.api.nvim_win_get_cursor(inst.win) end
    table.insert(tab.stack, view)
    inst.pending = nil
    show(inst, view)
  end
  -- opened from another window of the tab page: bring the tracker into focus
  if vim.api.nvim_get_current_win() ~= inst.win then pcall(vim.api.nvim_set_current_win, inst.win) end
end

---The tab a view made now belongs to: the provider of the API scope, else
---the tab shown.
local function tab_for(inst)
  local scope = api.current_scope()
  return ensure_tab(inst, (scope and scope.provider) or inst.active)
end

---Push `view` on the current instance; none in this tab page: open one.
---@param view TrackerView
function M.push(view)
  local inst = current()
  if inst then return push_on(inst, tab_for(inst), view) end
  local scope = api.current_scope()
  local cwd = (scope and scope.cwd) or vim.fs.normalize(vim.fn.getcwd())
  local info = api.provider_info({ provider = scope and scope.provider or nil, cwd = cwd })
  local name = (scope and scope.provider) or (info and info.name) or ""
  inst = { tabs = {}, order = api.active_providers({ cwd = cwd }), labels = {}, active = name, cwd = cwd, closing = false }
  for _, n in ipairs(vim.list_slice(inst.order)) do ensure_tab(inst, n) end
  local tab = ensure_tab(inst, name)
  table.insert(tab.stack, view)
  view._inst, view._tab, view.provider = inst, tab, name
  open_win(inst, view)
  show(inst, view)
end

---Replace the top view of the current instance (switching a list to another
---query).
---@param view TrackerView
function M.replace(view)
  local inst = current()
  if not inst then return M.push(view) end
  local tab = tab_for(inst)
  local old = table.remove(tab.stack)
  push_on(inst, tab, view)
  wipe(old)
end

---Back to the previous view; closes the window when the stack empties.
---With `view`: only when it is the top one (an issue archived from its
---view goes back; the callback may come late).
---@param view TrackerView|nil
function M.pop(view)
  local inst = resolve(view)
  if not inst then return end
  local tab = (view and view._tab) or inst.tabs[inst.active]
  if not tab then return end
  if view and tab.stack[#tab.stack] ~= view then return end
  local shown = tab.name == inst.active
  local top = table.remove(tab.stack)
  local prev = tab.stack[#tab.stack]
  if not prev then
    if shown then
      table.insert(tab.stack, top)
      close_instance(inst)
    else
      wipe(top) -- a hidden tab just empties
    end
    return
  end
  if shown then show(inst, prev) end
  wipe(top)
  if not shown then
    prev._returned = true
  elseif prev.on_return then
    prev.on_return(prev)
  end
end

close_instance = function(inst)
  if inst.closing then return end
  inst.closing = true
  local views = {}
  for _, tab in pairs(inst.tabs) do
    vim.list_extend(views, tab.stack)
    tab.stack = {}
  end
  if inst.win then instances[inst.win] = nil end
  if inst.group then pcall(vim.api.nvim_del_augroup_by_id, inst.group) end
  -- the last window of the last tab can't close: wiping its buffer below
  -- leaves an empty one in it instead
  if valid(inst) then pcall(vim.api.nvim_win_close, inst.win, true) end
  inst.win = nil
  for _, v in ipairs(views) do wipe(v) end
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
  if not inst then return 0 end
  return #((view and view._tab and view._tab.stack) or stack_of(inst))
end

---@param view TrackerView|nil  an instance's view; nil = the current instance
---@return TrackerView|nil
function M.top(view)
  local inst = resolve(view)
  if not inst then return nil end
  local stack = (view and view._tab and view._tab.stack) or stack_of(inst)
  return stack[#stack]
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
      for _, tab in pairs(inst.tabs) do
        for _, v in ipairs(tab.stack) do
          if v.buf == buf then return inst.win end
        end
      end
    end
  end
  return nil
end

---Update title/footer of `view` (only visible when it is on top of the tab
---shown).
---@param view TrackerView
function M.refresh_chrome(view)
  local inst = of(view)
  if not inst then return end
  local stack = stack_of(inst)
  if stack[#stack] == view then set_chrome(inst, view) end
end

---Whether `view` is on top of its tab's stack (the tab may be a hidden one).
---@param view TrackerView
---@return boolean
function M.is_top(view)
  local inst = of(view)
  if not inst then return false end
  local stack = (view._tab and view._tab.stack) or stack_of(inst)
  return stack[#stack] == view
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

-- region Tabs

---The provider tabs of `view`'s instance (else of the current one).
---@param view TrackerView|nil
---@return { order: string[], active: string, labels: table<string, string> }|nil
function M.tabs(view)
  local inst = resolve(view)
  if not inst then return nil end
  return { order = vim.deepcopy(inst.order), active = inst.active, labels = vim.deepcopy(inst.labels) }
end

---What an entry point is about to open belongs to `provider`'s tab (nil =
---the tab shown): the views pushed next bring that tab up. Returns the
---scope to open them in (`api.with_scope`).
---@param provider string|nil
---@return TrackerScope
function M.intend(provider)
  local inst = current()
  if not inst then
    return { provider = provider, cwd = vim.fs.normalize(vim.fn.getcwd()) }
  end
  provider = provider or inst.active
  if provider ~= inst.active then
    ensure_tab(inst, provider)
    inst.pending = provider
  end
  return scope_of(inst, provider)
end

---Switch the current instance to another provider's tab: its number (1 =
---the first) or its name. A tab without views opens the kind of view the
---current one started with — the default list when the provider has no
---such view.
---@param target integer|string
---@return boolean  false: no such tab (or no tracker window)
function M.switch_tab(target)
  local inst = current()
  if not inst then return false end
  local name = type(target) == "number" and inst.order[target] or target
  if not name or not vim.tbl_contains(inst.order, name) then return false end
  if name == inst.active then return true end
  local tab = ensure_tab(inst, name)
  if #tab.stack > 0 then
    activate(inst, name)
    return true
  end
  local base = stack_of(inst)[1]
  inst.pending = name
  api.with_scope(scope_of(inst, name), function()
    -- the provider may have to learn what it can do here first
    api.ready(function()
      if not valid(inst) or inst.pending ~= name then return end
      if base and base.reopen then base.reopen() end
      if #tab.stack == 0 and inst.pending == name then require("tracker.ui.list").search() end
      if #tab.stack == 0 and inst.pending == name then inst.pending = nil end
    end)
  end)
  return true
end

-- endregion

return M
