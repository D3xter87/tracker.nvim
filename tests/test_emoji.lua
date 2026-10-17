-- Emoji: lookups, Jira node attrs, `:` completion in the editor popup.

local h = require("helpers")
local emoji = require("tracker.emoji")
local complete = require("tracker.ui.emoji_complete")

require("tracker.providers").register("fake", "fake_provider")
require("tracker").setup({ default_provider = "fake", providers = { fake = { base_url = "https://fake" } } })
require("tracker.notify").set_sink(function() end)

local T = {}

T["attrs: Jira's ids (code points, a lone selector dropped) and Atlassian names"] = function()
  h.eq({ shortName = ":+1:", id = "1f44d", text = "👍" }, emoji.attrs("👍"))
  h.eq("26a0", emoji.attrs("⚠️").id)
  h.eq("26a0", emoji.attrs("⚠").id) -- typed without the selector
  h.eq("1f46e-200d-2642-fe0f", emoji.attrs("👮‍♂️").id)
  h.eq(nil, emoji.attrs("ą"))
  h.eq({ shortName = ":cross_mark:", id = "atlassian-cross_mark", text = ":cross_mark:" }, emoji.attrs_by_name("cross_mark"))
  h.eq("1f604", emoji.attrs_by_name("smile").id)
  h.eq(nil, emoji.attrs_by_name("no_such_emoji"))
end

T["at: the longest emoji at a position; Polish letters, © and keycaps aren't"] = function()
  local s = "ą 👮‍♂️ x © 1️⃣ ⚠️!"
  h.eq(nil, emoji.at(s, 1))
  h.eq("👮‍♂️", emoji.at(s, 4))
  h.eq(nil, emoji.at(s, s:find("©", 1, true)))
  h.eq(nil, emoji.at(s, s:find("1", 1, true)))
  h.eq("⚠️", emoji.at(s, s:find("⚠", 1, true)))
end

T["completion: prefix matches first, each emoji once, Atlassian ones as :name:"] = function()
  local m = complete.matches(":thu")
  h.eq("👍", m[1].word)
  local words = vim.tbl_map(function(i) return i.word end, m)
  h.eq(1, #vim.tbl_filter(function(w) return w == "👍" end, words))
  h.truthy(vim.tbl_contains(words, ":thumbs_up:"), vim.inspect(words))
  -- "contains" after "starts with"
  local rock = vim.tbl_map(function(i) return i.word end, complete.matches(":rock"))
  h.eq("🪨", rock[1])
  h.truthy(vim.tbl_contains(rock, "🚀"))
end

T["completion: a recently picked emoji comes first (kept in a file)"] = function()
  emoji.recent_file = vim.fn.tempname() .. ".json"
  emoji.recent_reset()
  local before = complete.matches(":thu")[1].word
  emoji.used("👎")
  h.eq("👎", complete.matches(":thu")[1].word)
  h.eq("👍", before)
  emoji.recent_reset() -- read back from the file
  h.eq({ "👎" }, emoji.recent())
  os.remove(emoji.recent_file)
  emoji.recent_file = nil
  emoji.recent_reset()
end

T["completefunc: start at the colon, not after a letter or a digit (10:30)"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  for _, case in ipairs({ { "ok :thu", 3 }, { "10:30", -3 }, { "a:smile", -3 }, { ":sm", 0 } }) do
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { case[1] })
    vim.api.nvim_win_set_cursor(0, { 1, #case[1] })
    h.eq(case[2], complete.completefunc(1, ""), case[1])
  end
  h.eq("😄", complete.completefunc(0, ":smile")[1].word)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["the editor popup gets the emoji completion"] = function()
  local buf, win = require("tracker.ui.editor").open({ title = "t", text = "x", on_submit = function() end })
  h.eq("v:lua.require'tracker.ui.emoji_complete'.completefunc", vim.bo[buf].completefunc)
  vim.bo[buf].modified = false
  vim.api.nvim_win_close(win, true)
end

return T
