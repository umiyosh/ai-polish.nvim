-- Measures how often Gemini fixes a real word that does not fit its context (正読 for 精読,
-- issue #23), and in which order it wrote a suggestion's fields in those answers. The cases file
-- is a JSON array of { id, text, wrong, right, language? }: `text` holds `wrong` once, where
-- `right` belongs; `language` is "ja" unless given. Each case is sent `--runs` times (default 2).
-- "fixed" counts the answers with a fix that puts `right` there, "alone" those where a fix does
-- nothing else.
--
--   nvim -l scripts/real-word-errors-live.lua <cases.json> <report.json> [--runs 2] [--only id] [--order f1,f2,...]
--
-- `--order` asks for the fields in that order instead of the plugin's, to see what an order
-- does: `--order message,category,from,to,before,after` is one that lets 正読 pass.
--
-- Paid: GEMINI_API_KEY must be set. An existing report is printed without sending.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local config = require("ai-polish.config")
local gemini = require("ai-polish.gemini")
local http = require("ai-polish.http")
local prompt = require("ai-polish.prompt")
local text = require("ai-polish.text")
local units = require("ai-polish.units")
config.setup({})

local IN_FLIGHT = 4
local FIELDS = { "from", "to", "before", "after", "context_before", "context_after", "message", "category" }

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
local only = option("--only")
if only then
  cases = vim.tbl_filter(function(c)
    return c.id == only
  end, cases)
end
local order = option("--order")
if order then
  for _, schema in ipairs({ prompt.schema, prompt.numbered_schema }) do
    local item = schema.properties.suggestions.items
    item.propertyOrdering = vim.tbl_filter(function(field)
      return item.properties[field] ~= nil
    end, vim.split(order, ","))
  end
end

---The text with `wrong` replaced by `right`.
local function corrected(c)
  local at = assert(c.text:find(c.wrong, 1, true), c.id .. ": `wrong` is not in the text")
  return c.text:sub(1, at - 1) .. c.right .. c.text:sub(at + #c.wrong)
end

---Whether a fix replaces `wrong` with `right`, and whether one does nothing else: Gemini
---sometimes folds a rewording into the same fix (正読に移行したいけど、→精読に移行したいけれど、).
---@return boolean fixed, boolean alone
local function fixes(c, sugs)
  local at = c.text:find(c.wrong, 1, true) - 1
  local fixed, alone = false, false
  for _, s in ipairs(sugs) do
    for _, a in ipairs(s.after) do
      if s.start <= at and at + #c.wrong <= s.finish and a:find(c.right, 1, true) and not a:find(c.wrong, 1, true) then
        fixed = true
      end
      if (c.text:sub(1, s.start) .. a .. c.text:sub(s.finish + 1)) == corrected(c) then
        alone = true
      end
    end
  end
  return fixed, alone
end

---The order of the fields in the first suggestion of a generateContent response, or nil when
---it holds none.
local function written(body)
  local ok, decoded = pcall(vim.json.decode, body or "")
  local part = ok and vim.tbl_get(decoded, "candidates", 1, "content", "parts", 1, "text")
  local first = type(part) == "string" and part:match('"suggestions"%s*:%s*%[%s*(%b{})')
  if not first then
    return nil
  end
  local found = {}
  for _, field in ipairs(FIELDS) do
    local at = first:find('"' .. field .. '":', 1, true)
    if at then
      found[#found + 1] = { field = field, at = at }
    end
  end
  table.sort(found, function(a, b)
    return a.at < b.at
  end)
  return table.concat(
    vim.tbl_map(function(f)
      return f.field
    end, found),
    ","
  )
end

local report
if vim.uv.fs_stat(out) then
  report = read(out)
else
  report = {}
  local queue = {}
  for _, c in ipairs(cases) do
    for _ = 1, runs do
      queue[#queue + 1] = c
    end
  end
  -- The response as received, to read the order Gemini wrote the fields in. A request is built
  -- once and sent again on a retry, so it names the row it belongs to.
  local post = http.post
  local row_of, starting = {}, nil
  http.post = function(req, cb)
    row_of[req] = row_of[req] or starting
    local row = row_of[req]
    return post(req, function(res)
      row.written = written(res.body)
      cb(res)
    end)
  end
  local next_i, running = 1, 0
  local function pump()
    while running < IN_FLIGHT and next_i <= #queue do
      local c = queue[next_i]
      next_i = next_i + 1
      running = running + 1
      local language = c.language or "ja"
      local ctx = { split = language == "ja" and units.split(c.text) or nil, language = language }
      local row = { id = c.id }
      starting = row
      local t0 = vim.uv.hrtime()
      gemini.proofread(c.text, ctx, function(sugs, err, usage, dropped)
        row.seconds, row.error = (vim.uv.hrtime() - t0) / 1e9, err
        if sugs then
          local placed, unplaced = text.resolve(c.text, sugs)
          row.fixes = vim.tbl_map(function(s)
            return ("%s→%s [%s]"):format(s.before, s.after[1], s.category)
          end, placed)
          row.dropped = (dropped or 0) + unplaced
          row.hit, row.alone = fixes(c, placed)
          row.thoughts = usage and usage.thoughtsTokenCount or 0
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

local function tally()
  return { n = 0, errors = 0, hits = 0, alone = 0, dropped = 0, seconds = {} }
end

local function add(t, r)
  if r.error then
    t.errors = t.errors + 1
    return
  end
  t.n = t.n + 1
  t.hits = t.hits + (r.hit and 1 or 0)
  t.alone = t.alone + (r.alone and 1 or 0)
  t.dropped = t.dropped + r.dropped
  t.seconds[#t.seconds + 1] = r.seconds
end

local by_case, by_order, total = {}, {}, tally()
for _, r in ipairs(report) do
  by_case[r.id] = by_case[r.id] or tally()
  add(by_case[r.id], r)
  add(total, r)
  if not r.error then
    local key = r.written or "(no suggestion)"
    by_order[key] = by_order[key] or tally()
    add(by_order[key], r)
  end
end
for _, c in ipairs(cases) do
  local t = by_case[c.id]
  if t then
    print(
      ("%-18s fixed %d/%d (alone %d)  dropped %d  errors %d"):format(c.id, t.hits, t.n, t.alone, t.dropped, t.errors)
    )
  end
end
print("\nby the order Gemini wrote the fields in:")
for key, t in vim.spairs(by_order) do
  print(("  fixed %d/%d (alone %d)  %s"):format(t.hits, t.n, t.alone, key))
end
table.sort(total.seconds)
print(
  ("\nTOTAL answers %d (errors %d)  fixed %d/%d (alone %d)  dropped %d  seconds median %.2f max %.2f"):format(
    total.n,
    total.errors,
    total.hits,
    total.n,
    total.alone,
    total.dropped,
    total.seconds[math.ceil(#total.seconds / 2)] or 0,
    total.seconds[#total.seconds] or 0
  )
)
