-- Provider registry.
--
-- Each provider module (providers/<name>/init.lua) conforms to one interface.
-- Every function takes the resolved provider config (`pcfg`, see
-- config.provider) first and finishes through `cb(result, err)`, always on the
-- main loop. Text in and out is Markdown (see tracker.model).
--
--   provider.name, provider.defaults
--   provider.capabilities          set of feature flags, see CAPABILITIES
--   provider.web_url(pcfg, key)                         → string (sync)
--   provider.myself(pcfg, cb)                           → TrackerUser
--   provider.search(pcfg, query, opts, cb)              → TrackerIssue[], meta
--   provider.get_issue(pcfg, key, cb)                   → TrackerIssue (+description)
--   provider.get_comments(pcfg, key, cb)                → TrackerComment[]
--   provider.add_comment(pcfg, key, markdown, cb)       → TrackerComment
--   provider.edit_comment(pcfg, key, id, markdown, cb)  → TrackerComment
--   provider.delete_comment(pcfg, key, id, cb)          → true
--   provider.clone_issue(pcfg, key, { summary, link?, subtasks? }, cb)
--       → { id, key, url, subtasks = keys, dropped = refused field names, failed = sub-task errors }
--   provider.upload_attachments(pcfg, key, paths, cb)   → TrackerAttachment[] (paths' order)
--   provider.delete_attachment(pcfg, key, id, cb)       → true
--       Markdown sent to add_comment / edit_comment / update_issue (description)
--       / create_issue may hold `![name](upload:<path>)` / `[attachment: name](upload:<path>)`
--       lines (also after a panel's / quote's `> `): the provider uploads those files and
--       embeds them (image inline / file card).
--   provider.add_remote_link(pcfg, key, { url, title }, cb) → true (a web link)
--   provider.link_types(pcfg, cb)                       → { id, name, inward, outward }[]
--   provider.add_link(pcfg, key, { type, direction = "outward"|"inward", key }, cb) → true
--   provider.delete_link(pcfg, key, link_id, cb)        → true (`key`: the issue the link was read from)
--   provider.get_transitions(pcfg, key, cb)             → TrackerTransition[]
--   provider.transition(pcfg, key, transition_id, cb)   → true
--   provider.assignable_users(pcfg, key, text, cb)      → TrackerUser[]
--   provider.assign(pcfg, key, user_id|nil, cb)         → true
--   provider.update_issue(pcfg, key, fields, cb)        → true
--       fields = { summary?, description? (Markdown), priority_id?, story_points?
--                  (false clears), labels?, parent? (epic key, false clears), reporter_id?,
--                  start_date? / due_date? ("YYYY-MM-DD", false clears) }
--   provider.priorities(pcfg, cb)                       → { { id, name } }
--   provider.epic_list(pcfg, project, cb)               → TrackerEpic[] (open epics)
--   provider.epic_issues(pcfg, project, { done_days? }, cb) → TrackerIssue[] (epics, rank order; timeline)
--   provider.issue_types(pcfg, project, cb)             → TrackerIssueType[]
--   provider.create_issue(pcfg, fields, cb)             → { id, key, url }
--       fields = { project, type_id, summary, description?, parent? }
--   provider.boards(pcfg, project, cb)                  → TrackerBoard[]
--   provider.board_columns(pcfg, board_id, cb)          → TrackerColumn[]
--   provider.active_sprints(pcfg, board_id, cb)         → TrackerSprint[]
--   provider.board_issues(pcfg, board_id, sprint_id|nil, cb) → TrackerIssue[]
--   provider.backlog(pcfg, board_id, cb)                → TrackerIssue[]
--   provider.download_attachment(pcfg, attachment, path, cb) → path
--       attachment = TrackerAttachment, or { url } for external media
--   provider.epics(pcfg, keys, cb)                      → { [key] = TrackerEpic }
--   provider.children(pcfg, keys, cb)                   → TrackerIssue[] whose parent is in keys
--   provider.rank(pcfg, keys, { after = key } | { before = key }, cb) → true
--   provider.open_sprints(pcfg, board_id, cb)           → TrackerSprint[] (active + future)
--   provider.move_to_sprint(pcfg, sprint_id, keys, cb)  → true
--   provider.move_to_backlog(pcfg, keys, cb)            → true
--   provider.sprints(pcfg, board_id, cb)                → TrackerSprint[] (every state, board order)
--   provider.create_sprint(pcfg, board_id, fields, cb)  → TrackerSprint (fields = TrackerSprintFields)
--   provider.update_sprint(pcfg, sprint_id, fields, cb) → TrackerSprint (state "active" / "closed" starts / completes)
--   provider.archive(pcfg, keys, cb)                    → true
--   provider.delete_issue(pcfg, key, with_subtasks, cb) → true
--
-- A provider leaves out what its tracker can't do and says so in
-- `capabilities`; the API refuses those calls with a clear error and the UI
-- hides the matching keys.
--
-- Optional members:
--   provider.label                  display name ("Jira"); default: the instance name
--   provider.query_label            what a raw query is called in prompts ("JQL", "Filter")
--   provider.capabilities           may be `fun(pcfg) → set` when it depends on the
--                                   instance (a licence tier, a project setting)
--   provider.prepare(pcfg, cb)      learn what `capabilities(pcfg)` needs (one probe,
--                                   cached by the provider); cb() when ready
--   provider.keys                   issue-key rules that differ from `ABC-123`, see tracker.keys
--   provider.search_text(pcfg, text, { limit, project? }, cb) → TrackerIssue[]
--       free-text search (the link picker); without it the text goes to `search`
--   provider.mention(pcfg, user)    → Markdown that mentions `user` in a comment
--   provider.detect(pcfg, repo)     → binding|nil   whether the repository `repo`
--       ({ root, host, path }, from its git remote) lives on this instance, and what
--       it adds to the config there (e.g. { project = "group/app" })
--
-- An INSTANCE is one entry of `providers` in setup(); its `type` (default:
-- its name) picks the module, so `work = { type = "gitlab", … }` is a second
-- GitLab. Config, credentials, caches and `issue.provider` go by the
-- instance name (`pcfg.name`).

local M = {}

M.CAPABILITIES = {
  "comments", "edit_comments", "transitions", "assign", "edit", "create",
  "subtasks", "boards", "sprints", "backlog", "attachments", "epics", "children",
  "priority", "story_points", "labels", "epic_link", "reporter",
  "rank", "sprint_move", "sprint_manage", "archive", "delete", "dates", "timeline",
  "delete_comments", "clone", "links", "upload", "remote_links",
}

local REGISTRY = {
  jira = "tracker.providers.jira",
  gitlab = "tracker.providers.gitlab",
}
-- Types in the order they were registered: the default order of instances
-- (and so of the provider tabs).
local ORDER = { "jira", "gitlab" }

---The provider type of an instance: its `type`, else its own name.
---@param name string  instance name
---@return string
function M.type_of(name)
  local p = require("tracker.config").get().providers[name]
  return (type(p) == "table" and p.type) or name
end

---@param name string  instance name (or a type)
---@return table provider module
function M.get(name)
  local mod = REGISTRY[M.type_of(name)]
  if not mod then
    error("tracker: unknown provider: " .. tostring(name))
  end
  return require(mod)
end

---Register an out-of-tree provider: `require("tracker.providers").register(
---"youtrack", "my.youtrack.provider")`. The module must follow the interface
---above.
---@param name string
---@param module_path string
function M.register(name, module_path)
  if not REGISTRY[name] then table.insert(ORDER, name) end
  REGISTRY[name] = module_path
end

---@return string[] names of every registered provider type
function M.names()
  local out = vim.tbl_keys(REGISTRY)
  table.sort(out)
  return out
end

---The capability set of a provider for one instance config.
---@param mod table   provider module
---@param pcfg table  resolved provider config
---@return table<string, boolean>
function M.capabilities(mod, pcfg)
  local caps = mod.capabilities
  if type(caps) == "function" then caps = caps(pcfg) end
  return caps or {}
end

---@return string[] instances that have a `base_url` in the user config, by
---  the registration order of their type, then by name
function M.configured()
  local cfg = require("tracker.config").get()
  local rank = {}
  for n, t in ipairs(ORDER) do rank[t] = n end
  local out = {}
  for name, p in pairs(cfg.providers) do
    if type(p) == "table" and p.base_url and p.base_url ~= "" and rank[p.type or name] then
      table.insert(out, name)
    end
  end
  table.sort(out, function(a, b)
    local ra, rb = rank[M.type_of(a)], rank[M.type_of(b)]
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return out
end

return M
