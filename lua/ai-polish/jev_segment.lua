-- Japanese rules ported from Kotobae PR #44 (9249f86); guarded by its 165-case golden corpus.
local M = {}
local topic_nouns = {
  "目的",
  "目標",
  "狙い",
  "ねらい",
  "特徴",
  "特長",
  "理由",
  "原因",
  "夢",
  "課題",
  "問題点",
  "変更点",
  "ポイント",
  "結論",
  "方針",
  "役割",
  "長所",
  "短所",
  "利点",
  "欠点",
}
local topic_clauses = {
  "わかった",
  "分かった",
  "判明した",
  "気づいた",
  "気付いた",
  "学んだ",
  "伝えたい",
  "言いたい",
  "大切な",
  "重要な",
  "大事な",
  "苦労した",
  "難しかった",
  "驚いた",
  "困った",
}
local copulas = { "です", "だ", "である", "でした", "だった", "であった" }
local quote_ends = {
  "と思う",
  "と思います",
  "と思っている",
  "と考える",
  "と考えている",
  "と考えられる",
  "と言われている",
  "とされる",
  "と感じる",
  "と感じた",
  "と見られる",
}
local resolved_topic = { "であり", "であって", "だが", "ですが", "であるが", "ではなく" }
local existence = { "ある", "ない", "あり", "なく", "多い", "少ない" }
local hedged = { "にある", "にあります", "と予想され", "と見込まれ", "と考えられ" }
local noun_ends = {
  "こと",
  "ため",
  "から",
  "もの",
  "の",
  "よう",
  "点",
  "予定",
  "はず",
  "わけ",
  "つもり",
  "ところ",
  "次第",
}
local verb_ends =
  { "ます", "ました", "ません", "ませんでした", "た", "だ", "い", "ている", "ていた" }
local function chars(s)
  return vim.fn.split(s, [[\zs]])
end
local function has(s, part)
  return s:find(part, 1, true) ~= nil
