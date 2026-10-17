-- Sprint form: the editor popup holding a small form.
--
--   Name:     #61
--   Start:    2026-11-02 13:00
--   Duration: 3w
--   End:      2026-11-23 13:00
--   Goal:
--   1. …  (every line from here on, as many as needed)
--
-- End follows Start + Duration as you type (1w … 4w, 10d, …); typing an End
-- by hand turns Duration into "custom" (or the matching "2w"), like Jira's
-- start-sprint dialog. Dates are local time. <C-s> / <CR> saves.

local M = {}

local date = require("tracker.util.date")

local FIELDS = { "Name", "Start", "Duration", "End", "Goal" }
local HINT = "<C-s>/<CR>: save  Duration: 1w 2w 3w 4w 10d custom  <Esc>/q: cancel"

local function label(name) return (name .. ":" .. string.rep(" ", 10)):sub(1, 10) end

---@class TrackerSprintDraft
---@field name string
---@field goal string|nil
---@field start integer|nil     epoch
---@field duration string|nil   "2w" | "10d" | "custom"
---@field finish integer|nil    epoch (end)

---Form text for a draft.
---@param d TrackerSprintDraft
---@return string
function M.text(d)
  local lines = {
    label("Name") .. (d.name or ""),
    label("Start") .. date.format(d.start),
    label("Duration") .. (d.duration or "custom"),
    label("End") .. date.format(d.finish),
    "Goal:",
  }
  for _, l in ipairs(vim.split(d.goal or "", "\n", { plain = true })) do table.insert(lines, l) end
  return table.concat(lines, "\n")
end

---Raw field values of the form (Goal = everything after its label).
---@param lines string[]
---@return table<string, string>
local function read(lines)
  local out, goal = {}, nil
  for _, l in ipairs(lines) do
    if goal then
      table.insert(goal, l)
    else
      local name, value = l:match("^(%a+):%s*(.-)%s*$")
      if name == "Goal" then
        goal = { value }
      elseif name and vim.tbl_contains(FIELDS, name) then
        out[name] = value
      end
    end
  end
  goal = goal or {}
  while #goal > 0 and goal[1]:match("^%s*$") do table.remove(goal, 1) end
  while #goal > 0 and goal[#goal]:match("^%s*$") do table.remove(goal) end
  out.Goal = table.concat(goal, "\n")
  return out
end

---Form text → sprint fields.
---@param text string
---@param require_dates boolean|nil  starting a sprint: both dates needed
---@return TrackerSprintFields|nil, string|nil err
function M.parse(text, require_dates)
  local f = read(vim.split(text, "\n", { plain = true }))
  local fields = { name = f.Name or "", goal = f.Goal }
  if fields.name == "" then return nil, "Name is empty" end
  if (f.Start or "") == "" then
    if require_dates then return nil, "Start is empty — a sprint needs dates to start" end
    fields.start_date, fields.end_date = false, false
    return fields
  end
  local s = date.parse(f.Start)
  if not s then return nil, "Start: use YYYY-MM-DD HH:MM" end
  local e
  if (f.End or "") ~= "" then
    e = date.parse(f.End)
    if not e then return nil, "End: use YYYY-MM-DD HH:MM" end
  else
    local days = date.parse_duration(f.Duration)
    if not days then return nil, "End is empty and Duration isn't 1w / 10d / …" end
    e = date.add_days(s, days)
  end
  if e <= s then return nil, "End must be after Start" end
  fields.start_date, fields.end_date = date.to_iso(s), date.to_iso(e)
  return fields
end

---Keep End / Duration in step while typing.
local function follow(buf)
  local function get() return read(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) end
  local function set(name, value)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local cur = l:match("^" .. name .. ":%s*(.-)%s*$")
      if cur then
        if cur ~= value then vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { label(name) .. value }) end
        return
      end
    end
  end
  local last = get()
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      local cur = get()
      if cur.Start ~= last.Start or cur.Duration ~= last.Duration then
        local s, days = date.parse(cur.Start), date.parse_duration(cur.Duration)
        if s and days then set("End", date.format(date.add_days(s, days))) end
      elseif cur.End ~= last.End then
        local s, e = date.parse(cur.Start), date.parse(cur.End)
        if s and e then
          local dur = date.duration_of(s, e)
          if date.parse_duration(cur.Duration) ~= date.parse_duration(dur) or dur == "custom" then
            set("Duration", dur)
          end
        end
      end
      last = get()
    end,
  })
end

---@param opts { title: string, draft: TrackerSprintDraft, require_dates: boolean? }
---@param on_submit fun(fields: TrackerSprintFields, finish: fun(ok: boolean))
---@return integer buf, integer win
function M.open(opts, on_submit)
  local buf, win = require("tracker.ui.editor").open({
    title = opts.title,
    text = M.text(opts.draft),
    hint = HINT,
    on_submit = function(text, finish)
      local fields, err = M.parse(text, opts.require_dates)
      if not fields then
        require("tracker.notify").error("sprint: " .. err)
        return finish(false)
      end
      on_submit(fields, finish)
    end,
  })
  vim.wo[win].wrap = false
  vim.fn.matchadd("TrackerKey", [[^\(Name\|Start\|Duration\|End\|Goal\):]], 10, -1, { window = win })
  -- cursor on the name's value
  pcall(vim.api.nvim_win_set_cursor, win, { 1, #label("Name") })
  follow(buf)
  return buf, win
end

return M
