-- Compares Gemini's context form with the numbered form (numbered.lua) on Japanese texts: output
-- tokens, time to the answer, and suggestions placed or dropped. The cases file is a JSON array
-- of { id, text }; the longest `--limit` texts (default 10) are sent once in each form.
--
--   nvim -l scripts/numbered-live.lua <cases.json> <report.json> [--limit 10] [--dry-run]
--
-- Paid: GEMINI_API_KEY must be set. An existing report is printed without sending.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local config = require("ai-polish.config")
local gemini = require("ai-polish.gemini")
local text = require("ai-polish.text")
local units = require("ai-polish.units")
config.setup({})

local function read(path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local cases = read(assert(arg[1], "pass the cases file"))
local out = assert(arg[2], "pass the report file")
local limit = 10
for i, a in ipairs(arg) do
  if a == "--limit" then
    limit = tonumber(arg[i + 1])
  end
end
table.sort(cases, function(a, b)
  return #a.text > #b.text
end)
cases = { unpack(cases, 1, limit) }

local est = text.estimate(
  vim.tbl_map(function(c)
    return { text = c.text }
  end, cases),
  config.pricing(config.options.model)
)
print(("%d texts, %d requests, about $%.3f (twice the one-form estimate)"):format(#cases, 2 * #cases, 2 * est.cost_usd))
if vim.tbl_contains(arg, "--dry-run") then
  return
end

local report
if vim.uv.fs_stat(out) then
  report = read(out)
else
  report = {}
  local pending = 0
  for _, c in ipairs(cases) do
    for _, form in ipairs({ "context", "numbered" }) do
      pending = pending + 1
      local split = form == "numbered" and units.split(c.text) or nil
      local t0 = vim.uv.hrtime()
      gemini.proofread(c.text, { split = split }, function(sugs, err, usage, dropped)
        local row = { id = c.id, form = form, seconds = (vim.uv.hrtime() - t0) / 1e9, error = err }
        if sugs then
          local resolved, d = text.resolve(c.text, sugs)
          row.placed, row.dropped = #resolved, d + (dropped or 0)
          row.output_tokens = usage and usage.candidatesTokenCount
        end
        report[#report + 1] = row
        pending = pending - 1
      end)
    end
  end
  vim.wait(600000, function()
    return pending == 0
  end, 50)
  vim.fn.writefile({ vim.json.encode(report) }, out)
end

local sum = {}
for _, r in ipairs(report) do
  local s = sum[r.form] or { n = 0, errors = 0, tokens = 0, seconds = 0, placed = 0, dropped = 0 }
  sum[r.form] = s
  if r.error then
    s.errors = s.errors + 1
  else
    s.n = s.n + 1
    s.tokens = s.tokens + (r.output_tokens or 0)
    s.seconds = s.seconds + r.seconds
    s.placed, s.dropped = s.placed + r.placed, s.dropped + r.dropped
  end
end
for _, form in ipairs({ "context", "numbered" }) do
  local s = sum[form]
  if s then
    print(
      ("%-9s answers %d (errors %d)  output tokens %6d (avg %5.0f)  seconds avg %.2f  placed %d  dropped %d"):format(
        form,
        s.n,
        s.errors,
        s.tokens,
        s.tokens / math.max(s.n, 1),
        s.seconds / math.max(s.n, 1),
        s.placed,
        s.dropped
      )
    )
  end
end
