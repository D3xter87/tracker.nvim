-- Issue list view, laid out like Jira's backlog: one row per issue with its
-- type icon, key, priority icon and summary, then the epic (as a chip in the
-- epic's Jira colour), story points, assignee and status on the right.
-- Sub-tasks sit under their parent as a foldable sub-list; `K` previews what
-- the row can't show (description, reporter, labels, ...).
-- Fed by any loader — a saved query, ad-hoc JQL, a board sprint / backlog.

local M = {}

local api = require("tracker.api")
local config = require("tracker.config")
local window = require("tracker.ui.window")
local view = require("tracker.ui.view")
local hl = require("tracker.ui.highlights")
local icons = require("tracker.ui.icons")
local actions = require("tracker.ui.actions")
local plan = require("tracker.ui.plan")
local listfilter = require("tracker.ui.listfilter")

---@class TrackerListOpts
---@field title string
---@field subtitle string|nil      shown above the rows (e.g. the JQL)
---@field load fun(cb: fun(issues: TrackerIssue[]|nil, err: string|nil, meta: table|nil))
---@field query string|nil         set for query-backed lists: enables `J`

local function matches(issue, needle)
  if not needle or needle == "" then return true end
  local hay = table.concat({
    issue.key, issue.summary, issue.status and issue.status.name or "",
    issue.assignee and issue.assignee.name or "", issue.type and issue.type.name or "",
    issue.parent and issue.parent.summary or "", table.concat(issue.labels or {}, " "),
  }, " "):lower()
  return hay:find(needle, 1, true) ~= nil
end

local function is_subtask(i) return i.type and (i.type.subtask or (i.type.level or 0) < 0) end

---@class TrackerListNode
---@field issue TrackerIssue
---@field children TrackerListNode[]

---Nest every issue under its parent when the parent is in the list too —
---epic → story / task → sub-task, any depth. Top-level rows keep the
---loader's order (Jira's rank); children keep it as well, except sub-tasks,
---which follow the parent's own sub-task order. An issue whose parent is
---not in the list is a top-level row.
---@param issues TrackerIssue[]
---@return TrackerListNode[]
function M.build_tree(issues)
  local node_of, pos = {}, {}
  for idx, i in ipairs(issues) do
    node_of[i.key] = node_of[i.key] or { issue = i, children = {} }
    pos[i.key] = pos[i.key] or idx
  end
  ---Would hanging `key` under `parent` close a loop (bad data)?
  local function loops(key, parent)
    local seen = 0
    while parent and seen < 50 do
      if parent == key then return true end
      local p = node_of[parent]
      parent = p and p.issue.parent and p.issue.parent.key or nil
      seen = seen + 1
    end
    return false
  end
  local roots, placed = {}, {}
  for _, i in ipairs(issues) do
    if not placed[i.key] then
      placed[i.key] = true
      local pk = i.parent and i.parent.key
      local parent = pk and node_of[pk]
      if parent and not loops(i.key, pk) then
        table.insert(parent.children, node_of[i.key])
      else
        table.insert(roots, node_of[i.key])
      end
    end
  end
  for _, node in pairs(node_of) do
    local order = {}
    for idx, ref in ipairs(node.issue.subtasks or {}) do order[ref.key] = idx end
    table.sort(node.children, function(a, b)
      local oa, ob = order[a.issue.key], order[b.issue.key]
      if oa and ob then return oa < ob end
      if oa or ob then return oa ~= nil end -- the parent's own sub-tasks first
      return pos[a.issue.key] < pos[b.issue.key]
    end)
  end
  return roots
end

---Depth-first walk over a tree; `fn(node, depth)`.
local function walk(nodes, fn, depth)
  depth = depth or 0
  for _, n in ipairs(nodes) do
    fn(n, depth)
    walk(n.children, fn, depth + 1)
  end
end

---Epic of a top-level row: its parent when that parent is an epic.
local function epic_key(i)
  if is_subtask(i) or not i.parent then return nil end
  local t = i.parent.type
  if t and ((t.level or 0) >= 1 or icons.kind(t) == "epic") then return i.parent.key end
  return nil
end

local function fmt_points(p)
  if type(p) ~= "number" then return "-" end
  if p == math.floor(p) then return tostring(math.floor(p)) end
  return (("%.1f"):format(p):gsub("%.0$", ""))
end

local function lpad(s, w)
  return string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(s))) .. s
end

