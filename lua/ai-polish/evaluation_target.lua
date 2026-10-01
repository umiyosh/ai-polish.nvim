-- 0-based, end-exclusive targets. Separate from disposable proofreading sessions.
local M = {}
M.ns = vim.api.nvim_create_namespace("ai-polish-evaluation-target")

function M.whole(buf)
  local last = vim.api.nvim_buf_line_count(buf) - 1
  return { 0, 0, last, #(vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or "") }
end

function M.read(buf, range)
  local ok, lines = pcall(vim.api.nvim_buf_get_text, buf, range[1], range[2], range[3], range[4], {})
  return ok and table.concat(lines, "\n") or nil
end

-- getregionpos handles reversed selections, 'selection=exclusive', UTF-8 and EOL.
function M.visual(buf, active)
  local mode = active and vim.fn.mode() or vim.fn.visualmode()
  if mode ~= "v" and mode ~= "V" then
    return nil, "unsupported"
  end
  local a = active and vim.fn.getpos("v") or vim.fn.getpos("'<")
  local b = active and vim.fn.getpos(".") or vim.fn.getpos("'>")
  a[1], b[1] = buf, buf
  if a[2] == 0 or b[2] == 0 then
    return nil, "invalid_target"
  end
  local ok, regions = pcall(vim.fn.getregionpos, a, b, { type = mode, exclusive = vim.o.selection == "exclusive" })
  if not ok or #regions == 0 then
    return nil, "invalid_target"
  end
  local first, last = regions[1][1], regions[#regions][2]
  if mode == "V" then
    local line = vim.api.nvim_buf_get_lines(buf, last[2] - 1, last[2], false)[1] or ""
    return { first[2] - 1, 0, last[2] - 1, #line }, nil, "lines"
  end
  local line = vim.api.nvim_buf_get_lines(buf, last[2] - 1, last[2], false)[1] or ""
  local col = math.min(last[3], #line)
  if col > 0 and col < #line then
    col = col + vim.str_utf_end(line, col)
  end
  return { first[2] - 1, math.max(0, first[3] - 1), last[2] - 1, col }, nil, "selection"
end

function M.set(buf, range, kind)
  if not range then
    return { kind = "whole" }
  end
  return {
    kind = kind or "selection",
    mark = vim.api.nvim_buf_set_extmark(buf, M.ns, range[1], range[2], {
      end_row = range[3],
      end_col = range[4],
      right_gravity = false,
      end_right_gravity = true,
    }),
  }
end

function M.range(buf, target)
  if not target or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return nil
  end
  if target.kind == "whole" then
    return M.whole(buf)
  end
  if target.invalid then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, target.mark, { details = true })
  if not mark[1] or (mark[1] == mark[3].end_row and mark[2] == mark[3].end_col) then
    target.invalid = true
    return nil
  end
  return { mark[1], mark[2], mark[3].end_row, mark[3].end_col }
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end
return M
