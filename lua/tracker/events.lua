-- `User` autocmds — the integration surface for other plugins and configs.
--
-- Every mutation that goes through `tracker.api` (and therefore every UI
-- action, since the UI only talks to the API) announces itself here, so a
-- consumer never has to poll:
--
--   vim.api.nvim_create_autocmd("User", {
--     pattern = "TrackerTransitioned",
--     callback = function(ev) print(ev.data.key, ev.data.status.name) end,
--   })
--
-- All events carry `data.provider` and `data.key`; extra fields are listed in
-- |tracker-events|.

local M = {}

M.ISSUE_UPDATED = "TrackerIssueUpdated"   -- + fields (table of changed field names)
M.TRANSITIONED = "TrackerTransitioned"    -- + transition, status
M.ASSIGNED = "TrackerAssigned"            -- + assignee (user|nil)
M.COMMENT_ADDED = "TrackerCommentAdded"   -- + comment
M.COMMENT_EDITED = "TrackerCommentEdited" -- + comment
M.COMMENT_DELETED = "TrackerCommentDeleted" -- + comment_id
M.LINKED = "TrackerLinked"                -- + link ({ type, direction, key })
M.UNLINKED = "TrackerUnlinked"            -- + link_id
M.ATTACHED = "TrackerAttached"            -- + attachments (TrackerAttachment[])
M.ATTACHMENT_DELETED = "TrackerAttachmentDeleted" -- + attachment_id
M.BRANCH_CREATED = "TrackerBranchCreated" -- + branch, root (repo), mr_url (or nil)
M.VERIFIED = "TrackerVerified"           -- + branch, target, hash (handed over), root (repo)
M.ISSUE_CREATED = "TrackerIssueCreated"   -- + issue ({ id, key, url })
M.STATUS_CHANGED = "TrackerStatusChanged" -- + entry (see |tracker-status|)
M.RANKED = "TrackerRanked"                -- keys (data.key = first), after | before
M.MOVED = "TrackerMoved"                  -- keys, sprint (TrackerSprint) | backlog = true
M.ARCHIVED = "TrackerArchived"            -- keys
M.DELETED = "TrackerDeleted"              -- with_subtasks
-- Sprint events carry `data.sprint` (TrackerSprint) instead of a key.
M.SPRINT_CREATED = "TrackerSprintCreated"
M.SPRINT_UPDATED = "TrackerSprintUpdated"
M.SPRINT_STARTED = "TrackerSprintStarted"
M.SPRINT_COMPLETED = "TrackerSprintCompleted" -- + moved (keys), target (TrackerSprint|nil)

---@param name string  one of the constants above
---@param data table
function M.emit(name, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = name, modeline = false, data = data })
end

return M
