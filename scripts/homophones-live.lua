-- Measures how often Gemini fixes a real word that does not fit its context (正読 for 精読,
-- issue #23), with the main request and with the request that looks only for such words. The
-- cases file is a JSON array of { id, text, wrong, right }: `text` holds `wrong` once, where
-- `right` belongs. Each case is sent `--runs` times (default 2) in each mode:
--
--   main        the main request on the text: runs whose fixes put `right` in place
--   homophones  the homophone request on the text: the same count
--   clean       the homophone request on the corrected text: fixes it should not have made
--
--   nvim -l scripts/homophones-live.lua <cases.json> <report.json> [--runs 2] [--modes main,homophones,clean] [--only id]
--
-- Paid: GEMINI_API_KEY must be set. An existing report is printed without sending.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local config = require("ai-polish.config")
local gemini = require("ai-polish.gemini")
local units = require("ai-polish.units")
config.setup({})

local IN_FLIGHT = 4

local function read(path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local function option(name, default)
  for i, a in ipairs(arg) do
    if a == name then
      return arg[i + 1]
    end
  end
  return default
end

local cases = read(assert(arg[1], "pass the cases file"))
local out = assert(arg[2], "pass the report file")
local runs = tonumber(option("--runs", "2"))
local modes = vim.split(option("--modes", "main,homophones,clean"), ",")
local only = option("--only")
if only then
  cases = vim.tbl_filter(function(c)
    return c.id == only
  end, cases)
end

---The text with `wrong` replaced by `right`.
local function corrected(c)
  local at = assert(c.text:find(c.wrong, 1, true), c.id .. ": `wrong` is not in the text")
  return c.text:sub(1, at - 1) .. c.right .. c.text:sub(at + #c.wrong)
end

---Whether adopting one alternative of a fix puts `right` where `wrong` stood.
local function fixes(c, sugs)
  for _, s in ipairs(sugs) do
    for _, a in ipairs(s.after) do
      if (c.text:sub(1, s.start) .. a .. c.text:sub(s.finish + 1)) == corrected(c) then
        return true
      end
    end
  end
  return false
end

local report
if vim.uv.fs_stat(out) then
  report = read(out)
else
  report = {}
  local queue = {}
  for _, c in ipairs(cases) do
    for _, mode in ipairs(modes) do
      for _ = 1, runs do
        queue[#queue + 1] = { case = c, mode = mode }
      end
    end
  end
  local next_i, running = 1, 0
  local function pump()
    while running < IN_FLIGHT and next_i <= #queue do
      local job = queue[next_i]
      next_i = next_i + 1
      running = running + 1
      local c, mode = job.case, job.mode
      local sent = mode == "clean" and corrected(c) or c.text
      local ctx = { split = units.split(sent), language = "ja", kind = mode ~= "main" and "homophones" or nil }
      local t0 = vim.uv.hrtime()
      gemini.proofread(sent, ctx, function(sugs, err, usage, dropped)
        local row = { id = c.id, mode = mode, seconds = (vim.uv.hrtime() - t0) / 1e9, error = err }
        if sugs then
          row.fixes = vim.tbl_map(function(s)
            return ("%s→%s [%s]"):format(s.before, s.after[1], s.category)
          end, sugs)
          row.dropped = dropped or 0
          row.hit = mode ~= "clean" and fixes(c, sugs) or nil
          row.thoughts = usage and usage.thoughtsTokenCount or 0
          row.output_tokens = usage and usage.candidatesTokenCount or 0
        end
        report[#report + 1] = row
        running = running - 1
        pump()
      end)
    end
  end
  pump()
  vim.wait(1200000, function()
    return #report == #queue
  end, 50)
  vim.fn.writefile({ vim.json.encode(report) }, out)
end

local function median(xs)
  table.sort(xs)
  return #xs == 0 and 0 or xs[math.ceil(#xs / 2)]
end

local by = {}
for _, r in ipairs(report) do
  local key = r.id .. "\t" .. r.mode
  local s = by[key] or { id = r.id, mode = r.mode, n = 0, errors = 0, hits = 0, fixes = 0, dropped = 0, seconds = {} }
  by[key] = s
  if r.error then
    s.errors = s.errors + 1
  else
    s.n = s.n + 1
    s.hits = s.hits + (r.hit and 1 or 0)
    s.fixes = s.fixes + #r.fixes
    s.dropped = s.dropped + r.dropped
    s.seconds[#s.seconds + 1] = r.seconds
  end
end
local total = {}
for _, c in ipairs(cases) do
  for _, mode in ipairs(modes) do
    local s = by[c.id .. "\t" .. mode]
    if s then
      local t = total[mode] or { n = 0, errors = 0, hits = 0, fixes = 0, dropped = 0, seconds = {} }
      total[mode] = t
      for _, k in ipairs({ "n", "errors", "hits", "fixes", "dropped" }) do
        t[k] = t[k] + s[k]
      end
      vim.list_extend(t.seconds, s.seconds)
      local result = mode == "clean" and ("%d fix(es) on correct text in %d"):format(s.fixes, s.n)
        or ("fixed %d/%d (%d fix(es) in all)"):format(s.hits, s.n, s.fixes)
      print(("%-18s %-10s %s  dropped %d  errors %d"):format(s.id, mode, result, s.dropped, s.errors))
    end
  end
end
for _, mode in ipairs(modes) do
  local t = total[mode]
  if t then
    print(
      ("TOTAL %-10s answers %d (errors %d)  %s  dropped %d  seconds median %.2f max %.2f"):format(
        mode,
        t.n,
        t.errors,
        mode == "clean" and ("fixes on correct text %d"):format(t.fixes) or ("fixed %d/%d"):format(t.hits, t.n),
        t.dropped,
        median(t.seconds),
        math.max(0, unpack(t.seconds))
      )
    )
  end
end
