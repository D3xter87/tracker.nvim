-- `gb`: branch names, the create command, the follow-ups.

local h = require("helpers")
local fake = require("fake_provider")
local git = require("tracker.util.git")
local branch = require("tracker.ui.branch")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
local notes = {}
require("tracker.notify").set_sink(function(msg) table.insert(notes, msg) end)
local config = require("tracker.config")
local api = require("tracker.api")
local window = require("tracker.ui.window")

local function wait_for(pred, what)
  if not vim.wait(8000, pred, 10) then error("timed out waiting for " .. (what or "condition"), 2) end
end
local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function text() return table.concat(lines(), "\n") end
local function press(lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
    if vim.keycode(m.lhs) == vim.keycode(lhs) then return m.callback() end
  end
  error("no mapping for " .. lhs)
end
local function goto_line(pattern)
  for lnum, l in ipairs(lines()) do
    if l:find(pattern) then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      return lnum, l
    end
  end
  error("no line " .. pattern .. " in\n" .. text())
end
local function calls(kind)
  return vim.tbl_filter(function(c) return c[1] == kind end, fake.calls)
end

---A throw-away git repository as the cwd; restores everything after.
local function in_repo(fn)
  return function()
    local cwd = vim.fn.getcwd()
    local saved = vim.deepcopy(config.get().git)
    local real_select = vim.ui.select
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.system({ "git", "init", "-q", dir }):wait()
    vim.fn.chdir(dir)
    notes = {}
    local ok, err = pcall(fn, dir)
    vim.fn.chdir(cwd)
    vim.ui.select = real_select
    for k in pairs(config.get().git) do config.get().git[k] = saved[k] end
    pcall(window.close)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
    end
    if not ok then error(err, 0) end
  end
end

---A command that runs this nvim on a tiny Lua script.
local function nvim_script(body)
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(vim.split(body, "\n"), script)
  return { vim.v.progpath, "--clean", "--headless", "-l", script }
end

local T = {}

T["slug / branch_name: ascii, dashes, Polish letters, cut at a word"] = function()
  h.eq("zolc-gesla-jazn", git.slug("Żółć gęślą jaźń!"))
  h.eq("ui-acme-partners-obsluga-przeciazenia", git.slug("[UI] ACME & Partners — Obsługa przeciążenia przez pomiar zużycia"))
  h.eq("abc-123", git.branch_name("{key_lower}", { key = "ABC-123", summary = "x" }))
  h.eq("blad/ABC-1-login-form", git.branch_name("{type}/{key}-{slug}", { key = "ABC-1", summary = "Login form", type = { name = "Błąd" } }))
end

T["mr_url: GitLab and GitHub links in a command's output"] = function()
  h.eq("https://gitlab.example.com/a/b/-/merge_requests/123",
    branch.mr_url("remote:\nremote: View merge request for abc-1:\nremote:   https://gitlab.example.com/a/b/-/merge_requests/123\n"))
  h.eq("https://github.com/o/r/pull/7", branch.mr_url("PR: https://github.com/o/r/pull/7 done"))
  h.eq(nil, branch.mr_url("Create it manually: https://gitlab/x/-/merge_requests/new?merge_request%5Bsource_branch%5D=a"))
end

T["transition by a status name without its emoji"] = function()
  fake.reset()
  local real = fake.get_transitions
  fake.get_transitions = function(_, _, cb)
    vim.schedule(function() cb({ { id = "11", name = "Start", to = { id = "2", name = "👨🏻‍💻 IN_PROGRESS", category = "in_progress" } } }) end)
  end
  local got, err
  api.transition("FAKE-1", "IN_PROGRESS", function(t, e) got, err = t, e end)
  wait_for(function() return got or err end, "transition")
  fake.get_transitions = real
  h.eq(nil, err)
  h.eq("11", got.id)
end

T["gb (default): asks, then git switch -c <key_lower> in the cwd's repo"] = in_repo(function(dir)
  fake.reset()
  local prompt
  vim.ui.select = function(items, o, cb)
    prompt = o.prompt
    cb(items[1])
  end
  vim.system({ "git", "-C", dir, "commit", "-q", "--allow-empty", "-m", "init" },
    { env = { GIT_AUTHOR_NAME = "t", GIT_AUTHOR_EMAIL = "t@t", GIT_COMMITTER_NAME = "t", GIT_COMMITTER_EMAIL = "t@t" } }):wait()
  config.get().git.assign_me = false
  local base = git.current_branch(dir) -- main or master, as git's init.defaultBranch says
  require("tracker").issue("FAKE-1")
  wait_for(function() return text():find("First issue", 1, true) end, "issue")
  press("gb")
  wait_for(function() return git.current_branch(dir) == "fake-1" end, "branch")
  h.eq("Create branch fake-1 from " .. base .. " in " .. vim.fs.basename(dir) .. " (git switch)?", prompt)
end)

T["program: other commands as they are; bash runnable on Windows without it on PATH"] = function()
  h.eq("git", git.program("git"))
  h.eq(1, vim.fn.executable(git.program("bash")))
end

T["gb with a create command: placeholders, MR link, assign me, transition out of to-do"] = in_repo(function()
  fake.reset()
  fake.issues[1].assignee = nil -- unassigned, To Do
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  local args_file = vim.fn.tempname()
  local cmd = nvim_script(([[
local f = io.open(%q, "w") f:write(table.concat(arg, "|")) f:close()
print("View merge request for x:")
print("  https://gitlab.example/g/p/-/merge_requests/42")]]):format(args_file))
  vim.list_extend(cmd, { "--non-interactive", "{branch}", "{key}" })
  local g = config.get().git
  g.create, g.transition, g.mr_link, g.assign_me = cmd, "In Progress", true, true
  require("tracker").search("all")
  wait_for(function() return text():find("FAKE-2", 1, true) end, "list")
  goto_line("FAKE%-1 ")
  press("gb")
  wait_for(function() return #calls("remote_link") == 1 end, "follow-ups")
  h.eq("--non-interactive|fake-1|FAKE-1", table.concat(vim.fn.readfile(args_file), "\n"))
  h.eq({ "assign", "FAKE-1", "u1" }, calls("assign")[1])
  h.eq({ "transition", "FAKE-1", "11" }, calls("transition")[1])
  h.eq({ "remote_link", "FAKE-1", { url = "https://gitlab.example/g/p/-/merge_requests/42", title = "MR !42" } },
    calls("remote_link")[1])
end)

T["gb: mr_link = false skips the web link; a failing command reports its output"] = in_repo(function()
  fake.reset()
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  local g = config.get().git
  g.create = nvim_script([[print("https://gitlab.example/g/p/-/merge_requests/9")]])
  g.mr_link, g.assign_me, g.transition = false, false, nil
  local issue = vim.deepcopy(fake.issues[1])
  local done = false
  branch.create(issue, function() done = true end)
  wait_for(function() return done end, "done")
  h.eq(0, #calls("remote_link"))
  g.create = nvim_script([[io.stderr:write("fatal: branch exists\n") os.exit(3)]])
  branch.create(issue)
  wait_for(function()
    return vim.iter(notes):any(function(n) return n:find("exit 3", 1, true) and n:find("branch exists", 1, true) end)
  end, "error note")
end)


T["term_text: lines the terminal wrapped are one again"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Pushing", "https://gitlab.ex", "ample/g/-/merge_r", "equests/5", "Done", "" })
  h.eq("https://gitlab.example/g/-/merge_requests/5", branch.mr_url(branch.term_text(buf, 17)))
  h.eq("Pushing\nhttps://gitlab.example/g/-/merge_requests/5\nDone\n\n", branch.term_text(buf, 17))
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["gb with terminal = true: runs in a float, closes on success, stays open on failure"] = in_repo(function()
  fake.reset()
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  local g = config.get().git
  g.terminal, g.assign_me, g.transition = true, false, nil
  -- a URL longer than the terminal is wide: wrapped there, one word in the output
  local url = "https://gitlab.example/" .. ("g"):rep(300) .. "/-/merge_requests/77"
  g.create = nvim_script(([[io.write("Pushing…\n%s\nDone\n")]]):format(url))
  g.mr_link = true
  local done, floats = false, 0
  branch.create(vim.deepcopy(fake.issues[1]), function() done = true end)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then floats = floats + 1 end
  end
  h.eq(1, floats)
  wait_for(function() return done end, "done")
  -- headless on Windows there is no console for a ConPTY: the child writes
  -- past the terminal buffer, so only the exit code arrives
  if vim.fn.has("win32") == 0 then h.eq(url, calls("remote_link")[1][3].url) end
  h.eq(false, vim.iter(vim.api.nvim_list_wins()):any(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end))
  g.create = nvim_script([[io.stderr:write("fatal: nope\n") os.exit(2)]])
  branch.create(vim.deepcopy(fake.issues[1]))
  wait_for(function()
    return vim.iter(notes):any(function(n) return n:find("exit 2", 1, true) end)
  end, "error note")
  h.truthy(vim.iter(vim.api.nvim_list_wins()):any(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end),
    "the failed terminal stays open")
end)

T["gb: transition list — the first one the workflow offers; none → a warning"] = in_repo(function()
  fake.reset()
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  local g = config.get().git
  g.create = nvim_script([[print("ok")]])
  g.mr_link, g.assign_me, g.transition = false, false, { "Nope", "In Progress" }
  local done = false
  branch.create(vim.deepcopy(fake.issues[1]), function() done = true end)
  wait_for(function() return done end, "done")
  h.eq({ "transition", "FAKE-1", "11" }, calls("transition")[1])
  fake.reset()
  g.transition = { "Nope" }
  done = false
  branch.create(vim.deepcopy(fake.issues[1]), function() done = true end)
  wait_for(function() return done end, "done again")
  h.eq(0, #calls("transition"))
  h.truthy(vim.iter(notes):any(function(n) return n:find("no transition to Nope", 1, true) end), vim.inspect(notes))
end)

-- region Branches of an issue, gb on an existing one, gr / gc, gv

local GIT_ENV = { GIT_AUTHOR_NAME = "t", GIT_AUTHOR_EMAIL = "t@t", GIT_COMMITTER_NAME = "t", GIT_COMMITTER_EMAIL = "t@t" }

---`git -C dir …`, failing the test when git does.
local function g(dir, ...)
  local res = vim.system(vim.list_extend({ "git", "-C", dir }, { ... }), { env = GIT_ENV, text = true }):wait()
  if res.code ~= 0 then error(table.concat({ ... }, " ") .. ": " .. (res.stderr or ""), 2) end
  return vim.trim(res.stdout or "")
end
local function commit(dir, msg)
  g(dir, "commit", "-q", "--allow-empty", "-m", msg)
  return g(dir, "rev-parse", "HEAD")
end

---`dir` with a first commit on Develop and a bare repository as origin.
local function with_origin(dir)
  local bare = vim.fn.tempname()
  vim.system({ "git", "init", "-q", "--bare", bare }):wait()
  commit(dir, "init")
  g(dir, "branch", "-M", "Develop")
  g(dir, "remote", "add", "origin", bare)
  g(dir, "push", "-q", "-u", "origin", "Develop")
  return bare
end

---The merge script's part gv relies on: on the issue branch, check out
---Develop and merge it there.
local MERGE = nvim_script([[
local function git(...)
  local r = vim.system({ "git", ... }, { text = true }):wait()
  if r.code ~= 0 then io.stderr:write(r.stderr) os.exit(r.code) end
  return vim.trim(r.stdout)
end
local branch = git("rev-parse", "--abbrev-ref", "HEAD")
git("switch", "-q", "Develop")
git("merge", "-q", "--no-ff", "-m", "Merge branch '" .. branch .. "' into 'Develop'", branch)]])

local function editor_text()
  wait_for(function() return vim.bo.filetype == "tracker_edit" end, "editor")
  return text()
end
local function close_editor()
  vim.cmd("stopinsert")
  press("q")
end

T["git: has_key, issue_branches (local / origin), web_url"] = in_repo(function(dir)
  h.eq(true, git.has_key("feature/abc-1-x", "ABC-1", "%u[%u%d]+%-%d+"))
  h.eq(false, git.has_key("abc-12", "ABC-1", "%u[%u%d]+%-%d+"))
  with_origin(dir)
  g(dir, "switch", "-q", "-c", "fake-1")
  g(dir, "push", "-q", "origin", "fake-1")
  g(dir, "switch", "-q", "-c", "feature/FAKE-1-old")
  g(dir, "switch", "-q", "Develop")
  g(dir, "push", "-q", "origin", "Develop:fake-1-remote-only")
  local list = git.issue_branches(dir, "FAKE-1", "%u[%u%d]+%-%d+", "fake-1", "origin")
  h.eq({
    { name = "fake-1", has_local = true, has_remote = true },
    { name = "feature/FAKE-1-old", has_local = true, has_remote = false },
    { name = "fake-1-remote-only", has_local = false, has_remote = true },
  }, list)
  for url, want in pairs({
    ["git@gitlab.example:grp/sub/proj.git"] = "https://gitlab.example/grp/sub/proj",
    ["ssh://git@gitlab.example:2222/grp/proj.git"] = "https://gitlab.example/grp/proj",
    ["https://user@github.com/o/r.git"] = "https://github.com/o/r",
    ["https://gitlab.example/grp/proj"] = "https://gitlab.example/grp/proj",
  }) do
    g(dir, "remote", "set-url", "origin", url)
    h.eq(want, git.web_url(dir, "origin"), url)
  end
end)

T["config: a user list replaces the default one; git.repos overrides per repository"] = function()
  local saved = vim.deepcopy(config.get())
  config.setup({
    default_provider = "fake", providers = { fake = { base_url = "https://fake" } },
    git = {
      create = { "bash", "new.sh", "{branch}" },
      verify = { transition = { "Review" } },
      repos = {
        app = { remote = "upstream", verify = { merge = { "git", "merge-branch" }, epic = { branch = "Production" } } },
        ["~/work/api"] = { review = false },
      },
    },
  })
  h.eq({ "bash", "new.sh", "{branch}" }, config.get().git.create) -- not 4 words
  h.eq({ "git", "fetch", "--prune", "{remote}" }, config.get().git.fetch)
  local app = config.git("/x/app")
  h.eq("upstream", app.remote)
  h.eq({ "git", "merge-branch" }, app.verify.merge)
  h.eq({ "Review" }, app.verify.transition)          -- the rest stays
  h.eq("Production", app.verify.epic.branch)
  h.truthy(app.verify.epic.template:find("[!SUCCESS]", 1, true))
  h.eq(false, config.git(vim.fn.expand("~/work/api")).review)
  h.eq("origin", config.git("/x/other").remote)
  h.eq(nil, config.get().git.verify.merge)            -- nothing leaked into the base
  config.setup(saved)
end

T["render: placeholders, a list repeats its line's prefix, unknown ones stay"] = function()
  h.eq("> **Done:**\n> - feat: a\n> - fix: b\n> `abc` {nope}",
    branch.render("> **Done:**\n> - {commits}\n> `{short_hash}` {nope}", { commits = { "feat: a", "fix: b" }, short_hash = "abc" }))
  h.eq("> - ", branch.render("> - {commits}", { commits = {} }))
  h.eq("x 100%", branch.render("{k}", { k = "x 100%" }))
  h.eq("fn KEY", branch.render(function(ctx) return "fn " .. ctx.key end, { key = "KEY" }))
end

T["gb: an existing branch (only on origin) is checked out and pulled, not created"] = in_repo(function(dir)
  fake.reset()
  local prompts = {}
  vim.ui.select = function(items, o, cb)
    table.insert(prompts, o.prompt)
    cb(items[1])
  end
  with_origin(dir)
  g(dir, "switch", "-q", "-c", "fake-1")
  local tip = commit(dir, "feat: remote work")
  g(dir, "push", "-q", "origin", "fake-1")
  g(dir, "switch", "-q", "Develop")
  g(dir, "branch", "-q", "-D", "fake-1")
  local g_cfg = config.get().git
  g_cfg.create = nvim_script([[os.exit(9)]]) -- must not run
  g_cfg.assign_me, g_cfg.transition = false, nil
  local done = false
  branch.create(vim.deepcopy(fake.issues[1]), function() done = true end)
  wait_for(function() return done end, "switched")
  h.eq("fake-1", git.current_branch(dir))
  h.eq(tip, g(dir, "rev-parse", "HEAD"))
  h.eq("Switch to fake-1 (origin) in " .. vim.fs.basename(dir) .. " and pull?", prompts[1])
end)

T["gr / gc: review.nvim / cicd.nvim (or git.review / git.cicd) on the issue's branch"] = in_repo(function(dir)
  fake.reset()
  commit(dir, "init")
  g(dir, "branch", "fake-1")
  local got = {}
  package.loaded["review"] = { open = function(o) got.review = o end }
  package.loaded["cicd"] = { open_pipeline_browser = function(o) got.cicd = o end }
  branch.review(vim.deepcopy(fake.issues[1]))
  branch.cicd(vim.deepcopy(fake.issues[1]))
  wait_for(function() return got.review and got.cicd end, "opened")
  h.eq({ branch = "fake-1" }, got.review)
  h.eq({ branch = "fake-1" }, got.cicd)
  config.get().git.review = function(b, i) got.custom = b .. " " .. i.key end
  branch.review(vim.deepcopy(fake.issues[1]))
  wait_for(function() return got.custom end, "custom")
  h.eq("fake-1 FAKE-1", got.custom)
  package.loaded["review"], package.loaded["cicd"] = nil, nil
  branch.review(vim.deepcopy(fake.issues[2]))
  wait_for(function()
    return vim.iter(notes):any(function(n) return n:find("FAKE-2 has no branch", 1, true) end)
  end, "no branch note")
end)

T["gv: merges the issue branch, moves it on, unassigns, drafts the comment"] = in_repo(function(dir)
  fake.reset()
  require("tracker.ui.drafts").clear()
  local prompts = {}
  vim.ui.select = function(items, o, cb)
    table.insert(prompts, o.prompt)
    cb(items[1])
  end
  with_origin(dir)
  g(dir, "switch", "-q", "-c", "fake-1")
  commit(dir, "feat: one")
  commit(dir, "fix: two")
  local v = config.get().git.verify
  v.merge, v.env, v.transition = MERGE, GIT_ENV, { "Nope", "In Progress" }
  v.template = "> - {commits}\n> {short_hash} {target} {branch} since={since}"
  local verified
  vim.api.nvim_create_autocmd("User", { pattern = "TrackerVerified", once = true, callback = function(ev) verified = ev.data end })
  branch.verify(vim.deepcopy(fake.issues[1]))
  local body = editor_text()
  h.eq("Develop", git.current_branch(dir))
  local head = g(dir, "rev-parse", "HEAD")
  h.eq(("> - fix: two\n> - feat: one\n> %s Develop fake-1 since="):format(g(dir, "rev-parse", "--short", head)), body)
  h.truthy(prompts[1]:find("^Merge fake%-1 %("), prompts[1])
  h.eq({ "transition", "FAKE-1", "11" }, calls("transition")[1])
  h.eq({ "assign", "FAKE-1", nil }, calls("assign")[1])
  h.eq({ key = "FAKE-1", branch = "fake-1", target = "Develop", hash = head, root = verified.root, provider = "fake" }, verified)
  -- closed untouched, the draft stays for `c`
  close_editor()
  h.eq(body, require("tracker.ui.drafts").get("comment:FAKE-1"))
  require("tracker.ui.drafts").clear()

  -- second round: only what is new since, and the earlier hand-over named
  fake.comments["FAKE-1"] = { { id = "c9", author = fake.me, body = "Commit: " .. head:sub(1, 10), created = "2026-10-20T10:00:00.000+0200" } }
  g(dir, "switch", "-q", "fake-1")
  commit(dir, "fix: three")
  branch.verify(vim.deepcopy(fake.issues[1]))
  body = editor_text()
  h.eq(("> - fix: three\n> %s Develop fake-1 since=%s"):format(g(dir, "rev-parse", "--short", "HEAD"),
    g(dir, "rev-parse", "--short", head)), body)
  close_editor()
end)

T["gv: merged already (conflicts done by hand) → only the hand-over, with the target's head"] = in_repo(function(dir)
  fake.reset()
  require("tracker.ui.drafts").clear()
  local prompts = {}
  vim.ui.select = function(items, o, cb)
    table.insert(prompts, o.prompt)
    cb(items[1])
  end
  with_origin(dir)
  g(dir, "switch", "-q", "-c", "fake-1")
  commit(dir, "feat: one")
  g(dir, "switch", "-q", "Develop")
  g(dir, "merge", "-q", "--no-ff", "-m", "merge", "fake-1")
  local fixed = commit(dir, "fix: conflict by hand")
  local v = config.get().git.verify
  v.merge = nvim_script([[os.exit(9)]]) -- must not run
  v.transition = nil
  v.template = "{commits} @ {short_hash}"
  branch.verify(vim.deepcopy(fake.issues[1]))
  h.eq("feat: one @ " .. g(dir, "rev-parse", "--short", fixed), editor_text())
  h.truthy(prompts[1]:find("fake-1 is already in Develop", 1, true), prompts[1])
  h.truthy(prompts[1]:find("not pushed", 1, true), prompts[1])
  close_editor()
end)

T["gv: elsewhere → switch to the issue branch and merge; a fresh branch isn't 'merged'"] = in_repo(function(dir)
  fake.reset()
  require("tracker.ui.drafts").clear()
  local prompts = {}
  vim.ui.select = function(items, o, cb)
    table.insert(prompts, o.prompt)
    cb(items[1])
  end
  with_origin(dir)
  local v = config.get().git.verify
  v.merge, v.env, v.transition, v.template = MERGE, GIT_ENV, nil, "{branch} → {target}"
  -- no commits of its own yet: on Develop's line, so not "already in Develop"
  g(dir, "branch", "fake-1")
  local cancel = vim.ui.select
  vim.ui.select = function(items, o, cb)
    table.insert(prompts, o.prompt)
    cb(items[#items])
  end
  branch.verify(vim.deepcopy(fake.issues[1]))
  wait_for(function() return #prompts == 1 end, "switch prompt")
  h.truthy(prompts[1]:find("^On Develop: switch to fake%-1"), prompts[1])
  vim.ui.select = cancel
  g(dir, "switch", "-q", "fake-1")
  commit(dir, "feat: x")
  g(dir, "switch", "-q", "Develop")
  branch.verify(vim.deepcopy(fake.issues[1]))
  h.eq("fake-1 → Develop", editor_text())
  h.truthy(prompts[2]:find("^On Develop: switch to fake%-1"), prompts[2])
  close_editor()
end)

T["gv: refuses uncommitted changes, unset merge; asks when already in verification"] = in_repo(function(dir)
  fake.reset()
  local asked
  vim.ui.select = function(items, o, cb)
    asked = o.prompt
    cb(items[#items]) -- Cancel
  end
  with_origin(dir)
  g(dir, "switch", "-q", "-c", "fake-1")
  local v = config.get().git.verify
  v.merge = nil
  branch.verify(vim.deepcopy(fake.issues[1]))
  wait_for(function()
    return vim.iter(notes):any(function(n) return n:find("set git.verify.merge", 1, true) end)
  end, "merge unset")
  v.merge = MERGE
  vim.fn.writefile({ "x" }, dir .. "/f.txt")
  g(dir, "add", "f.txt")
  branch.verify(vim.deepcopy(fake.issues[1]))
  wait_for(function()
    return vim.iter(notes):any(function(n) return n:find("uncommitted changes", 1, true) end)
  end, "dirty")
  local done_issue = vim.deepcopy(fake.issues[1])
  done_issue.status = { name = "🔎 IN_REVIEW", category = "in_progress" }
  v.transition = { "IN_REVIEW" }
  branch.verify(done_issue)
  h.eq(("FAKE-1 is 🔎 IN_REVIEW already — hand it over again?"), asked)
  h.eq("fake-1", git.current_branch(dir))
end)

T["gv on an epic: no merge, the production head, the template added to the description"] = in_repo(function(dir)
  fake.reset()
  require("tracker.ui.drafts").clear()
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  with_origin(dir)
  local prod = commit(dir, "release")
  g(dir, "push", "-q", "origin", "Develop:Production")
  commit(dir, "later work")
  local epic = vim.deepcopy(fake.issues[2])
  fake.issues[2].type = { id = "ep", name = "Epik", level = 1 }
  epic.type = fake.issues[2].type
  fake.issues[2].description = "Old text"
  local v = config.get().git.verify
  v.merge = nvim_script([[os.exit(9)]])
  v.epic = { branch = "Production", transition = { "Finish" }, template = "> [!SUCCESS]\n> **Program:** {hash}" }
  branch.verify(epic)
  h.eq("Second issue\n\nOld text\n\n> [!SUCCESS]\n> **Program:** " .. prod, editor_text())
  h.eq({ "transition", "FAKE-2", "21" }, calls("transition")[1])
  h.eq(0, #calls("assign")) -- nobody to unassign
  close_editor()
  h.truthy(require("tracker.ui.drafts").get("issue:FAKE-2"):find(prod, 1, true))
  -- no branch set: origin's default one
  require("tracker.ui.drafts").clear()
  local main = commit(dir, "main release")
  g(dir, "push", "-q", "origin", "Develop:main")
  g(dir, "remote", "set-head", "origin", "main")
  v.epic.branch = nil
  branch.verify(epic)
  h.truthy(editor_text():find("**Program:** " .. main, 1, true), text())
  close_editor()
end)

-- endregion

return T
