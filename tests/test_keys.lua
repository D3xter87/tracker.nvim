-- Issue-key rules: the `ABC-123` defaults (what the core did before the
-- rules became the provider's) and GitLab's `#123` with its branch patterns.

local h = require("helpers")
local keys = require("tracker.keys")
local gk = require("tracker.providers.gitlab.keys")
local git = require("tracker.util.git")

require("tracker").setup({})

local PATTERN = "%u[%u%d]+%-%d+"
local GL = { project = "group/app", base_url = "https://gitlab.example/" }

local T = {}

T["default: a branch names the key git.issue_key finds"] = function()
  local d = keys.default
  for _, branch in ipairs({ "abc-123-feat", "ABC-123-FEAT", "feature/abc-9-login", "main", "release-2", "issue-1234" }) do
    h.eq(git.issue_key(branch, PATTERN), d.from_branch({}, branch, nil), branch)
  end
  h.eq(nil, d.from_branch({}, "release-2", { "ABC" }))
  h.eq("ABC-1", d.from_branch({}, "release-2-abc-1", { "abc" }))
  h.eq(true, d.in_branch({}, "feature/abc-1-x", "ABC-1"))
  h.eq(false, d.in_branch({}, "abc-12", "ABC-1"))
end

T["default: normalize, parse, project, find"] = function()
  local d = keys.default
  h.eq("ABC-12", d.normalize({}, " abc-12 "))
  h.eq("ABC-12", d.parse({}, "abc-12"))
  h.eq(nil, d.parse({}, "abc-12 and more"))
  h.eq("ABC", d.project({}, "ABC-12"))
  h.eq("ABC-7", d.find({}, "  ABC-7 — Fix the login"))
  h.eq({ key = "ABC-7", key_lower = "abc-7" }, d.branch_vars({}, { key = "ABC-7" }))
  h.eq("", d.scope({}))
end

T["default: a pattern of the provider's own (key_pattern) replaces the global one"] = function()
  h.eq("X_1-9", keys.default.from_branch({ key_pattern = "%u[%u%d_]+%-%d+" }, "x_1-9-fix", nil))
end

T["default: restricted only when the config names the projects"] = function()
  local d = keys.default
  h.eq(false, d.restricted({}))
  h.eq(false, d.restricted({ projects = {} }))
  h.eq(true, d.restricted({ projects = { "ABC" } }))
  h.eq(true, d.restricted({ boards = { ABC = {} } }))
  h.eq(true, d.restricted({ project = "ABC" }))
end

T["rules(): a provider's keys over the defaults"] = function()
  h.eq(keys.default, keys.rules(nil))
  h.eq(keys.default, keys.rules({}))
  local r = keys.rules({ keys = gk })
  h.eq("#7", r.parse(GL, "7"))
  h.eq(true, r.restricted(GL))
end

T["gitlab: branches that name an issue"] = function()
  for branch, iid in pairs({
    ["123-fix-login"] = "123",
    ["123"] = "123",
    ["123_fix"] = "123",
    ["issue-1234"] = "1234",
    ["issue-1234-short-description"] = "1234",
    ["issue-1234-shortDescription"] = "1234",
    ["Issue-77-Fix"] = "77",
    ["issue/5"] = "5",
    ["issue_5_x"] = "5",
    ["feature/123-desc"] = "123",
    ["feature/123"] = "123",
    ["feature/issue-12-x"] = "12",
    ["bugfix/issue-12"] = "12",
  }) do
    h.eq("#" .. iid, gk.from_branch(GL, branch), branch)
  end
end

T["gitlab: branches that name none"] = function()
  for _, branch in ipairs({
    "main", "develop", "release-2", "release/3", "v1.2", "1.2-stable", "17-0-stable-ee", "2024-06-hotfix",
    "abc-123-fix", "gh-123", "issue-12ab", "issues-and-more", "feature/login", "dependabot/npm/x-1", "renovate/12-x",
  }) do
    h.eq(nil, gk.from_branch(GL, branch), branch)
  end
  h.eq(nil, gk.from_branch({ base_url = "https://gitlab.example" }, "123-fix"), "no project, no issues")
end

T["gitlab: patterns and the ignore list are the user's to replace"] = function()
  local pcfg = vim.tbl_extend("force", GL, { branch = { patterns = { "^gl%-(%d+)" }, ignore = {} } })
  h.eq("#9", gk.from_branch(pcfg, "gl-9-x"))
  h.eq(nil, gk.from_branch(pcfg, "9-x"))
end

T["gitlab: in_branch compares the whole number"] = function()
  h.eq(true, gk.in_branch(GL, "issue-12-x", "#12"))
  h.eq(false, gk.in_branch(GL, "issue-123-x", "#12"))
  h.eq(false, gk.in_branch(GL, "issue-12-x", "other/project#12"))
  h.eq(true, gk.in_branch(GL, "12-x", "group/app#12"))
end

T["gitlab: what the user types becomes a key"] = function()
  h.eq("#12", gk.parse(GL, "12"))
  h.eq("#12", gk.parse(GL, " #12 "))
  h.eq("#12", gk.parse(GL, "group/app#12"))
  h.eq("other/lib#3", gk.parse(GL, "other/lib#3"))
  h.eq("#12", gk.parse(GL, "https://gitlab.example/group/app/-/issues/12"))
  h.eq("other/lib#3", gk.parse(GL, "https://gitlab.example/other/lib/-/issues/3#note_9"))
  h.eq(nil, gk.parse(GL, "ABC-12"))
  h.eq(nil, gk.parse(GL, "fix the login"))
  h.eq("fix the login", gk.normalize(GL, "fix the login"))
end

T["gitlab: project, scope, find, branch values"] = function()
  h.eq("group/app", gk.project(GL, "#12"))
  h.eq("other/lib", gk.project(GL, "other/lib#3"))
  h.eq("group/app", gk.scope(GL))
  h.eq("#12", gk.find(GL, "  #12 — Fix the login"))
  h.eq("other/lib#3", gk.find(GL, "blocked by other/lib#3 since Monday"))
  h.eq(nil, gk.find(GL, "nothing here"))
  h.eq({ key = "12", key_lower = "12", id = "12" }, gk.branch_vars(GL, { key = "#12" }))
end

T["git.branch_name: {id}, {slug_camel} and the provider's values"] = function()
  local issue = { key = "#12", summary = "Short description: login", type = { name = "Issue" } }
  h.eq("issue-12-short-description-login", git.branch_name("issue-{id}-{slug}", issue, gk.branch_vars(GL, issue)))
  h.eq("issue-12-shortDescriptionLogin", git.branch_name("issue-{id}-{slug_camel}", issue, gk.branch_vars(GL, issue)))
  h.eq("12-short-description-login", git.branch_name("{key}-{slug}", issue, gk.branch_vars(GL, issue)))
  -- the ABC-123 shape keeps its values, and gains {id}
  h.eq("abc-7", git.branch_name("{key_lower}", { key = "ABC-7" }))
  h.eq("7-fix", git.branch_name("{id}-{slug}", { key = "ABC-7", summary = "Fix" }))
end

return T
