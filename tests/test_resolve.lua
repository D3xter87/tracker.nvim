-- Which providers a directory works with (the tabs and their order), and
-- which of them a branch / a key belongs to.

local h = require("helpers")
local git = require("tracker.util.git")

local api = require("tracker.api")
local tracker = require("tracker")

local JIRA = { base_url = "https://x.atlassian.net", login = "me@x.pl", token = "t" }
local GITLAB = { base_url = "https://gitlab.example", token = "t" }

local cwd = vim.fn.getcwd()

---Run `fn` in a fresh git repository whose origin is `remote` (nil: none).
local function in_repo(remote, fn)
  return function()
    local dir = vim.fs.normalize(vim.fn.tempname()) .. "/app"
    vim.fn.mkdir(dir, "p")
    vim.system({ "git", "init", "-q", dir }):wait()
    if remote then vim.system({ "git", "-C", dir, "remote", "add", "origin", remote }):wait() end
    vim.fn.chdir(dir)
    require("tracker.ui.window").close_all()
    local ok, err = pcall(fn, dir)
    vim.fn.chdir(cwd)
    require("tracker").setup({})
    if not ok then error(err, 0) end
  end
end

local T = {}

T["git: host and path of a remote"] = function()
  for url, want in pairs({
    ["git@gitlab.example:group/app.git"] = { "gitlab.example", "group/app" },
    ["git@gitlab.example:group/sub/app"] = { "gitlab.example", "group/sub/app" },
    ["ssh://git@gitlab.example:2222/group/app.git"] = { "gitlab.example", "group/app" },
    ["ssh://git@gitlab.example/group/app.git/"] = { "gitlab.example", "group/app" },
    ["https://gitlab.example/group/app.git"] = { "gitlab.example", "group/app" },
    ["https://user:secret@GitLab.Example:8443/group/app"] = { "gitlab.example", "group/app" },
    ["gitlab.example:group/app.git"] = { "gitlab.example", "group/app" },
    ["git@github.com:owner/repo.git"] = { "github.com", "owner/repo" },
  }) do
    local info = git.parse_remote(url)
    h.eq(want, info and { info.host, info.path }, url)
  end
  h.eq(nil, git.parse_remote(""))
  h.eq(nil, git.parse_remote(nil))
  h.eq(nil, git.parse_remote("C:/repos/app.git"))
  h.eq(nil, git.parse_remote("/srv/git/app.git"))
end

T["one provider: it answers everywhere, as before"] = in_repo("git@github.com:owner/repo.git", function()
  tracker.setup({ providers = { jira = JIRA } })
  h.eq({ "jira" }, api.active_providers())
  h.eq("jira", api.provider_info().name)
  -- any WORD-123 is a key while Jira is alone
  h.eq("FIX-12", (api.current_issue_key({ branch = "fix-12" })))
  h.eq("ISSUE-1234", (api.current_issue_key({ branch = "issue-1234" })))
end)

T["one provider: GitLab alone takes its project from the remote"] = in_repo("git@gitlab.example:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB } })
  h.eq({ "gitlab" }, api.active_providers())
  local info = api.provider_info()
  h.eq({ "gitlab", "group/app", "GitLab", "Filter" }, { info.name, info.project, info.label, info.query_label })
  h.eq("#1234", (api.current_issue_key({ branch = "issue-1234-short-description" })))
  h.eq("https://gitlab.example/group/app/-/issues/7", api.web_url("#7"))
end)

T["two providers in a GitLab repository: Jira first, GitLab second — no flip"] = in_repo("git@gitlab.example:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA } })
  h.eq({ "jira", "gitlab" }, api.active_providers())
  h.eq("jira", api.provider_info().name)
  h.eq("group/app", api.provider_info({ provider = "gitlab" }).project)
end)

T["two providers: the remote is elsewhere, so GitLab has nothing to show"] = in_repo("git@github.com:owner/repo.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA } })
  h.eq({ "jira" }, api.active_providers())
end)

T["two providers: a `project` keeps GitLab in, repository or not"] = in_repo(nil, function()
  tracker.setup({ providers = { gitlab = vim.tbl_extend("force", GITLAB, { project = "group/app" }), jira = JIRA } })
  h.eq({ "jira", "gitlab" }, api.active_providers())
end)

