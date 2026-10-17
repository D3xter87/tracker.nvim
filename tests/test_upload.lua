-- Attachments: uploads (multipart), files embedded from the editor's
-- `(upload:…)` lines, the clipboard image, the chooser, the view keys.

local h = require("helpers")
local fake = require("fake_provider")
local http = require("tracker.http.client")
local jira = require("tracker.providers.jira")
local files = require("tracker.util.files")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
local notes = {}
require("tracker.notify").set_sink(function(msg) table.insert(notes, msg) end)
local config = require("tracker.config")
local window = require("tracker.ui.window")

local PCFG = {
  base_url = "https://example.atlassian.net", login = "me@x.pl", token = "tok",
  fields = { story_points = "customfield_10016", epic_color = "customfield_10013",
             start_date = "customfield_10015", sprint = "customfield_10020" },
}

local function wait_for(pred, what)
  if not vim.wait(5000, pred, 10) then error("timed out waiting for " .. (what or "condition"), 2) end
end
local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function text() return table.concat(lines(), "\n") end
local function press(lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
    if vim.keycode(m.lhs) == vim.keycode(lhs) then return m.callback() end
  end
  error("no mapping for " .. lhs)
end
local function goto_line(pattern)
  for lnum, l in ipairs(lines()) do
    if l:find(pattern) then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      return lnum, l
    end
  end
  error("no line " .. pattern .. " in\n" .. text())
end
local function calls(kind)
  return vim.tbl_filter(function(c) return c[1] == kind end, fake.calls)
end

---A PNG header claiming w × h (enough for the IHDR reader).
local function write_png(path, w, hgt)
  local function u32(n) return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) end
  local f = assert(io.open(path, "wb"))
  f:write("\137PNG\r\n\26\n" .. u32(13) .. "IHDR" .. u32(w) .. u32(hgt) .. "\8\6\0\0\0")
  f:close()
end

---Stub the transport with responses { status, body?, headers? } in order.
local function stub(list)
  local sent = {}
  http.request = function(opts, cb)
    table.insert(sent, opts)
    local r = table.remove(list, 1) or { status = 200, body = "{}" }
    vim.schedule(function()
      local ok = r.status >= 200 and r.status < 300
      cb({ ok = ok, status = r.status, body = r.body or "", headers = r.headers or {},
           err = not ok and http.describe_error(r.status) or nil })
    end)
  end
  return sent
end
local real_request = http.request

local function run(fn)
  local res, done = {}, false
  fn(function(...)
    res = vim.F.pack_len(...)
    done = true
  end)
  vim.wait(3000, function() return done end, 5)
  assert(done, "callback never ran")
  return vim.F.unpack_len(res)
end

local function ui_test(fn)
  return function()
    local real_select = vim.ui.select
    local ui = vim.deepcopy(config.get().ui)
    notes = {}
    local ok, err = pcall(fn)
    vim.ui.select = real_select
    config.get().ui.paste_image, config.get().ui.file_chooser = ui.paste_image, ui.file_chooser
    pcall(window.close)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
    end
    if not ok then error(err, 0) end
  end
end

local T = {}

-- region provider

T["upload: multipart, quoted paths, the XSRF header; results in the paths' order"] = function()
  local sent = stub({ { status = 200, body = vim.json.encode({
    { id = 2, filename = "b;c.txt", mimeType = "text/plain", size = 3 },
    { id = 1, filename = "a.png", mimeType = "image/png", size = 9 },
  }) } })
  local atts = run(function(cb) jira.upload_attachments(PCFG, "ABC-1", { "C:/x/a.png", "C:/x/b;c.txt" }, cb) end)
  http.request = real_request
  h.eq("https://example.atlassian.net/rest/api/3/issue/ABC-1/attachments", sent[1].url)
  h.eq("no-check", sent[1].headers["X-Atlassian-Token"])
  h.eq({ { "file", '@"C:/x/a.png"' }, { "file", '@"C:/x/b;c.txt"' } }, sent[1].form)
  h.eq({ "1", "2" }, vim.tbl_map(function(a) return a.id end, atts))
end

