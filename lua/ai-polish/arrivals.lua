--- Places Gemini's streamed suggestions in the buffer as they arrive, as Kotobae's main window
--- does (src/proofread/ui/arrivals.ts): positions follow the edits made since the text was sent,
--- a suggestion whose text was edited is dropped, and one overlapping a suggestion that already
--- arrived (even one handled since) is dropped.
---
--- Each unit of a numbered chunk is anchored with an extmark when the text is sent, so a fix
--- named by unit numbers is looked for where those units are now. Text that is not split
--- (English, Chinese) is searched for by `before` and its context.
local numbered = require("ai-polish.numbered")
local text = require("ai-polish.text")

local M = {}

M.ns = vim.api.nvim_create_namespace("ai-polish-arrivals")

---@class AiPolishArrivals
---@field bufnr integer
---@field chunks { extent: integer, units?: integer[] }[]
---@field arrived integer[] extmarks of every suggestion placed so far
local Arrivals = {}
Arrivals.__index = Arrivals

-- Text typed at either edge of a span stays outside it; deleting all of it invalidates it.
local function anchor(bufnr, row, col, end_row, end_col)
  return vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, col, {
    end_row = end_row,
    end_col = end_col,
    right_gravity = true,
    end_right_gravity = false,
    invalidate = true,
  })
end

---Anchor the chunks of a check. `content` starts at (`row0`, `col0`) in the buffer.
---@param chunks { text: string, offset: integer, split?: { units: ai_polish.Unit[] } }[]
---@return AiPolishArrivals
function M.start(bufnr, chunks, content, row0, col0)
  local self = setmetatable({ bufnr = bufnr, chunks = {}, arrived = {} }, Arrivals)
  local function pos(off)
    return text.pos_at(content, off, row0, col0)
  end
  for i, c in ipairs(chunks) do
    local r1, c1 = pos(c.offset)
    local r2, c2 = pos(c.offset + #c.text)
    local entry = { extent = anchor(bufnr, r1, c1, r2, c2) }
    if c.split then
      entry.units = {}
      for n, u in ipairs(c.split.units) do
        local ur1, uc1 = pos(c.offset + u.from)
        local ur2, uc2 = pos(c.offset + u.to)
        entry.units[n] = anchor(bufnr, ur1, uc1, ur2, uc2)
      end
    end
    self.chunks[i] = entry
  end
  return self
end

---Current range of an anchor, or nil when its text was deleted.
function Arrivals:range(id)
  local m = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, M.ns, id, { details = true })
  if not m[1] or m[3].invalid then
    return nil
  end
  return { row = m[1], col = m[2], end_row = m[3].end_row, end_col = m[3].end_col }
end

---Where chunk `i` lies now.
function Arrivals:scope(i)
  return self:range(self.chunks[i].extent)
end

local function before(ar, ac, br, bc)
  return ar < br or (ar == br and ac < bc)
end

local function overlaps(x, y)
  return before(x.row, x.col, y.end_row, y.end_col) and before(y.row, y.col, x.end_row, x.end_col)
end

---Turn suggestions of chunk `i` into review items at their current buffer positions.
---@param raws table[] validated suggestions; numbered ones carry `from`/`to`
---@return table[] items with row, col, end_row, end_col, integer dropped
function Arrivals:place(i, raws)
  local chunk = self.chunks[i]
  local scope = self:scope(i)
  local items, dropped = {}, 0
  if not scope then
    return items, #raws
  end
  -- The chunk's current text: units are looked up in it, and positions converted back from it.
  local lines = vim.api.nvim_buf_get_text(self.bufnr, scope.row, scope.col, scope.end_row, scope.end_col, {})
  local cur = table.concat(lines, "\n")
  local function offset(row, col)
    return text.offset_at(cur, row, col, scope.row, scope.col)
  end
  for _, raw in ipairs(raws) do
    local s
    if chunk.units then
      local first = numbered.in_range(raw, #chunk.units) and self:range(chunk.units[raw.from])
      local last = first and self:range(chunk.units[raw.to])
      local lo = last and offset(first.row, first.col)
      local hi = lo and offset(last.end_row, last.end_col)
      s = hi and numbered.place_span(cur, lo, hi, raw)
    else
      local a, b = text.locate(cur, raw)
      s = a and vim.tbl_extend("force", raw, { start = a, finish = b })
    end
    local item
    if s then
      local row, col = text.pos_at(cur, s.start, scope.row, scope.col)
      local end_row, end_col = text.pos_at(cur, s.finish, scope.row, scope.col)
      item = vim.tbl_extend("force", s, { row = row, col = col, end_row = end_row, end_col = end_col })
      for _, id in ipairs(self.arrived) do
        local r = self:range(id)
        if r and overlaps(r, item) then
          item = nil
          break
        end
      end
    end
    if item then
      self.arrived[#self.arrived + 1] = vim.api.nvim_buf_set_extmark(self.bufnr, M.ns, item.row, item.col, {
        end_row = item.end_row,
        end_col = item.end_col,
        right_gravity = false,
        end_right_gravity = true,
      })
      items[#items + 1] = item
    else
      dropped = dropped + 1
    end
  end
  return items, dropped
end

function Arrivals:clear()
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_clear_namespace(self.bufnr, M.ns, 0, -1)
  end
end

return M