end
local function ends(s, tail)
  return s:sub(-#tail) == tail
end
local function any(list, f)
  for _, v in ipairs(list) do
    if f(v) then
      return true
    end
  end
  return false
end
local function hira(c)
  local n = c and vim.fn.char2nr(c) or 0
  return n >= 0x3041 and n <= 0x309f
end
local function japanese(s)
  return any(chars(s), function(c)
    local n = vim.fn.char2nr(c)
    return (n >= 0x3040 and n <= 0x30ff) or (n >= 0x4e00 and n <= 0x9fff)
  end)
end
function M.language(text, hint)
  if hint ~= "auto" then
    return hint
  end
  for _, c in ipairs(chars(text)) do
    local n = vim.fn.char2nr(c)
    if n >= 0x3040 and n <= 0x30ff then
      return "ja"
    end
  end
  -- Han-only text cannot reveal the script reliably. Keep the source unchanged.
  return japanese(text) and "zh" or "en"
end
function M.sentences(text, language)
  local found, current = {}, ""
  local endings = language == "ja" and "。！？" or "。！？!?"
  local function flush()
    if vim.trim(current) ~= "" then
      if language == "ja" and not has(endings, chars(current)[#chars(current)]) then
        current = current .. "。"
      end
      found[#found + 1] = current
    end
    current = ""
  end
  for _, c in ipairs(chars(text)) do
    if has(endings, c) then
      if current ~= "" then
        current = current .. c
        flush()
      end
    elseif c == "\n" then
      flush()
    else
      current = current .. c
    end
  end
  flush()
  return found
end
local function chunks(clause)
  local cs, raw, i = chars(clause), {}, 1
  while i <= #cs do
    local start = i
    while i <= #cs and not hira(cs[i]) do
      i = i + 1
    end
    while i <= #cs and hira(cs[i]) do
      i = i + 1
    end
    raw[#raw + 1] = table.concat(cs, "", start, i - 1)
  end
  local merged = {}
  for _, part in ipairs(raw) do
    local last = merged[#merged]
    local tail = last and chars(last)
    tail = tail and tail[#tail]
    if hira(tail) and not has("をにがはでとへものやてばから", tail) then
      merged[#merged] = last .. part
    else
      merged[#merged + 1] = part
    end
  end
  return merged
end
local function parentheses(sentence)
  local cs, outer, inner, i = chars(sentence), {}, {}, 1
  while i <= #cs do
    local close
    if cs[i] == "（" or cs[i] == "(" then
      for j = i + 1, #cs do
        if cs[j] == "）" or cs[j] == ")" then
          close = j
          break
        end
      end
    end
    if close then
      inner[#inner + 1] = table.concat(cs, "", i + 1, close - 1)
      i = close + 1
    else
      outer[#outer + 1] = cs[i]
      i = i + 1
    end
  end
  return table.concat(outer), inner
end
function M.spans(sentence, language)
  local outer, inner = parentheses(sentence)
  local clauses, current = {}, ""
  local separators = language == "ja" and "、。，．！？!?\n「」『』*:："
    or "、。，．！？!?\n「」『』*:：,;；"
  for _, c in ipairs(chars(outer)) do
    if has(separators, c) then
      clauses[#clauses + 1] = current
      current = ""
    else
      current = current .. c
    end
  end
  clauses[#clauses + 1] = current
  vim.list_extend(clauses, inner)
  local found, seen = {}, {}
  for _, clause in ipairs(clauses) do
    -- Chinese has no kana particle boundaries: use punctuation-delimited clauses,
    -- never arbitrary character windows that cut words. English uses clauses too.
    local parts = language == "ja" and chunks(clause) or { clause }
    local windows = {}
    if #parts <= 2 then
      windows[1] = table.concat(parts)
    else
      for i = 1, #parts - 1 do
        windows[#windows + 1] = parts[i] .. parts[i + 1]
      end
    end
    for _, s in ipairs(windows) do
      s = vim.trim(s)
      if s ~= "" and not seen[s] and (language ~= "ja" or japanese(s)) then
        found[#found + 1], seen[s] = s, true
      end
    end
  end
  return found
end
function M.nejire(sentence)
  local cs, out, i = chars(sentence), {}, 1
  while i <= #cs do
    local close = ({ ["「"] = "」", ["『"] = "』" })[cs[i]]
    local at
    if close then
      for j = i + 1, #cs do
        if cs[j] == close then
          at = j
          break
        end
      end
    end
    if at then
      i = at + 1
    else
      out[#out + 1] = cs[i]
      i = i + 1
    end
  end
  while #out > 0 and has("。！？!?」』）) 　", out[#out]) do
    table.remove(out)
  end
  local s, first, finish = table.concat(out)
  local heads = vim.deepcopy(topic_nouns)
  for index, noun in ipairs(heads) do
    heads[index] = noun .. "は"
  end
  for _, clause in ipairs(topic_clauses) do
    heads[#heads + 1], heads[#heads + 2] = clause .. "ことは", clause .. "のは"
  end
  for _, head in ipairs(heads) do
    local a, b = s:find(head, 1, true)
    if a and (not first or a < first) then
      first, finish = a, b
    end
  end
  if not finish then
    return false
  end
  local tail = s:sub(finish + 1)
  if not has(tail, "、") and vim.fn.strchars(tail) < 4 then
    return false
  end
  if
    any(quote_ends, function(v)
      return ends(s, v)
    end)
    or any(existence, function(v)
      return tail:sub(1, #v) == v
    end)
    or any(hedged, function(v)
      local at, last = s:find(v, 1, true)
      while at do
        last = at
        at = s:find(v, at + 1, true)
      end
      return last and not has(s:sub(last + #v), "、")
    end)
    or any(resolved_topic, function(v)
      return has(tail, v)
    end)
    or not (has(tail, "を") or has(tail, "が"))
  then
    return false
  end
  if
    any(noun_ends, function(v)
      return ends(s, v) or any(copulas, function(c)
        return ends(s, v .. c)
      end)
    end)
  then
    return false
  end
  local copula
  for _, c in ipairs(copulas) do
    if ends(s, c) and (not copula or #c > #copula) then
      copula = c
    end
  end
  if copula then
    local before = chars(s:sub(1, #s - #copula))
    return before[#before] == "い" or before[#before] == "た"
  end
  return any(verb_ends, function(v)
    return ends(s, v)
  end) or has("うくぐすつぬぶむる", out[#out])
end
function M.reference(text)
  local refs, run = {}, {}
  local function flush()
    local repeated = false
    for i = 2, #run do
      if run[i] == run[i - 1] then
        repeated = true
      end
    end
    if repeated then
      for i = 1, #run, 80 do
        if #refs == 32 then
          break
        end
        refs[#refs + 1] = table.concat(run, " ", i, math.min(i + 79, #run))
      end
    end
    run = {}
  end
  for _, c in ipairs(chars(text)) do
    local n = vim.fn.char2nr(c)
    if n >= 0x3041 and n <= 0x3096 then
      run[#run + 1] = c
    else
      flush()
    end
  end
  flush()
  return refs
end
return M