T["comment with an upload line: uploaded, media id from the redirect, embedded inline"] = function()
  local png = vim.fn.tempname() .. ".png"
  write_png(png, 640, 480)
  local name = vim.fs.basename(png)
  local sent = stub({
    { status = 200, body = vim.json.encode({ { id = 500, filename = name } }) },
    { status = 303, headers = { location = "https://api.media.atlassian.com/file/abcd-1234-ef/binary?token=x" } },
    { status = 201, body = vim.json.encode({ id = "c1", body = { type = "doc", version = 1, content = {} } }) },
  })
  local c, err = run(function(cb) jira.add_comment(PCFG, "ABC-1", "see:\n\n" .. files.upload_line(png) .. "\n\nend", cb) end)
  http.request = real_request
  h.eq(nil, err)
  h.truthy(c)
  h.eq("GET", sent[2].method)
  h.eq("https://example.atlassian.net/rest/api/3/attachment/content/500", sent[2].url)
  local doc = vim.json.decode(sent[3].body).body
  local single = doc.content[2]
  h.eq("mediaSingle", single.type)
  h.eq({ type = "file", id = "abcd-1234-ef", collection = "", alt = name, width = 640, height = 480 }, single.content[1].attrs)
  h.eq("end", doc.content[3].content[1].text)
end

T["create with an upload line: created first, then uploaded and the description set"] = function()
  local png = vim.fn.tempname() .. ".png"
  write_png(png, 10, 10)
  local sent = stub({
    { status = 201, body = vim.json.encode({ id = "9", key = "ABC-9" }) },
    { status = 200, body = vim.json.encode({ { id = 7, filename = vim.fs.basename(png) } }) },
    { status = 303, headers = { location = "https://api.media.atlassian.com/file/feed-1/binary" } },
    { status = 204 },
  })
  local issue = run(function(cb)
    jira.create_issue(PCFG, { project = "ABC", type_id = "1", summary = "S", description = "x\n\n" .. files.upload_line(png) }, cb)
  end)
  http.request = real_request
  h.eq("ABC-9", issue.key)
  h.eq(nil, issue.warning)
  h.eq(nil, vim.json.decode(sent[1].body).fields.description) -- no files yet
  h.eq({ "POST", "POST", "GET", "PUT" }, vim.tbl_map(function(s) return s.method end, sent))
  h.eq("https://example.atlassian.net/rest/api/3/issue/ABC-9/attachments", sent[2].url)
  local desc = vim.json.decode(sent[4].body).fields.description
  h.eq("feed-1", desc.content[2].content[1].attrs.id)
end

