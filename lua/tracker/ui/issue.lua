-- Single-issue view: header fields, description, sub-tasks, comments and
-- attachments as one Markdown buffer (treesitter-highlighted), organised in
-- SECTIONS like review.nvim's Info panel: the title, every field, the
-- description, each sub-task, comment and attachment is one section.
--
--   j / k    next / previous section (<Down> / <Up>, <C-d> / <C-u> still
--            move by line, e.g. through a long description)
--   e        edit the section under the cursor: the field, the description,
--            your comment, a sub-task's summary, ...
--   E        pick a field to edit

local M = {}

local api = require("tracker.api")
local window = require("tracker.ui.window")
local view = require("tracker.ui.view")
local hl = require("tracker.ui.highlights")
local icons = require("tracker.ui.icons")
local actions = require("tracker.ui.actions")
local fields = require("tracker.ui.fields")
local notify = require("tracker.notify")
local model = require("tracker.model")
local images = require("tracker.ui.images")

local WARN = vim.log.levels.WARN

local function human_size(bytes)
  if not bytes then return "?" end
  if bytes < 1024 then return bytes .. " B" end
  if bytes < 1024 * 1024 then return ("%.0f KB"):format(bytes / 1024) end
  return ("%.1f MB"):format(bytes / 1024 / 1024)
end

local function is_subtask(i) return i.type and (i.type.subtask or (i.type.level or 0) < 0) end
local function is_epic(i) return i.type and (i.type.level or 0) >= 1 end

---@class TrackerSection
---@field from integer        first line (1-based)
---@field to integer          last line
---@field kind string         field | info | parent | description | subtasks | subtask
---                           | links | link | comments | comment | attachments | attachment | dates
---@field field string|nil    fields.EDITORS key for kind = "field" / "description"
---@field ref table|nil       the sub-task / link / comment / attachment

