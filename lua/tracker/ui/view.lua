-- Shared view plumbing: scratch buffers, a line builder with highlights,
-- display-width padding, buffer keymaps with a generated `?` help.

local M = {}

M.ns = vim.api.nvim_create_namespace("tracker")

---@param filetype string
---@param opts { markdown: boolean? }|nil
---@return integer buf
function M.new_buf(filetype, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  vim.bo[buf].modifiable = false
  if opts and opts.markdown then
    pcall(vim.treesitter.start, buf, "markdown")
  end
  return buf
end

-- region Builder

---@class TrackerBuilder
---@field lines string[]
---@field hls table[]
local Builder = {}
Builder.__index = Builder

---@return TrackerBuilder
function M.builder()
  return setmetatable({ lines = {}, hls = {} }, Builder)
end

---Append a line. `chunks` is a plain string or a list of { text, hl? }.
---@return integer lnum  1-based line number of the new line
function Builder:add(chunks)
  if type(chunks) == "string" then
    table.insert(self.lines, chunks)
    return #self.lines
  end
  local parts, col, row = {}, 0, #self.lines
  for _, c in ipairs(chunks) do
    local text, hl = c[1] or "", c[2]
    if hl and #text > 0 then table.insert(self.hls, { row, col, col + #text, hl }) end
    table.insert(parts, text)
    col = col + #text
  end
  table.insert(self.lines, table.concat(parts))
  return #self.lines
end

---Append several plain lines (e.g. a Markdown body).
function Builder:add_lines(lines)
  for _, l in ipairs(lines) do table.insert(self.lines, l) end
end

---Highlight a whole existing line.
function Builder:hl_line(lnum, hl)
  table.insert(self.hls, { lnum - 1, 0, #self.lines[lnum], hl })
end

---A line's background across the whole window width (a band), under its
---chunks' own highlights.
function Builder:line_bg(lnum, hl)
  self.bands = self.bands or {}
  table.insert(self.bands, { lnum - 1, hl })
end

function Builder:render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, self.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, h in ipairs(self.hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  for _, band in ipairs(self.bands or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, band[1], 0, { line_hl_group = band[2], priority = 10 })
  end
end

-- endregion

---Ask render-markdown.nvim to draw `buf` now. It redraws on TextChanged,
---which a buffer filled through the API only gets late (or, headless, not
---at all). Only when render-markdown is loaded AND attached itself to the
---buffer — i.e. the user's config lets it render tracker_* filetypes.
---@param buf integer
function M.refresh_markdown(buf)
  if not package.loaded["render-markdown"] then return end
  local ok_m, manager = pcall(require, "render-markdown.core.manager")
  if not ok_m or not manager.attached(buf) then return end
  pcall(function() require("render-markdown.api").render({ buf = buf }) end)
end

---The `ui.redraw` mode in force: "auto" is "full" for Neovim inside tmux on
---Windows (tmux-win32 loses cells while the screen scrolls, see below),
---"window" anywhere else.
---@return "window"|"full"|false
function M.redraw_mode()
  local mode = require("tracker.config").get().ui.redraw
  if mode == "auto" or mode == nil then
    return (vim.env.TMUX and vim.fn.has("win32") == 1) and "full" or "window"
  end
  return mode
end

---Draw `win` (default: the current one) afresh, every row — see
---`ui.redraw`. When the view scrolls, Neovim moves the rows already on
---screen and draws only the new ones. "window" marks the window invalid so
---its next draw is complete (a line whose height changed meanwhile —
---wrapped text under conceal, inline virtual text, images — can't leave
---rows doubled or missing). "full" clears the screen too (`:redraw!`): a
---terminal that drops cells while the rows move (tmux-win32: the cells
---under the cursor column, single characters gone from the middle of a
---line) shows what Neovim has again. false does nothing.
---@param win integer|nil
function M.redraw(win)
  local mode = M.redraw_mode()
  if mode == false then return end
  if mode == "full" then return vim.cmd("redraw!") end
  if vim.api.nvim__redraw then
    pcall(vim.api.nvim__redraw, { win = win or 0, valid = false, flush = true })
  else
    vim.cmd("redraw")
  end
end

---`normal! zz` / `zt` after a jump. The scroll it causes is drawn afresh
---by the WinScrolled watch of the view (`watch_scroll`).
---@param cmd string|nil  "zz" (default) / "zt" / "zb"
function M.scroll(cmd)
  vim.cmd("normal! " .. (cmd or "zz"))
end

---After every scroll of a window showing `buf` — a jump, <C-d>, the wheel,
---<Down> through a long description — draw it afresh (`redraw`), once per
---batch of scroll events.
---@param buf integer
function M.watch_scroll(buf)
  if M.redraw_mode() == false then return end
  local group = vim.api.nvim_create_augroup("TrackerRedraw" .. buf, { clear = true })
  local pending = false
  -- WinScrolled is keyed by window, not buffer: a global one, filtered
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    desc = "Tracker: draw the view afresh after it scrolled (ui.redraw)",
    callback = function()
      local scrolled
      for _, w in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.v.event[tostring(w)] then scrolled = w end
      end
      if not scrolled or pending then return end
      pending = true
      vim.schedule(function()
        pending = false
        if vim.api.nvim_win_is_valid(scrolled) and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "c" then
          M.redraw(scrolled)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function() pcall(vim.api.nvim_del_augroup_by_id, group) end,
  })
end

---Show a one-line message ("Loading…", an error) in a view buffer.
---@param buf integer
---@param text string
---@param hl string|nil
function M.message(buf, text, hl)
  local b = M.builder()
  b:add("")
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    b:add({ { "  " .. l, hl or "TrackerMuted" } })
  end
  b:render(buf)
end

---Truncate / pad `s` to exactly `width` display cells.
---@param s string
---@param width integer
---@return string
function M.pad(s, width)
  s = (s or ""):gsub("[\r\n\t]", " ")
  if width <= 0 then return "" end
  local dw = vim.fn.strdisplaywidth(s)
  if dw <= width then return s .. string.rep(" ", width - dw) end
  local n = vim.fn.strchars(s)
  local out = s
  while n > 0 do
    n = n - 1
    out = vim.fn.strcharpart(s, 0, n) .. "…"
    if vim.fn.strdisplaywidth(out) <= width then break end
  end
  return out .. string.rep(" ", width - vim.fn.strdisplaywidth(out))
end

---Display width of the widest string, capped.
function M.width_of(strings, cap)
  local w = 0
  for _, s in ipairs(strings) do w = math.max(w, vim.fn.strdisplaywidth(s or "")) end
  return math.min(w, cap or w)
end

---First issue key under the cursor: the <cWORD>, else anywhere on the line.
---@return string|nil
function M.key_under_cursor()
  local pattern = require("tracker.config").get().issue_key_pattern
  local key = vim.fn.expand("<cWORD>"):match(pattern)
  if key then return key end
  return vim.api.nvim_get_current_line():match(pattern)
end

---Status / column name as displayed. With `ui.status_icons = false` leading
---emoji and symbols go ("👨🏻‍💻 IN_PROGRESS" → "IN_PROGRESS"): ZWJ emoji have no
---agreed cell width, so terminals disagree and columns drift.
---@param name string|nil
---@return string
function M.status_name(name)
  name = name or ""
  if require("tracker.config").get().ui.status_icons ~= false then return name end
  local i, n = 0, vim.fn.strchars(name)
  while i < n do
    local cp = vim.fn.char2nr(vim.fn.strcharpart(name, i, 1))
    -- space, ZWJ, variation selectors, and everything from arrows / symbols
    -- upward (Latin letters with diacritics sit far below 0x2190)
    if cp == 32 or cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F) or cp >= 0x2190 then
      i = i + 1
    else
      break
    end
  end
  local stripped = vim.fn.strcharpart(name, i)
  return stripped ~= "" and stripped or name
end

---Two-letter initials for a display name ("Jan Kowalski" → "JK").
function M.initials(name)
  if not name or name == "" then return "--" end
  local out = {}
  for word in name:gmatch("%S+") do
    table.insert(out, vim.fn.strcharpart(word, 0, 1))
    if #out == 2 then break end
  end
  if #out == 1 then out[2] = vim.fn.strcharpart(name, 1, 1) end
  return table.concat(out):upper()
end

-- region Keymaps + help

---@class TrackerKey
---@field [1] string|string[]  lhs (or several)
---@field [2] function
---@field desc string
---@field mode string|string[]|nil

local function lhs_list(k) return type(k[1]) == "table" and k[1] or { k[1] } end

---Show a float listing `keys`.
---@param title string
---@param keys TrackerKey[]
function M.help(title, keys)
  local b = M.builder()
  local width = 0
  for _, k in ipairs(keys) do width = math.max(width, #table.concat(lhs_list(k), " ")) end
  for _, k in ipairs(keys) do
    b:add({ { "  " .. M.pad(table.concat(lhs_list(k), " "), width), "TrackerKey" }, { "   " .. k.desc } })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  b:render(buf)
  local w = 0
  for _, l in ipairs(b.lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  local h = #b.lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = require("tracker.config").get().ui.border,
    width = w + 2, height = h, zindex = 60,
    row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    title = " " .. title .. " ", title_pos = "center",
  })
  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", lhs, function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, nowait = true })
  end
  M.map_close(buf, function() pcall(vim.api.nvim_win_close, win, true) end)
end

---Q on a float over the tracker (help, preview, picker, editor): `dismiss`
---it, then close the tracker window too.
---@param buf integer
---@param dismiss fun()
function M.map_close(buf, dismiss)
  vim.keymap.set("n", "Q", function()
    dismiss()
    require("tracker.ui.window").close()
  end, { buffer = buf, nowait = true, silent = true, desc = "Tracker: close the tracker window" })
end

---Map `keys` on `buf` plus the common view keys: q / <Esc> / <BS> / <C-o> go back
---one view (closing the window only from the first one), Q closes it from
---anywhere, ? shows help.
---@param buf integer
---@param title string  help window title
---@param keys TrackerKey[]
function M.map(buf, title, keys)
  local window = require("tracker.ui.window")
  -- A key the view maps itself wins over the common one (the board's h / l
  -- move between columns, the list's <Esc> first clears its filters and marks).
  local own = {}
  for _, k in ipairs(keys) do
    for _, lhs in ipairs(lhs_list(k)) do own[lhs] = true end
  end
  local all = vim.deepcopy(keys)
  local function common(lhss, fn, desc)
    local free = vim.tbl_filter(function(l) return not own[l] end, lhss)
    if #free > 0 then table.insert(all, { free, fn, desc = desc }) end
  end
  common({ "q", "<Esc>", "<BS>", "<C-o>" }, function() window.pop() end, "back (close on the first view)")
  common({ "Q" }, function() window.close() end, "close the tracker window")
  -- h: back, but never closes the window (the first view stays)
  common({ "h" }, function()
    if window.depth() > 1 then window.pop() end
  end, "back (only when there is a view to go back to)")
  table.insert(all, { "?", function() M.help(title, all) end, desc = "help" })
  for _, k in ipairs(all) do
    for _, lhs in ipairs(lhs_list(k)) do
      vim.keymap.set(k.mode or "n", lhs, k[2], { buffer = buf, nowait = true, silent = true, desc = "Tracker: " .. k.desc })
    end
  end
  M.watch_scroll(buf)
end

---Free mode: lift the view's buffer-local normal-mode keys so plain nvim
---motions work (j/k by line, w, /, v / V to select, y to yank …) until
---<Esc> or q, which put the view's keys back (Q closes the window as
---anywhere). The footer says so meanwhile.
---@param buf integer
---@param v TrackerView
function M.free_mode(buf, v)
  if vim.b[buf].tracker_free then return end
  local window = require("tracker.ui.window")
  local saved = vim.api.nvim_buf_get_keymap(buf, "n")
  for _, m in ipairs(saved) do pcall(vim.api.nvim_buf_del_keymap, buf, "n", m.lhs) end
  vim.b[buf].tracker_free = true
  local footer = v.footer
  v.footer = " FREE — move / select / yank freely   <Esc> q: back to sections "
  window.refresh_chrome(v)

  -- keys that stay meaningful while moving freely (gx on an attachment)
  for _, k in ipairs(v.free_keys or {}) do
    vim.keymap.set("n", k[1], k[2], { buffer = buf, nowait = true, silent = true, desc = "Tracker: " .. (k.desc or "") })
  end

  local function leave()
    for _, lhs in ipairs({ "<Esc>", "q" }) do pcall(vim.api.nvim_buf_del_keymap, buf, "n", lhs) end
    for _, k in ipairs(v.free_keys or {}) do pcall(vim.api.nvim_buf_del_keymap, buf, "n", k[1]) end
    for _, m in ipairs(saved) do
      local rhs = m.callback or m.rhs
      if rhs then
        vim.keymap.set("n", m.lhs, rhs, {
          buffer = buf, desc = m.desc, silent = m.silent == 1, nowait = m.nowait == 1,
          noremap = m.noremap == 1, expr = m.expr == 1,
        })
      end
    end
    vim.b[buf].tracker_free = false
    v.footer = footer
    window.refresh_chrome(v)
  end
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, leave, { buffer = buf, nowait = true, silent = true, desc = "Tracker: back to sections" })
  end
  -- Q still closes everything (leave() puts the view's own Q back)
  vim.keymap.set("n", "Q", function() window.close() end,
    { buffer = buf, nowait = true, silent = true, desc = "Tracker: close the tracker window" })
end

---Copy `text` to the unnamed and the clipboard register.
---@param text string
---@param what string  for the notification
function M.yank(text, what)
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  local n = #vim.split(text, "\n", { plain = true })
  require("tracker.notify").send("actions", ("copied %s (%d line%s)"):format(what, n, n == 1 and "" or "s"))
end

---Build a compact footer from a few (lhs, label) pairs.
---@param pairs_ string[][]
function M.footer(pairs_)
  local parts = {}
  for _, p in ipairs(pairs_) do table.insert(parts, p[1] .. ":" .. p[2]) end
  return " " .. table.concat(parts, "  ") .. " "
end

-- endregion

return M
