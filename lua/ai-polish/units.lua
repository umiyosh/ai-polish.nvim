--- Splits Japanese text into numbered units close to bunsetsu, for asking Gemini and Jev about
--- the same places by number. BudouX (vendored, see vendor/budoux/README.md) finds the phrase
--- boundaries; the rules around it follow Kotobae's units.rs, so its numbers line up: marks
--- join the unit before them, opening brackets the one after, spaces belong to no unit, and
--- sentences end at 。！？ (kept) or a line break (dropped).
---
--- Positions are 0-based byte offsets with `to` exclusive, like Neovim's extmark columns.
local M = {}

---@class ai_polish.Unit
---@field n integer 1-based, in text order
---@field from integer
---@field to integer
---@field sentence integer index into `sentences`

---@class ai_polish.Range
---@field from integer
---@field to integer

local function set(chars)
  local out = {}
  for _, c in ipairs(chars) do
    out[c] = true
  end
  return out
end

local SPACES = set({ " ", "\t", "\r", "\n", "　" })
local OPENING = set({ "「", "『", "（", "(", "【", "［", "[", "〈", "《", "“", "‘", "｛", "{", "〔" })
local MARKS = set({
  "。",
  "、",
  "，",
  "．",
  "・",
  "：",
  "；",
  "！",
  "？",
  "」",
  "』",
  "）",
  "】",
  "］",
  "〉",
  "》",
  "”",
  "’",
  "｝",
  "〕",
  "…",
  "‥",
})
local SENTENCE_ENDS = set({ "。", "！", "？" })

---@param c string one UTF-8 character
local function is_mark(c)
  return MARKS[c] or (#c == 1 and c:match("%p") ~= nil and not OPENING[c])
end

---@param s string
---@return { c: string, from: integer, to: integer }[] characters with 0-based byte offsets
local function characters(s)
  local out = {}
  for at, c in s:gmatch("()([%z\1-\127\194-\253][\128-\191]*)") do
    out[#out + 1] = { c = c, from = at - 1, to = at - 1 + #c }
  end
  return out
end

---@param text string
---@return ai_polish.Range[]
function M.sentences(text)
  local out, start = {}, 0
  local function push(from, to)
    if text:sub(from + 1, to):find("[^%s　]") then
      out[#out + 1] = { from = from, to = to }
    end
  end
  for _, ch in ipairs(characters(text)) do
    if SENTENCE_ENDS[ch.c] then
      push(start, ch.to)
      start = ch.to
    elseif ch.c == "\n" then
      push(start, ch.from)
      start = ch.to
    end
  end
  push(start, #text)
  return out
end

local parser
local function budoux(sentence)
  if not parser then
    local lib = require("ai-polish.vendor.budoux")
    parser = lib.Parser.new(require("ai-polish.vendor.budoux.models.ja"))
  end
  return parser:parse(sentence)
end

-- BudouX breaks lines, so it starts a phrase at formal nouns and postpositions that a bunsetsu
-- keeps with the word before (その日の|うちに, 注意点と|して), and its model sometimes breaks
-- before a small kana or ー (旧バージ|ョン). Chunks starting like these stay with the unit before.
local DEPENDENT = {
  "こと",
  "もの",
  "ため",
  "ところ",
  "うち",
  "という",
  "といった",
  "として",
  "について",
  "にとって",
  "によって",
  "による",
  "において",
  "における",
  "に関して",
  "に対して",
  "とともに",
  "ほど",
  "ばかり",
  -- BudouX also breaks after the と or に of a postposition (注意点と|して, 対策に|ついて).
  "して",
  "ついて",
  "いう",
}
local SMALL = set({
  "ぁ",
  "ぃ",
  "ぅ",
  "ぇ",
  "ぉ",
  "っ",
  "ゃ",
  "ゅ",
  "ょ",
  "ゎ",
  "ァ",
  "ィ",
  "ゥ",
  "ェ",
  "ォ",
  "ッ",
  "ャ",
  "ュ",
  "ョ",
  "ヮ",
  "ー",
})

local function depends(chunk)
  if SMALL[chunk:match("^[%z\1-\127\194-\253][\128-\191]*")] then
    return true
  end
  for _, word in ipairs(DEPENDENT) do
    if chunk:sub(1, #word) == word then
      return true
    end
  end
  return false
end

--- Where each chunk the parser returned starts, relative to the sentence; when the chunks do not
--- rebuild the sentence, the whole sentence is one chunk.
local function chunk_starts(sentence, chunks)
  local starts, at = {}, 0
  for i, chunk in ipairs(chunks) do
    if sentence:sub(at + 1, at + #chunk) ~= chunk then
      return { [0] = true }
    end
    starts[at] = i == 1 or not depends(chunk)
    at = at + #chunk
  end
  return at == #sentence and starts or { [0] = true }
end

---@param text string
---@param opts? { parse?: fun(sentence: string): string[] }
---@return { units: ai_polish.Unit[], sentences: ai_polish.Range[] }
function M.split(text, opts)
  local parse = opts and opts.parse or budoux
  local sentences = M.sentences(text)
  local units = {}
  for index, s in ipairs(sentences) do
    local sentence = text:sub(s.from + 1, s.to)
    local starts = chunk_starts(sentence, parse(sentence))
    -- `open`: the last unit can take the next character; `opening`: where brackets wait.
    local open, opening = false, nil
    local function start(from, to)
      units[#units + 1] = { n = #units + 1, from = from, to = to, sentence = index }
      open = true
    end
    for _, ch in ipairs(characters(sentence)) do
      local from, to = s.from + ch.from, s.from + ch.to
      local last = units[#units]
      if SPACES[ch.c] then
        open, opening = false, nil
      elseif OPENING[ch.c] then
        open, opening = false, opening or from
      elseif is_mark(ch.c) then
        -- Adjacent marks join the unit before even past a sentence end, as in Kotobae: the second
        -- 。 of 「。。」 starts a sentence of its own, and left out of every unit a fix of 「。。」
        -- fell outside its numbers.
        if last and last.to == from and not opening then
          last.to = to
        else
          opening = opening or from
        end
      elseif opening then
        start(opening, to)
        opening = nil
      elseif open and not starts[ch.from] and last.to == from then
        last.to = to
      else
        start(from, to)
      end
    end
  end
  return { units = units, sentences = sentences }
end

return M
