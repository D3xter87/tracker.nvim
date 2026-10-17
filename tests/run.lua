-- Minimal test runner, no dependencies:  nvim -l tests/run.lua [filter]
--
-- Each tests/test_*.lua returns a table of name → function. A test fails by
-- erroring (use the helpers in tests/helpers.lua). Only pure modules are
-- tested here — nothing touches the network.

-- absolute: tests may change the cwd (git repositories in a temp dir)
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = table.concat({
  root .. "/lua/?.lua", root .. "/lua/?/init.lua",
  root .. "/tests/?.lua", package.path,
}, ";")
vim.opt.rtp:prepend(root)

local filter = _G.arg and _G.arg[1]
local files = vim.fn.globpath(root .. "/tests", "test_*.lua", false, true)
table.sort(files)

local passed, failed = 0, 0
for _, file in ipairs(files) do
  local mod = vim.fs.basename(file):gsub("%.lua$", "")
  local suite = require(mod)
  local names = vim.tbl_keys(suite)
  table.sort(names)
  for _, name in ipairs(names) do
    local full = mod .. " :: " .. name
    if not filter or full:find(filter, 1, true) then
      local ok, err = pcall(suite[name])
      if ok then
        passed = passed + 1
      else
        failed = failed + 1
        io.stdout:write("FAIL " .. full .. "\n" .. tostring(err) .. "\n\n")
      end
    end
  end
end

io.stdout:write(("%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
