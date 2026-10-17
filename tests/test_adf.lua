local adf = require("tracker.providers.jira.adf")
local h = require("helpers")

local T = {}

local function p(...) return { type = "paragraph", content = { ... } } end
local function t(text, marks) return { type = "text", text = text, marks = marks } end
local function doc(...) return { type = "doc", version = 1, content = { ... } } end

---Markdown → ADF → Markdown must be the identity for the supported dialect.
local function roundtrip(md)
  local back = adf.to_markdown(adf.from_markdown(md))
  h.eq(md, back, "markdown round trip")
end

T["inline marks to markdown"] = function()
  local d = doc(p(
    t("plain "), t("bold", { { type = "strong" } }), t(" "),
    t("it", { { type = "em" } }), t(" "), t("code", { { type = "code" } }), t(" "),
    t("gone", { { type = "strike" } }), t(" "),
    t("site", { { type = "link", attrs = { href = "https://x.io" } } })
  ))
  h.eq("plain **bold** *it* `code` ~~gone~~ [site](https://x.io)", adf.to_markdown(d))
end

T["whitespace stays outside marks"] = function()
  h.eq("a **b** c", adf.to_markdown(doc(p(t("a"), t(" b ", { { type = "strong" } }), t("c")))))
end

T["mention, hard break, emoji"] = function()
  local d = doc(p(
    { type = "mention", attrs = { id = "557058:abc", text = "@Jan Kowalski" } },
    { type = "hardBreak" }, t("next "), { type = "emoji", attrs = { shortName = ":smile:", text = "S" } }
  ))
  h.eq("[@Jan Kowalski](mention:557058:abc)\nnext S", adf.to_markdown(d))
end

-- Cases found by round-tripping real Jira Cloud issues.

T["real: emoji and inline cards survive"] = function()
  local emoji = { type = "emoji", attrs = { shortName = ":check_mark:", id = "2714", text = "✔️" } }
  local d = doc(p(t("BOOST "), emoji, t(" see "), { type = "inlineCard", attrs = { url = "https://x.atlassian.net/browse/A-1" } }))
  local stash = {}
  local md = adf.to_markdown(d, stash)
  h.eq("BOOST ✔️ see <https://x.atlassian.net/browse/A-1>", md)
  h.eq(d, adf.from_markdown(md, stash))
  -- a known emoji name typed afresh becomes an emoji, as in Jira's editor
  h.eq(doc(p(t("hi "), { type = "emoji", attrs = { shortName = ":wave:", id = "1f44b", text = "👋" } })),
    adf.from_markdown("hi :wave:", stash))
  -- an unknown one, or one glued to a word / time, stays text
  h.eq(doc(p(t("hi :wavy_nope: 10:30:00 a:wave:"))), adf.from_markdown("hi :wavy_nope: 10:30:00 a:wave:", stash))
end

T["real: paragraph text that looks like block syntax"] = function()
  local d = doc(p(t("# not a heading")), p(t("- not a list")), p(t("12. not ordered")), p(t("> nor a quote")))
  local md = adf.to_markdown(d)
  h.eq("\\# not a heading\n\n\\- not a list\n\n12\\. not ordered\n\n\\> nor a quote", md)
  h.eq(d, adf.from_markdown(md))
end

T["real: plain text that looks like markup is escaped only when needed"] = function()
  local d = doc(p(t("use `make` and *not* this, a*b, snake_case, x < y, [see](here)")))
  local md = adf.to_markdown(d)
  h.eq(d, adf.from_markdown(md))
  -- harmless text stays readable
  h.eq("a*b, snake_case, 2 * 3", adf.to_markdown(doc(p(t("a*b, snake_case, 2 * 3")))))
end

T["real: two paragraphs in a list item / table cell stay two"] = function()
  local d = doc(
    { type = "bulletList", content = { { type = "listItem", content = { p(t("first")), p(t("second")) } } } },
    { type = "table", content = { { type = "tableRow", content = {
      { type = "tableHeader", content = { p(t("name"), { type = "hardBreak" }, t("title")), p(t("mail")) } },
    } } } }
  )
  local md = adf.to_markdown(d)
  h.eq("- first\n\n  second\n\n| name<br>title<p>mail |\n| --- |", md)
  h.eq(d, adf.from_markdown(md))