T["two providers: hosts names the remote's other host (an ssh alias)"] = in_repo("git@git-corp:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA } })
  h.eq({ "jira" }, api.active_providers())
  tracker.setup({ providers = { gitlab = vim.tbl_extend("force", GITLAB, { hosts = { "git-corp" } }), jira = JIRA } })
  h.eq({ "jira", "gitlab" }, api.active_providers())
  h.eq("group/app", api.provider_info({ provider = "gitlab" }).project)
end)

T["the order: provider_order, default_provider, repo_providers"] = in_repo("git@gitlab.example:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA }, provider_order = { "gitlab", "jira" } })
  h.eq({ "gitlab", "jira" }, api.active_providers())
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA }, default_provider = "gitlab" })
  h.eq({ "gitlab", "jira" }, api.active_providers())
  h.eq("gitlab", api.provider_info().name)
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA }, repo_providers = { app = { "gitlab" } } })
  h.eq({ "gitlab" }, api.active_providers())
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA }, repo_providers = { other = { "gitlab" } } })
  h.eq({ "jira", "gitlab" }, api.active_providers())
end)

T["two instances of one type go by name; each has its own config"] = in_repo("git@git.corp.example:team/svc.git", function()
  tracker.setup({ providers = {
    gitlab = GITLAB,
    work = { type = "gitlab", base_url = "https://git.corp.example", token = "t2" },
    jira = JIRA,
  } })
  h.eq({ "jira", "work" }, api.active_providers())
  local info = api.provider_info({ provider = "work" })
  h.eq({ "work", "gitlab", "team/svc", "work" }, { info.name, info.type, info.project, info.label })
end)

T["the branch picks the tracker: issue-1234 is GitLab's, abc-123 Jira's"] = in_repo("git@gitlab.example:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = vim.tbl_extend("force", JIRA, { projects = { "ABC" } }) } })
  h.eq({ key = "#1234", provider = "gitlab" }, api.branch_issue({ branch = "issue-1234-short-description" }))
  h.eq({ key = "#1234", provider = "gitlab" }, api.branch_issue({ branch = "issue-1234-shortDescription" }))
  h.eq({ key = "ABC-123", provider = "jira" }, api.branch_issue({ branch = "abc-123-fix" }))
  h.eq(nil, api.branch_issue({ branch = "main" }))
  h.eq(nil, api.branch_issue({ branch = "release-2" }))
  -- asked of one provider only
  h.eq(nil, (api.current_issue_key({ branch = "issue-1234", provider = "jira" })))
end)

T["next to another provider an unrestricted Jira claims no branch"] = in_repo("git@gitlab.example:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA } })
  h.eq({ key = "#1234", provider = "gitlab" }, api.branch_issue({ branch = "issue-1234" }))
  h.eq(nil, api.branch_issue({ branch = "fix-12" }))
  h.eq(nil, api.branch_issue({ branch = "hotfix-3" }))
  h.eq(nil, api.branch_issue({ branch = "release-2" }))
end)

T["a key says whose it is"] = in_repo("git@gitlab.example:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA } })
  h.eq({ "jira", "ABC-12" }, { api.owner("abc-12") })
  h.eq({ "gitlab", "#34" }, { api.owner("#34") })
  h.eq({ "gitlab", "#34" }, { api.owner("34") })
  h.eq({ "gitlab", "other/lib#3" }, { api.owner("other/lib#3") })
  h.eq({ "gitlab", "#34" }, { api.owner("gitlab:#34") })
  h.eq({ "jira", "ABC-1" }, { api.owner("jira:abc-1") })
  h.eq(nil, (api.owner("fix the login")))
  -- a call that names a key goes to its tracker
  h.eq("https://x.atlassian.net/browse/ABC-12", api.web_url("ABC-12"))
  h.eq("https://gitlab.example/group/app/-/issues/34", api.web_url("#34"))
end)

