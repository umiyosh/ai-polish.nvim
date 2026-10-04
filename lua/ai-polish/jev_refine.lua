-- Japanese-only refinements calibrated against injected-error gold levels (docs/jev.md). The local check
-- still decides whether a text needs correction; these questions only spread texts
-- that already need it over levels 3-5, and let AI style use the whole scale.
local path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/jev_ja.json"
local cfg = vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).refine
local M = { features = { "B1", "B2", "B3" } }

local function yes(answers, key)
  local a = answers[key]
  if type(a) == "table" and a.type == "noul" and type(a.noul) == "number" and a.noul == a.noul then
    return a.noul
  end
end

-- Structure questions travel in their own requests so the calibrated local-check
-- requests keep exactly the same packing and state.
function M.structure_batches(content, plan, hint, max_questions)
  local batches, groups = {}, {}
  for i = 1, plan.evaluated do
    local g = math.floor((i - 1) / max_questions) + 1
    groups[g] = groups[g] or {}
    table.insert(groups[g], i)
  end
  for _, group in ipairs(groups) do
    local text = content
    if #groups > 1 then
      local first = math.max(1, group[1] - cfg.structureContext)
      local last = math.min(#plan.sentences, group[#group] + cfg.structureContext)
      local parts = {}
      for i = first, last do
        parts[#parts + 1] = plan.sentences[i].text
      end
      text = table.concat(parts)
    end
    local questions = {}
    for _, i in ipairs(group) do
      questions["u_t" .. (i - 1)] = {
        type = "noul",
        instructions = { question = cfg.structure.question, sentence = plan.sentences[i].text },
        criteria = cfg.structure.criteria,
      }
    end
    batches[#batches + 1] = { state = { text = text, language = hint }, questions = questions }
  end
  return batches
end

-- Paragraphs, or the sentences when the text is a single paragraph.
function M.units(content, plan)
  local paragraphs = {}
  for _, p in ipairs(vim.split(content, "\n%s*\n")) do
    p = vim.trim(p)
    if p ~= "" then
      paragraphs[#paragraphs + 1] = p
    end
  end
  if #paragraphs > 1 then
    return paragraphs
  end
  return vim.tbl_map(function(s)
    return s.text
  end, plan.sentences)
end

function M.style_batches(content, plan, hint, max_questions)
  local style, questions = cfg.aiStyle, {}
  for k, unit in ipairs(M.units(content, plan)) do
    for _, f in ipairs(M.features) do
      questions[#questions + 1] = {
        ("a%d_%s"):format(k - 1, f),
        { type = "noul", instructions = { question = style.features[f], paragraph = unit } },
      }
    end
  end
  questions[#questions + 1] = { "a_vague", { type = "noul", instructions = style.vague } }
  local batches = {}
  for i = 1, #questions, max_questions do
    local chunk = {}
    for j = i, math.min(i + max_questions - 1, #questions) do
      chunk[questions[j][1]] = questions[j][2]
    end
    batches[#batches + 1] = { state = { text = content, language = hint }, questions = chunk }
  end
  return batches
end

-- How much correction a text needs (docs/jev.md, rubric v3).
-- Sentences just above the correction threshold make a text a 3 but are not
-- counted toward 4 and 5, so borderline false alarms are not escalated.
function M.extent_level(values, answers)
  local structural, critical, n = {}, {}, #values
  for i, v in ipairs(values) do
    structural[i] = (yes(answers, "u_t" .. (i - 1)) or 0) >= cfg.structureThreshold
    critical[i] = v >= cfg.escalationThreshold
  end
  local s_count, local_count, errors = 0, 0, 0
  for i = 1, n do
    s_count = s_count + (structural[i] and 1 or 0)
    local_count = local_count + ((critical[i] and not structural[i]) and 1 or 0)
    errors = errors + ((critical[i] or structural[i]) and 1 or 0)
  end
  local share = n > 0 and errors / n or 0
  if (errors >= 3 and share >= cfg.spreadRatio) or s_count >= 2 or (s_count == 1 and local_count >= 2) then
    return 5
  end
  if s_count == 1 or errors >= 2 then
    return 4
  end
  return 3
end

-- Feature coverage may raise, never lower, the Score level.
function M.ai_style_level(score_level, answers)
  local style = cfg.aiStyle
  if score_level < style.gateLevel then
    return score_level
  end
  local covered, total, kinds = 0, 0, {}
  while yes(answers, ("a%d_B1"):format(total)) ~= nil do
    local hit = false
    for _, f in ipairs(M.features) do
      if (yes(answers, ("a%d_%s"):format(total, f)) or 0) >= style.featureThreshold then
        kinds[f], hit = true, true
      end
    end
    covered, total = covered + (hit and 1 or 0), total + 1
  end
  local kind_count = vim.tbl_count(kinds)
  if kind_count == 0 then
    return score_level
  end
  local coverage = covered / total
  local vague = (yes(answers, "a_vague") or 0) >= style.vagueThreshold
  local composite = 2
  if coverage >= style.coverage.full and vague then
    composite = 5
  elseif coverage >= style.coverage.half and kind_count >= 2 then
    composite = 4
  elseif coverage >= style.coverage.partial or kind_count >= 2 then
    composite = 3
  end
  return math.max(score_level, composite)
end

return M
