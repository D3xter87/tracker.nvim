-- Floating Markdown input over the tracker window — same feel as the
-- review.nvim input: submit with <C-s> (normal or insert) or <CR> in normal
-- mode (so <CR> in insert mode still inserts a newline), close with
-- <Esc> / <C-c> / q in normal mode — never asks. `:w` submits too.
--
-- Unlike a fire-and-forget prompt, the popup stays open until the server
-- accepted the text: the caller's `on_submit(text, finish)` reports back with
-- finish(true) (close) or finish(false) (keep it, nothing typed is lost).
-- Closed without submitting, the text goes to `on_close` (a draft, see
-- tracker.ui.drafts) or is dropped.
--
-- NOTE: <C-s> in a terminal can be swallowed by TTY flow control (XOFF)
-- unless `stty -ixon`; <CR> in normal mode always works.

local M = {}

local counter = 0

---@class TrackerEditorOpts
---@field title string
---@field text string|nil
---@field cursor_end boolean|nil   start in insert mode at the end
---@field large boolean|nil        bigger popup (issue description)
---@field hint string|nil          footer instead of the default key hint
---@field attachments TrackerAttachment[]|nil  the issue's, for gx on `(adf:N)` lines
---@field on_submit fun(text: string, finish: fun(ok: boolean))
---@field on_cancel fun()|nil
---@field on_close fun(text: string)|nil  closed without submitting: the text (a draft)

local HINT = "<C-s>/<CR>: submit  <C-/>: panel/code/file  <C-v>: image  <Esc>/q: cancel"
local DRAFT_HINT = "<C-s>/<CR>: submit  <C-/>: panel/code/file  <C-v>: image  <Esc>/q: close, draft kept"

-- What <C-/> offers: Jira panels (as callouts) and a code block.
local BLOCKS = {
  { label = "Info panel", callout = "INFO" },
  { label = "Note panel", callout = "NOTE" },
  { label = "Success panel", callout = "SUCCESS" },
  { label = "Warning panel", callout = "WARNING" },
  { label = "Error panel", callout = "ERROR" },
  { label = "Code block", code = true },
  { label = "Image from the clipboard", paste = true },
  { label = "File(s)… (uploaded on submit)", files = true },
}

---Put `new` lines at the cursor: on a blank line instead of it, else below
---the cursor's line. The cursor ends on the last of them.
local function put_lines(buf, win, new)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then return end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(buf, cur - 1, cur, false)[1] or ""
  local row
  if line:match("^%s*$") then
    vim.api.nvim_buf_set_lines(buf, cur - 1, cur, false, new)
    row = cur + #new - 1
  else
    vim.api.nvim_buf_set_lines(buf, cur, cur, false, new)
    row = cur + #new
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
end

---<C-v>: the clipboard's image as an `![image-….png](upload:…)` line,
---uploaded and embedded when the text is submitted.
---@param insert boolean  back to insert mode afterwards
function M.paste_image(buf, win, insert)
  require("tracker.util.files").paste_image(function(path, err)
    if not path then return require("tracker.notify").send("actions", err, vim.log.levels.WARN) end
    put_lines(buf, win, { require("tracker.util.files").upload_line(path), "" })
    if insert then vim.cmd("startinsert") end
  end)
end

---Pick files (yazi / ui.file_chooser) and put an upload line for each.
function M.attach_files(buf, win)
  require("tracker.util.files").choose(function(paths)
    local new = vim.tbl_map(require("tracker.util.files").upload_line, paths)
    table.insert(new, "")
    put_lines(buf, win, new)
  end)
end

local ZINDEX = 60 -- above the tracker window

---Pickers (vim.ui.select / input: telescope, dressing, snacks …) float at
---Neovim's default zindex 50, so they'd open UNDER the popup. Drop the popup
---to that level while one is open — a float created later shows on top of
---an equal one — and lift it back with the returned function.
---@param win integer
---@return fun()
function M.below_pickers(win)
  if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_set_config, win, { zindex = 50 }) end
  return function()
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_set_config, win, { zindex = ZINDEX }) end
  end
end

