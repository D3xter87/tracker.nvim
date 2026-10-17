-- Issue type / priority icons and Jira's epic colours.
--
-- Glyphs are Nerd Font (Font Awesome range), written as \u{} escapes: they
-- live in the Private Use Area, which plenty of tooling strips when it
-- rewrites a file; the escape can't be lost.
--
-- A type's look comes from its kind (epic, story, task, subtask, bug, test,
-- experiment, retro): English keywords in its name, then its hierarchy level.
-- Trackers localize type names, so `ui.icons.keywords` adds the words of
-- another language (or of a site's own types), and `ui.icons.types` sets the
-- icon of one type outright.

local M = {}

local config = require("tracker.config")

M.glyph = {
  epic = "\u{f0e7}",      -- nf-fa-bolt
  story = "\u{f02e}",     -- nf-fa-bookmark
  task = "\u{f14a}",      -- nf-fa-check_square
  subtask = "\u{f0c5}",   -- nf-fa-files_o
  bug = "\u{f188}",       -- nf-fa-bug
  test = "\u{f058}",      -- nf-fa-check_circle
  experiment = "\u{f0c3}",-- nf-fa-flask
  retro = "\u{f1da}",     -- nf-fa-history
  other = "\u{f111}",     -- nf-fa-circle
  fold_open = "\u{f0d7}", -- nf-fa-caret_down
  fold_closed = "\u{f0da}", -- nf-fa-caret_right
  user = "\u{f007}",      -- nf-fa-user
  blocked = "\u{f05e}",   -- nf-fa-ban: an open "is blocked by" link
  points = "\u{f069}",    -- nf-fa-asterisk
}

-- Jira's own icon colours.
local TYPE_COLOR = {
  epic = "#904ee2", story = "#63ba3c", task = "#4bade8", subtask = "#4bade8",
  bug = "#e5493a", test = "#22a06b", experiment = "#e2b203", retro = "#8590a2", other = "#8590a2",
}

-- Keyword → kind, checked in order against the lower-cased type name, after
-- the user's `ui.icons.keywords`.
local KEYWORDS = {
  { "epi", "epic" },
  { "sub", "subtask" },
  { "bug", "bug" }, { "defect", "bug" },
  { "story", "story" },
  { "test", "test" }, { "verif", "test" }, { "qa", "test" },
  { "experim", "experiment" }, { "spike", "experiment" },
  { "retro", "retro" },
  { "task", "task" },
}

---The kind a keyword list gives a type name, nil when none of them is in it.
---@param name string  lower-cased type name
---@param keywords table[]|nil  { keyword, kind } pairs
---@param level integer
---@return string|nil
local function by_keyword(name, keywords, level)
  for _, kw in ipairs(keywords or {}) do
    local word, kind = kw[1], kw[2]
    if type(word) == "string" and type(kind) == "string" and name:find(vim.fn.tolower(word), 1, true) then
      -- a sub-task kind wins for sub-task levels ("Verification bug" may be
      -- a sub-task type: it keeps the bug look but nothing else)
      if level < 0 and kind ~= "bug" then return "subtask" end
      return kind
    end
  end
end

---@param t TrackerIssueType|nil
---@return string kind
function M.kind(t)
  if not t then return "other" end
  -- tolower(), not :lower(): type names needn't be ascii
  local name = vim.fn.tolower(t.name or "")
  local level = t.level or 0
  local kind = by_keyword(name, (config.get().ui.icons or {}).keywords, level) or by_keyword(name, KEYWORDS, level)
  if kind then return kind end
  if level >= 1 then return "epic" end
  if level < 0 or t.subtask then return "subtask" end
  return "task"
end

---Icon + highlight group for an issue type.
---@param t TrackerIssueType|nil
---@return string icon, string hl
function M.type(t)
  local user = (config.get().ui.icons or {}).types or {}
  local override = t and (user[vim.fn.tolower(t.name or "")] or user[(t.name or ""):lower()])
  if override then return override[1], override[2] or "TrackerTypeOther" end
  local kind = M.kind(t)
  return M.glyph[kind] or M.glyph.other, "TrackerType_" .. kind
end

-- Priority by id (default scheme: 1 Highest … 5 Lowest), name as fallback.
local PRIORITY = {
  ["1"] = { "\u{f102}", "#e5493a" }, -- nf-fa-angle_double_up
  ["2"] = { "\u{f106}", "#e97f33" }, -- nf-fa-angle_up
  ["3"] = { "\u{f068}", "#e2b203" }, -- nf-fa-minus
  ["4"] = { "\u{f107}", "#4bade8" }, -- nf-fa-angle_down
  ["5"] = { "\u{f103}", "#8590a2" }, -- nf-fa-angle_double_down
}
local PRIORITY_BY_NAME = { highest = "1", high = "2", medium = "3", low = "4", lowest = "5" }

---@param issue TrackerIssue
---@return string icon, string hl
function M.priority(issue)
  local id = issue.priority_id
  if not PRIORITY[id or ""] then id = PRIORITY_BY_NAME[(issue.priority or ""):lower()] end
  if not id or not PRIORITY[id] then return " ", "TrackerMuted" end
  return PRIORITY[id][1], "TrackerPriority" .. id
end

-- Jira Cloud's epic palette (ghx-label-N / color_N), per Atlassian's
-- "Use epic color for epics in Jira Cloud" support article.
M.EPIC_COLORS = {
  "#243859", "#fa9920", "#fac304", "#2a53cc", "#2aa3bf", "#58d8a4", "#8677d9",
  "#5244aa", "#fa7353", "#3884ff", "#34c7e6", "#6b778c", "#128759", "#dd350d",
}

local function luminance(hex)
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255
end

---Highlight group for an epic chip: background = the epic's colour, text
---dark or white for contrast. nil colour → a neutral chip.
---@param index integer|nil
---@return string hl
function M.epic_hl(index)
  local palette = (config.get().ui.icons or {}).epic_colors or M.EPIC_COLORS
  local hex = index and palette[index]
  if not hex then return "TrackerEpic" end
  local name = "TrackerEpic" .. hex:sub(2)
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = name })) then
    vim.api.nvim_set_hl(0, name, { bg = hex, fg = luminance(hex) > 0.6 and "#172b4d" or "#ffffff", bold = true })
  end
  return name
end

---Foreground-only epic colour (timeline bars, the "●" before an epic key).
---@param index integer|nil
---@return string
function M.epic_fg_hl(index)
  local palette = (config.get().ui.icons or {}).epic_colors or M.EPIC_COLORS
  local hex = index and palette[index]
  if not hex then return "TrackerKey" end
  local name = "TrackerEpicFg" .. hex:sub(2)
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = name })) then
    vim.api.nvim_set_hl(0, name, { fg = hex })
  end
  return name
end

---Define the type / priority groups (called from highlights.setup).
function M.setup_highlights()
  for kind, color in pairs(TYPE_COLOR) do
    vim.api.nvim_set_hl(0, "TrackerType_" .. kind, { fg = color, default = true })
  end
  for id, p in pairs(PRIORITY) do
    vim.api.nvim_set_hl(0, "TrackerPriority" .. id, { fg = p[2], default = true })
  end
  vim.api.nvim_set_hl(0, "TrackerEpic", { link = "Visual", default = true })
end

return M
