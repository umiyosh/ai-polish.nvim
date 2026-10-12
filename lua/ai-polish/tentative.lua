--- Jev's tentative marks in a buffer (Kotobae src/proofread/ui/tentative.ts): underlines that show
--- where to look while Gemini is still writing. Marks add up as Jev's requests answer and move
--- with edits as extmarks. Gemini writes its fixes in text order, so a mark gives way when a fix
--- lands on it and is dropped once fixes have moved past it; whatever is left goes when the check
--- ends.
local text = require("ai-polish.text")

local M = {}

M.ns = vim.api.nvim_create_namespace("ai-polish-tentative")

---@type table<integer, AiPolishTentative>
local active = {}

---@class AiPolishTentative
---@field bufnr integer
---@field content string the region text the marks were asked about
---@field row0 integer
---@field col0 integer
---@field tick integer
---@field closed boolean
local Tentative = {}
Tentative.__index = Tentative

---@param ranges { from: integer, to: integer }[] byte ranges in `content`
function Tentative:add(ranges)
  -- An answer about a text the user has since edited may point at the wrong characters.
  if self.closed or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end
  if vim.api.nvim_buf_get_changedtick(self.bufnr) ~= self.tick then
    return
  end
  for _, r in ipairs(ranges) do
    local row, col = text.pos_at(self.content, r.from, self.row0, self.col0)
    local end_row, end_col = text.pos_at(self.content, r.to, self.row0, self.col0)
    pcall(vim.api.nvim_buf_set_extmark, self.bufnr, M.ns, row, col, {
      end_row = end_row,
      end_col = end_col,
      hl_group = "AiPolishTentative",
      priority = 90, -- below suggestions, which take over the spot
    })
  end
end

local function before(ar, ac, br, bc)
  return ar < br or (ar == br and ac < bc)
end

---Fixes that just arrived, in buffer positions. Takes them as they come, so streaming (#17) can
---call this per fix; until then the whole answer arrives at once.
---@param fixes { row: integer, col: integer, end_row: integer, end_col: integer }[]
function Tentative:reached(fixes)
  if self.closed or #fixes == 0 or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end
  local rr, rc = fixes[1].row, fixes[1].col
  for _, f in ipairs(fixes) do
    if before(rr, rc, f.row, f.col) then
      rr, rc = f.row, f.col
    end
  end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(self.bufnr, M.ns, 0, -1, { details = true })) do
    local id, row, col, d = m[1], m[2], m[3], m[4]
    local passed = not before(rr, rc, d.end_row, d.end_col)
    local landed = vim.iter(fixes):any(function(f)
      return before(row, col, f.end_row, f.end_col) and before(f.row, f.col, d.end_row, d.end_col)
    end)
    if passed or landed then
      vim.api.nvim_buf_del_extmark(self.bufnr, M.ns, id)
    end
  end
end

---Start a check's marks, replacing those of an earlier check. `row0`/`col0` is where `content`
---starts in the buffer.
---@return AiPolishTentative
function M.start(bufnr, content, row0, col0)
  M.clear(bufnr)
  local t = setmetatable({
    bufnr = bufnr,
    content = content,
    row0 = row0,
    col0 = col0,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    closed = false,
  }, Tentative)
  active[bufnr] = t
  return t
end

---@return AiPolishTentative|nil
function M.get(bufnr)
  return active[bufnr]
end

---Remove every mark of the buffer; answers still on their way are ignored.
function M.clear(bufnr)
  local t = active[bufnr]
  if t then
    t.closed = true
    active[bufnr] = nil
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

return M
