-- Inline images in the issue view, through snacks.nvim's image module when
-- it is installed and the terminal speaks the Kitty graphics protocol
-- (`ui.images = "auto"`, the default). `true` skips the terminal check,
-- `false` turns images off. Without snacks nothing changes: the
-- `[attachment: name](adf:N)` lines stay text and <CR> opens the file.
--
-- Each image is drawn in virtual lines under its placeholder line, so the
-- line itself stays as the caption. An image that is attached to the issue
-- but embedded nowhere is drawn under its line of the Attachments section.

local M = {}

local config = require("tracker.config")

-- `[%s>]*`: also inside a panel / quote (`> [attachment: …](adf:N)`)
local PLACEHOLDER = "^[%s>]*%[attachments?: (.-)%]%(adf:%d+%)%s*$"
-- A tracker whose text is Markdown already (GitLab) links an uploaded file
-- as it is: `![shot.png](/uploads/<secret>/shot.png)` on a line of its own.
local UPLOADED = "^[%s>]*!?%[[^%]]*%]%(/uploads/(%x+/[^%s%)]+)%)"

---snacks' image module when images should be shown, else nil.
---@return table|nil
function M.snacks()
  local mode = config.get().ui.images
  if mode == false then return nil end
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then return nil end
  local ok_img, image = pcall(function() return snacks.image end)
  if not ok_img or type(image) ~= "table" then return nil end
  if mode ~= true then
    local ok_term, supported = pcall(image.supports_terminal)
    if not ok_term or not supported then return nil end
  end
  return image
end

---@param name string
---@return boolean
function M.is_image_name(name)
  local ext = (name or ""):lower():match("%.(%w+)$") or (name or ""):lower():match("%.(%w+)%?")
  return ext ~= nil and vim.tbl_contains({ "png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "heic", "avif", "svg" }, ext)
end

---Names in a placeholder line ("attachment: a.png" / "attachments: a.png, b.jpg").
---@param line string
---@return string[]|nil
function M.placeholder_names(line)
  local label = line:match(PLACEHOLDER)
  if label then return vim.split(label, ", ", { plain = true }) end
  local uploaded = line:match(UPLOADED) -- the attachment's id: "<secret>/<file name>"
  if uploaded then return { uploaded } end
  return nil
end

---The attachment a placeholder name refers to: an issue attachment by file
---name (newest wins on duplicates), or an external image URL.
---@param name string
---@param attachments TrackerAttachment[]|nil
---@return TrackerAttachment|{ url: string }|nil
function M.resolve(name, attachments)
  if name:match("^https?://") then return { url = name, filename = name } end
  local found
  for _, a in ipairs(attachments or {}) do
    if a.filename == name or a.id == name then
      if not found or (a.created or "") > (found.created or "") then found = a end
    end
  end
  return found
end

---`gx` (and <CR>) on a line of an issue, preview or editor buffer: an
---`[attachment: …](adf:N)` placeholder opens that attachment (downloaded
---once, then the system viewer), an `(upload:<path>)` line the local file,
---else an http(s) URL under the cursor. Never hands the OS an "adf:" /
---"upload:" pseudo-URL — Windows would offer the Microsoft Store for it.
---@param attachments TrackerAttachment[]|nil
---@return boolean handled
function M.open_at_cursor(attachments)
  local line = vim.api.nvim_get_current_line()
  local upload = line:match("%(upload:(.-)%)")
  if upload then
    pcall(vim.ui.open, upload)
    return true
  end
  local names = M.placeholder_names(line)
  if names then
    -- a file card of several: the name under the cursor
    local col, pick = vim.api.nvim_win_get_cursor(0)[2] + 1, names[1]
    for _, n in ipairs(names) do
      local s = line:find(n, 1, true)
      if s and col >= s and col < s + #n then pick = n end
    end
    local att = M.resolve(pick, attachments)
    if att then
      require("tracker.ui.actions").open_attachment(att)
    else
      require("tracker.notify").send("actions", pick .. ": not among the issue's attachments", vim.log.levels.WARN)
    end
    return true
  end
  local ok, urls = pcall(function() return require("vim.ui")._get_urls() end)
  for _, u in ipairs(ok and type(urls) == "table" and urls or {}) do
    if u:match("^https?://") then
      pcall(vim.ui.open, u)
      return true
    end
  end
  return false
end

---@param att TrackerAttachment|{ url: string }
local function is_image(att)
  return (att.mime or ""):match("^image/") ~= nil or M.is_image_name(att.filename or att.url or "")
end

-- Phone photos keep their rotation in an EXIF tag that browsers (and Jira)
-- apply, but snacks' ImageMagick conversion doesn't: draw from an upright
-- copy instead, made once next to the download.
local EXIF = { jpg = true, jpeg = true, tif = true, tiff = true, heic = true }
local uprighting = {} ---@type table<string, fun(path: string)[]>

---`path` turned upright (`magick -auto-orient`), or `path` itself when it
---can't carry an EXIF rotation or ImageMagick is missing.
---@param path string
---@param cb fun(path: string)
function M.upright(path, cb)
  local ext = (path:match("%.(%w+)$") or ""):lower()
  if not EXIF[ext] or vim.fn.executable("magick") == 0 then return cb(path) end
  local out = path:gsub("%.%w+$", "") .. ".upright." .. ext
  local stat = (vim.uv or vim.loop).fs_stat(out)
  if stat and stat.size > 0 then return cb(out) end
  if uprighting[out] then
    table.insert(uprighting[out], cb)
    return
  end
  uprighting[out] = { cb }
  local function done(res)
    vim.schedule(function()
      local waiting = uprighting[out]
      uprighting[out] = nil
      for _, w in ipairs(waiting) do w(res and res.code == 0 and out or path) end
    end)
  end
  if not pcall(vim.system, { "magick", path, "-auto-orient", out }, {}, done) then done(nil) end
end

function M.clear(buf)
  local image = M.snacks()
  if image then pcall(image.placement.clean, buf) end
end

---Draw every image placeholder found in `buf`, then the images of the
---`listed` lines that no placeholder showed: a file that is only attached
---to the issue (not embedded in the description or a comment) appears
---under its line of the Attachments section, and no image is drawn twice.
---@param buf integer
---@param attachments TrackerAttachment[]|nil
---@param max_width integer
---@param listed { lnum: integer, att: TrackerAttachment }[]|nil  attachment lines
function M.render(buf, attachments, max_width, listed)
  local image = M.snacks()
  if not image then return end
  pcall(image.placement.clean, buf)
  local api = require("tracker.api")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local function draw(lnum, att)
    local line = lines[lnum] or ""
    api.attachment_path(att, function(downloaded)
      if not downloaded then return end
      M.upright(downloaded, function(path)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        -- the buffer may have been re-rendered meanwhile: same line still?
        if (vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or "") ~= line then return end
        pcall(image.placement.new, buf, path, {
          pos = { lnum, 0 },
          range = { lnum, 0, lnum, #line },
          inline = true,
          max_width = max_width,
          max_height = config.get().ui.image_max_height,
        })
      end)
    end)
  end
  local shown = {} ---@type table<string, boolean>  attachment id → drawn at a placeholder
  for lnum, line in ipairs(lines) do
    for _, name in ipairs(M.placeholder_names(line) or {}) do
      local att = M.resolve(name, attachments)
      if att and is_image(att) then
        if att.id then shown[att.id] = true end
        draw(lnum, att)
      end
    end
  end
  for _, l in ipairs(listed or {}) do
    if l.att.id and not shown[l.att.id] and is_image(l.att) then draw(l.lnum, l.att) end
  end
end

return M
