-- Pure helpers: git key extraction, mapper, netrc, HTTP response parsing,
-- config merging, editor summary split.

local h = require("helpers")
local git = require("tracker.util.git")
local mapper = require("tracker.providers.jira.mapper")

local PATTERN = "%u[%u%d]+%-%d+"
local T = {}

T["branch key: plain, lower-case, prefixed"] = function()
  h.eq("ABC-123", git.issue_key("ABC-123-FEAT", PATTERN))
  h.eq("ECO-123", git.issue_key("eco-123", PATTERN))
  h.eq("ABC-9", git.issue_key("feature/abc-9-login", PATTERN))
  h.eq(nil, git.issue_key("main", PATTERN))
  h.eq(nil, git.issue_key(nil, PATTERN))
end

T["branch key: project allow-list"] = function()
  h.eq(nil, git.issue_key("release-2", PATTERN, { "ABC" }))
  h.eq("ABC-1", git.issue_key("release-2-abc-1", PATTERN, { "abc" }))
end

T["mapper: issue"] = function()
  local raw = h.fixture("issue.json")
  local i = mapper.issue(raw, { base_url = "https://example.atlassian.net/", fields = { story_points = "customfield_10016" } })
  h.eq("ABC-12", i.key)
  h.eq("https://example.atlassian.net/browse/ABC-12", i.url)
  h.eq({ id = "3", name = "In Progress", category = "in_progress" }, i.status)
  h.eq({ id = "557058:aaa", name = "Jan Kowalski" }, i.assignee)
  h.eq(3, i.story_points)
  h.eq("ABC-1", i.parent.key)
  h.eq("todo", i.parent.status.category)
  h.eq("done", i.subtasks[1].status.category)
  h.truthy(i.description:find("## Kroki", 1, true))
  h.eq({}, i.lossy)
end

T["mapper: list issue has no description"] = function()
  local raw = h.fixture("issue.json")
  raw.fields.description = nil
  h.eq(nil, mapper.issue(raw, {}).description)
end

T["netrc parse"] = function()
  local parsed = require("tracker.http.netrc").parse_string([[
machine a.atlassian.net
  login me@x.pl
  password tok1
machine other password tok2 login bob
default login d password dtok
]])
  h.eq({ login = "me@x.pl", password = "tok1" }, parsed.entries["a.atlassian.net"])
  h.eq({ login = "bob", password = "tok2" }, parsed.entries["other"])
  h.eq({ login = "d", password = "dtok" }, parsed.default)
end

T["http: response parsing with 100-continue and JSON blank lines"] = function()
  local raw = "HTTP/1.1 100 Continue\r\n\r\nHTTP/2 201\r\ncontent-type: application/json\r\n\r\n{\"a\":\n\n[]}"
  local status, body, headers = require("tracker.http.client")._parse_response(raw)
  h.eq(201, status)
  h.eq("{\"a\":\n\n[]}", body)
  h.eq("application/json", headers["content-type"])
end

T["auth: basic header and missing login"] = function()
  local auth = require("tracker.http.auth")
  local creds = assert(auth.credentials("jira", { token = "t", login = "me@x.pl", base_url = "https://a.b" }))
  h.eq("Basic " .. vim.base64.encode("me@x.pl:t"), auth.header(creds))
  local none, err = auth.credentials("zzz", { token = "t", base_url = "https://nohost.invalid" })
  h.eq(nil, none)
  h.truthy(err:find("no login", 1, true), err)
end

T["config: user lists replace default lists"] = function()
  local config = require("tracker.config")
  config.setup({ providers = { jira = { base_url = "https://x", queries = { { name = "one", jql = "a" } } } } })
  local p = config.provider("jira")
  h.eq({ { name = "one", jql = "a" } }, p.queries)
  h.eq("basic", p.auth)
  config.setup({})
end

T["editor: summary split"] = function()
  local split = require("tracker.ui.editor").split_summary
  h.eq({ "Title", "body\n\nmore" }, { split("\n# Title\n\nbody\n\nmore\n\n") })
  h.eq({ "Only", "" }, { split("Only") })
end

return T