end

T["real: UNC paths keep their backslashes"] = function()
  local d = doc(p(t([[location: \\fileserver\share\builds\project\!release\]])))
  local md = adf.to_markdown(d)
  h.eq(d, adf.from_markdown(md))
end

T["real: empty paragraphs and double breaks"] = function()
  local d = doc(p(t("a"), { type = "hardBreak" }, { type = "hardBreak" }, t("b")), { type = "paragraph" }, p(t("c")))
  local md = adf.to_markdown(d)
  h.eq("a\n\\\nb\n\n\\\n\nc", md)
  h.eq(d, adf.from_markdown(md))
end

T["real: table shape comes back from the stash"] = function()
  local d = doc({ type = "table", attrs = { isNumberColumnEnabled = false, layout = "default" }, content = {
    { type = "tableRow", content = {
      { type = "tableCell", attrs = { colwidth = { 120 } }, content = { p(t("a")) } },
      { type = "tableCell", attrs = {}, content = { p(t("b")) } },
    } },
    { type = "tableRow", content = {
      { type = "tableCell", attrs = { background = "#deebff" }, content = { p(t("1")) } },
      { type = "tableCell", attrs = {}, content = { p(t("2")) } },
    } },
  } })
  local stash = {}
  local md = adf.to_markdown(d, stash)
  h.eq(d, adf.from_markdown(md:gsub("| 2 |", "| 3 |"):gsub("| 3 |", "| 2 |"), stash))
end

T["markdown to adf: inline"] = function()
  local d = adf.from_markdown("a **b *c*** `x*y` [l](http://u) snake_case_name")
  h.eq(doc(p(
    t("a "), t("b ", { { type = "strong" } }), t("c", { { type = "strong" }, { type = "em" } }),
    t(" "), t("x*y", { { type = "code" } }), t(" "),
    t("l", { { type = "link", attrs = { href = "http://u" } } }),
    t(" snake_case_name")
  )), d)
end

T["markdown to adf: mention and autolink"] = function()
  local d = adf.from_markdown("hi [@Ann](mention:42) see https://a.b/c.")
  h.eq(doc(p(
    t("hi "), { type = "mention", attrs = { id = "42", text = "@Ann" } }, t(" see "),
    t("https://a.b/c", { { type = "link", attrs = { href = "https://a.b/c" } } }), t(".")
  )), d)
end

T["markdown to adf: code never combines with strong"] = function()
  local d = adf.from_markdown("**a `b`**")
  h.eq({ { type = "code" } }, d.content[1].content[2].marks)
end

T["roundtrip: blocks"] = function()
  roundtrip(table.concat({
    "# Title",
    "",
    "Para line one",
    "line two with **bold**",
    "",
    "- one",
    "- two",
    "  - nested",
    "  - nested *em*",
    "- three",
    "",
    "3. third",
    "4. fourth",
    "",
    "> quoted",
    ">",
    "> more",
    "",
    "```lua",
    "local x = 1",
    "",
    "print(x)",
    "```",
    "",
    "---",
    "",
    "- [ ] todo",
    "- [x] done",
    "  - [ ] sub",
    "",
    "| A | B |",
    "| --- | --- |",
    "| 1 | x \\| y |",
  }, "\n"))
end

T["roundtrip: list item with two paragraphs-like lines"] = function()
  roundtrip("1. first\n   continued\n2. second")
end

T["heading keeps a trailing C#"] = function()
  h.eq("Use C#", adf.from_markdown("## Use C#").content[1].content[1].text)
end

T["lossy detection"] = function()
  local d = doc(
    { type = "panel", attrs = { panelType = "info" }, content = { p(t("x", { { type = "underline" } })) } },
    p(t("ok", { { type = "strong" } }))
  )
  h.eq({ "underline" }, adf.lossy(d))
  h.eq({}, adf.lossy(adf.from_markdown("# a\n\n- b\n\n`c`")))
