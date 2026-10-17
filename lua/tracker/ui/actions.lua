-- Interactive flows shared by every view: pickers / editors in front of the
-- API calls. `done` callbacks let the calling view refresh itself.

local M = {}

local api = require("tracker.api")
local notify = require("tracker.notify")
local editor = require("tracker.ui.editor")
local drafts = require("tracker.ui.drafts")

local WARN = vim.log.levels.WARN

---Ask before editing text whose native form has parts Markdown can't carry.
---@param lossy string[]|nil
---@param what string
---@param fn fun()
local function confirm_lossy(lossy, what, fn)
  if not lossy or #lossy == 0 then return fn() end
  vim.ui.select({ "Edit anyway", "Cancel" }, {
    prompt = ("%s contains %s — saving from Markdown drops them"):format(what, table.concat(lossy, ", ")),
  }, function(choice)
    if choice == "Edit anyway" then fn() end
  end)
end

function M.transition(key, done)
  api.transitions(key, function(list, err)
    if not list then return notify.error(err) end
    if #list == 0 then return notify.send("actions", key .. ": no transitions available", WARN) end
    vim.ui.select(list, {
      prompt = key .. " status",
      format_item = function(t)
        if t.to and t.to.name ~= t.name then return t.name .. "  →  " .. t.to.name end
        return t.name
      end,
    }, function(choice)
      if not choice then return end
      api.transition(key, choice.id, function(t, terr)
        if not t then return notify.error(terr) end
        notify.send("actions", ("%s → %s"):format(key, t.to and t.to.name or t.name))
        if done then done() end
      end)
    end)
  end)
end

---Move `key` into a board column: the first transition whose target status
---is one of the column's statuses.
---@param column TrackerColumn
function M.move_to_column(key, column, done)
  local wanted = {}
  for _, id in ipairs(column.statuses) do wanted[id] = true end
  api.transitions(key, function(list, err)
    if not list then return notify.error(err) end
    for _, t in ipairs(list) do
      if t.to and t.to.id and wanted[t.to.id] then
        api.transition(key, t.id, function(ok, terr)
          if not ok then return notify.error(terr) end
          notify.send("actions", ("%s → %s"):format(key, t.to.name))
          if done then done() end
        end)
        return
      end
    end
    notify.send("actions", ("%s: no transition into column %q from its current status"):format(key, column.name), WARN)
  end)
end

local function assigned(key, done)
  return function(a, err)
    if a == nil then return notify.error(err) end
    notify.send("actions", ("%s → %s"):format(key, a and a.name or "unassigned"))
    if done then done() end
  end
end

function M.assign(key, done)
  api.assignable_users(key, nil, function(users, err)
    if not users then return notify.error(err) end
    local items = { { label = "Assign to me", value = "me" }, { label = "Unassigned", value = false } }
    for _, u in ipairs(users) do
      table.insert(items, { label = u.name .. (u.email and (" <" .. u.email .. ">") or ""), value = u })
    end
    vim.ui.select(items, {
      prompt = key .. " assignee",
      format_item = function(i) return i.label end,
    }, function(choice)
      if not choice then return end
      api.assign(key, choice.value or nil, assigned(key, done))
    end)
  end)
end

function M.assign_me(key, done)
  api.assign(key, "me", assigned(key, done))
end

---Toggle: assigned to me → unassign, otherwise → assign to me.
---@param issue TrackerIssue  needs `key` and `assignee`
function M.toggle_me(issue, done)
  api.myself(function(me, err)
    if not me then return notify.error(err) end
    if issue.assignee and issue.assignee.id == me.id then
      api.assign(issue.key, nil, assigned(issue.key, done))
    else
      api.assign(issue.key, me, assigned(issue.key, done))
    end
  end)
end

---Closed without submitting, the text stays as the issue's comment draft;
---a reply appends its quote to it.
---@param initial string|nil  prefilled text (reply quote)
---@param keep boolean|nil  `initial` stays as the draft even when closed untouched
function M.comment(key, done, initial, keep)
  local dkey = "comment:" .. key
  local draft = drafts.get(dkey)
  local text = draft and initial and (draft .. "\n\n" .. initial) or draft or initial or ""
  editor.open({
    title = " Comment " .. key .. (draft and " (draft) " or " "),
    text = text,
    cursor_end = true,
    on_close = drafts.keeper(dkey, "", keep and (draft or "") or text),
    on_submit = function(body, finish)
      api.comment(key, body, function(c, err)
        if not c then
          notify.error(err)
          return finish(false)
        end
        notify.send("actions", key .. ": comment added")
        drafts.clear(dkey)
        finish(true)
        if done then done() end
      end)
    end,
  })
