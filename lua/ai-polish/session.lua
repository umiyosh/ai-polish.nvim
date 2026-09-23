-- A review session: suggestions anchored to the buffer with extmarks.
-- Extmarks move with edits, so accepting one suggestion (or editing by hand) never
-- invalidates the positions of the others. Before applying, the anchored text is
-- compared with `before`; a mismatch means the spot was edited and the suggestion is stale.
local M = {}

M.ns = vim.api.nvim_create_namespace("ai-polish")

local SEVERITY_HL = {
  critical = "AiPolishCritical",
  warning = "AiPolishWarning",
  suggestion = "AiPolishSuggestion",
  info = "AiPolishInfo",
}

---@type table<integer, AiPolishSession>
local sessions = {}

---@class AiPolishSession
---@field bufnr integer
---@field items table[]
---@field index integer
local Session = {}
Session.__index = Session

local function hl_for(item, current)
  return current and "AiPolishCurrent" or (SEVERITY_HL[item.severity] or "AiPolishSuggestion")
end

---@param bufnr integer
---@param items table[] each with row, col, end_row, end_col (0-based, end-exclusive) + suggestion fields
---@return AiPolishSession
function M.create(bufnr, items)
  M.clear(bufnr)
  local self = setmetatable({ bufnr = bufnr, items = {}, index = 1 }, Session)
  for _, it in ipairs(items) do
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, it.row, it.col, {
      end_row = it.end_row,
      end_col = it.end_col,
      hl_group = hl_for(it, false),
      right_gravity = false,
      end_right_gravity = true,
      invalidate = true,
      priority = 150,
    })
    if ok then
      self.items[#self.items + 1] = vim.tbl_extend("force", it, { mark = id })
    end
  end
  sessions[bufnr] = self
  self:render()
  return self
end

---@return AiPolishSession|nil
function M.get(bufnr)
  local s = sessions[bufnr]
  if s and vim.api.nvim_buf_is_valid(bufnr) and #s.items > 0 then
    return s
  end
end

function M.clear(bufnr)
  sessions[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

---Current buffer range of an item, or nil when its text was deleted.
---@return integer|nil row, integer col, integer end_row, integer end_col
function Session:range(item)
  local m = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, M.ns, item.mark, { details = true })
  if not m[1] or m[3].invalid then
    return nil
  end
  return m[1], m[2], m[3].end_row, m[3].end_col
end

function Session:current()
  return self.items[self.index]
end

function Session:render()
  for i, it in ipairs(self.items) do
    local row, col, end_row, end_col = self:range(it)
    if row then
      vim.api.nvim_buf_set_extmark(self.bufnr, M.ns, row, col, {
        id = it.mark,
        end_row = end_row,
        end_col = end_col,
        hl_group = hl_for(it, i == self.index),
        right_gravity = false,
        end_right_gravity = true,
        invalidate = true,
        priority = i == self.index and 200 or 150,
      })
    end
  end
end

function Session:remove(i)
  local it = table.remove(self.items, i)
  pcall(vim.api.nvim_buf_del_extmark, self.bufnr, M.ns, it.mark)
  if self.index > #self.items then
    self.index = math.max(#self.items, 1)
  end
  if #self.items == 0 then
    sessions[self.bufnr] = nil
  end
  self:render()
end

---Replace the item's anchored text. Does not remove the item.
---@return boolean ok, string|nil err
function Session:apply(item, replacement)
  local row, col, end_row, end_col = self:range(item)
  if not row then
    return false, "the text of this suggestion was deleted"
  end
  local current = table.concat(vim.api.nvim_buf_get_text(self.bufnr, row, col, end_row, end_col, {}), "\n")
  if current ~= item.before then
    return false, "the text changed since proofreading"
  end
  if not vim.bo[self.bufnr].modifiable then
    return false, "buffer is not modifiable"
  end
  vim.api.nvim_buf_set_text(self.bufnr, row, col, end_row, end_col, vim.split(replacement, "\n", { plain = true }))
  return true
end

---API edits made from another window get no undo sync, so consecutive accepts would
---collapse into one undo step. Re-setting 'undolevels' closes the current undo block.
function Session:undo_break()
  vim.api.nvim_buf_call(self.bufnr, function()
    vim.cmd("let &l:undolevels = &l:undolevels")
  end)
end

---Accept candidate `n` (default 1) of the current suggestion.
---@return boolean ok, string|nil err
function Session:accept(n)
  local item = self:current()
  if not item then
    return false, "no suggestion"
  end
  local replacement = item.after[n or 1]
  if not replacement then
    return false, "no such candidate"
  end
  self:undo_break()
  local ok, err = self:apply(item, replacement)
  -- A stale suggestion can never be applied; drop it either way.
  self:remove(self.index)
  return ok, err
end

function Session:reject()
  if self:current() then
    self:remove(self.index)
  end
end

---Apply the first candidate of every remaining suggestion as a single undo step.
---@return integer applied, integer skipped
function Session:accept_all()
  local applied, skipped = 0, 0
  self:undo_break()
  -- Bottom-up so an earlier replacement cannot shift a later one (extmarks cope anyway,
  -- but this also keeps each item's text check independent).
  for i = #self.items, 1, -1 do
    if applied > 0 then
      pcall(vim.cmd, "undojoin")
    end
    local ok = self:apply(self.items[i], self.items[i].after[1])
    if ok then
      applied = applied + 1
    else
      skipped = skipped + 1
    end
  end
  M.clear(self.bufnr)
  self.items = {}
  return applied, skipped
end

function Session:reject_all()
  M.clear(self.bufnr)
  self.items = {}
end

---Drop suggestions whose anchored text no longer matches (edited or deleted by hand).
---@return integer removed
function Session:prune()
  local removed = 0
  for i = #self.items, 1, -1 do
    local it = self.items[i]
    local row, col, end_row, end_col = self:range(it)
    local text = row and table.concat(vim.api.nvim_buf_get_text(self.bufnr, row, col, end_row, end_col, {}), "\n")
    if text ~= it.before then
      pcall(vim.api.nvim_buf_del_extmark, self.bufnr, M.ns, it.mark)
      table.remove(self.items, i)
      if i < self.index then
        self.index = self.index - 1
      end
      removed = removed + 1
    end
  end
  self.index = math.min(math.max(self.index, 1), math.max(#self.items, 1))
  if #self.items == 0 then
    sessions[self.bufnr] = nil
  end
  self:render()
  return removed
end

function Session:move(delta)
  if #self.items == 0 then
    return
  end
  self.index = (self.index - 1 + delta) % #self.items + 1
  self:render()
end

---Jump to the item at or after the cursor position.
function Session:focus_near(row, col)
  for i, it in ipairs(self.items) do
    local r, _, er, ec = self:range(it)
    if r and (er > row or (er == row and ec >= col)) then
      self.index = i
      self:render()
      return
    end
  end
end

return M
