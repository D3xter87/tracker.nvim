-- Highlight groups. All are `default` links, so a colorscheme or the user can
-- override any of them; re-applied on ColorScheme because `:hi clear` drops
-- default links.

local M = {}

local LINKS = {
  TrackerKey = "Identifier",
  TrackerTitle = "Title",
  TrackerMuted = "Comment",
  TrackerLabel = "Special",
  TrackerUser = "Constant",
  TrackerType = "Type",
  TrackerField = "Label",
  TrackerStatusTodo = "Comment",
  TrackerStatusProgress = "DiagnosticWarn",
  TrackerStatusDone = "DiagnosticOk",
  TrackerColumn = "Title",
  TrackerSection = "Folded",          -- lists: a section / group header's band
  TrackerSectionTitle = "Title",      -- lists: a section's name
  TrackerSeparator = "FloatBorder",
  TrackerError = "ErrorMsg",
  TrackerFilter = "Search",
  TrackerPoints = "Number",
  TrackerPointsOver = "DiagnosticWarn",
  TrackerMarked = "DiagnosticWarn",
  TrackerToday = "DiagnosticError",   -- timeline: today's column
  TrackerBlocked = "DiagnosticError", -- the "blocked" icon in lists / on cards
  TrackerBarDerived = "NonText",      -- timeline: bar taken from sprints / children
  TrackerWeekend = "CursorLine",      -- timeline (days scale): Sat / Sun header
}

local STATUS = {
  todo = "TrackerStatusTodo",
  in_progress = "TrackerStatusProgress",
  done = "TrackerStatusDone",
}

---@param status TrackerStatus|nil
---@return string
function M.status(status)
  return STATUS[status and status.category or "todo"] or STATUS.todo
end

local done = false

function M.setup()
  for group, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  require("tracker.ui.icons").setup_highlights()
  if done then return end
  done = true
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("TrackerHighlights", { clear = true }),
    callback = M.setup,
  })
  -- Issue and editor buffers are Markdown to treesitter (and to
  -- render-markdown, if its file_types include them) without being
  -- `filetype=markdown`, so markdown LSPs / ftplugins stay out.
  pcall(vim.treesitter.language.register, "markdown", { "tracker_issue", "tracker_edit" })
end

return M