end

---Reply = quote + mention of the author (so they get notified).
---@param comment TrackerComment
function M.reply(key, comment, done)
  local lines = {}
  local author = comment.author and comment.author.name or "?"
  table.insert(lines, "> **" .. author .. "** wrote:")
  for _, l in ipairs(vim.split(comment.body, "\n", { plain = true })) do
    table.insert(lines, l == "" and ">" or ("> " .. l))
  end
  table.insert(lines, "")
  local mention = comment.author and ("[@%s](mention:%s) "):format(author, comment.author.id) or ""
  table.insert(lines, mention)
  M.comment(key, done, table.concat(lines, "\n"))
end

---@param comment TrackerComment
---@param attachments TrackerAttachment[]|nil  the issue's (gx on images)
function M.edit_comment(key, comment, done, attachments)
  confirm_lossy(comment.lossy, "This comment", function()
    local dkey = ("comment:%s:%s"):format(key, comment.id)
    local draft = drafts.get(dkey)
    local text = draft or comment.body
    editor.open({
      title = " Edit comment on " .. key .. (draft and " (draft) " or " "),
      text = text,
      attachments = attachments,
      on_close = drafts.keeper(dkey, comment.body, text),
      on_submit = function(body, finish)
        api.edit_comment(key, comment.id, body, function(c, err)
          if not c then
            notify.error(err)
            return finish(false)
          end
          notify.send("actions", key .. ": comment updated")
          drafts.clear(dkey)
          finish(true)
          if done then done() end
        end)
      end,
    })
  end)
end

---Delete a comment after a yes / no naming it (date + its first words).
---@param comment TrackerComment
function M.delete_comment(key, comment, done)
  local words = vim.trim((comment.body or ""):gsub("%s+", " "))
  if vim.fn.strchars(words) > 50 then words = vim.fn.strcharpart(words, 0, 50) .. "…" end
  local prompt = ("Delete your comment on %s from %s? “%s” — can't be undone"):format(
    key, require("tracker.model").short_time(comment.created), words)
  vim.ui.select({ "Delete", "Cancel" }, { prompt = prompt }, function(choice)
    if choice ~= "Delete" then return end
    api.delete_comment(key, comment.id, function(ok, err)
      if not ok then return notify.error(err) end
      notify.send("actions", key .. ": comment deleted")
      if done then done() end
    end)
  end)
end

