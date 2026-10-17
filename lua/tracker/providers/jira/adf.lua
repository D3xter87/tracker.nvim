-- Atlassian Document Format ↔ Markdown.
--
-- Jira Cloud (REST v3) stores descriptions and comments as ADF, a JSON tree.
-- The UI works in Markdown, so this module converts both ways.
--
-- Round-trip safe (Markdown → ADF gives the same structure back):
--   paragraph, text, hardBreak, heading, bulletList, orderedList, listItem,
--   taskList/taskItem, codeBlock, blockquote, rule, table, mention, emoji,
--   inlineCard; marks strong, em, code, strike, link. With a stash (below)
--   also media / macros, table layout and emoji / mention attributes.
-- Everything else (panels, expand, status lozenges, dates, colors,
-- underline, ...) renders as readable text but would NOT survive an edit.
-- `M.lossy(doc)` lists those, so an editor can warn before overwriting.
--
-- Verified against real Jira Cloud content: of ~220 descriptions/comments
-- without such elements, all but one come back identical (the rest differ
-- only in whitespace hugging bold text, which Markdown can't express).
--
-- Markdown dialect, chosen so `from_markdown(to_markdown(x))` is stable:
--   mention       [@Name](mention:<accountId>)
--   emoji         :shortName:
--   smart link    <https://...>
--   task item     - [ ] text  /  - [x] text
--   hard break    a line break inside a paragraph (no blank line); an empty
--                 line inside a paragraph is a lone `\`
--   table cell    `<br>` line break, `<p>` paragraph break
--   media/macro   [attachment: name](adf:N) on its own line (needs the stash)
--   escapes       a backslash only before syntax characters, and only where
--                 needed — `\\server\share` stays as is

local M = {}

-- region ADF → Markdown

local LOSSLESS_NODES = {
  doc = true, paragraph = true, text = true, hardBreak = true, heading = true,
  bulletList = true, orderedList = true, listItem = true, taskList = true,
  taskItem = true, codeBlock = true, blockquote = true, rule = true,
  table = true, tableRow = true, tableHeader = true, tableCell = true,
  mention = true, emoji = true, inlineCard = true, panel = true,
}

-- Jira panels ↔ Obsidian / GitHub callouts (render-markdown draws both):
--   > [!INFO]
--   > text, lists, code blocks …
local PANEL_TYPES = { info = true, note = true, success = true, warning = true, error = true, custom = true }

-- Atlassian's own emoji carry `:name:` as their text, not a character; show
-- the nearest Unicode one (the original node comes back from the stash).
local emoji = require("tracker.emoji")
local ATLASSIAN_EMOJI = emoji.ATLASSIAN

local LOSSLESS_MARKS = { strong = true, em = true, code = true, strike = true, link = true }

-- Block nodes Markdown can't express but an edit must not lose (images and
-- attachments, macros). With a stash table, `to_markdown` renders each as a
-- placeholder line `[attachment: shot.png](adf:1)` and stores the node;
-- `from_markdown` with the same stash puts the node back where the line is.
-- Delete the line to delete the node. Not inside table cells: a cell is one
-- Markdown line, so there they stay lossy.
local PRESERVED = { mediaSingle = true, mediaGroup = true, extension = true, bodiedExtension = true }
local PLACEHOLDER = "^%s*%[([^%]]*)%]%(adf:(%d+)%)%s*$"

-- Stash of the running to_markdown / from_markdown call (both synchronous).
-- Array part: PRESERVED nodes. `.emoji[shortName]` = emoji attrs.
-- `.emoji_seq[char]` = per occurrence of that character: emoji attrs or
-- false (plain text). `.tables[n]` = { attrs, cells[r][c] = { type, attrs } },
-- `.panels[n]` / `.codes[n]` = attrs of the n-th panel / code block.
local stash_out, stash_in
local tables_in, panels_in, codes_in -- tables / panels / code blocks parsed so far in the running from_markdown
local glyph_pos -- per emoji character: occurrences seen so far in the running from_markdown

-- Prefix of an emoji node's character in the raw to_markdown output; removed
-- by mark_glyphs, which records per character which occurrences are emoji.
local EMOJI_MARK = "\1"

---Longest emoji character at byte `i` of `s`: a stashed one (`chars`,
---sorted longest first) or any known emoji (tracker.emoji), whichever is
---longer ("👮‍♂️" over "👮").
---@param chars string[]|nil
local function glyph_match(s, i, chars)
  local stashed
  for _, g in ipairs(chars or {}) do
    if s:sub(i, i + #g - 1) == g then
      stashed = g
      break
    end
  end
  local known = emoji.at(s, i)
  if known and #known > #(stashed or "") then return known end
  return stashed
end

local function sorted_glyphs(set)
  local out = vim.tbl_keys(set)
  table.sort(out, function(a, b) return #a > #b end)
  return out
end

---Strip the emoji marks from `md` and record, for every character an emoji
---used, the sequence of its occurrences: the emoji's attrs, or false where
---the same character is plain text. `stash.emoji_seq[char] = { attrs|false… }`.
local function mark_glyphs(md, stash)
  -- Every emoji character is recorded, not only the stashed ones: one
  -- typed as text in Jira stays text on save, while a new one (not in the
  -- record) becomes an emoji node.
  local chars = stash.emoji_glyphs and sorted_glyphs(stash.emoji_glyphs) or {}
  local seq, out, i, next_emoji = {}, {}, 1, 1
  while i <= #md do
    local c = md:sub(i, i)
    if c == EMOJI_MARK then
      local g = glyph_match(md, i + 1, chars)
      if g then
        seq[g] = seq[g] or {}
        table.insert(seq[g], stash.emoji_pending[next_emoji] or false)
        next_emoji = next_emoji + 1
        table.insert(out, g)
        i = i + 1 + #g
      else
        i = i + 1
      end
    else
      local g = c:byte() >= 0x80 and glyph_match(md, i, chars) or nil
      if g then
        seq[g] = seq[g] or {}
        table.insert(seq[g], false)
        table.insert(out, g)
        i = i + #g
      else
        table.insert(out, c)
        i = i + 1
      end
    end
  end
  stash.emoji_seq, stash.emoji_glyphs, stash.emoji_pending = seq, nil, nil
  return table.concat(out)
end

---Node and mark types in `doc` that the Markdown form cannot carry back.
---@param doc table|nil
---@param preserving boolean|nil  a stash is used, so PRESERVED blocks survive
---@return string[] sorted, unique
function M.lossy(doc, preserving)
  local seen = {}
  local function walk(node, in_cell)
    if type(node) ~= "table" then return end
    if preserving and not in_cell and PRESERVED[node.type] then return end
    if node.type and not LOSSLESS_NODES[node.type] then seen[node.type] = true end
    for _, mark in ipairs(node.marks or {}) do
      if not LOSSLESS_MARKS[mark.type] then seen[mark.type] = true end
    end
    local cell = in_cell or node.type == "tableCell" or node.type == "tableHeader"
    for _, child in ipairs(node.content or {}) do walk(child, cell) end
  end
  walk(doc, false)
  local out = vim.tbl_keys(seen)
  table.sort(out)
  return out
end

local function apply_marks(text, marks)
  if not marks or #marks == 0 or text == "" then return text end
  -- Keep surrounding whitespace outside the delimiters: "** bold**" is not
  -- bold in Markdown.
  local lead, core, trail = text:match("^(%s*)(.-)(%s*)$")
  if core == "" then return text end
  local href
  for _, m in ipairs(marks) do
    if m.type == "code" then
      local fence = core:find("`", 1, true) and "``" or "`"
      core = fence .. core .. fence
    elseif m.type == "strong" then
      core = "**" .. core .. "**"
    elseif m.type == "em" then
      core = "*" .. core .. "*"
    elseif m.type == "strike" then
      core = "~~" .. core .. "~~"
    elseif m.type == "link" then
      href = m.attrs and m.attrs.href
    end
  end
  if href then core = "[" .. core .. "](" .. href .. ")" end
  return lead .. core .. trail
end

local inline_md
local parse_inline -- Markdown → ADF, below; used here to check escaping

local function has_mark(marks, kind)
  for _, m in ipairs(marks or {}) do
    if m.type == kind then return true end
  end
  return false
end

---Escape inline syntax in plain text, but only when the parser would
---otherwise read it as markup — `a*b` and `x_y` stay as they are.
local function escape_inline(text)
  if text == "" or not text:find("[`*_~%[%]<:]") then return text end
  local probe = {}
  parse_inline(text, {}, probe)
  if #probe == 1 and probe[1].type == "text" and probe[1].text == text and not probe[1].marks then
    return text
  end
  return (text:gsub("([`*_~%[%]<:])", "\\%1"))
