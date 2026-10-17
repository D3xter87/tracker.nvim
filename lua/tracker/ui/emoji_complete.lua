-- `:` + two letters in the editor popup suggests emoji, like Jira's editor:
-- ":thu" → 👍 thumbsup … The pick goes in as the character (Atlassian's own
-- as `:check_mark:`) and is saved as a Jira emoji. Through nvim-cmp when it
-- is installed (source "tracker_emoji", only in the tracker's popups),
-- else <C-x><C-u> (completefunc).

local M = {}

local emoji = require("tracker.emoji")

local MIN = 2 -- letters after the colon before suggesting

---Everything to offer: { word, label, filter (":name"), key (for recents) }.
local items_cache
local function all_items()
  if items_cache then return items_cache end
  items_cache = {}
  for name, glyph in pairs(emoji.ATLASSIAN) do
    table.insert(items_cache, {
      word = ":" .. name .. ":", label = glyph .. " " .. name .. "  (Atlassian)", filter = ":" .. name,
      key = ":" .. name .. ":", name = name,
    })
  end
  for _, e in ipairs(emoji.list()) do
    for _, name in ipairs(e.names) do
      table.insert(items_cache, { word = e.glyph, label = e.glyph .. " " .. name, filter = ":" .. name, key = e.glyph, name = name })
    end
  end
  return items_cache
end

---The `:word` being typed before the cursor: start column (0-based) and
---the word, or nil (not after a letter / digit, so 10:30 doesn't count).
---@param before string  the line up to the cursor
local function typed(before)
  local start, word = before:match("()(:[%w_+%-]*)$")
  if not start then return nil end
  if start > 1 and before:sub(start - 1, start - 1):match("[%w:]") then return nil end
  return start - 1, word
end

---Matches for `word` (":thu"): names starting with it first, then names
---containing it; recently picked ones ahead within each.
---@return table[]
function M.matches(word)
  local q = word:sub(2):lower()
  local rank = {}
  for n, k in ipairs(emoji.recent()) do rank[k] = n end
  local starts, contains = {}, {}
  for _, it in ipairs(all_items()) do
    if it.name:sub(1, #q) == q then
      table.insert(starts, it)
    elseif #q >= MIN and it.name:find(q, 1, true) then
      table.insert(contains, it)
    end
  end
  local function by_recent(a, b)
    local ra, rb = rank[a.key] or math.huge, rank[b.key] or math.huge
    if ra ~= rb then return ra < rb end
    if #a.name ~= #b.name then return #a.name < #b.name end
    return a.name < b.name
  end
  table.sort(starts, by_recent)
  table.sort(contains, by_recent)
  -- each emoji once, under its best-matching name (👍 thumbsup, not also thumbs_up)
  local seen, out = {}, {}
  for _, it in ipairs(vim.list_extend(starts, contains)) do
    if not seen[it.key] then
      seen[it.key] = true
      table.insert(out, it)
    end
  end
  return out
end

-- region nvim-cmp source

local source = {}

function source.new() return setmetatable({}, { __index = source }) end

function source:is_available() return vim.bo.filetype == "tracker_edit" end

function source:get_debug_name() return "tracker_emoji" end

function source:get_trigger_characters() return { ":" } end

-- the colon is part of the word, so ":thu" is replaced as a whole
function source:get_keyword_pattern() return [[\%(^\|[^[:alnum:]:]\)\zs:[[:alnum:]_+-]*]] end

function source:complete(params, callback)
  local _, word = typed(params.context.cursor_before_line)
  if not word or #word < MIN + 1 then return callback({ items = {}, isIncomplete = true }) end
  local items = {}
  for n, it in ipairs(M.matches(word)) do
    table.insert(items, {
      label = it.label, filterText = it.filter, insertText = it.word,
      sortText = ("%05d"):format(n), data = { key = it.key },
    })
  end
  callback({ items = items, isIncomplete = true })
end

function source:execute(item, callback)
  if item.data and item.data.key then emoji.used(item.data.key) end
  callback(item)
end

local registered = false

---Offer emoji in the popup's buffer `buf` (call with it current): the
---source is added in front of the buffer's usual nvim-cmp sources.
function M.attach(buf)
  vim.bo[buf].completefunc = "v:lua.require'tracker.ui.emoji_complete'.completefunc"
  local ok, cmp = pcall(require, "cmp")
  if not ok then return end
  if not registered then
    cmp.register_source("tracker_emoji", source.new())
    registered = true
  end
  local sources = vim.deepcopy(cmp.get_config().sources or {})
  -- in the group of the user's last source (buffer / path); their grouping stays
  table.insert(sources, 1, { name = "tracker_emoji", group_index = sources[#sources] and sources[#sources].group_index or nil })
  pcall(cmp.setup.buffer, { sources = sources })
end

-- endregion

---<C-x><C-u> without nvim-cmp.
function M.completefunc(findstart, base)
  if findstart == 1 then
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local start = typed(vim.api.nvim_get_current_line():sub(1, col))
    return start or -3
  end
  local out = {}
  for _, it in ipairs(M.matches(base)) do
    table.insert(out, { word = it.word, abbr = it.label, user_data = it.key })
  end
  return out
end

return M
