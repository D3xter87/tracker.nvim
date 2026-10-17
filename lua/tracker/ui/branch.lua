-- Git work on an issue, in the repository Neovim's cwd is in:
--   gb  its branch: switch to an existing one (local or on the remote) and pull, or
--       create it (`git.create`: e.g. + a merge request). Afterwards, as
--       configured: assign the issue to you, move it out of "to do", link the
--       merge request.
--   gr / gc  review.nvim / cicd.nvim on its branch.
--   gv  hand it over for verification: merge it (`git.verify.merge`), move it
--       on, unassign it and draft the comment (an epic: its description).

local M = {}

local api = require("tracker.api")
local config = require("tracker.config")
local notify = require("tracker.notify")
local events = require("tracker.events")
local git = require("tracker.util.git")

local WARN = vim.log.levels.WARN

---`args` with {name} placeholders filled (function replacement: values may
---contain `%`).
local function expand(args, vals)
  return vim.tbl_map(function(a)
    return (a:gsub("{([%w_]+)}", function(k) return vals[k] end))
  end, args)
end

---First merge-request URL in a command's output (GitLab / GitHub style).
---@param out string
---@return string|nil
function M.mr_url(out)
  return out:match("(https?://[^%s'\"]+/merge_requests/%d+)") or out:match("(https?://[^%s'\"]+/pull/%d+)")
end

---`steps` (each `fn(next_step)`) one after another, then `finish`.
local function chain(steps, finish)
  local n = 0
  local function next_step()
    n = n + 1
    if steps[n] then return steps[n](next_step) end
    if finish then finish() end
  end
  next_step()
end

---A step moving `key` (now in status `from`) with the first of `targets` its
---workflow offers (To Do → In Progress, Analysis → Analysing, …); what
---happened goes to `did`.
local function transition_step(key, from, targets, did)
  targets = type(targets) == "table" and targets or { targets }
  return function(next_step)
    local n = 0
    local function try()
      n = n + 1
      local target = targets[n]
      if not target then
        notify.send("actions", ("%s: no transition to %s from %s"):format(key, table.concat(targets, " / "),
          from or "its status"), WARN)
        return next_step()
      end
      api.transition(key, target, function(t, err)
        if t then
          table.insert(did, "→ " .. (t.to and t.to.name or t.name))
          return next_step()
        end
        if err and err:find("has no transition", 1, true) then return try() end
        notify.error(err)
        next_step()
      end)
    end
    try()
  end
end

---A step unassigning `key`.
local function unassign_step(key, did)
  return function(next_step)
    api.assign(key, nil, function(a, err)
      if a == false then table.insert(did, "unassigned") else notify.error(err) end
      next_step()
    end)
  end
end

local function report(key, did)
  if #did > 0 then notify.send("actions", key .. ": " .. table.concat(did, ", ")) end
end

---The follow-ups once the branch exists: assign, transition, MR link — each
---one only when it applies; one note at the end.
local function after(cfg, issue, mr_url, done)
  local did, steps = {}, {}
  if cfg.assign_me and not issue.assignee then
    table.insert(steps, function(next_step)
      api.assign(issue.key, "me", function(a, err)
        if a then table.insert(did, "assigned to you") else notify.error(err) end
        next_step()
      end)
    end)
  end
  if cfg.transition and (not issue.status or issue.status.category == "todo") then
    table.insert(steps, transition_step(issue.key, issue.status and issue.status.name, cfg.transition, did))
  end
  if cfg.mr_link and mr_url then
    table.insert(steps, function(next_step)
      local iid = mr_url:match("(%d+)$")
      api.add_web_link(issue.key, mr_url, "MR !" .. (iid or "?"), function(ok, err)
        if ok then table.insert(did, "MR linked") else notify.error(err) end
        next_step()
      end)
    end)
  end
  chain(steps, function()
    report(issue.key, did)
    if done then done() end
  end)
end