---`issues` with `keys` (kept in this order) moved right after / before
---`target`, as a successful rank leaves them.
---@param where "after"|"before"
local function reranked(issues, keys, target, where)
  local set, moving, out = {}, {}, {}
  for _, k in ipairs(keys) do set[k] = true end
  for _, i in ipairs(issues) do
    if set[i.key] then table.insert(moving, i) end
  end
  for _, i in ipairs(issues) do
    if not set[i.key] then
      if i.key == target and where == "before" then vim.list_extend(out, moving) end
      table.insert(out, i)
      if i.key == target and where == "after" then vim.list_extend(out, moving) end
    end
  end
  return out
end

---@param opts TrackerListOpts
---@param replace boolean|nil  replace the top view instead of pushing
function M.open(opts, replace)
  local buf = view.new_buf("tracker_list")
  local v = {
    buf = buf,
    title = " " .. opts.title .. " ",
    footer = view.footer({
      { "<CR>", "open" }, { "K", "preview" }, { "e", "title" }, { "E", "fields" }, { "S", "points" }, { "L", "labels" },
      { "A", "me" }, { "m", "mark" }, { "p/P", "put" }, { "M", "move" }, { "d/D", "archive/delete" },
      { "f", "filters" }, { "F", "group" }, { "<Tab>", "fold" }, { "/", "search" }, { "J", "query" }, { "?", "help" },
    }),
    win_opts = { cursorline = true, wrap = false },
  }
  local st = {
    issues = {}, rows = {}, filter = nil, meta = nil, first_row = nil,
    collapsed = {}, epics = {}, details = {}, has_children = {},
    marked = {}, -- keys marked with m (to move with p / P, M, d, D)
    filters = {}, -- quick filters (f), see ui/listfilter.lua
    group = nil, -- grouping (F): nil | "epic" | "assignee" | "status"
    group_rows = {}, -- lnum → group id of a group header
  }
  local expand_default = config.get().ui.expand_subtasks ~= false

  local function is_collapsed(key)
    if st.collapsed[key] == nil then return not expand_default end
    return st.collapsed[key]
  end

  local function group_collapsed(id) return st.collapsed["group:" .. id] == true end

  ---Header line describing the active quick filters (f).
  local function filter_chunks()
    local chunks = { { " filters: ", "TrackerMuted" } }
    local by_key = {}
    for _, i in ipairs(st.issues) do by_key[i.key] = i end
    for _, cat in ipairs(listfilter.CATEGORIES) do
      local set = st.filters[cat.id]
      if set and next(set) then
        table.insert(chunks, { cat.label:lower() .. " ", "TrackerField" })
        for val in pairs(set) do
          local text, hlg = val, "TrackerFilter"
          if val == listfilter.NONE then
            text = ({ epic = "no epic", assignee = "unassigned", label = "no labels" })[cat.id] or "none"
          elseif cat.id == "epic" and st.epics[val] then
            text, hlg = " " .. st.epics[val].summary .. " ", icons.epic_hl(st.epics[val].color)
          elseif cat.id == "assignee" then
            for _, i in ipairs(st.issues) do
              if i.assignee and i.assignee.id == val then text = i.assignee.name break end
            end
          end
          table.insert(chunks, { text, hlg })
          table.insert(chunks, { " " })
        end
        table.insert(chunks, { " " })
      end
    end
    return chunks
  end

  local function render()
    local win = window.win()
    local width = (win and vim.api.nvim_win_get_width(win) or vim.o.columns) - 1
    local b = view.builder()
    local filtering = st.filter ~= nil
    local base = listfilter.apply(st.issues, st.filters)
    local shown = vim.tbl_filter(function(i) return matches(i, st.filter) end, base)
    local function nodes_of(list)
      return filtering and vim.tbl_map(function(i) return { issue = i, children = {} } end, list)
        or M.build_tree(list)
    end
    -- groups (F): { group, nodes }; else the loader's sections (meta.sections:
    -- a query made of several, see api.search); else one anonymous group
    local sections = {}
    if st.group then
      for _, g in ipairs(listfilter.groups(shown, st.group)) do
        table.insert(sections, { group = g, nodes = nodes_of(g.issues) })
      end
    elseif st.meta and st.meta.sections then
      for n, s in ipairs(st.meta.sections) do
        local list = listfilter.apply(s.issues, st.filters)
        if filtering then list = vim.tbl_filter(function(i) return matches(i, st.filter) end, list) end
        table.insert(sections, { group = { id = "section:" .. n, title = s.title, issues = list }, nodes = nodes_of(list) })
      end
    else
      table.insert(sections, { nodes = nodes_of(filtering and shown or base) })
    end

    b:add({ { " " .. (opts.subtitle or ""), "TrackerMuted" } })
    if listfilter.active(st.filters) then
      local chunks = filter_chunks()
      table.insert(chunks, { ("(%d of %d, f: change)"):format(#base, #st.issues), "TrackerMuted" })
      b:add(chunks)
    end
    if filtering then
      b:add({ { " filter: ", "TrackerMuted" }, { st.filter, "TrackerFilter" },
              { ("  (%d of %d)"):format(#shown, #st.issues), "TrackerMuted" } })
    end
    b:add("")
    st.rows, st.group_rows, st.first_row = {}, {}, nil
    -- (sections say it under their own header)
    local titled = sections[1] and sections[1].group and sections[1].group.title
    if #shown == 0 and not titled then b:add({ { "  no issues", "TrackerMuted" } }) end

    -- Column widths from what is shown.
    local all, max_depth = {}, 0
    local nodes = {}
    for _, sec in ipairs(sections) do vim.list_extend(nodes, sec.nodes) end
    st.has_children = {}
    walk(nodes, function(n, depth)
      table.insert(all, n.issue)
      max_depth = math.max(max_depth, depth)
      if #n.children > 0 then st.has_children[n.issue.key] = true end
    end)
    local wk = view.width_of(vim.tbl_map(function(i) return i.key end, all))
    local ws = view.width_of(vim.tbl_map(function(i) return view.status_name(i.status and i.status.name) end, all), 16)
    local wa = view.width_of(vim.tbl_map(function(i) return i.assignee and i.assignee.name or "Unassigned" end, all), 16)
    local we = 0
    for _, i in ipairs(all) do
      local e = st.epics[epic_key(i) or ""]
      if e then we = math.max(we, math.min(18, vim.fn.strdisplaywidth(e.summary)) + 2) end
    end
    -- Points column. A parent with sub-tasks shows "closed sub-task points /
    -- its own estimate" (e.g. 3/10, 14/10). Closed = status in the Done
    -- category (e.g. Done and Rejected). A sum above the
    -- story's estimate is flagged: its points need correcting by hand.
    local points = {}
    walk(nodes, function(n)
      if #n.children > 0 then
        local sum = 0
        for _, cn in ipairs(n.children) do
          local c = cn.issue
          if type(c.story_points) == "number" and c.status and c.status.category == "done" then
            sum = sum + c.story_points
          end
        end
        local own = n.issue.story_points
        local over = type(own) ~= "number" and sum > 0 or (type(own) == "number" and sum > own)
        points[n.issue.key] = {
          text = fmt_points(sum) .. "/" .. fmt_points(own),
          hl = over and "TrackerPointsOver" or "TrackerPoints",
        }
      end
    end)
    local wp = 4
    for _, i in ipairs(all) do
      wp = math.max(wp, vim.fn.strdisplaywidth(points[i.key] and points[i.key].text or fmt_points(i.story_points)))
    end
    -- " " indent(2/level) fold(2) icon(2) key " " prio(2) summary " " epic " " points "  " user(2)+name " " status
    -- The indent eats into the summary, so the right-hand columns line up.
    local fixed = 1 + 2 + 2 + wk + 1 + 2 + 1 + we + 1 + wp + 2 + 2 + wa + 1 + ws
    local wsum = math.max(20 + 2 * max_depth, width - fixed)
    -- "fit": the summary column only as wide as its longest summary + labels
    -- (folded rows counted too, so folding doesn't shift anything), so on a
    -- wide window the right-hand columns sit next to the text instead of at
    -- the far edge. "fill": up to the window's edge.
    if config.get().ui.list_width ~= "fill" then
      local need = 0
      walk(nodes, function(n, depth)
        local i = n.issue
        local tags = #(i.labels or {}) > 0
          and " " .. table.concat(vim.tbl_map(function(l) return "#" .. l end, i.labels), " ") or ""
        local folded = #n.children > 0 and (" [+%d]"):format(#n.children) or ""
        need = math.max(need, 2 * depth + (i.blocked and 2 or 0) + vim.fn.strdisplaywidth(i.summary .. folded .. tags))
      end)
      wsum = math.min(wsum, math.max(20 + 2 * max_depth, need))
    end

    local function row(i, depth, node)
      local child = depth > 0
      local fold = "  "
      if node and #node.children > 0 then
        fold = (is_collapsed(i.key) and icons.glyph.fold_closed or icons.glyph.fold_open) .. " "
      end
      local icon, icon_hl = icons.type(i.type)
      local prio, prio_hl = icons.priority(i)
      local summary = i.summary
      if node and #node.children > 0 and is_collapsed(i.key) then
        summary = summary .. (" [+%d]"):format(#node.children)
      end
      local e = not child and st.epics[epic_key(i) or ""] or nil
      local epic_chunk = we > 0 and (e and { " " .. view.pad(e.summary, we - 2) .. " ", icons.epic_hl(e.color) }
        or { string.rep(" ", we) }) or { "" }
      local indent = string.rep("  ", depth)
      -- Labels right after the summary ("#backend #hotfix"): whatever room the
      -- summary leaves, but at least a third of the column when it is tight.
      local avail = wsum - #indent
      local tags = #(i.labels or {}) > 0
        and " " .. table.concat(vim.tbl_map(function(l) return "#" .. l end, i.labels), " ") or ""
      local tw = math.min(vim.fn.strdisplaywidth(tags), math.max(math.floor(avail / 3),
        avail - vim.fn.strdisplaywidth(summary) - (i.blocked and 2 or 0)))
      -- blocked by an open issue: a red ban sign in front of the summary
      local block = i.blocked and (icons.glyph.blocked .. " ") or ""
      local bw = vim.fn.strdisplaywidth(block)
      -- No highlight on the summary: a group with a background (Normal)
      -- would cut through the cursorline.
      local lnum = b:add({
        { st.marked[i.key] and "●" or " ", "TrackerMarked" }, { indent }, { fold, "TrackerMuted" },
        { icon .. " ", icon_hl },
        { view.pad(i.key, wk), "TrackerKey" }, { " " },
        { prio .. " ", prio_hl },
        { block, "TrackerBlocked" },
        { view.pad(summary, avail - tw - bw) }, { tw > 0 and view.pad(tags, tw) or "", "TrackerLabel" }, { " " },
        epic_chunk, { " " },
        points[i.key] and { lpad(points[i.key].text, wp), points[i.key].hl }
          or { lpad(fmt_points(i.story_points), wp), type(i.story_points) == "number" and "TrackerPoints" or "TrackerMuted" },
        { "  " },
        { icons.glyph.user .. " " .. view.pad(i.assignee and i.assignee.name or "Unassigned", wa),
          i.assignee and "TrackerUser" or "TrackerMuted" }, { " " },
        { view.pad(view.status_name(i.status and i.status.name), ws), hl.status(i.status) },
      })
      st.rows[lnum] = i
      st.first_row = st.first_row or lnum
    end

    local function emit(list, depth)
      for _, node in ipairs(list) do
        row(node.issue, depth, node)
        if #node.children > 0 and not is_collapsed(node.issue.key) then emit(node.children, depth + 1) end
      end
    end

    ---Group header: fold marker, the group's name (an epic as its coloured
    ---chip), issue count and closed / total points.
    local function group_header(g)
      local folded = group_collapsed(g.id)
      local chunks = { { " " }, { (folded and icons.glyph.fold_closed or icons.glyph.fold_open) .. " ", "TrackerMuted" } }
      local none = g.value == listfilter.NONE
      if g.title then
        table.insert(chunks, { g.title, "TrackerSectionTitle" })
      elseif st.group == "epic" then
        local e = st.epics[g.value]
        if none then
          table.insert(chunks, { "No epic", "TrackerColumn" })
        elseif e then
          table.insert(chunks, { " " .. e.summary .. " ", icons.epic_hl(e.color) })
          table.insert(chunks, { "  " .. g.value, "TrackerKey" })
        else
          table.insert(chunks, { g.value, "TrackerKey" })
        end
      elseif st.group == "assignee" then
        local u = not none and g.issues[1].assignee or nil
        table.insert(chunks, { icons.glyph.user .. " " .. (u and u.name or "Unassigned"), u and "TrackerUser" or "TrackerMuted" })
      else
        local s = g.issues[1].status
        table.insert(chunks, { view.status_name(s and s.name), hl.status(s) })
      end
      local closed, total, count = listfilter.points(g.issues)
      table.insert(chunks, { ("   %d issue%s"):format(count, count == 1 and "" or "s"), "TrackerMuted" })
      if total > 0 then
        table.insert(chunks, { ("  %s/%s pts"):format(fmt_points(closed), fmt_points(total)),
          closed >= total and "TrackerStatusDone" or "TrackerPoints" })
      end
      local lnum = b:add(chunks)
      b:line_bg(lnum, "TrackerSection")
      st.group_rows[lnum] = g.id
      st.first_row = st.first_row or lnum
    end

    for n, sec in ipairs(sections) do
      if sec.group then
        if n > 1 then b:add("") end
        group_header(sec.group)
        if not group_collapsed(sec.group.id) then
          emit(sec.nodes, 0)
          if #sec.nodes == 0 then b:add({ { "    no issues", "TrackerMuted" } }) end
        end
      else
        emit(sec.nodes, 0)
      end
    end

    if st.meta and st.meta.truncated then
      b:add("")
      b:add({ { ("  … more issues match; showing the first %d (config `limit`)"):format(#st.issues), "TrackerMuted" } })
    end
    b:render(buf)
    v.title = (" %s (%d) "):format(opts.title, #st.issues)
    window.refresh_chrome(v)
  end

  local function current() return st.rows[vim.api.nvim_win_get_cursor(0)[1]] end

  ---Re-render keeping the cursor on the same issue (or group header, whose
  ---key is "group:<id>"). An issue in several sections: the row nearest to
  ---where the cursor was.
  local function rerender(target_key)
    local win = window.is_top(v) and window.win()
    local was = win and vim.api.nvim_win_get_cursor(win)[1] or 1
    if win and not target_key then
      local at = st.rows[was]
      target_key = at and at.key or (st.group_rows[was] and ("group:" .. st.group_rows[was]))
    end
    render()
    if not win then return end
    local best
    for lnum, i in pairs(st.rows) do
      if i.key == target_key and (not best or math.abs(lnum - was) < math.abs(best - was)) then best = lnum end
    end
    if best then
      pcall(vim.api.nvim_win_set_cursor, win, { best, 0 })
      return
    end
    for lnum, id in pairs(st.group_rows) do
      if "group:" .. id == target_key then
        pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
        return
      end
    end
    if st.first_row then pcall(vim.api.nvim_win_set_cursor, win, { st.first_row, 0 }) end
  end

  local function load_epics()
    local seen, keys = {}, {}
    for _, i in ipairs(st.issues) do
      local k = epic_key(i)
      if k and not seen[k] then
        seen[k] = true
        table.insert(keys, k)
      end
    end
    if #keys == 0 or not api.has("epics") then return end
    api.epics(keys, function(epics)
      if not epics or not vim.api.nvim_buf_is_valid(buf) then return end
      st.epics = epics
      rerender()
    end)
  end

  local function load()
    local had = #st.issues > 0
    if not had then view.message(buf, "Loading…") end
    opts.load(function(issues, err, meta)
      if not vim.api.nvim_buf_is_valid(buf) then return end
      if not issues then return view.message(buf, err or "error", "TrackerError") end
      st.issues, st.meta, st.details = issues, meta, {}
      rerender()
      load_epics()
    end)
  end

  local function on_issue(fn)
    return function()
      local i = current()
      if i then fn(i) end
    end
  end

  ---Marked issues in list order, else the cursor's.
  ---@return TrackerIssue[]
  local function targets()
    local out = {}
    for _, i in ipairs(st.issues) do
      if st.marked[i.key] then table.insert(out, i) end
    end
    if #out == 0 then
      local i = current()
      if i then out = { i } end
    end
    return out
  end

  local function clear_marks() st.marked = {} end

  ---p / P: re-rank the marked issues right below / above the cursor's.
  ---@param where "after"|"before"
  local function put(target, where)
    local moving = {}
    for _, i in ipairs(st.issues) do
      if st.marked[i.key] then table.insert(moving, i.key) end
    end
    if #moving == 0 then
      return require("tracker.notify").send("actions", "mark issues with m first", vim.log.levels.WARN)
    end
    if st.marked[target.key] then
      return require("tracker.notify").send("actions", "put them next to an issue that isn't marked", vim.log.levels.WARN)
    end
    api.rank(moving, { [where] = target.key }, function(ok, err)
      if not ok then return require("tracker.notify").error(err) end
      require("tracker.notify").send("actions", ("moved %s %s %s"):format(table.concat(moving, ", "),
        where == "after" and "below" or "above", target.key))
      clear_marks()
      -- Reorder in place rather than reload: Jira's search index (behind the
      -- search and the board / backlog endpoints alike) catches up with a
      -- rank only after a moment, so a reload right away shows the old order.
      if not vim.api.nvim_buf_is_valid(buf) then return end
      st.issues = reranked(st.issues, moving, target.key, where)
      rerender(moving[1])
    end)
  end

  ---j / k: issue rows and group headers only (other headers and blank lines
  ---skipped), a count works (5j), and the row is centred like the issue
  ---view's sections.
  local function row_jump(dir)
    return function()
      local lnums = vim.tbl_keys(st.rows)
      vim.list_extend(lnums, vim.tbl_keys(st.group_rows))
      if #lnums == 0 then return end
      table.sort(lnums)
      local row = vim.api.nvim_win_get_cursor(0)[1]
      for _ = 1, vim.v.count1 do
        local target
        if dir > 0 then
          for _, l in ipairs(lnums) do
            if l > row then target = l break end
          end
        else
          for n = #lnums, 1, -1 do
            if lnums[n] < row then target = lnums[n] break end
          end
        end
        if not target then break end
        row = target
      end
      if not st.rows[row] and not st.group_rows[row] then row = dir > 0 and lnums[1] or lnums[#lnums] end
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      vim.cmd("normal! zz")
    end
  end

  ---[[ / ]]: the previous / next section or group header (a count works),
  ---put at the top of the window. Inside a section `[[` goes to its own
  ---header, like Vim's section motions.
  local function section_jump(dir)
    return function()
      local lnums = vim.tbl_keys(st.group_rows)
      if #lnums == 0 then return end
      table.sort(lnums)
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local target
      for _ = 1, vim.v.count1 do
        local found
        if dir > 0 then
          for _, l in ipairs(lnums) do
            if l > row then found = l break end
          end
        else
          for n = #lnums, 1, -1 do
            if lnums[n] < row then found = lnums[n] break end
          end
        end
        if not found then break end
        row, target = found, found
      end
      if not target then return end
      vim.api.nvim_win_set_cursor(0, { target, 0 })
      vim.cmd("normal! zt")
    end
  end

  ---The fold target for the cursor row: the row itself if it has children,
  ---else its parent row.
  ---What <Tab> folds: a group header, the row's own sub-list, or its parent's.
  local function fold_target()
    local gid = st.group_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if gid then return "group:" .. gid end
    local i = current()
    if not i then return nil end
    if st.has_children[i.key] then return i.key end
    if i.parent and st.has_children[i.parent.key] then return i.parent.key end
    return nil
  end

  local function folded(key)
    if key:sub(1, 6) == "group:" then return st.collapsed[key] == true end
    return is_collapsed(key)
  end

  local function set_fold(state)
    return function()
      local key = fold_target()
      if not key then return end
      if state == nil then st.collapsed[key] = not folded(key) else st.collapsed[key] = state end
      rerender(key)
    end
  end

  local function fold_all(state)
    return function()
      for key in pairs(st.has_children) do st.collapsed[key] = state end
      for _, id in pairs(st.group_rows) do st.collapsed["group:" .. id] = state end
      rerender()
    end
  end

  -- region Quick filters (f) and grouping (F)

  local function filter_category(cat)
    local items = listfilter.candidates(st.issues, cat.id, st.filters, st.epics)
    if #items == 0 then
      return require("tracker.notify").send("actions", "nothing to filter by", vim.log.levels.WARN)
    end
    require("tracker.ui.multiselect").open(items, { prompt = "Filter: " .. cat.label }, function(values)
      if not values then return end
      local set = {}
      for _, val in ipairs(values) do set[val] = true end
      st.filters[cat.id] = next(set) and set or nil
      rerender()
    end)
  end

  ---"Open a whole epic": every issue of an epic (sub-tasks included) in a
  ---new list.
  local function open_epic()
    local project = st.issues[1] and st.issues[1].key:match("^(.-)%-%d+$") or nil
    api.epic_list(project, function(epics, err)
      if not epics then return require("tracker.notify").error(err) end
      -- epics of this list first (in list order), then the project's others
      local seen, items = {}, {}
      for _, c in ipairs(listfilter.candidates(st.issues, "epic", {}, st.epics)) do
        local e = st.epics[c.value]
        if e then
          seen[c.value] = true
          table.insert(items, e)
        end
      end
      for _, e in ipairs(epics) do
        if not seen[e.key] then table.insert(items, e) end
      end
      vim.ui.select(items, {
        prompt = "Open epic",
        format_item = function(e) return e.key .. "  " .. e.summary end,
      }, function(e)
        if not e then return end
        M.open({
          title = e.key .. " " .. e.summary,
          subtitle = "parent = " .. e.key,
          load = function(cb)
            api.search(("parent = %s ORDER BY Rank ASC"):format(e.key), function(issues, serr, meta)
              if not issues then return cb(nil, serr) end
              api.with_children(issues, function(all) cb(all, nil, meta) end)
            end)
          end,
        })
      end)
    end)
  end

  local function filter_menu()
    local items = {}
    if listfilter.active(st.filters) then
      table.insert(items, { label = "Clear filters", clear = true })
    end
    for _, cat in ipairs(listfilter.CATEGORIES) do
      local set = st.filters[cat.id]
      local n = set and vim.tbl_count(set) or 0
      table.insert(items, { label = cat.label .. "…" .. (n > 0 and ("  (" .. n .. ")") or ""), cat = cat })
    end
    table.insert(items, { label = "Open a whole epic…", epic = true })
    vim.ui.select(items, { prompt = "Filter", format_item = function(i) return i.label end }, function(choice)
      if not choice then return end
      if choice.clear then
        st.filters = {}
        rerender()
      elseif choice.epic then
        open_epic()
      else
        filter_category(choice.cat)
      end
    end)
  end

  local function group_menu()
    local items = { { label = "No grouping", id = false } }
    for _, g in ipairs(listfilter.GROUPINGS) do
      table.insert(items, { label = "By " .. g.label:lower() .. (st.group == g.id and "  (current)" or ""), id = g.id })
    end
    vim.ui.select(items, { prompt = "Group", format_item = function(i) return i.label end }, function(choice)
      if not choice then return end
      st.group = choice.id or nil
      rerender()
    end)
  end

  -- endregion

  view.map(buf, opts.title, {
    { { "<CR>", "l" }, on_issue(function(i) require("tracker.ui.issue").open(i.key) end), desc = "open issue (detail view)" },
    { "j", row_jump(1), desc = "next issue (centred)" },
    { "k", row_jump(-1), desc = "previous issue (centred)" },
    { "]]", section_jump(1), desc = "next section / group header" },
    { "[[", section_jump(-1), desc = "previous section / group header (inside one: its own)" },
    { "K", on_issue(function(i) require("tracker.ui.preview").toggle(i, st.details) end), desc = "preview (description, details)" },
    { { "<Tab>", "za" }, set_fold(nil), desc = "fold / unfold sub-tasks" },
    { "zo", set_fold(false), desc = "unfold sub-tasks" },
    { "zc", set_fold(true), desc = "fold sub-tasks" },
    { "zR", fold_all(false), desc = "unfold all" },
    { "zM", fold_all(true), desc = "fold all" },
    { "f", filter_menu, desc = "quick filters (epic, assignee, type, status, label), open a whole epic" },
    { "F", group_menu, desc = "group by epic / assignee / status (or none)" },
    { "e", on_issue(function(i) require("tracker.ui.fields").summary(i, load) end), desc = "edit the summary (title)" },
    { "E", on_issue(function(i) require("tracker.ui.fields").menu(i, load) end),
      desc = "edit a field: pick summary, description, status, assignee, priority, points, epic, labels, reporter" },
    { "S", on_issue(function(i) require("tracker.ui.fields").edit(i, "points", load) end), desc = "edit story points" },
    { "L", on_issue(function(i) require("tracker.ui.fields").edit(i, "labels", load) end), desc = "edit labels" },
    { "m", on_issue(function(i)
        st.marked[i.key] = not st.marked[i.key] or nil
        rerender(i.key)
      end), desc = "mark / unmark the issue (then p / P, M, d, D act on the marked ones)" },
    { "p", on_issue(function(i) put(i, "after") end), desc = "put the marked issues below the cursor's (rank)" },
    { "P", on_issue(function(i) put(i, "before") end), desc = "put the marked issues above the cursor's (rank)" },
    { "M", function()
        local t = targets()
        if #t > 0 then plan.move(t, st.issues, function() clear_marks() load() end) end
      end, desc = "move the marked / cursor issue: sprint, backlog, epic, parent" },
    { "d", function()
        local t = targets()
        if #t > 0 then plan.archive(t, function() clear_marks() load() end) end
      end, desc = "archive the marked / cursor issue (asks first)" },
    { "D", function()
        local t = targets()
        if #t > 0 then plan.delete(t, function() clear_marks() load() end) end
      end, desc = "DELETE the marked / cursor issue (asks first)" },
    -- filters first: search, mark the hits, <Esc> — the marks stay for p / M
    { "<Esc>", function()
        if st.filter then
          st.filter = nil
          rerender()
        elseif listfilter.active(st.filters) then
          st.filters = {}
          rerender()
        elseif next(st.marked) then
          clear_marks()
          rerender()
        else
          window.pop()
        end
      end, desc = "clear the / filter, then the quick filters (f), then the marks; without any: back" },
    { "s", on_issue(function(i) actions.transition(i.key, load) end), desc = "change status" },
    { "a", on_issue(function(i) actions.assign(i.key, load) end), desc = "assign" },
    { "A", on_issue(function(i) actions.toggle_me(i, load) end), desc = "assign to me / unassign me (toggle)" },
    { "c", on_issue(function(i) actions.comment(i.key) end), desc = "add comment" },
    { "n", function()
        actions.create(nil, function(issue) require("tracker.ui.issue").open(issue.key) end)
      end, desc = "new issue" },
    { "gb", on_issue(function(i) require("tracker.ui.branch").create(i, load) end),
      desc = "the issue's branch: check out + pull (local / origin), else create (+ MR, see git.create)" },
    { "gr", on_issue(function(i) require("tracker.ui.branch").review(i) end), desc = "review the issue's branch (review.nvim)" },
    { "gc", on_issue(function(i) require("tracker.ui.branch").cicd(i) end), desc = "pipelines of the issue's branch (cicd.nvim)" },
    { "gv", on_issue(function(i) require("tracker.ui.branch").verify(i, load) end),
      desc = "hand over for verification: merge (git.verify.merge), status, unassign, comment draft" },
    { "U", on_issue(function(i) actions.upload(i.key, function() load() end) end),
      desc = "upload files to the issue (yazi / ui.file_chooser)" },
    { "C", on_issue(function(i)
        actions.clone(i, function(res) require("tracker.ui.issue").open(res.key) end)
      end), desc = "clone: summary in a popup; fields, description, sub-tasks, a \"clones\" link" },
    { { "o", "gx" }, on_issue(function(i) actions.web(i.key) end), desc = "open in browser" },
    { "y", on_issue(function(i) actions.copy(i.key) end), desc = "copy key" },
    { "Y", on_issue(function(i) actions.copy(i.url) end), desc = "copy URL" },
    { "/", function()
        vim.ui.input({ prompt = "Filter: ", default = st.filter or "" }, function(text)
          if text == nil then return end
          st.filter = text ~= "" and text:lower() or nil
          rerender()
        end)
      end, desc = "filter (key, summary, status, assignee, type, epic, labels)" },
    { "J", function()
        M.pick_query(function(query) M.search(query, true) end)
      end, desc = "switch query / enter JQL" },
    { "r", load, desc = "refresh" },
  })

  -- Coming back from an issue view: the issue may have changed there.
  v.on_return = load
  v.on_resize = function() rerender() end

  if replace and window.top() then window.replace(v) else window.push(v) end
  load()
end

---What a saved query lists, in a few words.
---@param q TrackerQuery
local function describe(q)
  if q.sections then return table.concat(q.sections, " + ") end
  if q.sprints then return "active sprints of each board" end
  if q.backlogs then return "backlog of each board" end
  if q.backlog then return "board backlog" end
  if q.sprint then return "board active sprint" end
  return q.jql
end

---Pick a saved query, or type one.
---@param cb fun(query: string)
function M.pick_query(cb)
  local items = api.queries({ all_boards = true })
  table.insert(items, { name = "Custom query…", custom = true })
  vim.ui.select(items, {
    prompt = "Query",
    format_item = function(q)
      if q.custom then return q.name end
      return q.name .. "  —  " .. describe(q)
    end,
  }, function(q)
    if not q then return end
    if not q.custom then return cb(q.name) end
    vim.ui.input({ prompt = "JQL: " }, function(text)
      if text and vim.trim(text) ~= "" then cb(vim.trim(text)) end
    end)
  end)
end

---List view for a saved query name or raw query.
---@param query string|nil  nil = the default query
---@param replace boolean|nil
function M.search(query, replace)
  local q, label, entry = api.resolve_query(query)
  if not entry then
    return require("tracker.notify").error("tracker: no query given and no saved queries configured")
  end
  local info = api.provider_info({ board_name = entry.board_name })
  M.open({
    title = label == q and "Search" or label,
    subtitle = (entry.backlog or entry.sprint)
      and ("board " .. (entry.sprint and "active sprint" or "backlog") .. (info and info.project and (" — " .. info.project) or ""))
      or q or describe(entry),
    query = q,
    -- By name, so the saved entry's options (sprint, backlog, children) apply.
    load = function(cb) api.search(entry.name, cb) end,
  }, replace)
end

return M
