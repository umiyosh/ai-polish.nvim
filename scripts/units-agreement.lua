-- How closely units.lua (BudouX) matches Kotobae's units (lindera with IPADIC), which its
-- Gemini and Jev calibration rests on. The golden file comes from Kotobae's
-- `services::units::tests::dump`: a JSON array of { id, text, units = { {from, to} } }.
-- nvim -l scripts/units-agreement.lua tests/fixtures/units-golden.json
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local units = require("ai-polish.units")

local golden = vim.json.decode(table.concat(vim.fn.readfile(assert(arg[1], "pass the golden file")), "\n"))

local function new()
  return { texts = 0, gold = 0, ours = 0, starts_hit = 0, units_hit = 0 }
end
local total, groups = new(), {}

for _, case in ipairs(golden) do
  local group = case.id:match("^([^/]+)/") or "all"
  groups[group] = groups[group] or new()
  local starts, spans = {}, {}
  for _, u in ipairs(case.units) do
    starts[u[1]] = true
    spans[u[1] .. ":" .. u[2]] = true
  end
  local ours = units.split(case.text).units
  for _, t in ipairs({ total, groups[group] }) do
    t.texts = t.texts + 1
    t.gold = t.gold + #case.units
    t.ours = t.ours + #ours
    for _, u in ipairs(ours) do
      t.starts_hit = t.starts_hit + (starts[u.from] and 1 or 0)
      t.units_hit = t.units_hit + (spans[u.from .. ":" .. u.to] and 1 or 0)
    end
  end
end

local function line(name, t)
  local p, r = t.starts_hit / t.ours, t.starts_hit / t.gold
  return string.format(
    "%-16s texts %4d  units lindera %6d budoux %6d (x%.2f)  starts P %.3f R %.3f F1 %.3f  same unit %.3f",
    name,
    t.texts,
    t.gold,
    t.ours,
    t.ours / t.gold,
    p,
    r,
    2 * p * r / (p + r),
    t.units_hit / t.gold
  )
end

local names = vim.tbl_keys(groups)
table.sort(names)
for _, name in ipairs(names) do
  print(line(name, groups[name]))
end
print(line("all", total))
