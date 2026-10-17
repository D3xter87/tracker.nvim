-- Local files for uploads: picking them (yazi, or any chooser command, in a
-- floating terminal) and grabbing an image from the clipboard.

local M = {}

local config = require("tracker.config")

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true, svg = true }

---@param path string
---@return boolean
function M.is_image(path)
  return IMAGE_EXT[(path:match("%.([%w]+)$") or ""):lower()] == true
end

---The editor line that uploads `path` on submit: an inline image, or a file
---card for anything else.
---@param path string
---@return string
function M.upload_line(path)
  local name = vim.fs.basename(path)
  path = path:gsub("\\", "/")
  if M.is_image(name) then return ("![%s](upload:%s)"):format(name, path) end
  return ("[attachment: %s](upload:%s)"):format(name, path)
end

---`args` with every `{key}` replaced (a function replacement: paths may
---contain `%`).
local function expand(args, key, value)
  return vim.tbl_map(function(a) return (a:gsub("{" .. key .. "}", function() return value end)) end, args)
end

local function chooser_cmd()
  local cmd = config.get().ui.file_chooser
  if cmd then return cmd end
  if vim.fn.executable("yazi") == 1 then return { "yazi", "--chooser-file={file}" } end
end

---Pick one or more files. With a chooser (`ui.file_chooser`, else yazi) in a
---floating terminal: select, <CR> confirms, q quits without a choice.
---Without one: a path prompt with file completion.
---@param cb fun(paths: string[])  not called when nothing was picked
function M.choose(cb)
  local cmd = chooser_cmd()
  if not cmd then
    return vim.ui.input({ prompt = "File to upload: ", completion = "file" }, function(p)
      if p and vim.trim(p) ~= "" then cb({ vim.fn.fnamemodify(vim.fn.expand(vim.trim(p)), ":p") }) end
    end)
  end
  local out = vim.fn.tempname()
  local args = expand(cmd, "file", out)
  local buf = vim.api.nvim_create_buf(false, true)
  local w = math.floor(vim.o.columns * 0.85)
  local h = math.floor((vim.o.lines - vim.o.cmdheight) * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = config.get().ui.border,
    width = w, height = h, zindex = 70,
    row = math.floor((vim.o.lines - h) / 2) - 1, col = math.floor((vim.o.columns - w) / 2),
    title = " Choose files to upload — <Space> select, <CR> confirm, q cancel ", title_pos = "center",
  })
  local function on_exit()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
      local paths = {}
      local f = io.open(out, "r")
      if f then
        for line in f:lines() do
          line = vim.trim(line)
          if line ~= "" then table.insert(paths, line) end
        end
        f:close()
        os.remove(out)
      end
      if #paths > 0 then cb(paths) end
    end)
  end
  local ok, err = pcall(function()
    if vim.fn.has("nvim-0.11") == 1 then
      vim.fn.jobstart(args, { term = true, on_exit = on_exit })
    else
      vim.fn.termopen(args, { on_exit = on_exit })
    end
  end)
  if not ok then
    pcall(vim.api.nvim_win_close, win, true)
    return require("tracker.notify").error("tracker: can't start " .. args[1] .. ": " .. tostring(err))
  end
  vim.cmd("startinsert")
end

---Built-in clipboard → PNG commands. They write to $TRACKER_PASTE_PATH (no
---quoting trouble) and exit non-zero when the clipboard holds no image.
local function default_paste_cmd()
  if vim.fn.has("win32") == 1 then
    -- Windows PowerShell 5.1 (always there); -STA: the clipboard needs it
    return { "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command",
      "Add-Type -AssemblyName System.Windows.Forms, System.Drawing; "
        .. "$i = [System.Windows.Forms.Clipboard]::GetImage(); if ($i -eq $null) { exit 1 }; "
        .. "$i.Save($env:TRACKER_PASTE_PATH, [System.Drawing.Imaging.ImageFormat]::Png)" }
  elseif vim.fn.has("mac") == 1 then
    if vim.fn.executable("pngpaste") == 1 then return { "pngpaste", "{path}" } end
  elseif vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-paste") == 1 then
    return { "sh", "-c", 'wl-paste --no-newline --type image/png > "$TRACKER_PASTE_PATH"' }
  elseif vim.fn.executable("xclip") == 1 then
    return { "sh", "-c", 'xclip -selection clipboard -t image/png -o > "$TRACKER_PASTE_PATH"' }
  end
end

---Save the clipboard's image as a PNG under stdpath("cache")/tracker/paste,
---named like Jira names pasted images (image-20261017-120000.png).
---@param cb fun(path: string|nil, err: string|nil)
function M.paste_image(cb)
  local cmd = config.get().ui.paste_image or default_paste_cmd()
  if not cmd then
    return vim.schedule(function() cb(nil, "tracker: no clipboard-image command here — set ui.paste_image") end)
  end
  local dir = vim.fn.stdpath("cache") .. "/tracker/paste"
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.normalize(dir .. "/" .. os.date("image-%Y%m%d-%H%M%S.png"))
  local ok, err = pcall(vim.system, expand(cmd, "path", path), { text = true, env = { TRACKER_PASTE_PATH = path } },
    function(res)
      vim.schedule(function()
        local st = vim.uv.fs_stat(path)
        if res.code ~= 0 or not st or st.size == 0 then
          if st then os.remove(path) end
          return cb(nil, "no image in the clipboard")
        end
        cb(path)
      end)
    end)
  if not ok then vim.schedule(function() cb(nil, "tracker: " .. tostring(err)) end) end
end

return M