T["a non-image upload becomes a file card; a missing file fails before any request"] = function()
  local txt = vim.fn.tempname() .. ".log"
  vim.fn.writefile({ "x" }, txt)
  h.truthy(files.upload_line(txt):match("^%[attachment: "), files.upload_line(txt))
  local sent = stub({
    { status = 200, body = vim.json.encode({ { id = 8, filename = vim.fs.basename(txt) } }) },
    { status = 303, headers = { location = "https://api.media.atlassian.com/file/f00d/binary" } },
  })
  local md, stash = run(function(cb) jira.resolve_uploads(PCFG, "ABC-1", files.upload_line(txt), nil, cb) end)
  h.eq("mediaGroup", stash[1].type)
  h.truthy(md:find("(adf:1)", 1, true), md)
  sent = stub({})
  local res, _, err = run(function(cb) jira.resolve_uploads(PCFG, "ABC-1", "![x.png](upload:C:/nope/x.png)", nil, cb) end)
  http.request = real_request
  h.eq(nil, res)
  h.truthy(err:find("not found", 1, true), err)
  h.eq(0, #sent)
end

-- endregion

-- region UI

---A command that runs this nvim on a tiny Lua script (cross-platform stand-in
---for PowerShell / wl-paste / yazi).
local function nvim_script(body)
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(vim.split(body, "\n"), script)
  return { vim.v.progpath, "--clean", "--headless", "-l", script }
end

T["editor <C-v>: the clipboard image becomes an upload line at the cursor"] = ui_test(function()
  local cmd = nvim_script([[local f = io.open(arg[1], "wb") f:write("\137PNG\r\n\26\n0000IHDR") f:close()]])
  table.insert(cmd, "{path}")
  config.get().ui.paste_image = cmd
  require("tracker.ui.editor").open({ title = "t", text = "before", on_submit = function() end })
  press("<C-v>")
  wait_for(function() return text():find("upload:", 1, true) end, "pasted")
  local l = lines()
  h.eq("before", l[1])
  h.truthy(l[2]:match("^!%[image%-%d+%-%d+%.png%]%(upload:.+%.png%)$"), l[2])
  h.eq("", l[3])
end)

T["editor <C-v> without an image in the clipboard: a note, nothing inserted"] = ui_test(function()
  config.get().ui.paste_image = nvim_script("os.exit(1)")
  require("tracker.ui.editor").open({ title = "t", text = "before", on_submit = function() end })
  press("<C-v>")
  wait_for(function() return vim.tbl_contains(notes, "no image in the clipboard") end, "note")
  h.eq({ "before" }, lines())
end)

T["issue view: e on Attachments → chooser → upload; D on an attachment deletes it"] = ui_test(function()
  fake.reset()
  local a = vim.fn.tempname() .. ".png"
  local b = vim.fn.tempname() .. ".pdf"
  local cmd = nvim_script(([[local f = io.open(arg[1], "w") f:write(%q .. "\n" .. %q .. "\n") f:close()]]):format(a, b))
  table.insert(cmd, "{file}")
  config.get().ui.file_chooser = cmd
  require("tracker").issue("FAKE-2")
  wait_for(function() return text():find("## Attachments (0)", 1, true) end, "issue")
  goto_line("## Attachments")
  press("e")
  wait_for(function() return #calls("upload") == 1 end, "upload")
  h.eq({ "upload", "FAKE-2", { a, b } }, calls("upload")[1])
  wait_for(function() return text():find("## Attachments (2)", 1, true) end, "reloaded")
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  goto_line(vim.pesc(vim.fs.basename(b)))
  press("D")
  wait_for(function() return #calls("delete_attachment") == 1 end, "delete")
  wait_for(function() return text():find("## Attachments (1)", 1, true) end, "one left")
  h.eq(0, #calls("delete"))
end)

T["list U uploads to the issue under the cursor"] = ui_test(function()
  fake.reset()
  local a = vim.fn.tempname() .. ".txt"
  local cmd = nvim_script(([[local f = io.open(arg[1], "w") f:write(%q) f:close()]]):format(a))
  table.insert(cmd, "{file}")
  config.get().ui.file_chooser = cmd
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  goto_line("FAKE%-1 ")
  press("U")
  wait_for(function() return #calls("upload") == 1 end, "upload")
  h.eq({ "upload", "FAKE-1", { a } }, calls("upload")[1])
end)

-- endregion


-- region gx never hands the OS a pseudo-URL

local function capture_open(fn)
  local real, opened = vim.ui.open, {}
  vim.ui.open = function(p) table.insert(opened, p) return nil end
  local ok, err = pcall(fn, opened)
  vim.ui.open = real
  if not ok then error(err, 0) end
end

T["gx on an (adf:N) image line opens the attachment file — in section and free mode"] = ui_test(function()
  capture_open(function(opened)
    fake.reset()
    require("tracker").issue("FAKE-1")
    wait_for(function() return text():find("(adf:1)", 1, true) end, "issue")
    goto_line("%(adf:1%)")
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], 5 })
    press("gx")
    wait_for(function() return #opened == 1 end, "opened")
    h.truthy(opened[1]:match("shot%.png$"), opened[1])
    -- free mode: the view keys step aside, gx stays ours
    press("v")
    press("gx")
    wait_for(function() return #opened == 2 end, "opened in free mode")
    h.truthy(opened[2]:match("shot%.png$"), opened[2])
    for _, p in ipairs(opened) do h.truthy(not p:find("adf:", 1, true), p) end
    press("<Esc>")
    -- back in section mode gx is the section-mode one again
    h.truthy(vim.iter(vim.api.nvim_buf_get_keymap(0, "n")):any(function(m) return m.lhs == "j" end), "keys restored")
  end)
end)

T["gx in the editor: an upload line opens the local file, never 'upload:'"] = ui_test(function()
  capture_open(function(opened)
    require("tracker.ui.editor").open({ title = "t", text = "![a.png](upload:C:/tmp/a.png)", on_submit = function() end })
    vim.cmd("stopinsert")
    press("gx")
    h.eq({ "C:/tmp/a.png" }, opened)
  end)
end)

-- endregion


T["<C-/> menu: the popup steps below pickers while one is open, then back on top"] = function()
  -- No resizing of columns / lines here: headless nvim (0.12.2) crashes on
  -- it with floats open once enough tests ran before; the default 80x24
  -- holds the floats below at row 2, col 2 just as well.
  local function float(ch, z)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.fn["repeat"]({ string.rep(ch, 40) }, 10))
    return vim.api.nvim_open_win(b, true, { relative = "editor", row = 2, col = 2, width = 40, height = 10, zindex = z })
  end
  local function top()
    vim.cmd("redraw!")
    pcall(vim.api.nvim__redraw, { flush = true, valid = false })
    return vim.fn.screenstring(5, 10)
  end
  local tracker_win = float("T", nil)
  local editor_win = float("E", 60)
  local restore = require("tracker.ui.editor").below_pickers(editor_win)
  h.eq("E", top()) -- still above the tracker window
  local picker = float("P", nil)
  h.eq("P", top())
  vim.api.nvim_win_close(picker, true)
  restore()
  h.eq("E", top())
  h.eq(60, vim.api.nvim_win_get_config(editor_win).zindex)
  vim.api.nvim_win_close(editor_win, true)
  vim.api.nvim_win_close(tracker_win, true)
end

return T