---`args` in the background; `cb(code, output)`.
local function run_quiet(args, root, env, cb)
  local ok, err = pcall(vim.system, args, { cwd = root, text = true, env = env }, function(res)
    vim.schedule(function() cb(res.code, (res.stdout or "") .. "\n" .. (res.stderr or "")) end)
  end)
  if not ok then notify.error("tracker: can't run " .. tostring(args[1]) .. ": " .. tostring(err)) end
end

---The screen text of a terminal buffer, lines the terminal wrapped joined
---again (a long merge-request URL stays one word).
function M.term_text(buf, width)
  local out = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    table.insert(out, l)
    table.insert(out, vim.fn.strdisplaywidth(l) >= width and "" or "\n")
  end
  return table.concat(out)
end

---`args` in a floating terminal, for scripts that ask (a milestone menu):
---closes by itself when the command succeeded, stays open on a failure
---(q closes it); `cb(code, output)`.
local function run_terminal(args, root, env, title, cb)
  local buf = vim.api.nvim_create_buf(false, true)
  local w = math.floor(vim.o.columns * 0.85)
  local h = math.floor((vim.o.lines - vim.o.cmdheight) * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = config.get().ui.border,
    width = w, height = h, zindex = 70,
    row = math.floor((vim.o.lines - h) / 2) - 1, col = math.floor((vim.o.columns - w) / 2),
    title = " " .. title .. " ", title_pos = "center",
  })
  local start = vim.fn.has("nvim-0.11") == 1 and vim.fn.jobstart or vim.fn.termopen
  local ok, err = pcall(start, args, {
    term = true, cwd = root, env = env,
    on_exit = function(_, code)
      vim.schedule(function()
        local out = vim.api.nvim_buf_is_valid(buf) and M.term_text(buf, w) or ""
        if code == 0 then
          pcall(vim.api.nvim_win_close, win, true)
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        elseif vim.api.nvim_buf_is_valid(buf) then
          vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf })
          vim.bo[buf].bufhidden = "wipe"
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_config(win, { title = " " .. title .. " — failed, q closes ", title_pos = "center" })
          end
        end
        cb(code, out)
      end)
    end,
  })
  if not ok or err <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return notify.error("tracker: can't run " .. tostring(args[1]) .. ": " .. tostring(ok and "not executable" or err))
  end
  vim.cmd("startinsert")
end

---`args` in a floating terminal (`terminal`) or in the background.
local function run(args, root, env, terminal, title, cb)
  if terminal then return run_terminal(args, root, env, title, cb) end
  run_quiet(args, root, env, cb)
end

