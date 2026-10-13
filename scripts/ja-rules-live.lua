-- Japanese prompt rules (#14) before and after, on Kotobae's measurement texts. The cases file is a
-- JSON array of { id, text, runs? }; each case is sent `runs` times (default 3) without and with
-- the rules, in the numbered form ai-polish uses for Japanese. Each answer's fixes are all adopted
-- (first alternative) and the result is checked for the failures the rules target.
--
--   nvim -l scripts/ja-rules-live.lua <cases.json> <report.json> [--max-usd 0.45] [--dry-run]
--
-- Paid: GEMINI_API_KEY must be set. An existing report is scored without sending.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local config = require("ai-polish.config")
local gemini = require("ai-polish.gemini")
local text = require("ai-polish.text")
local units = require("ai-polish.units")
config.setup({})

local IN_FLIGHT = 8

local function read(path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local cases = read(assert(arg[1], "pass the cases file"))
local out = assert(arg[2], "pass the report file")
-- Stop sending once the reported tokens reach this spend; pairs already in flight still finish.
local max_usd = math.huge
for i, a in ipairs(arg) do
  if a == "--max-usd" then
    max_usd = tonumber(arg[i + 1])
  end
end
local price = config.pricing(config.options.model)
local function cost_of(usage)
  return (usage.promptTokenCount or 0) / 1e6 * price.input_per_mtok
    + ((usage.candidatesTokenCount or 0) + (usage.thoughtsTokenCount or 0)) / 1e6 * price.output_per_mtok
end

local jobs = {}
for _, c in ipairs(cases) do
  for run = 1, c.runs or 3 do
    for _, rules in ipairs({ false, true }) do
      jobs[#jobs + 1] = { case = c, run = run, rules = rules }
    end
  end
end
local est = text.estimate(
  vim.tbl_map(function(j)
    return { text = j.case.text }
  end, jobs),
  config.pricing(config.options.model)
)
print(("%d cases, %d requests, about $%.3f"):format(#cases, #jobs, est.cost_usd))
if vim.tbl_contains(arg, "--dry-run") then
  return
end

local function adopt(t, sugs)
  table.sort(sugs, function(a, b)
    return a.start > b.start
  end)
  for _, s in ipairs(sugs) do
    t = t:sub(1, s.start) .. s.after[1] .. t:sub(s.finish + 1)
  end
  return t
end

local report
if vim.uv.fs_stat(out) then
  report = read(out)
else
  report = {}
  local next_i, running, spent = 1, 0, 0
  local function pump()
    while running < IN_FLIGHT and next_i <= #jobs and spent < max_usd do
      local j = jobs[next_i]
      next_i, running = next_i + 1, running + 1
      local t = j.case.text
      gemini.proofread(t, { split = units.split(t), language = j.rules and "ja" or nil }, function(sugs, err, usage)
        running = running - 1
        spent = spent + (usage and cost_of(usage) or 0)
        local resolved = sugs and text.resolve(t, sugs) or {}
        report[#report + 1] = {
          id = j.case.id,
          run = j.run,
          rules = j.rules,
          error = err,
          output_tokens = usage and usage.candidatesTokenCount,
          prompt_tokens = usage and usage.promptTokenCount,
          thought_tokens = usage and usage.thoughtsTokenCount,
          fixes = vim.tbl_map(function(s)
            return { before = s.before, after = s.after[1], category = s.category }
          end, resolved),
          adopted = adopt(t, resolved),
        }
        pump()
      end)
    end
  end
  pump()
  vim.wait(900000, function()
    return running == 0 and (next_i > #jobs or spent >= max_usd)
  end, 50)
  if #report < #jobs then
    print(("stopped at the spend cap after %d of %d requests"):format(#report, #jobs))
  end
  vim.fn.writefile({ vim.json.encode(report) }, out)
end

-- A case may name the text expected after adopting every fix (`expect`), such as a voice-input
-- fragment deleted rather than replaced by a guessed word.
local text_of, expect_of = {}, {}
for _, c in ipairs(cases) do
  text_of[c.id], expect_of[c.id] = c.text, c.expect
end
local function count(s, pattern)
  return select(2, s:gsub(pattern, ""))
end
local STACKED = { "ですです", "ますです", "でしたです", "ましたです", "ですます", "ますます" }

-- What the run cost, from the tokens Gemini reported (thinking is billed as output).
local cost = 0
for _, r in ipairs(report) do
  cost = cost
    + cost_of({
      promptTokenCount = r.prompt_tokens,
      candidatesTokenCount = r.output_tokens,
      thoughtsTokenCount = r.thought_tokens,
    })
end
print(("spent about $%.3f"):format(cost))

local sum = { [false] = {}, [true] = {} }
for _, r in ipairs(report) do
  local s = sum[r.rules]
  local function add(k, v)
    s[k] = (s[k] or 0) + v
  end
  if r.error then
    add("errors", 1)
  else
    add("answers", 1)
    add("fixes", #r.fixes)
    add("tokens", r.output_tokens or 0)
    local original = text_of[r.id]
    local polite = function(t)
      return count(t, "です") + count(t, "ます")
    end
    if r.id:match("^plain%-") then
      add("plain_runs", 1)
      add("plain_to_polite", polite(r.adopted) > polite(original) and 1 or 0)
    end
    for _, p in ipairs(STACKED) do
      if r.adopted:find(p, 1, true) and not original:find(p, 1, true) then
        add("stacked", 1)
        break
      end
    end
    if expect_of[r.id] then
      add("expect_runs", 1)
      add("expect_met", r.adopted == expect_of[r.id] and 1 or 0)
    end
    if r.id:match("^yoyo") then
      add("yoyo_runs", 1)
      add("yoyo_fixed", r.adopted:find("よよ", 1, true) and 0 or 1)
      -- The error fixed on its own: `before` is the repeated characters, not the words around them.
      local minimal = vim.iter(r.fixes):any(function(f)
        return f.before:gsub("。$", ""):match("^[よ]+$") ~= nil
      end)
      add("yoyo_minimal", minimal and 1 or 0)
    end
  end
end

for _, rules in ipairs({ false, true }) do
  local s = sum[rules]
  local g = function(k)
    return s[k] or 0
  end
  print(
    ("%-13s answers %d (errors %d)  fixes/answer %.2f  output tokens/answer %.0f"):format(
      rules and "with rules" or "without rules",
      g("answers"),
      g("errors"),
      g("fixes") / math.max(g("answers"), 1),
      g("tokens") / math.max(g("answers"), 1)
    )
  )
  print(
    ("%-13s plain→polite %d/%d  stacked politeness %d  as expected %d/%d  よよよよ fixed %d/%d, alone %d/%d"):format(
      "",
      g("plain_to_polite"),
      g("plain_runs"),
      g("stacked"),
      g("expect_met"),
      g("expect_runs"),
      g("yoyo_fixed"),
      g("yoyo_runs"),
      g("yoyo_minimal"),
      g("yoyo_runs")
    )
  )
end
