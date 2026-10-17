-- GitLab's raw query: a filter line, turned into parameters of the Issues
-- API.
--
--   assignee=@me state=opened labels=bug,ui order=updated_at login form
--
-- `key=value` pairs separated by blanks (quote a value with blanks:
-- milestone="Release 2"); words without a key are the text search.
--
--   assignee   @me | none | any | <username>
--   author     @me | <username>
--   state      opened (default) | closed | all
--   labels     a,b (all of them) | none | any
--   milestone  <title> | none | any
--   iteration  <id> | none | any | current        (Premium)
--   epic       <id> | none | any                  (Premium)
--   weight     <n> | none | any                   (Premium)
--   type       issue | incident | test_case | task
--   search     text (same as bare words);  in = title | description | title,description
--   order      created_at | updated_at | priority | due_date | relative_position
--              | label_priority | milestone_due | popularity | weight
--   sort       asc | desc
--   iids       1,2,3
--   not.<key>  the opposite: not.labels=wontfix, not.assignee=<username>
--   project    another project's path;  group = a group's path (its issues)
--
-- Any other `key=value` goes to the API as it is.

local M = {}

---Split a filter line into words; quotes keep blanks together.
---@param text string
---@return string[]
local function words(text)
  local out, cur, quote = {}, {}, nil
  local function flush()
    if #cur > 0 then
      table.insert(out, table.concat(cur))
      cur = {}
    end
  end
  for c in text:gmatch(".") do
    if quote then
      if c == quote then quote = nil else table.insert(cur, c) end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c:match("%s") then
      flush()
    else
      table.insert(cur, c)
    end
  end
  flush()
  return out
end

local WILD = { none = "None", any = "Any" }

---One `key=value` as API parameters (into `p`).
local function apply(p, key, value, negated)
  local function set(k, v)
    if negated then p["not[" .. k .. "]"] = v else p[k] = v end
  end
  local low = value:lower()
  if key == "assignee" then
    if low == "@me" and not negated then
      p.scope = "assigned_to_me"
    elseif WILD[low] then
      set("assignee_id", WILD[low])
    else
      set("assignee_username", (value:gsub("^@", "")))
    end
  elseif key == "author" then
    if low == "@me" and not negated then p.scope = "created_by_me" else set("author_username", (value:gsub("^@", ""))) end
  elseif key == "state" then
    if low ~= "all" then p.state = low else p.state = nil end
    p._state = true
  elseif key == "labels" or key == "label" then
    set("labels", WILD[low] or value)
  elseif key == "milestone" then
    set("milestone", WILD[low] or value)
  elseif key == "iteration" then
    set("iteration_id", WILD[low] or (low == "current" and "Current") or value)
  elseif key == "epic" then
    set("epic_id", WILD[low] or value)
  elseif key == "weight" then
    set("weight", WILD[low] or value)
  elseif key == "type" then
    set("issue_type", low)
  elseif key == "order" then
    p.order_by = low
  elseif key == "iids" then
    local list = {}
    for n in value:gmatch("%d+") do table.insert(list, n) end
    set("iids[]", list)
  else
    set(key, value)
  end
end

---@class TrackerGitlabQuery
---@field params table        Issues API parameters
---@field project string|nil  another project's path
---@field group string|nil    a group's path: its issues

---@param text string|nil
---@return TrackerGitlabQuery
function M.parse(text)
  local p, out, search = {}, {}, {}
  for _, word in ipairs(words(text or "")) do
    local key, value = word:match("^([%w_.%[%]]+)=(.*)$")
    if not key then
      table.insert(search, word)
    else
      local negated = key:match("^not%.(.+)$")
      key = (negated or key):lower()
      if key == "project" then
        out.project = value
      elseif key == "group" then
        out.group = value
      elseif key == "search" then
        table.insert(search, value)
      elseif value ~= "" then
        apply(p, key, value, negated ~= nil)
      end
    end
  end
  if #search > 0 then p.search = table.concat(search, " ") end
  -- open issues unless the filter says otherwise
  if not p._state then p.state = "opened" end
  p._state = nil
  out.params = p
  return out
end

return M