end

T["panel and media render as readable text"] = function()
  local d = doc(
    { type = "panel", attrs = { panelType = "warning" }, content = { p(t("careful")) } },
    { type = "mediaSingle", content = { { type = "media", attrs = { id = "1" } } } }
  )
  h.eq("> [!WARNING]\n> careful\n\n[attachment]", adf.to_markdown(d))
end

T["panels ↔ callouts, with code, lists and headings inside"] = function()
  local code = { type = "codeBlock", attrs = { language = "c" }, content = { t("int x = 1;\nint y = 2;") } }
  local d = doc(
    { type = "panel", attrs = { panelType = "info" }, content = { p(t("Przerobiłem tryb ręczny")) } },
    { type = "panel", attrs = { panelType = "note" }, content = { code } },
    { type = "panel", attrs = { panelType = "success" }, content = {
      { type = "heading", attrs = { level = 3 }, content = { t("Done") } },
      { type = "bulletList", content = { { type = "listItem", content = { p(t("a")) } } } },
    } },
    { type = "blockquote", content = { p(t("plain quote")) } }
  )
  local md = adf.to_markdown(d)
  h.eq(table.concat({
    "> [!INFO]", "> Przerobiłem tryb ręczny", "",
    "> [!NOTE]", "> ```c", "> int x = 1;", "> int y = 2;", "> ```", "",
    "> [!SUCCESS]", "> ### Done", ">", "> - a", "",
    "> plain quote",
  }, "\n"), md)
  h.eq(d, adf.from_markdown(md))
  h.eq({}, adf.lossy(d))
end

T["callouts typed by hand become panels; custom attrs come back from the stash"] = function()
  h.eq(doc({ type = "panel", attrs = { panelType = "warning" }, content = { p(t("uwaga")) } }),
    adf.from_markdown("> [!warning] uwaga"))
  h.eq(doc({ type = "panel", attrs = { panelType = "error" }, content = { { type = "paragraph" } } }),
    adf.from_markdown("> [!ERROR]"))
  -- an unknown callout is just a quote
  h.eq("blockquote", adf.from_markdown("> [!FOO]\n> x").content[1].type)
  local custom = { type = "panel", attrs = { panelType = "custom", panelIcon = ":rocket:", panelColor = "#ffeeaa" },
                   content = { p(t("go")) } }
  local stash = {}
  local md = adf.to_markdown(doc(custom), stash)
  h.eq("> [!CUSTOM]\n> go", md)
  h.eq(doc(custom), adf.from_markdown(md, stash))
end

T["real: code block attrs, plain emoji characters, paragraph after a list"] = function()
  local cross = { type = "emoji", attrs = { shortName = ":cross_mark:", id = "atlassian-cross_mark", text = ":cross_mark:" } }
  local d = doc(
    { type = "codeBlock", attrs = { language = "c", wrap = true }, content = { t("x();") } },
    p(t("typed ❌ by hand, then "), cross),
    { type = "bulletList", content = { { type = "listItem", content = { p(t("item")) } } } },
    p(t(" starts with a space"))
  )
  local stash = {}
  local md = adf.to_markdown(d, stash)
  h.eq(d, adf.from_markdown(md, stash))
end

T["emoji: an emoji added in an edit becomes a node, the old text one stays text"] = function()
  local cop = { type = "emoji", attrs = { shortName = ":smile:", id = "1f604", text = "😄" } }
  local d = doc(p(t("plain 😄 then "), cop))
  local stash = {}
  local md = adf.to_markdown(d, stash)
  h.eq("plain 😄 then 😄", md)
  local got = adf.from_markdown(md .. " and 😄 again 👍", stash)
  local c = got.content[1].content
  h.eq({ "text", "emoji", "text", "emoji", "text", "emoji" }, vim.tbl_map(function(n) return n.type end, c))
  h.eq("plain 😄 then ", c[1].text)
  h.eq("1f604", c[4].attrs.id)
  h.eq("1f44d", c[6].attrs.id)
