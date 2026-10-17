-- Normalized shapes every provider maps into and every consumer (UI, API
-- callers, other plugins) reads. Text fields are Markdown regardless of the
-- tracker's native format — conversion is the provider's job.
--
-- Fields marked `?` may be nil. Timestamps are kept as the provider sent them
-- (ISO 8601); use `M.short_time` for display.

---@alias TrackerStatusCategory "todo"|"in_progress"|"done"

---@class TrackerUser
---@field id string        provider user id (Jira: accountId)
---@field name string      display name
---@field email string?

---@class TrackerStatus
---@field id string?
---@field name string
---@field category TrackerStatusCategory

---@class TrackerIssueType
---@field id string
---@field name string             localized ("Zadanie", "Podzadanie", ...)
---@field subtask boolean
---@field level integer           hierarchy: 1 epic, 0 standard, -1 sub-task

---@class TrackerEpic
---@field key string
---@field summary string
---@field color integer|nil       Jira's epic colour index 1..14 (ghx-label-N)

---@class TrackerIssueRef      parent / sub-task / linked issue
---@field key string
---@field summary string
---@field status TrackerStatus?
---@field type TrackerIssueType?

---@class TrackerLink          read from the issue's side
---@field id string
---@field type string               link type name ("Blocks")
---@field direction "outward"|"inward"
---@field label string              "blocks" / "is blocked by"
---@field issue TrackerIssueRef     the other issue

---@class TrackerAttachment
---@field id string
---@field filename string
---@field mime string|nil
---@field size integer|nil       bytes
---@field created string|nil
---@field author TrackerUser|nil

---@class TrackerIssue
---@field provider string
---@field id string
---@field key string
---@field summary string
---@field url string
---@field status TrackerStatus?
---@field type TrackerIssueType?
---@field priority string?
---@field priority_id string?      "1" highest … "5" lowest on default schemes
---@field assignee TrackerUser?
---@field reporter TrackerUser?
---@field labels string[]
---@field story_points number?
---@field start_date string?        "YYYY-MM-DD" (the timeline's start)
---@field due_date string?          "YYYY-MM-DD"
---@field sprints TrackerSprint[]?  every sprint the issue was / is in
---@field links TrackerLink[]?
---@field blocked boolean?          an open issue blocks it ("is blocked by")
---@field parent TrackerIssueRef?
---@field subtasks TrackerIssueRef[]
---@field created string?
---@field updated string?
---@field description string?      Markdown; only set by get_issue
---@field lossy string[]?          native elements the Markdown form drops
---@field attachments TrackerAttachment[]?  only set by get_issue (files on
---                                the issue, comment images included)

---@class TrackerComment
---@field id string
---@field author TrackerUser?
---@field body string              Markdown
---@field lossy string[]?
---@field created string?
---@field updated string?

---@class TrackerTransition
---@field id string
---@field name string
---@field to TrackerStatus?

---@class TrackerBoard
---@field id string
---@field name string
---@field type string?             "scrum"|"kanban"|...

---@class TrackerSprint
---@field id string
---@field name string
---@field state string?            "active" | "future" | "closed"
---@field goal string?
---@field start_date string?       ISO timestamp
---@field end_date string?
---@field complete_date string?    closed sprints
---@field board_id string?         the board the sprint was created on

---@class TrackerSprintFields    create / update a sprint
---@field name string?
---@field goal string?
---@field start_date string|false|nil   ISO; false clears
---@field end_date string|false|nil
---@field state string?                  "active" starts, "closed" completes

---@class TrackerColumn
---@field name string
---@field statuses string[]        status ids shown in this column

local M = {}

---"2026-10-16T09:12:33.123+0200" → "2026-10-16 09:12"
---@param ts string|nil
---@return string
function M.short_time(ts)
  if type(ts) ~= "string" or #ts < 16 then return ts or "" end
  return ts:sub(1, 10) .. " " .. ts:sub(12, 16)
end

---"2026-10-16T..." → "2026-10-16"
---@param ts string|nil
---@return string
function M.short_date(ts)
  if type(ts) ~= "string" then return "" end
  return ts:sub(1, 10)
end

return M
