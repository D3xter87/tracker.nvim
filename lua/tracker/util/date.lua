-- Dates for sprints: the tracker's ISO timestamps ("…Z", "+0200", "+02:00")
-- ↔ local "YYYY-MM-DD HH:MM" as shown and typed in the sprint form, and
-- durations ("2w", "10d", "custom").

local M = {}

---Seconds east of UTC of the local zone at epoch `t` (DST included).
local function offset(t)
  local u = os.date("!*t", t)
  u.isdst = nil -- let mktime decide, as for any local time
  return os.difftime(t, os.time(u))
end

---"2026-10-13T06:31:52.786Z" → epoch seconds; nil when unparsable.
---@param s string|nil
---@return integer|nil
function M.parse_iso(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, sec, rest = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):?(%d*)[%.%d]*(.*)$")
  if not y then
    y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil end
    h, mi, sec, rest = "00", "00", "0", "Z"
  end
  local tz = 0
  local sign, th, tm = rest:match("^([+-])(%d%d):?(%d%d)$")
  if sign then tz = (sign == "-" and -1 or 1) * (tonumber(th) * 3600 + tonumber(tm) * 60) end
  -- os.time reads the fields as local time: shift back to what they mean.
  local t = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) or 0,
  })
  t = t + offset(t)
  return t - tz
end

---Epoch → "2026-10-13T08:31:00.000+02:00" in the local zone (Jira's format).
---@param t integer
---@return string
function M.to_iso(t)
  local off = offset(t)
  local sign = off < 0 and "-" or "+"
  off = math.abs(off)
  return os.date("%Y-%m-%dT%H:%M:%S.000", t) .. ("%s%02d:%02d"):format(sign, math.floor(off / 3600), math.floor(off % 3600 / 60))
end

---Epoch → local "2026-10-13 08:31".
---@param t integer|nil
---@return string
function M.format(t)
  return t and os.date("%Y-%m-%d %H:%M", t) or ""
end

---Local "2026-10-13 08:31" (or just "2026-10-13" → 00:00) → epoch; nil when
---unparsable or not a real date (2026-02-30).
---@param s string|nil
---@return integer|nil
function M.parse(s)
  s = vim.trim(s or "")
  local y, mo, d, h, mi = s:match("^(%d%d%d%d)-(%d%d?)-(%d%d?)%s+(%d%d?):(%d%d)$")
  if not y then
    y, mo, d = s:match("^(%d%d%d%d)-(%d%d?)-(%d%d?)$")
    h, mi = "0", "0"
  end
  if not y then return nil end
  local f = { year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = 0 }
  if f.hour > 23 or f.min > 59 then return nil end
  local t = os.time(f)
  local back = os.date("*t", t)
  if back.year ~= f.year or back.month ~= f.month or back.day ~= f.day then return nil end
  return t
end

---"2w" / "3 w" / "10d" → days; nil for "custom" or anything else.
---@param s string|nil
---@return integer|nil
function M.parse_duration(s)
  local n, unit = vim.trim(s or ""):lower():match("^(%d+)%s*([wd])")
  if not n or tonumber(n) == 0 then return nil end
  return tonumber(n) * (unit == "w" and 7 or 1)
end

---`t` plus `days` calendar days, same local time of day (DST-safe).
---@param t integer
---@param days integer
---@return integer
function M.add_days(t, days)
  local f = os.date("*t", t)
  f.day = f.day + days
  f.isdst = nil
  return os.time(f)
end

---Duration between two epochs as typed in the form: "3w" / "10d" when the
---end falls on the same time of day, else "custom".
---@return string
function M.duration_of(t1, t2)
  if not t1 or not t2 or t2 <= t1 then return "custom" end
  local days = math.floor((t2 - t1) / 86400 + 0.5)
  if days == 0 or M.add_days(t1, days) ~= t2 then return "custom" end
  return days % 7 == 0 and ((days / 7) .. "w") or (days .. "d")
end

---Whole weeks between two epochs, rounded (a sprint's usual length).
---@return integer|nil
function M.weeks_between(t1, t2)
  if not t1 or not t2 or t2 <= t1 then return nil end
  local w = math.floor((t2 - t1) / (7 * 86400) + 0.5)
  return w > 0 and w or nil
end

return M
