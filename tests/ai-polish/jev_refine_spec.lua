local local_check = require("ai-polish.jev_local")
local refine = require("ai-polish.jev_refine")
local jev = require("ai-polish.jev")
local config = require("ai-polish.config")

-- Sentences that contain "誤り" are answered as erroneous, the rest as correct.
local function numbered(flags)
  local parts = {}
  for i, wrong in ipairs(flags) do
    parts[i] = ("第%d項の記述%s。"):format(i, wrong and "が誤り" or "です")
  end
  return table.concat(parts)
end
local function answers(plan, error_value, broken)
  local result = {}
  for i, s in ipairs(plan.sentences) do
    local wrong = s.text:find("誤り", 1, true) ~= nil
    local p = wrong and (1 - error_value) or 0.95
    result["u_s" .. (i - 1)] = { type = "noul", noul = p }
    for j = 1, #s.spans do
      result[("u_p%d_%d"):format(i - 1, j - 1)] = { type = "noul", noul = p }
    end
    result["u_t" .. (i - 1)] = { type = "noul", noul = vim.tbl_contains(broken or {}, i - 1) and 0.9 or 0.1 }
  end
  return result
end
local function level(flags, broken, error_value)
  local p = jev.plan(numbered(flags))
  return local_check.aggregate(p, answers(p, error_value or 0.9, broken), 1).level
end
local function flags(n, wrong)
  local f = {}
  for i = 1, n do
    f[i] = vim.tbl_contains(wrong, i)
  end
  return f
end

describe("Jev refinement for Japanese", function()
  before_each(function()
    config.setup({ evaluation = { language = "ja" } })
  end)
  after_each(function()
    config.setup({})
  end)

  it("sends structure and style questions separately from the local check", function()
    local text = "一文目です。二文目です。三文目です。"
    local p = jev.plan(text)
    assert.equals(1, #p.batches)
    assert.is_nil(p.batches[1].questions.u_t0)
    assert.equals(2, #p.extra_batches)
    local structure = p.extra_batches[1]
    assert.equals(text, structure.state.text)
    assert.equals("二文目です。", structure.questions.u_t1.instructions.sentence)
    local style = p.extra_batches[2]
    assert.equals("一文目です。", style.questions.a0_B2.instructions.paragraph)
    assert.equals("noul", style.questions.a_vague.type)
  end)

  it("gives split structure requests their neighbouring sentences", function()
    local text = numbered(flags(130, {}))
    local p = jev.plan(text)
    local structure = vim.tbl_filter(function(b)
      return b.questions.u_t0 ~= nil or b.questions.u_t60 ~= nil
    end, p.extra_batches)
    assert.equals(2, #structure)
    assert.is_truthy(structure[2].state.text:find("^第59項"))
  end)

  it("adds no refinement requests outside Japanese", function()
    config.setup({ evaluation = { language = "en" } })
    assert.same({}, jev.plan("This is fine. That is fine too.").extra_batches)
  end)

  it("raises texts that need correction by error count, spread and structure", function()
    local one = flags(10, { 1 })
    assert.equals(3, level(one))
    assert.equals(4, level(one, { 5 }))
    assert.equals(4, level(flags(10, { 1, 5 })))
    assert.equals(5, level(flags(10, { 1, 4, 7 })))
    assert.equals(5, level(one, { 3, 6 }))
    assert.equals(5, level(flags(10, { 1, 5 }), { 8 }))
  end)

  it("never raises texts below correction and does not count borderline errors", function()
    assert.equals(1, level(flags(6, {}), { 1, 3 }))
    -- Two sentences just above the correction threshold stay a 3.
    assert.equals(3, level(flags(6, { 1, 4 }), {}, 0.42))
  end)

  it("raises AI style by feature coverage only when the Score already marks it", function()
    local function style(units, hits, vague)
      local a = {}
      for k = 0, units - 1 do
        for _, f in ipairs(refine.features) do
          a[("a%d_%s"):format(k, f)] = { type = "noul", noul = vim.tbl_contains(hits, k .. f) and 0.9 or 0.1 }
        end
      end
      a.a_vague = { type = "noul", noul = vague }
      return a
    end
    local all = style(4, { "0B1", "1B2", "2B2", "3B3" }, 0.9)
    assert.equals(1, refine.ai_style_level(1, all))
    assert.equals(5, refine.ai_style_level(2, all))
    assert.equals(4, refine.ai_style_level(2, style(4, { "0B1", "1B2" }, 0.1)))
    assert.equals(3, refine.ai_style_level(2, style(4, { "0B2" }, 0.1)))
    assert.equals(3, refine.ai_style_level(3, style(4, {}, 0.1)))
    assert.equals(2, refine.ai_style_level(2, {}))
  end)
end)

describe("Japanese level guide", function()
  after_each(function()
    config.setup({})
  end)

  it("explains levels 4 and 5 by the amount of correction", function()
    config.setup({ locale = "ja" })
    local copy = require("ai-polish.evaluation_copy").get()
    assert.equals("大幅な手直し", copy.stages[1][5])
    assert.is_truthy(copy.criteria[1][4]:find("2文以上", 1, true))
    assert.is_truthy(copy.criteria[1][5]:find("3割以上", 1, true))
    assert.is_falsy(copy.criteria[1][5]:find("読み取れず", 1, true))
  end)
end)
