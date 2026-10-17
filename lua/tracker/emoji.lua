-- Emoji: names ↔ characters, and the attrs of a Jira emoji node — what
-- Jira's editor inserts (shortName / id / text), so an emoji typed here is
-- the same thing in Jira as one picked there.
--
--   Unicode:   { shortName = ":smile:", id = "1f604", text = "😄" }
--   Atlassian: { shortName = ":check_mark:", id = "atlassian-check_mark", text = ":check_mark:" }

local M = {}

-- Atlassian's own emoji and the Unicode look-alike shown for each.
M.ATLASSIAN = {
  check_mark = "✅", cross_mark = "❌", question_mark = "❓", warning = "⚠️",
  info = "ℹ️", plus = "➕", minus = "➖", light_bulb_on = "💡", light_bulb_off = "💡",
  error = "⛔", tick = "✔️", thumbs_up = "👍", thumbs_down = "👎",
}

local VS16 = "\239\184\143" -- U+FE0F, the "show as emoji" selector

local data ---@type { glyph: string, names: string[] }[]|nil
local by_glyph, by_name, lengths

local function load()
  if data then return end
  data, by_glyph, by_name = {}, {}, {}
  local seen_len = {}
  for _, e in ipairs(require("tracker.data.emoji")) do
    local entry = { glyph = e[1], names = vim.list_slice(e, 2) }
    table.insert(data, entry)
    -- with and without the selector: "⚠️" and "⚠" are the same emoji
    for _, g in ipairs({ entry.glyph, (entry.glyph:gsub(VS16 .. "$", "")) }) do
      -- only characters from the symbol / emoji planes count when spotted in
      -- text (©, ®, keycaps like 1️⃣ stay text)
      if g:byte(1) >= 0xE2 and not by_glyph[g] then
        by_glyph[g] = entry
        seen_len[#g] = true
      end
    end
    for _, n in ipairs(entry.names) do by_name[n] = by_name[n] or entry end
  end
  lengths = vim.tbl_keys(seen_len)
  table.sort(lengths, function(a, b) return a > b end)
end

---All emoji, in gemoji's order: { glyph, names }.
function M.list()
  load()
  return data
end

---The emoji character at byte `i` of `s` (longest match: "👮‍♂️" over "👮"),
---or nil.
---@return string|nil
function M.at(s, i)
  if s:byte(i) < 0xE2 then return nil end
  load()
  for _, len in ipairs(lengths) do
    local g = s:sub(i, i + len - 1)
    if #g == len and by_glyph[g] then
      -- keep a trailing selector with the character
      if s:sub(i + len, i + len + 2) == VS16 and not g:find(VS16 .. "$") then g = g .. VS16 end
      return g
    end
  end
  return nil
end

---Jira's id of a Unicode emoji: its code points in hex, "-" joined; a lone
---selector after a single character is dropped ("⚠️" → "26a0",
---"👮‍♂️" → "1f46e-200d-2642-fe0f").
function M.hex_id(glyph)
  local cps = vim.fn.str2list(glyph)
  if #cps == 2 and cps[2] == 0xFE0F then cps = { cps[1] } end
  return table.concat(vim.tbl_map(function(c) return ("%x"):format(c) end, cps), "-")
end

---Emoji node attrs for a character typed / picked here.
---@return table|nil
function M.attrs(glyph)
  load()
  local e = by_glyph[glyph] or by_glyph[(glyph:gsub(VS16 .. "$", ""))]
  if not e then return nil end
  return { shortName = ":" .. e.names[1] .. ":", id = M.hex_id(glyph), text = glyph }
end

---Emoji node attrs for a typed `:name:` — Atlassian's own first (as Jira
---does: :cross_mark: is Atlassian's), then the Unicode names.
---@param name string  without colons
---@return table|nil
function M.attrs_by_name(name)
  if M.ATLASSIAN[name] then
    return { shortName = ":" .. name .. ":", id = "atlassian-" .. name, text = ":" .. name .. ":" }
  end
  load()
  local e = by_name[name]
  if not e then return nil end
  return { shortName = ":" .. name .. ":", id = M.hex_id(e.glyph), text = e.glyph }
end

-- region Recently used (completion order)

local RECENT_MAX = 30
local recent ---@type string[]|nil  keys: a glyph, or ":name:" for Atlassian ones

-- M.recent_file: tests point it elsewhere (then call M.recent_reset())
local function recent_path() return M.recent_file or (vim.fn.stdpath("data") .. "/tracker/emoji_recent.json") end

function M.recent_reset() recent = nil end

---@return string[]
function M.recent()
  if recent then return recent end
  recent = {}
  local ok, lines = pcall(vim.fn.readfile, recent_path())
  if ok and #lines > 0 then
    local dok, list = pcall(vim.json.decode, table.concat(lines, "\n"))
    if dok and type(list) == "table" then recent = list end
  end
  return recent
end

---Remember `key` as the newest pick.
function M.used(key)
  local list = vim.tbl_filter(function(k) return k ~= key end, M.recent())
  table.insert(list, 1, key)
  recent = vim.list_slice(list, 1, RECENT_MAX)
  pcall(vim.fn.mkdir, vim.fs.dirname(recent_path()), "p")
  pcall(vim.fn.writefile, { vim.json.encode(recent) }, recent_path())
end

-- endregion

return M