---Pick files (yazi / ui.file_chooser) and upload them to `key`.
function M.upload(key, done)
  require("tracker.util.files").choose(function(paths)
    notify.send("actions", ("%s: uploading %d file(s)…"):format(key, #paths))
    api.upload(key, paths, function(atts, err)
      if not atts then return notify.error(err) end
      notify.send("actions", ("%s: attached %s"):format(key,
        table.concat(vim.tbl_map(function(a) return a.filename end, atts), ", ")))
      if done then done(atts) end
    end)
  end)
end

---Delete an attachment after a yes / no naming it.
---@param att TrackerAttachment
function M.delete_attachment(key, att, done)
  local prompt = ("Delete the attachment %s from %s? It can't be undone"):format(att.filename, key)
  vim.ui.select({ "Delete", "Cancel" }, { prompt = prompt }, function(choice)
    if choice ~= "Delete" then return end
    api.delete_attachment(key, att.id, function(ok, err)
      if not ok then return notify.error(err) end
      notify.send("actions", ("%s: %s deleted"):format(key, att.filename))
      if done then done() end
    end)
  end)
end

---Pick an issue to link to: issues seen this session, or "Search…" — a key
---goes straight through, other text searches the project.
---@param exclude string  the issue being linked
---@param cb fun(key: string)
local function pick_issue(exclude, cb)
  local pattern = require("tracker.config").get().issue_key_pattern
  local function search()
    vim.ui.input({ prompt = "Issue key or text: " }, function(text)
      text = text and vim.trim(text) or ""
      if text == "" then return end
      local key = text:upper():match("^" .. pattern .. "$")
      if key then return cb(key) end
      local info = api.provider_info() or {}
      local jql = ('%stext ~ "%s" ORDER BY updated DESC'):format(
        info.project and ("project = " .. info.project .. " AND ") or "", (text:gsub('[\\"]', "\\%0")))
      api.search(jql, function(issues, err)
        if not issues then return notify.error(err) end
        issues = vim.tbl_filter(function(i) return i.key ~= exclude end, issues)
        if #issues == 0 then return notify.send("actions", "no issue matches “" .. text .. "”", WARN) end
        vim.ui.select(issues, {
          prompt = "Link to",
          format_item = function(i) return i.key .. "  " .. i.summary end,
        }, function(i)
          if i then cb(i.key) end
        end)
      end, { limit = 30 })
    end)
  end
  local recent = vim.tbl_filter(function(k) return k ~= exclude end, api.recent_keys())
  if #recent == 0 then return search() end
  local items = { { label = "Search (key or text)…", search = true } }
  for n = 1, math.min(#recent, 15) do table.insert(items, { label = recent[n], key = recent[n] }) end
  vim.ui.select(items, { prompt = "Link to", format_item = function(i) return i.label end }, function(item)
    if not item then return end
    if item.search then return search() end
    cb(item.key)
  end)
end

---Add a link from `issue`: the relation (both directions of every link
---type: "blocks", "is blocked by", …), then the other issue.
---@param issue TrackerIssue
function M.add_link(issue, done)
  api.link_types(function(types, err)
    if not types then return notify.error(err) end
    local items = {}
    for _, t in ipairs(types) do
      table.insert(items, { label = t.outward, type = t.name, direction = "outward" })
      if t.inward ~= t.outward then table.insert(items, { label = t.inward, type = t.name, direction = "inward" }) end
    end
    vim.ui.select(items, {
      prompt = issue.key .. " …",
      format_item = function(i) return i.label .. "  (" .. i.type .. ")" end,
    }, function(rel)
      if not rel then return end
      pick_issue(issue.key, function(other)
        api.link(issue.key, { type = rel.type, direction = rel.direction, key = other }, function(ok, lerr)
          if not ok then return notify.error(lerr) end
          notify.send("actions", ("%s %s %s"):format(issue.key, rel.label, other))
          if done then done() end
        end)
      end)
    end)
  end)
end

---Remove a link after a yes / no that names it.
---@param link TrackerLink
function M.remove_link(key, link, done)
  local prompt = ("Remove the link: %s %s %s?"):format(key, link.label, link.issue.key)
  vim.ui.select({ "Remove", "Cancel" }, { prompt = prompt }, function(choice)
    if choice ~= "Remove" then return end
    api.unlink(key, link.id, function(ok, err)
      if not ok then return notify.error(err) end
      notify.send("actions", ("%s: link to %s removed"):format(key, link.issue.key))
      if done then done() end
    end)
  end)
end

---Clone an issue: a popup with "CLONE - <summary>" to adjust, then the
---clone (fields, description, sub-tasks, a "clones" link) is created.
---@param issue TrackerIssue|{ key: string, summary: string }
---@param done fun(res: { key: string })|nil  e.g. open the clone
function M.clone(issue, done)
  editor.open({
    title = (" Clone %s — the summary of the copy "):format(issue.key),
    text = "CLONE - " .. (issue.summary or ""),
    cursor_end = true,
    on_submit = function(text, finish)
      local summary = editor.split_summary(text)
      if summary == "" then
        notify.error("tracker: the summary is empty")
        return finish(false)
      end
      api.clone(issue.key, { summary = summary, link = true, subtasks = true }, function(res, err)
        if not res then
          notify.error(err)
          return finish(false)
        end
        finish(true)
        local msg = ("cloned %s → %s"):format(issue.key, res.key)
        if #res.subtasks > 0 then msg = msg .. (" with %d sub-task(s)"):format(#res.subtasks) end
        notify.send("actions", msg)
        if #res.dropped > 0 then
          notify.send("actions", ("%s: not copied (not on Jira's create screen): %s"):format(res.key,
            table.concat(res.dropped, ", ")), WARN)
        end
        if #res.failed > 0 then
          notify.error(("%s: sub-tasks not cloned: %s"):format(res.key, table.concat(res.failed, "; ")))
        end
        if done then done(res) end
      end)
    end,
  })
end

---Summary + description in one buffer: first line = summary.
---@param issue TrackerIssue  as returned by get_issue
---@param append string|nil  added below the description (or its draft)
function M.edit_issue(issue, done, append)
  confirm_lossy(issue.lossy, "The description", function()
    local dkey = "issue:" .. issue.key
    local draft = drafts.get(dkey)
    local pristine = issue.summary .. "\n\n" .. (issue.description or "")
    local text = draft or pristine
    if append then text = vim.trim(text) .. "\n\n" .. append end
    editor.open({
      title = " Edit " .. issue.key .. (draft and " (draft)" or "") .. " — first line is the summary ",
      large = true,
      attachments = issue.attachments,
      text = text,
      cursor_end = append ~= nil,
      -- measured against what was stored: closed as is, an appended text
      -- stays as the draft
      on_close = drafts.keeper(dkey, pristine, draft or pristine),
      on_submit = function(text, finish)
        local summary, description = editor.split_summary(text)
        if summary == "" then
          notify.error("tracker: the first line (summary) is empty")
          return finish(false)
        end
        local fields = {}
        if summary ~= issue.summary then fields.summary = summary end
        if description ~= vim.trim(issue.description or "") then fields.description = description end
        if vim.tbl_isempty(fields) then
          drafts.clear(dkey)
          return finish(true)
        end
        api.update(issue.key, fields, function(ok, err)
          if not ok then
            notify.error(err)
            return finish(false)
          end
          notify.send("actions", issue.key .. ": updated")
          drafts.clear(dkey)
          finish(true)
          if done then done() end
        end)
      end,
    })
  end)
end

---Create an issue (or a sub-task when `opts.parent` is a key).
---@param opts { project: string?, parent: string? }|nil
---@param done fun(issue: { id: string, key: string, url: string })|nil
function M.create(opts, done)
  opts = opts or {}
  local info = api.provider_info()
  local project = opts.project
    or (opts.parent and opts.parent:match("^(.-)%-%d+$"))
    or (info and info.project)

  local function with_project(p)
    api.issue_types(p, function(types, err)
      if not types then return notify.error(err) end
      local choices = vim.tbl_filter(function(t) return t.subtask == (opts.parent ~= nil) end, types)
      if #choices == 0 then return notify.error(("tracker: no %s issue types in %s"):format(opts.parent and "sub-task" or "standard", p)) end
      local function with_type(t)
        local where = opts.parent and ("under " .. opts.parent) or ("in " .. p)
        editor.open({
          title = (" New %s %s — first line is the summary "):format(t.name, where),
          large = true,
          text = "",
          cursor_end = true,
          on_submit = function(text, finish)
            local summary, description = editor.split_summary(text)
            if summary == "" then
              notify.error("tracker: the first line (summary) is empty")
              return finish(false)
            end
            api.create({ project = p, type_id = t.id, summary = summary, description = description, parent = opts.parent },
              function(issue, cerr)
                if not issue then
                  notify.error(cerr)
                  return finish(false)
                end
                notify.send("actions", "created " .. issue.key)
                if issue.warning then notify.send("actions", issue.key .. ": " .. issue.warning, WARN) end
                finish(true)
                if done then done(issue) end
              end)
          end,
        })
      end
      if #choices == 1 then return with_type(choices[1]) end
      vim.ui.select(choices, { prompt = "Issue type", format_item = function(t) return t.name end }, function(t)
        if t then with_type(t) end
      end)
    end)
  end

  if project then return with_project(project) end
  vim.ui.input({ prompt = "Project key: " }, function(p)
    if p and vim.trim(p) ~= "" then with_project(vim.trim(p):upper()) end
  end)
end

function M.web(key)
  local url = api.web_url(key)
  if not url then return notify.error("tracker: no provider configured") end
  if not require("tracker.util.browser").open(url) then
    notify.error("tracker: could not open " .. url)
  end
end

---Download (once, cached) and open with the system viewer.
---@param att TrackerAttachment|{ url: string }
function M.open_attachment(att)
  notify.send("actions", "opening " .. (att.filename or att.url or "attachment") .. "…")
  api.attachment_path(att, function(path, err)
    if not path then return notify.error(err) end
    local ok, oerr = pcall(vim.ui.open, path)
    if not ok then notify.error("tracker: could not open " .. path .. ": " .. tostring(oerr)) end
  end)
end

---@param text string
function M.copy(text)
  if not text then return end
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  notify.send("actions", "copied " .. text)
end

return M