---Insert a panel / code block at the cursor line, or wrap lines l1..l2
---(visual selection). An empty template leaves you in insert mode inside it.
---@param buf integer
---@param win integer
---@param l1 integer|nil
---@param l2 integer|nil
function M.insert_block(buf, win, l1, l2)
  local restore = M.below_pickers(win)
  vim.ui.select(BLOCKS, { prompt = "Insert", format_item = function(b) return b.label end }, function(b)
    if not b or not vim.api.nvim_buf_is_valid(buf) then return restore() end
    if not b.code then restore() end
    if b.paste then return M.paste_image(buf, win, false) end
    if b.files then return M.attach_files(buf, win) end
    local function apply(lang)
      local wrap = l1 and vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false) or nil
      local new
      if b.code then
        new = { "```" .. (lang or "") }
        vim.list_extend(new, wrap or { "" })
        table.insert(new, "```")
      else
        new = { "> [!" .. b.callout .. "]" }
        for _, l in ipairs(wrap or { "" }) do table.insert(new, l == "" and (wrap and ">" or "> ") or ("> " .. l)) end
      end
      local row
      if wrap then
        vim.api.nvim_buf_set_lines(buf, l1 - 1, l2, false, new)
        row = l1
      else
        local cur = vim.api.nvim_win_get_cursor(win)[1]
        local line = vim.api.nvim_buf_get_lines(buf, cur - 1, cur, false)[1] or ""
        if line:match("^%s*$") then
          vim.api.nvim_buf_set_lines(buf, cur - 1, cur, false, new)
          row = cur
        else
          vim.api.nvim_buf_set_lines(buf, cur, cur, false, vim.list_extend({ "" }, new))
          row = cur + 1
        end
      end
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        if wrap then
          vim.api.nvim_win_set_cursor(win, { row, 0 })
        else
          -- into the template's content line
          vim.api.nvim_win_set_cursor(win, { row + 1, #new[2] })
          vim.cmd("startinsert!")
        end
      end
    end
    if not b.code then return apply() end
    vim.ui.input({ prompt = "Code language (empty = none): " }, function(lang)
      restore()
      if lang ~= nil then apply(vim.trim(lang)) end
    end)
  end)
end

---@param opts TrackerEditorOpts
---@return integer buf, integer win
function M.open(opts)
  counter = counter + 1
  local HINT = opts.hint or (opts.on_close and DRAFT_HINT or HINT)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, ("tracker://edit/%d"):format(counter))
  vim.bo[buf].filetype = "tracker_edit"
  pcall(vim.treesitter.start, buf, "markdown")
  local lines = vim.split(opts.text or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  -- Back here on close: Neovim would go to `prevwin`, which after any picker
  -- / chooser opened from the popup is gone, so it lands on the first window
  -- (the code under the tracker) instead.
  local origin = vim.api.nvim_get_current_win()
  local function back_to_origin()
    if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
  end

  local title = " " .. vim.trim(opts.title) .. " "
  local scale = opts.large and { 0.75, 0.7 } or { 0.6, 0.4 }
  local width = math.floor(vim.o.columns * scale[1])
  local height = math.max(8, math.floor(vim.o.lines * scale[2]))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = require("tracker.config").get().ui.border,
    title = title,
    title_pos = "center",
    footer = " " .. HINT .. " ",
    footer_pos = "center",
    zindex = ZINDEX,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  -- `:thu` → 👍 suggestions (nvim-cmp; <C-x><C-u> without it)
  pcall(require("tracker.ui.emoji_complete").attach, buf)

  local closed, submitting = false, false
  local function close()
    if closed then return end
    closed = true
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    back_to_origin()
  end

  local function set_footer(text)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, { footer = " " .. text .. " ", footer_pos = "center" })
    end
  end

  local function buf_text()
    if not vim.api.nvim_buf_is_valid(buf) then return "" end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function submit()
    if submitting or closed then return end
    submitting = true
    vim.cmd("stopinsert")
    set_footer("submitting…")
    opts.on_submit(buf_text(), function(ok)
      submitting = false
      if ok then
        if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modified = false end
        close()
      else
        set_footer("not saved — " .. HINT)
      end
    end)
  end

  local function cancel()
    if closed then return end
    if opts.on_close then opts.on_close(buf_text()) end
    close()
    if opts.on_cancel then opts.on_cancel() end
  end

  local map = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, map)
  vim.keymap.set("n", "<CR>", submit, map)
  vim.keymap.set("n", "<Esc>", cancel, map)
  vim.keymap.set("n", "<C-c>", cancel, map)
  vim.keymap.set("n", "q", cancel, map)
  -- <C-/>: insert a panel / code block (terminals send it as <C-_>).
  for _, lhs in ipairs({ "<C-/>", "<C-_>" }) do
    vim.keymap.set({ "n", "i" }, lhs, function()
      vim.cmd("stopinsert")
      M.insert_block(buf, win)
    end, map)
    vim.keymap.set("x", lhs, function()
      local a, b = vim.fn.line("v"), vim.fn.line(".")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      M.insert_block(buf, win, math.min(a, b), math.max(a, b))
    end, map)
  end
  -- gx: the attachment / file / URL of the line, never the raw link target
  vim.keymap.set("n", "gx", function()
    if not require("tracker.ui.images").open_at_cursor(opts.attachments) then
      require("tracker.notify").send("actions", "no attachment or link here", vim.log.levels.WARN)
    end
  end, map)
  -- <C-v>: paste an image from the clipboard (text pastes as usual with p /
  -- the terminal's own paste)
  vim.keymap.set({ "n", "i" }, "<C-v>", function()
    local insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
    vim.cmd("stopinsert")
    M.paste_image(buf, win, insert)
  end, map)
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = submit })
  -- Closed some other way (:q, <C-w>c): treat as cancel.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not closed then
        closed = true
        -- the buffer is still there during WinClosed
        if opts.on_close then opts.on_close(buf_text()) end
        -- the window still exists during WinClosed: switch once it's gone,
        -- unless a float opened meanwhile (it has the focus for a reason)
        vim.schedule(function()
          if vim.api.nvim_win_get_config(0).relative == "" then back_to_origin() end
        end)
        if opts.on_cancel then opts.on_cancel() end
      end
    end,
  })

  if #lines == 1 and lines[1] == "" then
    vim.cmd("startinsert")
  elseif opts.cursor_end then
    vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
    vim.cmd("startinsert!")
  end
  return buf, win
end

---Split editor text into (summary, description): the first non-blank line is
---the summary (a leading `# ` is dropped), the rest — minus surrounding blank
---lines — the description.
---@param text string
---@return string summary, string description
function M.split_summary(text)
  local lines = vim.split(text, "\n", { plain = true })
  local i = 1
  while i <= #lines and lines[i]:match("^%s*$") do i = i + 1 end
  local summary = vim.trim(((lines[i] or ""):gsub("^#+%s*", "")))
  local rest = vim.list_slice(lines, i + 1)
  while #rest > 0 and rest[1]:match("^%s*$") do table.remove(rest, 1) end
  while #rest > 0 and rest[#rest]:match("^%s*$") do table.remove(rest) end
  return summary, table.concat(rest, "\n")
end

return M