---The error for a failed command: its exit code and last lines.
local function failed(prog, code, out)
  local tail = vim.split(vim.trim(out), "\n", { plain = true })
  tail = vim.list_slice(tail, math.max(1, #tail - 5))
  notify.error(("tracker: %s failed (exit %d):\n%s"):format(prog, code, table.concat(tail, "\n")))
end

local function confirm(prompt, yes, fn)
  vim.ui.select({ yes, "Cancel" }, { prompt = prompt }, function(choice)
    if choice == yes then fn() end
  end)
end

---The git root of Neovim's cwd (nil after saying so).
local function repo()
  local root = git.root(vim.fn.getcwd())
  if not root then notify.error("tracker: Neovim's cwd isn't in a git repository") end
  return root
end

---A command named by its first two words ("bash CreateBranch.sh", "git
---switch"), for prompts.
local function describe(cmd)
  return table.concat(vim.tbl_map(function(w) return vim.fs.basename(w) end, vim.list_slice(cmd, 1, 2)), " ")
end

---`cb()` after `git.fetch` (at once without it or without the remote; a
---failed fetch — offline — still leaves what is known locally).
local function fetched(cfg, root, cb)
  if not cfg.fetch or not git.has_remote(root, cfg.remote) then return cb() end
  run_quiet(expand(cfg.fetch, { remote = cfg.remote }), root, nil, function() cb() end)
end

---`issue`'s local and remote branches, after a fetch; `cb(list)`.
local function branches(cfg, root, issue, cb)
  fetched(cfg, root, function()
    cb(git.issue_branches(root, issue.key, config.get().issue_key_pattern, git.branch_name(cfg.branch, issue), cfg.remote))
  end)
end

---One of `list`, asking when there are several; `cb(branch)`.
---@param list TrackerBranchRef[]
local function pick(cfg, list, prompt, cb)
  if #list == 1 then return cb(list[1]) end
  vim.ui.select(list, {
    prompt = prompt,
    format_item = function(b) return b.name .. (b.has_local and "" or (" (%s)"):format(cfg.remote)) end,
  }, function(b)
    if b then cb(b) end
  end)
end

---Check out `b` with `git.checkout` and, when it is on the remote, pull it
---with `git.pull`; `cb()` once both worked.
---@param b TrackerBranchRef
local function switch(cfg, root, b, cb)
  local vals = { branch = b.name, remote = cfg.remote }
  local function pull()
    if not (cfg.pull and b.has_remote) then return cb() end
    local args = expand(cfg.pull, vals)
    run_quiet(args, root, nil, function(code, out)
      if code ~= 0 then return failed(table.concat(args, " "), code, out) end
      cb()
    end)
  end
  if git.current_branch(root) == b.name then return pull() end
  local args = expand(cfg.checkout, vals)
  run_quiet(args, root, nil, function(code, out)
    if code ~= 0 then return failed(table.concat(args, " "), code, out) end
    pull()
  end)
end

---A new branch through `git.create`.
local function create_new(cfg, issue, root, done)
  local branch = git.branch_name(cfg.branch, issue)
  local milestone = cfg.milestone
  if type(milestone) == "function" then milestone = milestone(issue) end
  local args = expand(cfg.create, {
    branch = branch, key = issue.key, summary = issue.summary or "", milestone = milestone or "", remote = cfg.remote,
  })
  args[1] = git.program(args[1])
  -- the new branch starts at HEAD: say which one, not only the repository
  local base = git.current_branch(root) or "detached HEAD"
  local prompt = ("Create branch %s from %s in %s (%s)?"):format(branch, base, vim.fs.basename(root), describe(cfg.create))
  confirm(prompt, "Create", function()
    local function finished(code, out)
      if code ~= 0 then return failed(args[1], code, out) end
      local url = M.mr_url(out)
      notify.send("actions", ("%s: branch %s created%s"):format(issue.key, branch, url and (" — " .. url) or ""))
      events.emit(events.BRANCH_CREATED, { provider = issue.provider, key = issue.key, branch = branch, root = root, mr_url = url })
      after(cfg, issue, url, done)
    end
    if not cfg.terminal then notify.send("actions", ("%s: creating branch %s…"):format(issue.key, branch)) end
    run(args, root, cfg.env, cfg.terminal, ("%s: branch %s"):format(issue.key, branch), finished)
  end)
end

---`gb`: the issue's branch. One that exists (here or on the remote) is
---checked out and pulled; otherwise it is created (asks first: `git.create`
---may push and open an MR). Then the follow-ups of |tracker-git|.
---@param issue TrackerIssue
---@param done fun()|nil  after the follow-ups (refresh the view)
function M.create(issue, done)
  local root = repo()
  if not root then return end
  local cfg = config.git(root)
  branches(cfg, root, issue, function(list)
    if #list == 0 then return create_new(cfg, issue, root, done) end
    pick(cfg, list, issue.key .. ": which branch?", function(b)
      local pulls = cfg.pull and b.has_remote
      local function on_it()
        notify.send("actions", ("%s: on %s%s"):format(issue.key, b.name, pulls and ", pulled" or ""))
        after(cfg, issue, nil, done)
      end
      local here = git.current_branch(root) == b.name
      if here and not pulls then return on_it() end
      local prompt = here and ("Pull %s in %s?"):format(b.name, vim.fs.basename(root))
        or ("Switch to %s%s in %s%s?"):format(b.name, b.has_local and "" or (" (%s)"):format(cfg.remote),
          vim.fs.basename(root), pulls and " and pull" or "")
      confirm(prompt, here and "Pull" or "Switch", function() switch(cfg, root, b, on_it) end)
    end)
  end)
end

---`git[what]`(branch, issue) on the issue's branch (asks which when it has
---several).
local function on_branch(issue, what, label)
  local root = repo()
  if not root then return end
  local cfg = config.git(root)
  local open = cfg[what]
  if not open then return notify.error(("tracker: git.%s is off"):format(what)) end
  branches(cfg, root, issue, function(list)
    if #list == 0 then
      return notify.error(("tracker: %s has no branch in %s (local or %s)"):format(issue.key, vim.fs.basename(root), cfg.remote))
    end
    pick(cfg, list, ("%s: %s of which branch?"):format(issue.key, label), function(b)
      local ok, err = pcall(open, b.name, issue)
      if not ok then notify.error(("tracker: git.%s failed: %s"):format(what, err)) end
    end)
  end)
end

---`gr`: `git.review` (review.nvim by default) on the issue's branch.
function M.review(issue)
  on_branch(issue, "review", "review")
end

---`gc`: `git.cicd` (cicd.nvim's pipelines by default) of the issue's branch.
function M.cicd(issue)
  on_branch(issue, "cicd", "pipelines")
end

-- region Verification (gv)

---`template` filled from `ctx`: a function gets `ctx`; in a string {name}
---placeholders are replaced (unknown ones stay), and a value of several lines
---(or a list) repeats what precedes its placeholder on the line, so `> -
---{commits}` gives one `> - …` item per commit inside a callout.
---@param template string|fun(ctx: table): string
---@param ctx table
---@return string
function M.render(template, ctx)
  if type(template) == "function" then return template(ctx) end
  local out = {}
  for _, line in ipairs(vim.split(template, "\n", { plain = true })) do
    local more = {}
    local filled = line:gsub("{([%w_]+)}", function(k)
      local v = ctx[k]
      if v == nil then return nil end
      if type(v) == "table" then v = table.concat(v, "\n") end
      local parts = vim.split(tostring(v), "\n", { plain = true })
      local prefix = line:match("^(.-){" .. k .. "}")
      for i = 2, #parts do table.insert(more, prefix .. parts[i]) end
      return parts[1]
    end)
    table.insert(out, filled)
    vim.list_extend(out, more)
  end
  return table.concat(out, "\n")
end

---Commits named in `key`'s comments (hashes of 7–40 hex digits this
---repository knows): its earlier hand-overs. `cb(hashes, latest)` — latest
---from the newest such comment.
local function handed_over(root, key, cb)
  api.get_comments(key, function(comments)
    local hashes, seen, latest, latest_at = {}, {}, nil, nil
    for _, c in ipairs(comments or {}) do
      for h in (c.body or ""):gmatch("%f[%w]([0-9a-f]+)%f[%W]") do
        if #h >= 7 and #h <= 40 and not seen[h] then
          seen[h] = true
          local full = git.rev(root, h)
          if full then
            table.insert(hashes, full)
            if not latest_at or (c.created or "") >= latest_at then latest, latest_at = full, c.created or "" end
          end
        end
      end
    end
    cb(hashes, latest)
  end)
end

---What a template gets. `hash` is the commit handed over.
local function context(cfg, issue, root, hash, extra)
  local web = cfg.web_url or git.web_url(root, cfg.remote)
  local short = git.short(root, hash) or hash:sub(1, 8)
  local url
  if web and cfg.commit_url then
    url = type(cfg.commit_url) == "function" and cfg.commit_url(web, hash)
      or expand({ cfg.commit_url }, { web_url = web, hash = hash })[1]
  end
  return vim.tbl_extend("force", {
    key = issue.key, summary = issue.summary or "", repo = vim.fs.basename(root),
    hash = hash, short_hash = short, web_url = web or "", commit_url = url or "",
    commit = url and ("[%s](%s)"):format(short, url) or ("`%s`"):format(short),
    commits = {}, since = "", changelogs = "",
  }, extra)
end

---Move it on, unassign it, emit TrackerVerified; then `draft()` (after
---refreshing the view with `done`).
local function finish(cfg, issue, targets, info, draft, done)
  local did, steps = { info.what }, {}
  if targets then table.insert(steps, transition_step(issue.key, issue.status and issue.status.name, targets, did)) end
  if cfg.verify.unassign and issue.assignee then table.insert(steps, unassign_step(issue.key, did)) end
  chain(steps, function()
    events.emit(events.VERIFIED, {
      provider = issue.provider, key = issue.key, branch = info.branch, target = info.target, hash = info.hash, root = info.root,
    })
    report(issue.key, did)
    if done then done() end
    draft()
  end)
end

---The hand-over of a task once `tip` (its branch `branch`) is merged into
---HEAD (`target`). `own`: the branch's commits as seen before merging, for
---a fast-forward merge.
local function hand_over(cfg, issue, root, h, done)
  local vcfg = cfg.verify
  handed_over(root, issue.key, function(earlier, since)
    local commits = git.merged_subjects(root, h.tip, earlier)
    if #commits == 0 and h.own then commits = h.own end
    local hash = git.rev(root, "HEAD")
    local ctx = context(cfg, issue, root, hash, {
      branch = h.branch, target = h.target, commits = commits, since = since and git.short(root, since) or "",
    })
    finish(cfg, issue, vcfg.transition, {
      what = ("%s in %s at %s"):format(h.branch, h.target, ctx.short_hash),
      branch = h.branch, target = h.target, hash = hash, root = root,
    }, function()
      if vcfg.template ~= false then require("tracker.ui.actions").comment(issue.key, done, M.render(vcfg.template, ctx), true) end
    end, done)
  end)
end

---Merge the checked-out `branch` with `git.verify.merge`, then hand over.
---@param asked boolean|nil  the user already agreed
local function merge(cfg, issue, root, branch, done, asked)
  local vcfg = cfg.verify
  if git.dirty(root) then
    return notify.error(("tracker: %s has uncommitted changes — commit or stash them first"):format(vim.fs.basename(root)))
  end
  local tip = git.rev(root, "HEAD")
  local own = git.own_subjects(root, branch, cfg.remote)
  local args = expand(vcfg.merge, { branch = branch, key = issue.key, summary = issue.summary or "", remote = cfg.remote })
  args[1] = git.program(args[1])
  local function go()
    run(args, root, vcfg.env, vcfg.terminal, ("%s: merge %s"):format(issue.key, branch), function(code, out)
      local now = git.current_branch(root)
      if code ~= 0 then
        failed(args[1], code, out)
        return notify.send("actions", ("%s: resolve it (commit + push on %s), then gv hands the issue over"):format(
          issue.key, now or "the target branch"), WARN)
      end
      if not now or now == branch then
        return notify.error(("tracker: still on %s after %s — nothing handed over"):format(now or "a detached HEAD", args[1]))
      end
      hand_over(cfg, issue, root, { branch = branch, target = now, tip = tip, own = own }, done)
    end)
  end
  if asked then return go() end
  confirm(("Merge %s (%s) and hand %s over for verification?"):format(branch, describe(vcfg.merge), issue.key),
    "Merge", go)
end

local function verify_task(cfg, issue, root, done)
  local vcfg = cfg.verify
  if not vcfg.merge then
    return notify.error("tracker: set git.verify.merge (the command merging an issue's branch), see :help tracker-verify")
  end
  local pattern = config.get().issue_key_pattern
  local name = vim.fs.basename(root)
  branches(cfg, root, issue, function(list)
    local cur = git.current_branch(root)
    if cur and git.has_key(cur, issue.key, pattern) then return merge(cfg, issue, root, cur, done) end
    if #list == 0 then
      return notify.error(("tracker: %s has no branch in %s (local or %s)"):format(issue.key, name, cfg.remote))
    end
    -- merged already (conflicts resolved by hand, fixes committed on top):
    -- only the hand-over is left. A branch still on HEAD's own line (no
    -- commits of its own yet) doesn't count.
    for _, b in ipairs(list) do
      local tip = cur and git.rev(root, b.has_local and b.name or (cfg.remote .. "/" .. b.name))
      if tip and git.is_ancestor(root, tip, "HEAD") and not git.on_first_parent(root, tip, "HEAD") then
        local unpushed = git.unpushed(root)
        local warn = unpushed == nil and (" (%s has no upstream!)"):format(cur)
          or unpushed > 0 and (" (%d commit(s) of %s not pushed!)"):format(unpushed, cur) or ""
        local prompt = ("%s is already in %s — hand %s over for verification with %s?%s"):format(
          b.name, cur, issue.key, git.short(root, git.rev(root, "HEAD")), warn)
        return confirm(prompt, "Hand over", function()
          hand_over(cfg, issue, root, { branch = b.name, target = cur, tip = tip }, done)
        end)
      end
    end
    pick(cfg, list, issue.key .. ": merge which branch?", function(b)
      local prompt = ("On %s: switch to %s%s and merge it (%s) to hand %s over?"):format(cur or "a detached HEAD", b.name,
        (cfg.pull and b.has_remote) and " (pulled)" or "", describe(vcfg.merge), issue.key)
      confirm(prompt, "Switch and merge", function()
        if git.dirty(root) then
          return notify.error(("tracker: %s has uncommitted changes — commit or stash them first"):format(name))
        end
        switch(cfg, root, b, function() merge(cfg, issue, root, b.name, done, true) end)
      end)
    end)
  end)
end

local function verify_epic(cfg, issue, root, done)
  local ecfg = cfg.verify.epic or {}
  fetched(cfg, root, function()
    local name = ecfg.branch or git.remote_head(root, cfg.remote)
    if not name then
      return notify.error(("tracker: %s has no %s/HEAD — set git.verify.epic.branch"):format(vim.fs.basename(root), cfg.remote))
    end
    local hash = git.rev(root, cfg.remote .. "/" .. name) or git.rev(root, name)
    if not hash then return notify.error(("tracker: no branch %s in %s"):format(name, vim.fs.basename(root))) end
    local prompt = ("Hand epic %s over for verification with %s at %s?"):format(issue.key, name, git.short(root, hash))
    confirm(prompt, "Hand over", function()
      -- the description to extend: list rows don't carry it
      api.get_issue(issue.key, function(full, err)
        if not full then return notify.error(err) end
        -- TODO(gitlab-api): {changelogs} = links to the releases since the
        -- last approved one, once tracker talks to GitLab / GitHub.
        local ctx = context(cfg, full, root, hash, { branch = name, target = name })
        finish(cfg, full, ecfg.transition, {
          what = ("%s at %s"):format(name, ctx.short_hash),
          branch = name, target = name, hash = hash, root = root,
        }, function()
          if ecfg.template ~= false then
            require("tracker.ui.actions").edit_issue(full, done, M.render(ecfg.template, ctx))
          end
        end, done)
      end)
    end)
  end)
end

---Whether status `name` is one of `targets` (leading emoji ignored).
local function is_target(name, targets)
  local function bare(s) return (s:lower():gsub("^[^%w]+", "")) end
  for _, t in ipairs(type(targets) == "table" and targets or { targets }) do
    if bare(name) == bare(t) then return true end
  end
  return false
end

---`gv`: hand the issue over for verification — see |tracker-verify|. A task
---is merged first (or found merged already); an epic only names the head of
---`git.verify.epic.branch`.
---@param issue TrackerIssue
---@param done fun()|nil  refresh the view
function M.verify(issue, done)
  local root = repo()
  if not root then return end
  local cfg = config.git(root)
  local vcfg = cfg.verify
  local epic = issue.type and (issue.type.level or 0) >= 1
  local function go()
    if epic then return verify_epic(cfg, issue, root, done) end
    verify_task(cfg, issue, root, done)
  end
  local s = issue.status
  if s and (s.category == "done" or is_target(s.name, vcfg.transition or {})
      or is_target(s.name, (vcfg.epic or {}).transition or {})) then
    return confirm(("%s is %s already — hand it over again?"):format(issue.key, s.name), "Hand over again", go)
  end
  go()
end

-- endregion

return M