end

---@param node table
---@return string
local function inline_node(node)
  local t = node.type
  local a = node.attrs or {}
  if t == "text" then
    local text = node.text or ""
    if not has_mark(node.marks, "code") then text = escape_inline(text) end
    return apply_marks(text, node.marks)
  elseif t == "hardBreak" then
    return "\n"
  elseif t == "mention" then
    if stash_out and a.id then
      stash_out.mentions = stash_out.mentions or {}
      stash_out.mentions[a.id] = vim.deepcopy(a)
    end
    local name = (a.text or ""):gsub("^@", "")
    return ("[@%s](mention:%s)"):format(name, a.id or "")
  elseif t == "emoji" then
    -- Shown as the character (🙂, or ✅ for Atlassian's :check_mark:); the
    -- node's attrs ride in the stash under both the character and the
    -- `:shortName:`, so either form comes back as the same emoji.
    local short = a.shortName or ""
    local glyph = a.text
    if not glyph or glyph == "" or glyph:match("^:.*:$") then
      glyph = ATLASSIAN_EMOJI[short:gsub("^:", ""):gsub(":$", "")]
    end
    if stash_out then
      if short ~= "" then
        stash_out.emoji = stash_out.emoji or {}
        stash_out.emoji[short] = vim.deepcopy(a)
      end
      if glyph then
        -- Marked, so mark_glyphs can tell this ✅ from a ✅ typed as text;
        -- the attrs go in emission order (the same ❌ can be :x: or
        -- Atlassian's :cross_mark:).
        stash_out.emoji_glyphs = stash_out.emoji_glyphs or {}
        stash_out.emoji_glyphs[glyph] = true
        stash_out.emoji_pending = stash_out.emoji_pending or {}
        table.insert(stash_out.emoji_pending, vim.deepcopy(a))
        return EMOJI_MARK .. glyph
      end
    end
    return glyph or (short ~= "" and short) or ""
  elseif t == "inlineCard" then
    return "<" .. (a.url or "") .. ">"
  elseif t == "status" then
    return "[" .. (a.text or "") .. "]"
  elseif t == "date" then
    local ms = tonumber(a.timestamp)
    return ms and os.date("!%Y-%m-%d", math.floor(ms / 1000)) or ""
  elseif t == "mediaInline" then
    return "[attachment]"
  elseif node.content then
    return inline_md(node.content)
  end
  return a.text or ""
end

---@param nodes table[]|nil
---@return string
inline_md = function(nodes)
  local parts = {}
  for _, n in ipairs(nodes or {}) do
    table.insert(parts, inline_node(n))
  end
  return table.concat(parts)
end

local blocks_md

-- Text that would read as block syntax at the start of a line gets a
-- backslash, so a paragraph starting "# 123" or "- x" stays a paragraph.
local function escape_block_start(line)
  if line:match("^#+%s") or line:match("^>") or line:match("^[-*+]%s") or line:match("^```")
      or line:match("^|") or line:match("^%-%-%-") or line:match("^%*%*%*") or line:match("^___") then
    return "\\" .. line
  end
  local num, rest = line:match("^(%d+)([.)]%s.*)$")
  if num then return num .. "\\" .. rest end
  return line
end

---Paragraph lines. A blank line would split the paragraph, so an empty
---line (an empty paragraph, or two hardBreaks in a row) is written as a lone
---backslash — a Markdown hard break with nothing before it.
local function paragraph_lines(text)
  local out = {}
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(out, l == "" and "\\" or escape_block_start(l))
  end
  return out
end

---Prefix the first line with `first` and every following line with `rest`.
local function indent_lines(lines, first, rest)
  local out = {}
  for i, l in ipairs(lines) do
    local p = i == 1 and first or rest
    table.insert(out, l == "" and (p:match("^(.-)%s*$")) or (p .. l))
  end
  if #out == 0 then out[1] = (first:match("^(.-)%s*$")) end
  return out
end

local function split_lines(s)
  return vim.split(s, "\n", { plain = true })
end

local function placeholder_label(node)
  if node.type == "extension" or node.type == "bodiedExtension" then
    return "macro: " .. ((node.attrs or {}).extensionKey or "?")
  end
  -- Names let a viewer find the file: the attachment's file name (alt), or
  -- the URL of an external image.
  local names = {}
  local function walk(n)
    if n.type == "media" then
      local a = n.attrs or {}
      local name = a.type == "external" and a.url or a.alt or a.id or "file"
      table.insert(names, (name:gsub("[%[%]\n]", "")))
    end
    for _, c in ipairs(n.content or {}) do walk(c) end
  end
  walk(node)
  return (#names == 1 and "attachment: " or "attachments: ") .. table.concat(names, ", ")
end

local in_cell = false -- see PRESERVED: no placeholders inside a one-line cell

local function cell_md(cell)
  in_cell = true
  local parts = {}
  for _, block in ipairs(cell.content or {}) do
    local text = block.type == "paragraph" and inline_md(block.content) or table.concat(blocks_md({ block }, true), " ")
    table.insert(parts, text)
  end
  in_cell = false
  return (table.concat(parts, "<p>"):gsub("\n", "<br>"):gsub("|", "\\|"))
end

---@param node table
---@return string[] lines
local function block_node(node)
  local t = node.type
  local a = node.attrs or {}
  if stash_out and not in_cell and PRESERVED[t] then
    table.insert(stash_out, vim.deepcopy(node))
    return { ("[%s](adf:%d)"):format(placeholder_label(node), #stash_out) }
  end
  if t == "paragraph" then
    return paragraph_lines(inline_md(node.content))
  elseif t == "heading" then
    return { string.rep("#", a.level or 1) .. " " .. inline_md(node.content):gsub("\n", " ") }
  elseif t == "bulletList" or t == "orderedList" then
    local out = {}
    local n = a.order or 1
    for _, item in ipairs(node.content or {}) do
      local marker = t == "bulletList" and "- " or (tostring(n) .. ". ")
      n = n + 1
      vim.list_extend(out, indent_lines(blocks_md(item.content, true), marker, string.rep(" ", #marker)))
    end
    return out
  elseif t == "taskList" then
    local out = {}
    for _, item in ipairs(node.content or {}) do
      if item.type == "taskList" then
        vim.list_extend(out, indent_lines(block_node(item), "  ", "  "))
      else
        local box = (item.attrs and item.attrs.state == "DONE") and "- [x] " or "- [ ] "
        vim.list_extend(out, indent_lines(split_lines(inline_md(item.content)), box, "  "))
      end
    end
    return out
  elseif t == "codeBlock" then
    -- attrs beyond the language (wrap, ...) ride in the stash by position
    if stash_out then
      stash_out.codes = stash_out.codes or {}
      table.insert(stash_out.codes, vim.deepcopy(a))
    end
    local out = { "```" .. (a.language or "") }
    local text = inline_md(node.content)
    if text ~= "" then vim.list_extend(out, split_lines(text)) end
    table.insert(out, "```")
    return out
  elseif t == "blockquote" then
    return indent_lines(blocks_md(node.content), "> ", "> ")
  elseif t == "rule" then
    return { "---" }
  elseif t == "panel" then
    -- A callout: `> [!INFO]` + the panel's blocks. Attrs (custom icon /
    -- colour) ride in the stash by position.
    local kind = PANEL_TYPES[a.panelType or ""] and a.panelType or "info"
    if stash_out then
      stash_out.panels = stash_out.panels or {}
      table.insert(stash_out.panels, vim.deepcopy(node.attrs or {}))
    end
    local inner = blocks_md(node.content)
    table.insert(inner, 1, "[!" .. kind:upper() .. "]")
    return indent_lines(inner, "> ", "> ")
  elseif t == "table" then
    -- Layout, widths, header-vs-cell and cell colours can't be written in a
    -- Markdown table: stash them per table and re-apply by position.
    local shape = { attrs = vim.deepcopy(node.attrs), cells = {} }
    local rows = {}
    for r, row in ipairs(node.content or {}) do
      local cells = {}
      shape.cells[r] = {}
      for c, cell in ipairs(row.content or {}) do
        table.insert(cells, cell_md(cell))
        shape.cells[r][c] = { type = cell.type, attrs = vim.deepcopy(cell.attrs) }
      end
      table.insert(rows, cells)
    end
    if stash_out then
      stash_out.tables = stash_out.tables or {}
      table.insert(stash_out.tables, shape)
    end
    if #rows == 0 then return {} end
    local width = 0
    for _, r in ipairs(rows) do width = math.max(width, #r) end
    local out = {}
    for i, r in ipairs(rows) do
      for c = #r + 1, width do r[c] = "" end
      table.insert(out, "| " .. table.concat(r, " | ") .. " |")
      if i == 1 then
        table.insert(out, "|" .. string.rep(" --- |", width))
      end
    end
    return out
  elseif t == "mediaSingle" or t == "mediaGroup" or t == "media" then
    return { "[attachment]" }
  elseif t == "expand" or t == "nestedExpand" then
    local inner = blocks_md(node.content)
    table.insert(inner, 1, "**" .. (a.title or "Details") .. "**")
    return inner
  elseif t == "blockCard" or t == "embedCard" then
    return { a.url or "" }
  elseif t == "extension" or t == "bodiedExtension" or t == "inlineExtension" then
    return { "[macro: " .. (a.extensionKey or "?") .. "]" }
  elseif node.content then
    return blocks_md(node.content)
  end
  return { inline_node(node) }
end

---@param nodes table[]|nil
local LISTS = { bulletList = true, orderedList = true, taskList = true }

---@param tight boolean|nil  list item body: a nested list follows its text
---  directly; any other block still gets a blank line, or two paragraphs
---  would read back as one
---@return string[]
blocks_md = function(nodes, tight)
  local out = {}
  for i, n in ipairs(nodes or {}) do
    if i > 1 and not (tight and LISTS[n.type]) then table.insert(out, "") end
    vim.list_extend(out, block_node(n))
  end
  return out
end

---@param doc table|nil  ADF document (or nil / empty)
---@param stash table[]|nil  receives PRESERVED nodes (see above)
---@return string markdown
function M.to_markdown(doc, stash)
  if type(doc) ~= "table" then return "" end
  stash_out = stash
  local ok, lines = pcall(blocks_md, doc.content)
  stash_out = nil
  if not ok then error(lines, 0) end
  local md = table.concat(lines, "\n")
  return stash and mark_glyphs(md, stash) or md
end

-- endregion

-- region Markdown → ADF

-- taskList/taskItem need a localId unique within the document; hrtime plus a
-- counter is unique enough without touching the global math.random seed.
local id_counter = 0
local function local_id()
  id_counter = id_counter + 1
  return ("%x-%x"):format((vim.uv or vim.loop).hrtime(), id_counter)
end

local function text_node(text, marks)
  local n = { type = "text", text = text }
  if marks and #marks > 0 then n.marks = vim.deepcopy(marks) end
  return n
end

local function with_mark(marks, mark)
  local out = vim.deepcopy(marks)
  table.insert(out, mark)
  return out
end

-- ADF forbids combining `code` with anything but `link`.
local function code_marks(marks)
  local out = {}
  for _, m in ipairs(marks) do
    if m.type == "link" then table.insert(out, vim.deepcopy(m)) end
  end
  table.insert(out, { type = "code" })
  return out
end

-- Characters a backslash escapes: exactly those the writer escapes (block
-- starts, inline syntax). Not the backslash itself or other punctuation:
-- Windows / UNC paths (\\server\share\!dir) must come back unchanged.
local PUNCT = "[#>%-%+%*`|_%.%)%[%]~<:]"

---Find the closing delimiter for emphasis starting after `from`. The closer
---must not be preceded by whitespace; for `_` it must not be followed by a
---word character (so snake_case stays text).
local function find_closer(s, delim, from)
  local pos = from
  while true do
    local i = s:find(delim, pos, true)
    if not i then return nil end
    -- In a run like `***` the strong closer is the LAST pair, the leftover
    -- `*` closes an inner emphasis: `***x***` = strong(em(x)).
    if #delim == 2 then
      while s:sub(i + 2, i + 2) == delim:sub(1, 1) do i = i + 1 end
    end
    local before = s:sub(i - 1, i - 1)
    local after = s:sub(i + #delim, i + #delim)
    local ok = before ~= "" and not before:match("%s")
    if ok and delim:sub(1, 1) == "_" and after:match("[%w]") then ok = false end
    -- a single `*` must not be half of a `**`
    if ok and #delim == 1 and (after == delim or before == delim) then ok = false end
    if ok and i > from then return i end
    pos = i + 1
  end
end


local glyph_chars -- emoji characters of the running from_markdown, longest first

---An emoji character of the stash at byte `i` of `s` (longest first, so
---"👮‍♂️" wins over "👮"), or nil.
local function glyph_at(s, i)
  return glyph_match(s, i, glyph_chars)
end

---Next occurrence of emoji character `g`: its emoji attrs, or nil when this
---occurrence was plain text. A new one (past the recorded occurrences, or
---typed / picked here) becomes an emoji node, as Jira's editor makes it.
local function next_glyph(g)
  glyph_pos[g] = (glyph_pos[g] or 0) + 1
  local seq = stash_in and stash_in.emoji_seq and stash_in.emoji_seq[g]
  local recorded = seq and seq[glyph_pos[g]]
  if recorded ~= nil then return recorded or nil end
  return emoji.attrs(g)
end

---Emoji attrs for a typed `:name:`: the stashed node of that name, else a
---known Atlassian / Unicode emoji.
local function named_emoji(short)
  local stashed = stash_in and stash_in.emoji and stash_in.emoji[short]
  if stashed then return stashed end
  return emoji.attrs_by_name(short:sub(2, -2))
end

---Count the emoji characters inside code (spans, blocks): they are always
---text, but keep the occurrence numbering in step with to_markdown's.
local function skip_glyphs(text)
  local i = 1
  while i <= #text do
    local g = text:byte(i) >= 0x80 and glyph_at(text, i) or nil
    if g then
      next_glyph(g)
      i = i + #g
    else
      i = i + 1
    end
  end
end

---Inline Markdown → list of ADF inline nodes.
---@param s string
---@param marks table[]  marks inherited from the enclosing span
---@param out table[]
parse_inline = function(s, marks, out)
  local buf = {}
  local function flush()
    if #buf > 0 then
      table.insert(out, text_node(table.concat(buf), marks))
      buf = {}
    end
  end

  local i, len = 1, #s
  while i <= len do
    local c = s:sub(i, i)
    local two = s:sub(i, i + 1)
    local prev = i > 1 and s:sub(i - 1, i - 1) or ""

    if c == "\\" and s:sub(i + 1, i + 1):match(PUNCT) then
      table.insert(buf, s:sub(i + 1, i + 1))
      i = i + 2
    elseif c == "`" then
      local fence = two == "``" and "``" or "`"
      local j = s:find(fence, i + #fence, true)
      if j then
        flush()
        local code = s:sub(i + #fence, j - 1)
        if fence == "``" then code = vim.trim(code) end
        skip_glyphs(code)
        table.insert(out, text_node(code, code_marks(marks)))
        i = j + #fence
      else
        table.insert(buf, c)
        i = i + 1
      end
    elseif (two == "**" or two == "__" or two == "~~") and not s:sub(i + 2, i + 2):match("^%s?$") then
      local j = (two ~= "__" or not prev:match("%w")) and find_closer(s, two, i + 2) or nil
      if j then
        flush()
        local mark = two == "~~" and { type = "strike" } or { type = "strong" }
        parse_inline(s:sub(i + 2, j - 1), with_mark(marks, mark), out)
        i = j + 2
      else
        table.insert(buf, two)
        i = i + 2
      end
    elseif (c == "*" or c == "_") and not s:sub(i + 1, i + 1):match("^%s?$")
        and not (c == "_" and prev:match("%w")) then
      local j = find_closer(s, c, i + 1)
      if j then
        flush()
        parse_inline(s:sub(i + 1, j - 1), with_mark(marks, { type = "em" }), out)
        i = j + 1
      else
        table.insert(buf, c)
        i = i + 1
      end
    elseif c == "<" and s:match("^<https?://[^%s>]+>", i) then
      local url = s:match("^<(https?://[^%s>]+)>", i)
      flush()
      table.insert(out, { type = "inlineCard", attrs = { url = url } })
      i = i + #url + 2
    elseif c:byte() >= 0x80 and glyph_at(s, i) then
      -- an emoji character: an emoji node where the original had one,
      -- plain text where it was text
      local glyph = glyph_at(s, i)
      local attrs = next_glyph(glyph)
      if attrs then
        flush()
        table.insert(out, { type = "emoji", attrs = vim.deepcopy(attrs) })
      else
        table.insert(buf, glyph)
      end
      i = i + #glyph
    elseif c == ":" and not prev:match("[%w:]") and s:match("^:[%w_%+%-]+:", i)
        and named_emoji(s:match("^:[%w_%+%-]+:", i)) then
      local short = s:match("^:[%w_%+%-]+:", i)
      flush()
      table.insert(out, { type = "emoji", attrs = vim.deepcopy(named_emoji(short)) })
      i = i + #short
    elseif c == "[" then
      local label, href, stop = s:match("^%[(.-)%]%(([^%s%)]*)%)()", i)
      if label and href then
        flush()
        local id = href:match("^mention:(.*)$")
        if id then
          -- Known mention: its original attrs (accessLevel, ...); new: id + text.
          local known = stash_in and stash_in.mentions and stash_in.mentions[id]
          local attrs = known and vim.deepcopy(known) or { id = id }
          attrs.text = "@" .. label:gsub("^@", "")
          table.insert(out, { type = "mention", attrs = attrs })
        else
          parse_inline(label, with_mark(marks, { type = "link", attrs = { href = href } }), out)
        end
        i = stop
      else
        table.insert(buf, c)
        i = i + 1
      end
    elseif (c == "h") and (prev == "" or prev:match("[%s%(]")) and s:match("^https?://", i) then
      local url = s:match("^https?://[^%s<>]+", i)
      url = url:gsub("[%.,;:!%?%)]+$", "")
      flush()
      table.insert(out, text_node(url, with_mark(marks, { type = "link", attrs = { href = url } })))
      i = i + #url
    else
      table.insert(buf, c)
      i = i + 1
    end
  end
  flush()
end

---Inline content for a paragraph made of several source lines: each line
---break becomes a hardBreak.
---@param lines string[]
---@return table[]
local function inline_lines(lines)
  local out = {}
  for idx, line in ipairs(lines) do
    -- A lone backslash is the empty-line marker (see paragraph_lines). A
    -- trailing one elsewhere is content (`\\server\share\`), and so are
    -- trailing spaces (Jira text often ends in one).
    if line == "\\" then line = "" end
    if idx > 1 then
      line = line:gsub("^%s+", "") -- continuation indent is not content
      table.insert(out, { type = "hardBreak" })
    end
    parse_inline(line, {}, out)
  end
  return out
end

local function paragraph(lines)
  local content = inline_lines(lines)
  local p = { type = "paragraph" }
  if #content > 0 then p.content = content end
  return p
end

local function list_marker(line)
  local ind, mark, rest = line:match("^(%s*)([-*+])%s+(.*)$")
  if ind then
    local box, text = rest:match("^%[([ xX])%]%s+(.*)$")
    if not box then box, text = rest:match("^%[([ xX])%]()$"), "" end
    if box then return #ind, "task", text, box:lower() == "x", #ind + #mark + 1 end
    return #ind, "bullet", rest, nil, #ind + #mark + 1
  end
  local ind2, num, sep, rest2 = line:match("^(%s*)(%d+)([.)])%s+(.*)$")
  if ind2 then
    return #ind2, "ordered", rest2, tonumber(num), #ind2 + #num + #sep + 1
  end
  return nil
end

local function is_fence(line) return line:match("^%s*```") ~= nil end
local function is_heading(line) return line:match("^#+%s") ~= nil and #line:match("^(#+)") <= 6 end
local function is_rule(line)
  local l = line:gsub("%s", "")
  return l:match("^%-%-%-+$") or l:match("^%*%*%*+$") or l:match("^___+$")
end
local function is_table_sep(line)
  return line and line:match("^%s*|?%s*:?%-+:?%s*|") ~= nil
end

local parse_blocks

local function split_row(line)
  line = vim.trim(line):gsub("^|", ""):gsub("|$", "")
  -- Cells are written "| text |": strip exactly the one padding space on each
  -- side, so whitespace that belongs to the cell text survives.
  local function cell(parts)
    return (table.concat(parts):gsub("^ ", ""):gsub(" $", ""))
  end
  local cells, cur, i = {}, {}, 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == "\\" and line:sub(i + 1, i + 1) == "|" then
      table.insert(cur, "|")
      i = i + 2
    elseif c == "|" then
      table.insert(cells, cell(cur))
      cur = {}
      i = i + 1
    else
      table.insert(cur, c)
      i = i + 1
    end
  end
  table.insert(cells, cell(cur))
  return cells
end

-- In a cell, `<p>` separates paragraphs and `<br>` is a line break.
local function table_cell(kind, text)
  local content = {}
  for _, para in ipairs(vim.split(text, "<p>", { plain = true })) do
    table.insert(content, paragraph(vim.split(para, "<br>", { plain = true })))
  end
  return { type = kind, content = content }
end

---Parse a list starting at lines[i]; returns the ADF list node and the index
---of the first line after it.
local function parse_list(lines, i)
  local base_indent, kind = list_marker(lines[i])
  local node
  if kind == "task" then
    node = { type = "taskList", attrs = { localId = local_id() }, content = {} }
  elseif kind == "ordered" then
    local _, _, _, first = list_marker(lines[i])
    node = { type = "orderedList", attrs = { order = first or 1 }, content = {} }
  else
    node = { type = "bulletList", content = {} }
  end

  while i <= #lines do
    local ind, k, text, extra, content_col = list_marker(lines[i])
    if not ind or ind ~= base_indent or k ~= kind then break end
    -- Gather the item's continuation lines: anything indented deeper than the
    -- marker, plus blank lines followed by a line indented to the item's
    -- content column (a paragraph after the list that merely starts with a
    -- space is not part of the last item).
    local body = { text }
    local j = i + 1
    while j <= #lines do
      local l = lines[j]
      if l:match("^%s*$") then
        local nxt = lines[j + 1]
        if nxt and #nxt:match("^(%s*)") >= content_col and not nxt:match("^%s*$") then
          table.insert(body, "")
          j = j + 1
        else
          break
        end
      elseif #l:match("^(%s*)") > base_indent then
        local strip = math.min(content_col, #l:match("^(%s*)"))
        table.insert(body, l:sub(strip + 1))
        j = j + 1
      else
        break
      end
    end

    if kind == "task" then
      -- taskItem holds inline content only; nested task lists become siblings
      -- in the parent taskList, which is how ADF nests them.
      local text_lines, rest = {}, {}
      for idx, l in ipairs(body) do
        if idx > 1 and (list_marker(l) or #rest > 0) then
          table.insert(rest, l)
        else
          table.insert(text_lines, l)
        end
      end
      local item = {
        type = "taskItem",
        attrs = { localId = local_id(), state = extra and "DONE" or "TODO" },
      }
      local content = inline_lines(text_lines)
      if #content > 0 then item.content = content end
      table.insert(node.content, item)
      for _, child in ipairs(parse_blocks(rest)) do
        if child.type == "taskList" then table.insert(node.content, child) end
      end
    else
      local content = parse_blocks(body)
      -- An item may open with a nested list ("10. 1. foo"); only an empty
      -- item needs a placeholder paragraph.
      if #content == 0 then content = { { type = "paragraph" } } end
      table.insert(node.content, { type = "listItem", content = content })
    end
    i = j
  end
  return node, i
end

---@param lines string[]
---@return table[] ADF block nodes
parse_blocks = function(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line:match("^%s*$") then
      i = i + 1
    elseif is_fence(line) then
      local lang = line:match("^%s*```%s*(%S*)")
      local body = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^%s*```%s*$") do
        table.insert(body, lines[i])
        i = i + 1
      end
      i = i + 1 -- closing fence (or EOF)
      skip_glyphs(table.concat(body, "\n"))
      local node = { type = "codeBlock" }
      codes_in = (codes_in or 0) + 1
      local attrs = stash_in and stash_in.codes and vim.deepcopy(stash_in.codes[codes_in]) or {}
      -- the fence wins; an empty fence keeps an empty stashed language ("")
      if lang and lang ~= "" then
        attrs.language = lang
      elseif attrs.language ~= "" then
        attrs.language = nil
      end
      if next(attrs) then node.attrs = attrs end
      if #body > 0 then node.content = { { type = "text", text = table.concat(body, "\n") } } end
      table.insert(out, node)
    elseif is_heading(line) then
      local hashes, text = line:match("^(#+)%s(.*)$")
      text = text:gsub("%s+#+%s*$", "") -- optional closing sequence, not "C#"
      local node = { type = "heading", attrs = { level = #hashes } }
      local content = {}
      parse_inline(text, {}, content)
      if #content > 0 then node.content = content end
      table.insert(out, node)
      i = i + 1
    elseif is_rule(line) then
      table.insert(out, { type = "rule" })
      i = i + 1
    elseif line:match(PLACEHOLDER) then
      local label, n = line:match(PLACEHOLDER)
      local node = stash_in and stash_in[tonumber(n)]
      -- Without its stashed node the line is just the label as text.
      table.insert(out, node and vim.deepcopy(node) or paragraph({ "[" .. label .. "]" }))
      i = i + 1
    elseif line:match("^%s*>") then
      local body = {}
      while i <= #lines and lines[i]:match("^%s*>") do
        table.insert(body, (lines[i]:gsub("^%s*> ?", "")))
        i = i + 1
      end
      local kind, rest = (body[1] or ""):match("^%[!(%a+)%]%s*(.-)%s*$")
      if kind and PANEL_TYPES[kind:lower()] then
        -- callout → panel; text after the marker starts the content
        kind = kind:lower()
        local inner = vim.list_slice(body, 2)
        if rest ~= "" then table.insert(inner, 1, rest) end
        local content = parse_blocks(inner)
        if #content == 0 then content = { { type = "paragraph" } } end
        panels_in = panels_in + 1
        local saved = stash_in and stash_in.panels and stash_in.panels[panels_in]
        local attrs = (saved and saved.panelType == kind) and vim.deepcopy(saved) or { panelType = kind }
        table.insert(out, { type = "panel", attrs = attrs, content = content })
      else
        table.insert(out, { type = "blockquote", content = parse_blocks(body) })
      end
    elseif line:match("^%s*|") and is_table_sep(lines[i + 1]) then
      local tbl = { type = "table", content = {} }
      local header = split_row(line)
      local row = { type = "tableRow", content = {} }
      for _, cell in ipairs(header) do table.insert(row.content, table_cell("tableHeader", cell)) end
      table.insert(tbl.content, row)
      i = i + 2
      while i <= #lines and lines[i]:match("^%s*|") do
        local r = { type = "tableRow", content = {} }
        local cells = split_row(lines[i])
        for c = 1, #header do table.insert(r.content, table_cell("tableCell", cells[c] or "")) end
        table.insert(tbl.content, r)
        i = i + 1
      end
      -- Re-apply the stashed shape of the table at the same position.
      tables_in = tables_in + 1
      local shape = stash_in and stash_in.tables and stash_in.tables[tables_in]
      if shape then
        tbl.attrs = vim.deepcopy(shape.attrs)
        for r, row in ipairs(tbl.content) do
          for c, cell in ipairs(row.content) do
            local s = shape.cells[r] and shape.cells[r][c]
            if s then
              cell.type = s.type
              cell.attrs = vim.deepcopy(s.attrs)
            end
          end
        end
      end
      table.insert(out, tbl)
    elseif list_marker(line) then
      local node
      node, i = parse_list(lines, i)
      table.insert(out, node)
    else
      local para = {}
      while i <= #lines do
        local l = lines[i]
        if l:match("^%s*$") or is_fence(l) or is_heading(l) or l:match("^%s*>") or l:match(PLACEHOLDER)
            or (#para > 0 and (list_marker(l) or is_rule(l))) then
          break
        end
        table.insert(para, l)
        i = i + 1
      end
      table.insert(out, paragraph(para))
    end
  end
  return out
end

---@param md string|nil
---@param stash table[]|nil  nodes stashed by to_markdown for this text
---@return table ADF document
function M.from_markdown(md, stash)
  local lines = vim.split((md or ""):gsub("\r\n", "\n"), "\n", { plain = true })
  stash_in, tables_in, panels_in, codes_in = stash, 0, 0, 0
  glyph_pos = {}
  glyph_chars = stash and stash.emoji_seq and sorted_glyphs(stash.emoji_seq) or nil
  local ok, content = pcall(parse_blocks, lines)
  stash_in, glyph_chars = nil, nil
  if not ok then error(content, 0) end
  return { type = "doc", version = 1, content = content }
end

-- endregion

return M
