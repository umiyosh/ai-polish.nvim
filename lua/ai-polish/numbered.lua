--- Numbered fixes, ported from Kotobae's gemini/numbered.rs: Gemini gets Japanese text with each
--- bunsetsu numbered (〔1〕, 〔2〕, …) and names a fix by the numbers of the bunsetsu it touches
--- plus the exact text it changes (`before`). Positions then come from the numbers instead of
--- quoted context, which halved Gemini's output in Kotobae, and a fix whose `before` is not inside
--- its numbers is dropped instead of replacing text Gemini never quoted.
---
--- Offsets are 0-based bytes into the text, end exclusive.
local M = {}

-- Context kept with a placed fix, so it can still be found after the buffer was edited.
local CONTEXT_CHARS = 10

---@param text string
---@param split { units: ai_polish.Unit[] }
---@return string
function M.text(text, split)
  local out, cursor = {}, 0
  for i, u in ipairs(split.units) do
    out[#out + 1] = text:sub(cursor + 1, u.from)
    out[#out + 1] = ("〔%d〕"):format(i)
    out[#out + 1] = text:sub(u.from + 1, u.to)
    cursor = u.to
  end
  out[#out + 1] = text:sub(cursor + 1)
  return table.concat(out)
end

--- Gemini sometimes copies the 〔n〕 markers into `before`; they are not part of the text.
function M.strip_numbers(s)
  return (s:gsub("〔%d+〕", ""))
end

local MARKS = { ["。"] = true, ["、"] = true, ["！"] = true, ["？"] = true }

--- Gemini ends some fixes with a mark the text already has right after `before` (「すすん」→「。」
--- before an existing 「。」), and adopting one left the mark twice (Kotobae #76). Such a fix
--- takes that mark in, and alternatives without it keep it, so each one means what Gemini wrote.
local function take_following_mark(text, finish, after)
  local mark = text:sub(finish + 1):match("^[%z\1-\127\194-\253][\128-\191]*")
  if not mark or not MARKS[mark] then
    return finish, after
  end
  local ends = function(a)
    return a:sub(-#mark) == mark
  end
  if not vim.iter(after):any(ends) then
    return finish, after
  end
  return finish + #mark, vim.tbl_map(function(a)
    return ends(a) and a or a .. mark
  end, after)
end

---@param text string
---@param n integer characters
local function tail(text, n)
  local len = vim.fn.strchars(text)
  return len <= n and text or vim.fn.strcharpart(text, len - n)
end

---Whether `raw` names units that exist among `count`.
function M.in_range(raw, count)
  return type(raw.from) == "number"
    and type(raw.to) == "number"
    and raw.from >= 1
    and raw.from <= raw.to
    and raw.to <= count
end

---Turn one of Gemini's answers into a suggestion positioned in `text`, or nil to drop it.
---@param raw { from: integer, to: integer, before: string, after: string[], category?: string, severity?: string, message?: string }
---@return table|nil suggestion with `start`/`finish`, `context_before`/`context_after`
function M.place(text, split, raw)
  local units = split.units
  if not M.in_range(raw, #units) then
    return nil
  end
  return M.place_span(text, units[raw.from].from, units[raw.to].to, raw)
end

---Place `raw` inside bytes `lo`..`hi` of `text`, where its units lie now. A streamed suggestion
---uses the current extent of its units, which have moved with edits made while it was coming.
function M.place_span(text, lo, hi, raw)
  local before = M.strip_numbers(raw.before or "")
  if before == "" then
    return nil
  end
  local at = text:sub(lo + 1, hi):find(before, 1, true)
  if not at then
    return nil
  end
  local start = lo + at - 1
  local finish, after = take_following_mark(text, start + #before, raw.after or {})
  before = text:sub(start + 1, finish)
  after = vim.tbl_filter(function(a)
    return a ~= before
  end, after)
  if #after == 0 then
    return nil
  end
  local s = vim.tbl_extend("force", raw, {
    before = before,
    after = after,
    start = start,
    finish = finish,
    context_before = tail(text:sub(1, start), CONTEXT_CHARS),
    context_after = vim.fn.strcharpart(text:sub(finish + 1), 0, CONTEXT_CHARS),
  })
  s.from, s.to = nil, nil
  return s
end

---@return table[] placed, integer dropped
function M.place_all(text, split, raws)
  local placed, dropped = {}, 0
  for _, raw in ipairs(raws) do
    local s = M.place(text, split, raw)
    if s then
      placed[#placed + 1] = s
    else
      dropped = dropped + 1
    end
  end
  return placed, dropped
end

return M
