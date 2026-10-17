# tracker.nvim

Issue tracker client for Neovim, starting with **Jira Cloud**: your issues and saved JQL searches, a single issue with its comments, the active sprint board, and the everyday actions (transitions, assignee, comments, editing, creating issues and sub-tasks).

- **Code only.** No commands, keymaps or site data are built in. Your config holds the base URL, project, queries, commands and keys. Tokens come from netrc or env.
- **Provider-agnostic.** Each tracker is a provider behind one interface. Jira Cloud (REST v3 + Agile 1.0) is the first one.
- **Built to integrate.** The UI only uses the public Lua API (`require("tracker.api")`), and every change emits a `User` event. Other plugins and scripts can hook in without touching the UI.
- Only the system `curl` binary is used. No plenary, no CLI wrappers.

## Install (lazy.nvim)

```lua
{
  "D3xter87/tracker.nvim",
  cmd = { "Tracker" },
  opts = {
    providers = {
      jira = { base_url = "https://<site>.atlassian.net", project = "ABC" },
    },
  },
  config = function(_, opts)
    require("tracker").setup(opts)
    vim.api.nvim_create_user_command("Tracker", function(a) require("tracker").open(a.args) end, {
      nargs = "?",
      complete = function(lead) return require("tracker").complete(lead, "keys") end,
    })
  end,
}
```

Auth goes in netrc (`%USERPROFILE%\_netrc` on Windows), using your Atlassian e-mail and an [API token](https://id.atlassian.com/manage-profile/security/api-tokens):

```
machine <site>.atlassian.net
  login you@example.com
  password <api-token>
```

Then run `:checkhealth tracker`.

## Views

One window holds a stack of views: lists, issue, board and editor. `open()` without a key (`:Tracker` on a branch like `abc-123-fix`) opens the branch's issue on top of its board (`ui.issue_base = "search"`: the default query; `false`: the issue alone), so going back lands on its card / row. It is a float by default; `ui.layout = "split"`, `"vsplit"` or `"tab"` opens it as a split of the current window or in a new tab page instead. There is one tracker window per tab page: opening a view from a tab that has none starts another, independent one (with `"tab"`, a tracker tab per project tab — each keeps the `:tcd` of the tab it came from, so it resolves that repository's boards), while opening one from the tracker's own tab stacks it there. `q`, `<Esc>`, `<BS>` and `<C-o>` go back one view and close the window only from the first one; `h` goes back only when there is somewhere to go, `l` opens the issue under the cursor. `Q` closes the window from anywhere (free mode and the floats over it included), and `?` shows the keys of the current view. In lists `j`/`k` move between issue rows, centred. After a view scrolled it is drawn afresh (`ui.redraw`: `"auto"` is a full `:redraw!` inside tmux on Windows, where tmux drops single characters from lines while rows move, and a window redraw elsewhere). Views refresh when you come back to them, and the list and the board reload after each action in them — repeated a few times (1, 2, 3, 5 s; "syncing…" in the title) while Jira's search index still shows the old state.

