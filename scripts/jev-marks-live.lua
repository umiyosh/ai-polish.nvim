-- How well Jev's per-bunsetsu marks (jev_marks.lua) foretell Gemini's fixes on budoux units.
-- The gold file is a JSON array of { id, text, fixes = { {from, to} } } with UTF-8 byte ranges
-- of the fixes Gemini showed; Kotobae's regression runs provide them.
--
--   nvim -l scripts/jev-marks-live.lua <gold.json> <answers.json> [--dry-run]
--
-- Paid: TYPESAFE_API_KEY must be set. An existing answers file is scored without sending, so a
-- run is never repeated by accident. --dry-run prints the request count and cost estimate only.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local http = require("ai-polish.http")
local marks = require("ai-polish.jev_marks")
local units = require("ai-polish.units")

-- Kotobae tools/jev-eval/send.ts: Jev's price, with the body's characters as an upper bound on
-- tokens.
local PRICE_PER_TOKEN = 0.042 / 1000000
local IN_FLIGHT = 16

local function read(path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local gold = read(assert(arg[1], "pass the gold file"))
local out = assert(arg[2], "pass the answers file")
-- A case may carry Kotobae's lindera units ({start, end} byte pairs), to tell the effect of the
-- units apart from that of the texts.
local function given(case)
  local split = { units = {}, sentences = {} }
  for i, s in ipairs(case.sentences) do
    split.sentences[i] = { from = s[1], to = s[2] }
  end
  for n, u in ipairs(case.units) do
    local sentence = 1
    for i, s in ipairs(case.sentences) do
      if s[1] <= u[1] and u[1] < s[2] then
        sentence = i
      end
    end
    split.units[n] = { n = n, from = u[1], to = u[2], sentence = sentence }
  end
  return split
end

local cases = {}
for _, case in ipairs(gold) do
  local split = case.units and given(case) or units.split(case.text)
  cases[#cases + 1] = { case = case, split = split, bodies = marks.bodies(case.text, split) }
end

local function send_all(key)
  local queue, answers, failed = {}, {}, 0
  for _, c in ipairs(cases) do
    answers[c.case.id] = {}
    for _, body in ipairs(c.bodies) do
      queue[#queue + 1] = { id = c.case.id, body = body }
    end
  end
  local next_i, running, done = 1, 0, 0
  local function pump()
    while running < IN_FLIGHT and next_i <= #queue do
      local q = queue[next_i]
      next_i, running = next_i + 1, running + 1
      http.post({
        url = marks.endpoint,
        headers = { Authorization = "Bearer " .. key, ["Content-Type"] = "application/json" },
        body = vim.json.encode(q.body),
        timeout_ms = 20000,
      }, function(res)
        running, done = running - 1, done + 1
        local ok, data = pcall(vim.json.decode, res.status == 200 and res.body or "")
        if ok and type(data) == "table" and type(data.answers) == "table" then
          for k, a in pairs(data.answers) do
            answers[q.id][k] = a.noul
          end
        else
          failed = failed + 1
        end
        pump()
      end)
    end
  end
  pump()
  vim.wait(600000, function()
    return done == #queue
  end, 50)
  return answers, failed
end

local requests, bytes = 0, 0
for _, c in ipairs(cases) do
  for _, body in ipairs(c.bodies) do
    requests, bytes = requests + 1, bytes + vim.fn.strchars(vim.json.encode(body))
  end
end
print(("%d texts, %d requests, at most $%.3f"):format(#cases, requests, bytes * PRICE_PER_TOKEN))
if vim.tbl_contains(arg, "--dry-run") then
  return
end

local answers
if vim.uv.fs_stat(out) then
  answers = read(out)
else
  local key = vim.env.TYPESAFE_API_KEY
  if not key or key == "" then
    io.stderr:write("TYPESAFE_API_KEY is not set\n")
    vim.cmd("cquit 2")
  end
  local failed
  answers, failed = send_all(key)
  vim.fn.writefile({ vim.json.encode(answers) }, out)
  print(("%d request(s) failed"):format(failed))
end

local function overlaps(a_from, a_to, b_from, b_to)
  return a_from < b_to and b_from < a_to
end

-- Every unit with its probability and whether a fix touches it.
local scored, fixes_total = {}, 0
for _, c in ipairs(cases) do
  fixes_total = fixes_total + #c.case.fixes
  for _, u in ipairs(c.split.units) do
    local p = answers[c.case.id][("e%04d"):format(u.n)]
    if type(p) == "number" then
      local hit = false
      for _, f in ipairs(c.case.fixes) do
        hit = hit or overlaps(u.from, u.to, f[1], f[2])
      end
      scored[#scored + 1] = { p = p, hit = hit, unit = u, case = c.case }
    end
  end
end

-- AUC by ranks (Mann-Whitney), ties counted half.
table.sort(scored, function(a, b)
  return a.p < b.p
end)
local pos, neg, rank_sum, i = 0, 0, 0, 1
while i <= #scored do
  local j = i
  while j < #scored and scored[j + 1].p == scored[i].p do
    j = j + 1
  end
  for k = i, j do
    if scored[k].hit then
      pos, rank_sum = pos + 1, rank_sum + (i + j) / 2
    else
      neg = neg + 1
    end
  end
  i = j + 1
end
local auc = (rank_sum - pos * (pos + 1) / 2) / (pos * neg)
print(("units %d (fixed %d), fixes %d, AUC %.3f"):format(#scored, pos, fixes_total, auc))

for _, t in ipairs({ 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8 }) do
  local marked, confirmed, foretold = 0, 0, 0
  local by_case = {}
  for _, s in ipairs(scored) do
    if s.p >= t then
      marked = marked + 1
      confirmed = confirmed + (s.hit and 1 or 0)
      by_case[s.case.id] = by_case[s.case.id] or {}
      table.insert(by_case[s.case.id], s.unit)
    end
  end
  for _, c in ipairs(cases) do
    for _, f in ipairs(c.case.fixes) do
      for _, u in ipairs(by_case[c.case.id] or {}) do
        if overlaps(u.from, u.to, f[1], f[2]) then
          foretold = foretold + 1
          break
        end
      end
    end
  end
  print(
    ("threshold %.2f  marks %4d (x%.2f of fixes)  fixes marked first %.3f  marks confirmed %.3f"):format(
      t,
      marked,
      marked / fixes_total,
      foretold / fixes_total,
      marked > 0 and confirmed / marked or 0
    )
  )
end