end

T["emoji: Atlassian ones show as Unicode and come back as themselves"] = function()
  local check = { type = "emoji", attrs = { shortName = ":check_mark:", id = "atlassian-check_mark", text = ":check_mark:" } }
  local cop = { type = "emoji", attrs = { shortName = ":man_police_officer:", id = "1f46e-200d-2642-fe0f", text = "👮‍♂️" } }
  local d = doc(p(t("OK "), check, t(" "), cop))
  local stash = {}
  local md = adf.to_markdown(d, stash)
  h.eq("OK ✅ 👮‍♂️", md)
  h.eq(d, adf.from_markdown(md, stash))
  -- the shortName still works when typed
  h.eq(d, adf.from_markdown("OK :check_mark: :man_police_officer:", stash))
  -- without the stash (a new text): emoji nodes like Jira's editor makes
  local e = require("tracker.emoji")
  h.eq(doc(p(t("OK "), { type = "emoji", attrs = e.attrs("✅") }, t(" "), { type = "emoji", attrs = e.attrs("👮‍♂️") })),
    adf.from_markdown(md))
  h.eq("2705", e.attrs("✅").id)
  h.eq("1f46e-200d-2642-fe0f", e.attrs("👮‍♂️").id)
  h.eq("26a0", e.attrs("⚠️").id)
  h.eq({ shortName = ":check_mark:", id = "atlassian-check_mark", text = ":check_mark:" }, e.attrs_by_name("check_mark"))
end

local MEDIA = {
  type = "mediaSingle", attrs = { layout = "center" },
  content = { { type = "media", attrs = { id = "abc-1", type = "file", collection = "", alt = "shot.png" } } },
}

T["stash: media survives an edit around it"] = function()
  local d = doc(p(t("before")), MEDIA, { type = "bulletList", content = {
    { type = "listItem", content = { p(t("item")), MEDIA } },
  } })
  local stash = {}
  local md = adf.to_markdown(d, stash)
  h.eq("before\n\n[attachment: shot.png](adf:1)\n\n- item\n\n  [attachment: shot.png](adf:2)", md)
  h.eq(2, #stash)
  h.eq({}, adf.lossy(d, true))
  h.eq({ "media", "mediaSingle" }, adf.lossy(d))
  -- edit the text, keep the placeholder lines
  local back = adf.from_markdown(md:gsub("before", "after"), stash)
  h.eq(doc(p(t("after")), MEDIA, d.content[3]), back)
end

T["stash: deleted placeholder deletes the node, unknown one stays text"] = function()
  local stash = {}
  adf.to_markdown(doc(MEDIA), stash)
  h.eq(doc(p(t("x"))), adf.from_markdown("x", stash))
  h.eq(doc(p(t("[attachment: shot.png]"))), adf.from_markdown("[attachment: shot.png](adf:1)", nil))
end

T["stash: media inside a table cell stays lossy"] = function()
  local d = doc({ type = "table", content = { { type = "tableRow", content = {
    { type = "tableHeader", content = { MEDIA } },
  } } } })
  local stash = {}
  h.eq("| [attachment] |\n| --- |", adf.to_markdown(d, stash))
  h.eq(0, #stash)
  h.eq({ "media", "mediaSingle" }, adf.lossy(d, true))
end

T["empty input"] = function()
  h.eq({ type = "doc", version = 1, content = {} }, adf.from_markdown(""))
  h.eq("", adf.to_markdown(nil))
end

T["fixture: real description"] = function()
  local d = h.fixture("issue.json").fields.description
  local md = adf.to_markdown(d)
  h.truthy(md:find("## Kroki", 1, true), md)
  h.truthy(md:find("- [x] analiza", 1, true), md)
  -- and what comes back is structurally the same document
  h.eq(h.strip_ids(d), h.strip_ids(adf.from_markdown(md)))
end

return T
