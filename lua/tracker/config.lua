-- Plugin configuration. Defaults carry NO site data: base URLs, projects,
-- boards and queries all come from the user's setup() — see |tracker-config|.

local M = {}

local defaults = {
  -- Provider used when a call doesn't name one. nil = the first configured
  -- provider (alphabetical), which is the only one in a single-tracker setup.
  default_provider = nil,
  -- Per-provider options, merged over the provider module's own defaults.
  -- A provider counts as configured once its table has a `base_url`.
  providers = {
    -- jira = {
    --   base_url = "https://<site>.atlassian.net",
    --   project = "ABC",
    --   queries = { { name = "sprint", jql = "project = {project} AND sprint in openSprints()" } },
    --   -- several boards, and which ones a git repository uses (main first)
    --   boards = { ABC = { board = 12 }, XYZ = { project = "XYZ", board = 34 } },
    --   repos = { ["my-repo"] = { "ABC", "XYZ" } },
    -- },
  },
  -- Lua pattern for an issue key inside a branch name. The branch is
  -- upper-cased first, so `abc-123-fix` yields ABC-123.
  issue_key_pattern = "%u[%u%d]+%-%d+",
  -- Maximum issues fetched for one list view (paged under the hood).
  limit = 200,
  ui = {
    -- Where views open: "float" (centred, width / height below), "split" /
    -- "vsplit" (next to the current window, as 'splitbelow' / 'splitright'
    -- say) or "tab" (a new tab page).
    layout = "float",
    -- The view under the current branch's issue when open() gets no key
    -- (:Tracker on abc-123-fix), so back from the issue lands there, on its
    -- card / row: "board" (the issue's board), "search" (the default query,
    -- as search() with none) or false (just the issue).
    issue_base = "board",
    width = 0.85,   -- fraction of the editor (float)
    height = 0.8,
    border = "rounded",
    -- After a view scrolled (j / k between sections and rows, <C-d>, the
    -- wheel): "window" draws the whole window afresh instead of moving the
    -- rows on screen (no doubled / missing rows under wrapped text, conceal
    -- or images); "full" clears the screen too (`:redraw!`) — needed where
    -- the terminal loses cells while rows move: tmux on Windows drops
    -- single characters from the middle of lines. "auto" = "full" inside
    -- tmux on Windows, "window" elsewhere; false leaves it to Neovim.
    redraw = "auto",
    board_min_column = 22, -- board column width floor (chars)
    -- Inline images (snacks.nvim): "auto" = when snacks is installed and the
    -- terminal supports Kitty graphics; true = skip the terminal check; false.
    images = "auto",
    image_max_height = 20, -- rows
    -- Lists: sub-tasks start unfolded under their parent (<Tab> toggles).
    expand_subtasks = true,
    -- Overrides: icons.types[<type name lower-cased>] = { glyph, hl_group },
    -- icons.epic_colors = { 14 hex colours for ghx-label-1..14 }.
    icons = {},
    -- false: drop leading emoji / symbols from status and column names
    -- (ZWJ emoji have no agreed width, so columns can drift).
    status_icons = true,
    -- Lists: "fit" = the summary column only as wide as the longest summary
    -- (right-hand columns follow the text); "fill" = up to the window edge.
    list_width = "fit",
    -- Picking files to upload: a command run in a floating terminal that
    -- writes the chosen paths, one per line, to {file}. nil = yazi when it
    -- is installed, else a path prompt.
    file_chooser = nil, -- e.g. { "yazi", "--chooser-file={file}" }
    -- Pasting an image from the clipboard (<C-v> in the editor): a command
    -- that writes the clipboard's image as PNG to {path} and exits non-zero
    -- when there is none. nil = a built-in one for the platform (PowerShell
    -- on Windows, wl-paste / xclip on Linux, pngpaste on macOS).
    paste_image = nil,
  },
  -- Git work on an issue (gb gr gc gv), in the repository of Neovim's cwd;
  -- see |tracker-git|. Commands are lists with {placeholders} expanded.
  git = {
    -- Per repository: any of the options below, over these ones. A key
    -- without a slash is the repository's directory name, one with a slash
    -- its path: repos = { panel = { verify = { … } } }.
    repos = nil,
    remote = "origin",
    -- Run before looking for an issue's branch ({remote}); false = none.
    fetch = { "git", "fetch", "--prune", "{remote}" },
    -- Branch name: {key} (ABC-12), {key_lower} (abc-12), {slug} (the summary
    -- in ascii-dashes, ≤ 40 chars), {type} (bug / story / task / …).
    branch = "{key_lower}",
    -- `gb` when the issue has a branch (any with its key, here or on the
    -- remote): check it out ({branch}, without "<remote>/"), then pull it
    -- when it is on the remote (false = no pull).
    checkout = { "git", "switch", "{branch}" },
    pull = { "git", "pull" },
    -- `gb` when it has none: what creates it, {branch} {key} {summary}
    -- {milestone} expanded — e.g. a script that also pushes and opens a
    -- merge request.
    create = { "git", "switch", "-c", "{branch}" },
    env = nil,       -- extra environment for `create`, e.g. { DEBUG = "true" }
    -- Run `create` in a floating terminal, for a script that asks something
    -- (a milestone menu); false = in the background.
    terminal = false,
    -- {milestone}: a string, or function(issue) → string. nil = "".
    milestone = nil,
    -- After `create` succeeded:
    assign_me = true,  -- an unassigned issue goes to you
    -- status (or transition) name(s) to move a still-to-do issue to; a list:
    -- the first one its workflow offers from where it is
    transition = nil,
    -- A merge-request URL in the command's output (…/merge_requests/123)
    -- becomes a web link on the issue.
    mr_link = true,
    -- `gr` / `gc`: function(branch, issue) opening a review / the pipelines
    -- of the issue's branch; false = off.
    review = function(branch) require("review").open({ branch = branch }) end,
    cicd = function(branch) require("cicd").open_pipeline_browser({ branch = branch }) end,
    -- The remote's web address; nil = from its URL (ssh → https).
    web_url = nil,
    -- {commit_url}: a string ({web_url} {hash}) or function(web_url, hash).
    commit_url = function(web_url, hash)
      return web_url .. (web_url:find("^https://github%.com/") and "/commit/" or "/-/commit/") .. hash
    end,
    -- `gv`: hand an issue over for verification, see |tracker-verify|.
    verify = {
      -- What merges the checked-out issue branch and leaves the target
      -- branch checked out, {branch} {key} {summary} expanded; nil = `gv`
      -- is off for tasks. E.g. { "git", "merge-branch" }.
      merge = nil,
      env = nil,         -- extra environment for `merge`
      terminal = false,  -- run `merge` in a floating terminal
      -- status (or transition) name(s), the first the workflow offers
      transition = nil,
      unassign = true,
      -- The comment drafted afterwards (an editor opens; closed, it stays as
      -- the issue's comment draft): a string with {placeholders} or
      -- function(ctx) → string; false = none.
      template = table.concat({
        "> [!INFO]",
        "> **Done:**",
        "> - {commits}",
        "",
        "> [!SUCCESS]",
        "> **Commit:** {commit} ({target})",
        "",
        "> [!NOTE]",
        "> **Documentation:**",
        "",
        "> [!WARNING]",
        "> **Watch out for:**",
      }, "\n"),
      -- Epics: no merge; the head of `branch` (on the remote) is named and
      -- the template is added to the description. nil = the remote's
      -- default branch (<remote>/HEAD: main, Production, …).
      epic = {
        branch = nil,
        transition = nil,
        template = table.concat({
          "> [!INFO]",
          "> **Features:**",
          "> - ",
          "",
          "> [!SUCCESS]",
          "> **Location:**",
          "> **Program:** {commit} ({branch})",
          "",
          "> [!NOTE]",
          "> **Changelog:**",
          "",
          "> [!WARNING]",
          "> **Watch out for:**",
        }, "\n"),
      },
    },
  },
  -- Per-category notification switches; see |tracker-notify|.
  notify = {
    enabled = true,
    actions = true, -- "ABC-1 → In Progress", "comment added", ...
    errors = true,  -- API / auth failures
  },
  status = {
    -- How long a fetched branch issue stays fresh for |tracker-status|.
    ttl = 300000,
  },
  debug = false,
}

---`over` on top of `base` (copies): tables merge key by key, but a
---non-empty list (and anything that isn't a table) replaces what it lands
---on, so a 3-word command doesn't keep the default's 4th word.
local function merge(base, over)
  if type(over) ~= "table" or (vim.islist(over) and next(over) ~= nil) or type(base) ~= "table" then
    return vim.deepcopy(over)
  end
  local out = vim.deepcopy(base)
  if vim.islist(out) and next(out) ~= nil then out = {} end
  for k, v in pairs(over) do out[k] = merge(out[k], v) end
  return out
end

local options = vim.deepcopy(defaults)

function M.setup(opts)
  options = merge(defaults, opts or {})
end

function M.get()
  return options
end

---`git` options for the repository at `root`: its `git.repos` entry over
---the rest.
---@param root string|nil
---@return table
function M.git(root)
  local entry = root and require("tracker.boards").repo_entry({ repos = options.git.repos }, root)
  if not entry then return options.git end
  return merge(options.git, entry)
end

---Provider options: the provider module's defaults with the user's table on
---top. Lists (e.g. `queries`) are replaced, not merged, so a user list wins
---outright.
---@param name string
---@return table
function M.provider(name)
  local mod = require("tracker.providers").get(name)
  local user = options.providers[name] or {}
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(mod.defaults or {}), user)
  -- tbl_deep_extend merges lists index by index; a user list must replace
  -- the default one instead (3 default queries + 1 user query ≠ 4 queries).
  for k, v in pairs(user) do
    if type(v) == "table" and vim.islist(v) then merged[k] = vim.deepcopy(v) end
  end
  return merged
end

return M