T["the branch template: the provider's own unless the user set git.branch"] = in_repo("git@gitlab.example:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA } })
  local default = require("tracker.config").get().git.branch
  h.eq("{id}-{slug}", api.branch_template(default, { provider = "gitlab" }))
  h.eq(default, api.branch_template(default, { provider = "jira" }))
  tracker.setup({ providers = { gitlab = vim.tbl_extend("force", GITLAB, { branch = { template = "issue-{id}-{slug}" } }), jira = JIRA } })
  h.eq("issue-{id}-{slug}", api.branch_template(default, { provider = "gitlab" }))
  -- the user's git.branch beats a provider's DEFAULT template …
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA }, git = { branch = "{key_lower}-{slug}" } })
  h.eq("{key_lower}-{slug}", api.branch_template("{key_lower}-{slug}", { provider = "gitlab" }))
  -- … but not one the user set for that provider: Jira's branches one way, GitLab's another
  local own = vim.tbl_extend("force", GITLAB, { branch = { template = "issue-{id}-{slug_camel}" } })
  tracker.setup({ providers = { gitlab = own, jira = JIRA }, git = { branch = "{key_lower}-{slug}" } })
  h.eq("issue-{id}-{slug_camel}", api.branch_template("{key_lower}-{slug}", { provider = "gitlab" }))
  h.eq("{key_lower}-{slug}", api.branch_template("{key_lower}-{slug}", { provider = "jira" }))
  -- and the repository's own (git.repos) beats both
  tracker.setup({ providers = { gitlab = own, jira = JIRA }, git = { repos = { app = { branch = "x-{id}" } } } })
  h.eq("x-{id}", api.branch_template("x-{id}", { provider = "gitlab" }))
  tracker.setup({ providers = { gitlab = own, jira = JIRA }, git = { repos = { elsewhere = { branch = "x-{id}" } } } })
  h.eq("issue-{id}-{slug_camel}", api.branch_template(default, { provider = "gitlab" }))
end)

T["a key the view's tracker can't read goes to the one it belongs to"] = in_repo("git@gitlab.example:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA } })
  local on_gitlab, on_jira = { provider = "gitlab" }, { provider = "jira" }
  h.eq("https://x.atlassian.net/browse/ABC-12", api.with_scope(on_gitlab, api.web_url, "ABC-12"))
  h.eq("https://gitlab.example/group/app/-/issues/34", api.with_scope(on_jira, api.web_url, "#34"))
  h.eq("https://gitlab.example/group/app/-/issues/34", api.with_scope(on_gitlab, api.web_url, "#34"))
  -- named outright, the provider is taken at its word
  h.eq("https://x.atlassian.net/browse/#34", api.web_url("#34", on_jira))
end)

T["a callback runs in the scope of its call — also when that was none"] = in_repo("git@gitlab.example:group/app.git", function()
  tracker.setup({ providers = { gitlab = GITLAB, jira = JIRA } })
  local bound = api.with_scope({ provider = "gitlab" }, api.bind, function() return api.provider_info().name end)
  h.eq("gitlab", api.with_scope({ provider = "jira" }, bound))
  local unscoped = api.with_scope(nil, api.bind, function() return api.current_scope() end)
  h.eq(nil, api.with_scope({ provider = "gitlab" }, unscoped))
  -- an error inside leaves the scope as it was
  h.eq(false, (pcall(api.with_scope, { provider = "gitlab" }, error, "boom")))
  h.eq(nil, api.current_scope())
end)

T["events say which tracker and which project"] = in_repo("git@gitlab.example:group/app.git", function()
  local http = require("tracker.http.client")
  local real = http.request
  tracker.setup({ providers = { gitlab = vim.tbl_extend("force", GITLAB, { tier = "free" }), jira = JIRA } })
  http.request = function(_, cb)
    vim.schedule(function() cb({ ok = true, status = 200, body = '{"id":1,"body":"x"}', headers = {} }) end)
  end
  local got
  local id = vim.api.nvim_create_autocmd("User", { pattern = "TrackerCommentAdded", callback = function(ev) got = ev.data end })
  local done
  api.comment("#34", "hello", function(c, err) done = c or err end)
  vim.wait(2000, function() return done end, 5)
  http.request = real
  vim.api.nvim_del_autocmd(id)
  h.eq({ "gitlab", "group/app", "#34" }, { got.provider, got.project, got.key })
end)

return T