- **List**: laid out like Jira's backlog. Each row has a type icon, key, priority icon, summary and its labels (`#tag`), plus the epic as a chip in its Jira colour, story points (on parents `closed/own`: points of finished or rejected sub-tasks over the story's own estimate, highlighted when the sum exceeds it), assignee and status. Sub-tasks form a foldable sub-list under their parent (`<Tab>`/`za`, `zR`/`zM`). `K` previews the description and details in a float. Other keys: `e` title · `E` field menu · `S` story points · `L` labels · `A` assign me / unassign me (toggle) · `m` mark, then `p`/`P` put below / above (rank) · `M` move to sprint / backlog / epic / parent · `d` archive · `D` delete (both ask first) · `s` status · `a` assign · `c` comment · a red ⊘ before the summary = blocked by an open issue (also on board cards) · `n` new · `gb` branch: check out + pull (local / remote), else create (+ MR via your script) · `gr` review / `gc` pipelines of its branch (review.nvim / cicd.nvim by default) · `gv` hand over for verification · `U` upload files (yazi) · `C` clone (fields, description as is, sub-tasks, a "clones" link; the summary in a popup) · `f` quick filters (epic / assignee / type / status / label, multi-select incl. "No epic"; "Open a whole epic…" lists all its children) · `F` group by epic / assignee / status (section headers with issue count and `closed/total` points, foldable) · `]]`/`[[` next / previous section or group header · `/` text filter (`<Esc>` clears the `/` filter, then the `f` filters, then the marks, and only then goes back) · `J` switch query · `o` browser
- **Issue**: sections like review.nvim's Info panel. `j`/`k` jump between sections (each field, the description, sub-tasks, comments, attachments) and `e` edits the one under the cursor: summary, priority, story points, labels, epic (including "+ New epic…"), assignee, reporter, description, your comment. `E` opens a field menu, `V` copies the section's content, `v` switches to free movement and selection (`Esc`/`q` back). A Links section groups linked issues by relation ("blocks", "is blocked by", "clones", …): `e` on it adds a link (relation, then an issue from this session or a search), `D` on a link removes it, `<CR>` opens it. `e` on Attachments uploads files picked in yazi and `D` on one deletes it. `R` reply · `D` on your comment deletes it (asks first; elsewhere it deletes the issue) · `C` clone · `S` sub-task · `gb` `gr` `gc` `gv` as in lists · `gp` parent
- **Board**: `<`/`>` move a card to the previous / next column · `m` only mine · `B` backlog · `S` sprints
- **Sprints**: active, future and (folded) closed sprints with dates and goals. `<CR>` lists a sprint's issues · `n` new sprint (pre-filled: next number, starts where the last one ends, the board's usual length) · `e` edit · `s` start · `C` complete (open issues go to the next future sprint, created when there is none). The form is a popup (`Name`, `Start`, `Duration`, `End`, `Goal`). End follows Start + Duration as you type.
- **Timeline**: like Jira's Timeline. Each epic is a bar from Start date to Due date, filled by progress (█ done ▓ in progress ░ to do, plus a %). `<Tab>` unfolds its issues. A missing date comes from the sprint (an epic spans its issues), and such a bar is drawn dimmed. `<`/`>` move a bar by a week and `[`/`]` move only its end; the change is saved once you stop pressing. `e` edits both dates · `H`/`L` scroll · `t` today · `+`/`-` zoom days / weeks / months · `d` adds epics done in the last 90 days
- **Editor**: a popup with review.nvim-style keys. `<C-s>` (or `<CR>` in normal mode) submits, and `<Esc>`/`q` closes without asking. On failure it stays open and keeps your text. A comment, reply, comment edit or description closed unsent stays as a draft for the session and comes back when you open it again.
- **Images**: with [snacks.nvim](https://github.com/folke/snacks.nvim)'s image module and a Kitty-graphics terminal, images in descriptions and comments are drawn inline. `<CR>` on an attachment opens it.

Default saved queries are `mine`, `sprint` and `backlog`. The last two are the active sprint and backlog of `board`, with the same issues in the same rank order as in Jira.

Descriptions and comments are converted between Jira's ADF and Markdown, and the conversion is checked against real Jira Cloud content. Jira panels become callouts (`> [!INFO]`, `[!NOTE]`, `[!SUCCESS]`, `[!WARNING]`, `[!ERROR]`), which render-markdown.nvim draws in colour. In the editor `<C-/>` inserts a panel, a code block or files, and `<C-v>` pastes the clipboard's image. Both are uploaded on submit and embedded like Jira's editor does: images inline, other files as file cards. Emoji show as characters (✅ for Atlassian's `:check_mark:`), mentions are written `[@Name](mention:<accountId>)` and smart links `<https://…>`. Comments are listed newest first. Images and attachments appear as `[attachment: name](adf:N)` lines. Keep such a line and the file survives the edit. Only elements Markdown can't carry (panels, status lozenges, colours) make the editor ask before saving.

## Branches and review.nvim

