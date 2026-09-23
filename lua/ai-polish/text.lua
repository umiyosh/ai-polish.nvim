-- Pure text helpers: chunking, size/cost estimation, locating suggestions.
-- All offsets are 0-based byte offsets into the joined text ("\n" line separators).
local M = {}

function M.chars(s)
  return vim.fn.strchars(s)
end

---Byte length of the first `n` characters of `s` (never splits a UTF-8 sequence).
local function byte_len_of_chars(s, n)
  if n >= M.chars(s) then
    return #s
  end
  return vim.fn.byteidx(s, n)
end

---Byte index of the end of the last occurrence of any literal in `lits` (excluding the very end).
local function last_of(s, lits)
  local best
  for _, lit in ipairs(lits) do
    local init = 1
    while true do
      local _, e = s:find(lit, init, true)
      if not e then
        break
      end
      if e < #s and (not best or e > best) then
        best = e
      end
      init = e + 1
    end
  end
  return best
end

-- Break preference: paragraph, line, sentence end, clause, whitespace.
-- Literals, not Lua patterns: a `[...]` class would match single bytes inside
-- multibyte characters and split them.
local BREAKS = {
  { "\n\n" },
  { "\n" },
  { "。", "．", "！", "？", "! ", "? ", ". " },
  { "、", "，", ", " },
  { " ", "\t", "　" },
}

local function last_break(s)
  for _, lits in ipairs(BREAKS) do
    local e = last_of(s, lits)
    if e then
      -- Keep a run of blank lines together with the preceding paragraph.
      while s:sub(e + 1, e + 1) == "\n" and e + 1 < #s do
        e = e + 1
      end
      return e
    end
  end
end

---Split text into chunks of at most `max_chars` characters, preferring natural boundaries.
---@return { text: string, offset: integer }[]
function M.chunk(text, max_chars)
  local chunks = {}
  local pos = 0
  local rest = text
  while M.chars(rest) > max_chars do
    local window = rest:sub(1, byte_len_of_chars(rest, max_chars))
    local cut = last_break(window)
    -- Avoid degenerate tiny chunks when the only break is near the start.
    if not cut or M.chars(window:sub(1, cut)) < max_chars / 4 then
      cut = #window
    end
    chunks[#chunks + 1] = { text = rest:sub(1, cut), offset = pos }
    pos = pos + cut
    rest = rest:sub(cut + 1)
  end
  if rest ~= "" then
    chunks[#chunks + 1] = { text = rest, offset = pos }
  end
  return chunks
end

---Rough token count. ASCII ≈ 4 chars/token, other scripts (CJK etc.) ≈ 1 char/token.
---Deliberately conservative; no API call is made before the user confirms.
function M.estimate_tokens(s)
  local ascii = select(2, s:gsub("[%z\1-\127]", ""))
  local other = M.chars(s) - ascii
  return math.ceil(ascii / 4 + other)
end

local PROMPT_OVERHEAD_TOKENS = 700
local OUTPUT_OVERHEAD_TOKENS = 600 -- low-effort thinking + JSON envelope

---@param chunks { text: string }[]
---@param pricing AiPolishPricing
function M.estimate(chunks, pricing)
  local input, output, chars = 0, 0, 0
  for _, c in ipairs(chunks) do
    local t = M.estimate_tokens(c.text)
    chars = chars + M.chars(c.text)
    input = input + t + PROMPT_OVERHEAD_TOKENS
    -- Suggestions quote the text (before/after/context), so output scales with input.
    output = output + math.ceil(t * 0.6) + OUTPUT_OVERHEAD_TOKENS
  end
  local cost = input / 1e6 * pricing.input_per_mtok + output / 1e6 * pricing.output_per_mtok
  return { chars = chars, requests = #chunks, input_tokens = input, output_tokens = output, cost_usd = cost }
end

local function common_suffix(a, b)
  local n = 0
  while n < #a and n < #b and a:byte(#a - n) == b:byte(#b - n) do
    n = n + 1
  end
  return n
end

local function common_prefix(a, b)
  local n = 0
  while n < #a and n < #b and a:byte(n + 1) == b:byte(n + 1) do
    n = n + 1
  end
  return n
end

---Find the byte range of `s.before` in `text`, using the surrounding context to pick among
---duplicate occurrences.
---@return integer|nil start, integer|nil finish  0-based, end-exclusive
function M.locate(text, s)
  local best, best_score
  local init = 1
  while true do
    local i, j = text:find(s.before, init, true)
    if not i then
      break
    end
    local score = common_suffix(text:sub(1, i - 1), s.context_before or "")
      + common_prefix(text:sub(j + 1), s.context_after or "")
    if not best_score or score > best_score then
      best, best_score = { i - 1, j }, score
    end
    init = i + 1
  end
  if best then
    return best[1], best[2]
  end
end

---Locate every suggestion, drop unlocatable and overlapping ones (earlier position wins).
---@return table[] resolved sorted by start, integer dropped
function M.resolve(text, suggestions, offset)
  offset = offset or 0
  local located = {}
  local dropped = 0
  for _, s in ipairs(suggestions) do
    local a, b = M.locate(text, s)
    if a then
      located[#located + 1] = vim.tbl_extend("force", s, { start = a + offset, finish = b + offset })
    else
      dropped = dropped + 1
    end
  end
  table.sort(located, function(x, y)
    return x.start < y.start or (x.start == y.start and x.finish < y.finish)
  end)
  local out = {}
  local last_end = -1
  for _, s in ipairs(located) do
    if s.start >= last_end then
      out[#out + 1] = s
      last_end = s.finish
    else
      dropped = dropped + 1
    end
  end
  return out, dropped
end

---Convert a byte offset in `text` to a buffer position, given where `text` starts.
---@return integer row, integer col 0-based
function M.pos_at(text, off, start_row, start_col)
  local prefix = text:sub(1, off)
  local row, last_nl = 0, nil
  for idx in prefix:gmatch("()\n") do
    row = row + 1
    last_nl = idx
  end
  if row == 0 then
    return start_row, start_col + off
  end
  return start_row + row, off - last_nl
end

return M