---@param key string
function M.open(key)
  key = key:upper()
  local buf = view.new_buf("tracker_issue", { markdown = true })
  local v = {
    buf = buf,
    title = " " .. key .. " ",
    footer = view.footer({
      { "j/k", "sections" }, { "e", "edit" }, { "V", "copy" }, { "v", "free" }, { "E", "fields" }, { "s", "status" },
      { "c", "comment" }, { "R", "reply" }, { "S", "sub-task" }, { "C", "clone" }, { "<CR>", "open" }, { "?", "help" },
    }),
    win_opts = { cursorline = true, wrap = true, linebreak = true, conceallevel = 2 },
  }
  local st = { issue = nil, comments = {}, me = nil, sections = {} }
  -- free mode (`v`) keeps gx: the plain one would hand "adf:1" to the OS
  v.free_keys = {
    { "gx", function()
        if not images.open_at_cursor(st.issue and st.issue.attachments) then actions.web(key) end
      end, desc = "open the attachment / link of the line" },
  }

  local function render()
    local i = st.issue
    local b = view.builder()
    local sections = {}
    local function section(kind, from, to, extra)
      table.insert(sections, vim.tbl_extend("force", { kind = kind, from = from, to = to or from }, extra or {}))
    end
    local function field_line(label, chunks, kind, field_name)
      local line = { { view.pad(label, 13), "TrackerField" } }
      vim.list_extend(line, chunks)
      local lnum = b:add(line)
      section(kind, lnum, lnum, { field = field_name })
    end

    local title = b:add("# " .. i.key .. "  " .. i.summary)
    b:hl_line(title, "TrackerTitle")
    section("field", title, title, { field = "summary" })
    b:add("")

    field_line("Status", { { view.status_name(i.status and i.status.name), hl.status(i.status) } }, "field", "status")
    local ticon, thl = icons.type(i.type)
    field_line("Type", { { ticon .. " ", thl }, { i.type and i.type.name or "?", "TrackerType" } }, "info")
    local picon, phl = icons.priority(i)
    field_line("Priority", { { picon .. " ", phl }, { i.priority or "-" } }, "field", "priority")
    field_line("Assignee", { { i.assignee and i.assignee.name or "Unassigned", i.assignee and "TrackerUser" or "TrackerMuted" } },
      "field", "assignee")
    field_line("Reporter", { { i.reporter and i.reporter.name or "-", "TrackerUser" } }, "field", "reporter")
    field_line("Labels", { { #(i.labels or {}) > 0 and table.concat(i.labels, ", ") or "-", "TrackerLabel" } }, "field", "labels")
    field_line("Story points", { { type(i.story_points) == "number" and tostring(i.story_points) or "-", "TrackerPoints" } },
      "field", "points")
    if is_subtask(i) then
      if i.parent then
        field_line("Parent", { { i.parent.key, "TrackerKey" }, { "  " .. i.parent.summary } }, "parent")
      end
    elseif not is_epic(i) then
      if i.parent then
        field_line("Epic", { { i.parent.key, "TrackerKey" }, { "  " .. i.parent.summary } }, "field", "epic")
      else
        field_line("Epic", { { "-", "TrackerMuted" } }, "field", "epic")
      end
    end
    local d1 = b:add({ { view.pad("Updated", 13), "TrackerField" }, { model.short_time(i.updated), "TrackerMuted" } })
    b:add({ { view.pad("Created", 13), "TrackerField" }, { model.short_time(i.created), "TrackerMuted" } })
    local d3 = b:add({ { view.pad("URL", 13), "TrackerField" }, { i.url, "TrackerMuted" } })
    section("dates", d1, d3)

    b:add("")
    local dfrom = b:add("## Description")
    b:add("")
    if i.description and vim.trim(i.description) ~= "" then
      b:add_lines(vim.split(i.description, "\n", { plain = true }))
    else
      b:add("_No description_")
    end
    if i.lossy and #i.lossy > 0 then
      b:add("")
      b:add({ { "(shown simplified: " .. table.concat(i.lossy, ", ") .. ")", "TrackerMuted" } })
    end
    section("description", dfrom, #b.lines, { field = "description" })

    if #i.subtasks > 0 or not is_subtask(i) then
      b:add("")
      section("subtasks", b:add(("## Sub-tasks (%d)"):format(#i.subtasks)))
      for _, s in ipairs(i.subtasks) do
        local sicon, shl = icons.type(s.type)
        local lnum = b:add({ { "- " }, { sicon .. " ", shl }, { s.key, "TrackerKey" }, { " " },
          { "[" .. (s.status and view.status_name(s.status.name) or "?") .. "]", hl.status(s.status) }, { " " .. (s.summary or "") } })
        section("subtask", lnum, lnum, { ref = s })
      end
    end

    -- Links, grouped by relation in the order Jira lists them ("blocks",
    -- "is blocked by", "clones", …); `e` on the header adds one.
    local links = i.links or {}
    b:add("")
    section("links", b:add(("## Links (%d)"):format(#links)))
    local groups, order = {}, {}
    for _, l in ipairs(links) do
      if not groups[l.label] then
        groups[l.label] = {}
        table.insert(order, l.label)
      end
      table.insert(groups[l.label], l)
    end
    for _, label in ipairs(order) do
      b:add({ { label, "TrackerField" } })
      for _, l in ipairs(groups[label]) do
        local o = l.issue
        local licon, lhl = icons.type(o.type)
        local lnum = b:add({ { "- " }, { licon .. " ", lhl }, { o.key, "TrackerKey" }, { " " },
          { "[" .. (o.status and view.status_name(o.status.name) or "?") .. "]", hl.status(o.status) }, { " " .. (o.summary or "") } })
        section("link", lnum, lnum, { ref = l })
      end
    end

    b:add("")
    section("comments", b:add(("## Comments (%d)"):format(#st.comments)))
    -- Newest first: the latest discussion is what you open an issue for.
    for n = #st.comments, 1, -1 do
      local c = st.comments[n]
      b:add("")
      local edited = c.updated and c.created and c.updated:sub(1, 16) ~= c.created:sub(1, 16)
      local from = b:add(("### %s · %s%s"):format(c.author and c.author.name or "?", model.short_time(c.created), edited and " (edited)" or ""))
      b:add("")
      b:add_lines(vim.split(c.body, "\n", { plain = true }))
      section("comment", from, #b.lines, { ref = c })
    end

    -- always there: `e` on it uploads files
    do
      b:add("")
      section("attachments", b:add(("## Attachments (%d)"):format(#(i.attachments or {}))))
      for _, a in ipairs(i.attachments or {}) do
        local lnum = b:add({ { "- " }, { a.filename, "TrackerLabel" },
          { ("  %s · %s · %s"):format(human_size(a.size), a.author and a.author.name or "?", model.short_date(a.created)), "TrackerMuted" } })
        section("attachment", lnum, lnum, { ref = a })
      end
    end

    b:render(buf)
    view.refresh_markdown(buf)
    st.sections = sections
    v.title = " " .. i.key .. " "
    window.refresh_chrome(v)
    local win = window.win(v)
    images.render(buf, i.attachments, (win and vim.api.nvim_win_get_width(win) or vim.o.columns) - 4)
  end

  ---Index of the section the cursor is in (or the last one above it).
  local function section_index()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local idx
    for n, s in ipairs(st.sections) do
      if s.from <= row then idx = n end
      if row <= s.to and row >= s.from then return n end
    end
    return idx
  end

  local function current_section()
    local idx = section_index()
    return idx and st.sections[idx] or nil
  end

  local function jump(dir)
    return function()
      if #st.sections == 0 then return end
      local idx = section_index()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local target
      if not idx then
        target = st.sections[1]
      elseif dir < 0 and row > st.sections[idx].from then
        target = st.sections[idx] -- inside a tall section: k goes to its start first
      else
        target = st.sections[math.max(1, math.min(#st.sections, idx + dir))]
      end
      vim.api.nvim_win_set_cursor(0, { target.from, 0 })
      -- Centre it, so the section's content is in view, not below the edge.
      view.scroll("zz")
    end
  end

  ---Attachment for the cursor line: an attachment section, or the first file
  ---of an `[attachment: …](adf:N)` line.
  local function attachment_under_cursor()
    local s = current_section()
    if s and s.kind == "attachment" then return s.ref end
    local names = images.placeholder_names(vim.api.nvim_get_current_line())
    if names and st.issue then return images.resolve(names[1], st.issue.attachments) end
  end

  local function load()
    if not st.issue then view.message(buf, "Loading " .. key .. "…") end
    local pending, failed = 3, nil
    local function step(err)
      failed = failed or err
      pending = pending - 1
      if pending > 0 or not vim.api.nvim_buf_is_valid(buf) then return end
      if not st.issue then return view.message(buf, failed or "error", "TrackerError") end
      if failed then notify.error(failed) end
      local keep = window.is_top(v) and vim.api.nvim_win_get_cursor(window.win())
      render()
      if keep then pcall(vim.api.nvim_win_set_cursor, window.win(), keep) end
    end
    api.get_issue(key, function(issue, err)
      st.issue = issue or st.issue
      step(err)
    end)
    api.get_comments(key, function(comments, err)
      st.comments = comments or {}
      step(err)
    end)
    api.myself(function(me)
      st.me = me
      step(nil) -- not fatal: only gates editing other people's comments
    end)
  end

  ---@param what string|nil  "edited" (default) / "deleted"
  local function own_comment(c, what)
    if st.me and c.author and c.author.id ~= st.me.id then
      notify.send("actions", ("only your own comments can be %s"):format(what or "edited"), WARN)
      return false
    end
    return true
  end

  local function comment_under_cursor()
    local s = current_section()
    return s and s.kind == "comment" and s.ref or nil
  end

  ---`e`: edit whatever the cursor's section is.
  local function edit_section(i)
    local s = current_section()
    if not s then return fields.menu(i, load) end
    if s.kind == "field" or s.kind == "description" then
      fields.edit(i, s.field, load)
    elseif s.kind == "subtask" then
      fields.summary({ key = s.ref.key, summary = s.ref.summary }, load)
    elseif s.kind == "subtasks" then
      actions.create({ parent = i.key }, function() load() end)
    elseif s.kind == "comment" then
      if own_comment(s.ref) then actions.edit_comment(i.key, s.ref, load, i.attachments) end
    elseif s.kind == "comments" then
      actions.comment(i.key, load)
    elseif s.kind == "links" or s.kind == "link" then
      actions.add_link(i, load)
    elseif s.kind == "attachments" then
      actions.upload(i.key, function() load() end)
    elseif s.kind == "attachment" then
      actions.open_attachment(s.ref)
    elseif s.kind == "parent" then
      notify.send("actions", "a sub-task's parent can't be changed here", WARN)
    elseif s.kind == "info" then
      notify.send("actions", "the issue type can't be changed through the API", WARN)
    else
      notify.send("actions", "nothing to edit here", WARN)
    end
  end

  ---`V`: the section's content as text — the Markdown of a description or
  ---comment, a field's value, the title, … — without headers or labels.
  ---@return string text, string what
  local function section_text(i, s)
    local function lines(from, to)
      return table.concat(vim.api.nvim_buf_get_lines(buf, from - 1, to, false), "\n")
    end
    if s.kind == "description" then return i.description or "", "the description" end
    if s.kind == "comment" then
      return s.ref.body, ("%s's comment"):format(s.ref.author and s.ref.author.name or "the")
    end
    if s.kind == "field" and s.field == "summary" then return i.summary, "the summary" end
    if s.kind == "subtask" then return s.ref.key .. " " .. s.ref.summary, s.ref.key end
    if s.kind == "link" then return s.ref.issue.key .. " " .. s.ref.issue.summary, s.ref.issue.key end
    if s.kind == "attachment" then return s.ref.filename, s.ref.filename end
    if s.kind == "field" or s.kind == "info" or s.kind == "parent" then
      -- the value after the 13-column label
      local line = lines(s.from, s.from)
      local label = vim.trim(line:sub(1, 13))
      return vim.trim(line:sub(14)), label:lower()
    end
    return lines(s.from, s.to), s.kind
  end

  local function loaded(fn)
    return function()
      if st.issue then fn(st.issue) end
    end
  end

  view.map(buf, key, {
    { "j", jump(1), desc = "next section" },
    { "k", jump(-1), desc = "previous section" },
    { "V", loaded(function(i)
        local s = current_section()
        if not s then return end
        view.yank(section_text(i, s))
      end), desc = "copy the section's content (stay in section mode)" },
    { "v", function() view.free_mode(buf, v) end,
      desc = "free mode: plain motions, select (v / V), yank (y); <Esc> / q back" },
    { "e", loaded(edit_section), desc = "edit the section under the cursor" },
    { "M", loaded(function(i) require("tracker.ui.plan").move({ i }, nil, load) end),
      desc = "move: sprint, backlog, epic, parent" },
    { "d", loaded(function(i) require("tracker.ui.plan").archive({ i }, function() window.pop(v) end) end),
      desc = "archive this issue (asks first)" },
    { "D", loaded(function(i)
        -- on a comment / link: that one; anywhere else: the issue
        local c = comment_under_cursor()
        if c then
          if own_comment(c, "deleted") then actions.delete_comment(i.key, c, load) end
          return
        end
        local s = current_section()
        if s and s.kind == "link" then return actions.remove_link(i.key, s.ref, load) end
        if s and s.kind == "attachment" then return actions.delete_attachment(i.key, s.ref, load) end
        require("tracker.ui.plan").delete({ i }, function() window.pop(v) end)
      end), desc = "DELETE the comment (yours) / link / attachment under the cursor, else this issue (asks first)" },
    { "E", loaded(function(i) fields.menu(i, load) end), desc = "edit a field (menu)" },
    { "s", loaded(function(i) actions.transition(i.key, load) end), desc = "change status" },
    { "a", loaded(function(i) actions.assign(i.key, load) end), desc = "assign" },
    { "A", loaded(function(i) actions.toggle_me(i, load) end), desc = "assign to me / unassign me (toggle)" },
    { "c", loaded(function(i) actions.comment(i.key, load) end), desc = "add comment" },
    { "R", loaded(function(i)
        local c = comment_under_cursor()
        if not c then return notify.send("actions", "put the cursor on a comment to reply", WARN) end
        actions.reply(i.key, c, load)
      end), desc = "reply to the comment under the cursor" },
    { "C", loaded(function(i)
        actions.clone(i, function(res) M.open(res.key) end)
      end), desc = "clone: summary in a popup; fields, description, sub-tasks, a \"clones\" link" },
    { "S", loaded(function(i) actions.create({ parent = i.key }, function() load() end) end), desc = "create sub-task" },
    { "gb", loaded(function(i) require("tracker.ui.branch").create(i, load) end),
      desc = "the issue's branch: check out + pull (local / origin), else create (+ MR, see git.create)" },
    { "gr", loaded(function(i) require("tracker.ui.branch").review(i) end), desc = "review the issue's branch (review.nvim)" },
    { "gc", loaded(function(i) require("tracker.ui.branch").cicd(i) end), desc = "pipelines of the issue's branch (cicd.nvim)" },
    { "gv", loaded(function(i) require("tracker.ui.branch").verify(i, load) end),
      desc = "hand over for verification: merge (git.verify.merge), status, unassign, comment draft" },
    { "gp", loaded(function(i)
        if i.parent then M.open(i.parent.key) end
      end), desc = "open parent / epic" },
    { { "<CR>", "l" }, function()
        local att = attachment_under_cursor()
        if att then return actions.open_attachment(att) end
        local s = current_section()
        if s and s.kind == "subtask" then return M.open(s.ref.key) end
        if s and s.kind == "link" then return M.open(s.ref.issue.key) end
        local k = view.key_under_cursor()
        if k and k ~= key then M.open(k) end
      end, desc = "open the attachment / sub-task / issue key under the cursor" },
    { "o", function() actions.web(key) end, desc = "open in browser" },
    { "gx", function()
        -- the attachment / URL of the line; the issue in the browser otherwise
        if not images.open_at_cursor(st.issue and st.issue.attachments) then actions.web(key) end
      end, desc = "open the attachment / link of the line (else the issue in the browser)" },
    { "y", function() actions.copy(key) end, desc = "copy key" },
    { "Y", loaded(function(i) actions.copy(i.url) end), desc = "copy URL" },
    { "r", load, desc = "refresh" },
  })

  -- Back from an editor (comment, edit, sub-task): show the result.
  v.on_return = load

  window.push(v)
  load()
end

return M