`gb` (list or issue) checks out the issue's branch when it exists, locally or on the remote (any branch with its key, after a fetch), and pulls it. Otherwise it creates it (`abc-123` by default) in the current repository. `git.create` can point it at a script that also pushes and opens a merge request. Afterwards an unassigned issue goes to you, a to-do issue moves to the first configured status its workflow offers, and the MR URL from the script's output can become a web link on the issue. [review.nvim](https://github.com/D3xter87/review.nvim) shows the issue of an MR's branch in its Info panel. `gr` and `gc` call `git.review` / `git.cicd` with the issue's branch. By default they open review.nvim and [cicd.nvim](https://github.com/D3xter87/cicd.nvim)'s pipelines.

The plugin holds only defaults here. The remote, the fetch / checkout / pull / create / merge commands, the integrations, statuses and templates are all `git` options. `git.repos` overrides any of them for one repository, by directory name or path.

`gv` hands an issue over for verification. On its branch it runs `git.verify.merge` (a script that merges the branch into e.g. Develop and leaves that checked out). If the branch is already merged (a conflict you resolved by hand), only the rest happens. Elsewhere it offers to switch to the branch first. Then the issue moves to the first of `git.verify.transition` its workflow offers and is unassigned, and the comment editor opens with `git.verify.template` filled in: the new commits of the branch as a list, the head of Develop as a link, and the panels your team fills. Closed unsent, it stays as the issue's comment draft. On an epic there is no merge. `gv` names the head of `git.verify.epic.branch` (default: the remote's default branch, e.g. Production) and adds `epic.template` to the description. See `:help tracker-verify`.

```lua
git = {
  verify = {
    merge = { "git", "merge-branch" }, terminal = true,
    transition = { "In Verification" },
    template = "> [!INFO]\n> **Done:**\n> - {commits}\n\n> [!SUCCESS]\n> **Commit:** {commit} ({target})",
    epic = { transition = { "Verification" } }, -- branch = nil: <remote>/HEAD
  },
  repos = {
    firmware = { verify = { epic = { branch = "Production" } } }, -- directory name
    ["~/work/web"] = { remote = "upstream", review = false },     -- or path
  },
},
```

## Several boards

One provider can serve several boards, and each git repository picks the ones it works with:

```lua
jira = {
  base_url = "https://<site>.atlassian.net",
  project = "ABC", board = 12,              -- outside the repositories below
  boards = {
    ABC = { board = 12 },                    -- project defaults to the name
    XYZ = { project = "XYZ", board = 34, default_query = "project = XYZ AND assignee = currentUser()" },
  },
  repos = {
    ["web-app"] = { "ABC", "XYZ" },          -- directory name of the repository
    ["~/work/api"] = { "XYZ" },              -- or its path
  },
}
```

In `web-app` the branch `abc-123` opens ABC-123 and `xyz-45` opens XYZ-45. A branch with no key of the repository's boards opens the default query (`default_query`, else the first saved one). Board, sprints, backlog, timeline, new issues and `{project}` in queries use the repository's first board. The board view lets you pick when it has several, and the queries of boards with `queries` of their own are listed as `XYZ/sprint`. A board's `tags` (default `{ project }`) are the key prefixes it owns in branch names.

Queries can span the boards and be made of other queries. Each part gets its own foldable header:

```lua
queries = {
  { name = "all", sections = { "mine", "sprints", "backlogs" } },  -- first = default
  { name = "mine", jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC" },
  { name = "sprints", sprints = true },   -- every active sprint of the repository's boards, one section each
  { name = "backlogs", backlogs = true }, -- the backlog of each board
},
```

## API & events

```lua
local tracker = require("tracker.api")
tracker.current_issue_key()                       -- "ABC-12" from branch "abc-12-fix"
tracker.transition("ABC-12", "Done", function(t, err) end)
tracker.comment("ABC-12", "**Deployed** to staging", function(c, err) end)

vim.api.nvim_create_autocmd("User", {
  pattern = "TrackerTransitioned",
  callback = function(ev) print(ev.data.key, ev.data.status.name) end,
})
```

`require("tracker.status")` exposes the current branch's issue for statuslines. The full reference is in `:help tracker`.

In the editor, `:` and two letters (`:thu`) suggest emoji like Jira's editor does (nvim-cmp, else `<C-x><C-u>`). A picked or typed emoji is saved as a real Jira emoji.

## Credits

Emoji names come from [gemoji](https://github.com/github/gemoji), Copyright (c) 2019 GitHub, Inc., MIT License — the full notice is in [`lua/tracker/data/LICENSE-gemoji`](lua/tracker/data/LICENSE-gemoji). `scripts/gen_emoji.lua` regenerates `lua/tracker/data/emoji.lua`. tracker.nvim itself is MIT licensed, see [LICENSE](LICENSE).

## Tests

```
nvim -l tests/run.lua [filter]
```

The tests cover the ADF ↔ Markdown conversion, the Jira provider against a stubbed transport, and the API events. They also run headless UI flows on an in-memory provider. Nothing in the suite touches the network.
