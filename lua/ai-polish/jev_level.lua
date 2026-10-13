--- The unnaturalness level, ported from Kotobae's src-tauri/src/services/jev/level.rs: how much a
--- text needs fixing, on five levels. Level 1 means almost nothing to fix; 2 to 5 take the larger
--- of what the errors (the local check) and the rewriting (the bunsetsu Jev marks) say. Kotobae
--- chose it on its evaluator's gold: QWK rose from 0.36 to 0.68 on dev and holdout and from 0.24
--- to 0.63 on fresh, while correct texts rated 3 or higher went from 3 to 2 of 84.
local M = {}

-- The local check's threshold for a correction (jev_ja.json `correctionThreshold`).
local CORRECTION = 0.37

--- The marks Jev puts on correct texts too, taken off before marks count as rewriting: a share
--- of the bunsetsu, or at least a number of marks.
---@class ai_polish.Background
---@field share number
---@field marks number

-- Written style marks about 3% of a correct long text, or up to 2 marks.
M.WRITTEN = { share = 0.03, marks = 2 }
-- The errors measure marks fewer bunsetsu; with marks of either measure confirming errors, 2%
-- matched the written level on Kotobae's fresh set where errors-only confirmation fell (#77).
M.ERRORS = { share = 0.02, marks = 2 }
-- A short text counts its marks as if it had this many bunsetsu, so one mark on a sentence of
-- five bunsetsu does not read as a fifth of the text to rewrite.
local MIN_UNITS = 20
-- Shares of bunsetsu to rewrite, beyond the background, that start levels 2 to 5. Level 5 needs
-- close to a third, so a text full of spoken style is not 5 whenever it has some.
local REWRITE_CUTS = { 0.02, 0.06, 0.15, 0.3 }

--- Whether a mark lies in the sentence of an error the local check found.
---@param marks { from: integer, to: integer }[] byte ranges in `text`
local function corroborated(check, text, marks)
  for _, f in ipairs(check.findings or {}) do
    local at = f.value >= CORRECTION and text:find(f.sentence, 1, true)
    if at then
      local start, finish = at - 1, at - 1 + #f.sentence
      for _, m in ipairs(marks) do
        if m.from < finish and start < m.to then
          return true
        end
      end
    end
  end
  return false
end

--- Like `level`, with the marks that confirm the local check's errors given apart.
---@param check { level: integer, value: number, findings: table[] } the local check
---@param marks { from: integer, to: integer }[] the bunsetsu Jev marked
---@param confirming { from: integer, to: integer }[]
---@param units integer bunsetsu in the text
---@param background ai_polish.Background
---@return integer
function M.level_with(check, text, marks, confirming, units, background)
  local floor = math.max(background.share * units, background.marks)
  local marked = #marks
  if check.value < CORRECTION and marked <= floor then
    return 1
  end
  local rewrite = math.max(marked - floor, 0) / math.max(units, MIN_UNITS)
  local rewrite_level = 1
  for _, cut in ipairs(REWRITE_CUTS) do
    if rewrite >= cut then
      rewrite_level = rewrite_level + 1
    end
  end
  -- The local check alone puts correct texts at 3 too often, sometimes with full confidence;
  -- a mark in the same sentence separates those from real errors.
  local error_level = check.level
  if check.level >= 3 and not corroborated(check, text, confirming) then
    error_level = 2
  end
  return math.min(math.max(error_level, rewrite_level, 2), 5)
end

---@return integer
function M.level(check, text, marks, units, background)
  return M.level_with(check, text, marks, marks, units, background)
end

--- Both levels from the local check and the marks of both measures, as Kotobae's with_marks:
--- the default level counts errors marks with errors and written marks confirming, and the
--- written level counts written marks.
---@return integer level, integer written_level
function M.both(check, text, errors, written, units)
  local confirming = vim.list_extend(vim.list_extend({}, errors), written)
  return M.level_with(check, text, errors, confirming, units, M.ERRORS), M.level(check, text, written, units, M.WRITTEN)
end

return M
