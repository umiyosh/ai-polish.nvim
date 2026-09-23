-- In-buffer progress indicator: a spinner as virtual text at the end of the target's first line.
local config = require("ai-polish.config")

local M = {}

local ns = vim.api.nvim_create_namespace("ai-polish-progress")

---@param bufnr integer
---@param row integer 0-based
---@return { update: fun(label: string), stop: fun() }
function M.start(bufnr, row)
  local frames = config.options.ui.spinner
  local frame, label = 1, ""
  local mark
  local stopped = false
  local timer = assert(vim.uv.new_timer())

  local function draw()
    -- A tick queued by vim.schedule_wrap can run after stop(); drawing then would
    -- re-create the deleted mark and leave the spinner behind.
    if stopped or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local r = mark and vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})[1] or row
    mark = vim.api.nvim_buf_set_extmark(bufnr, ns, r or row, 0, {
      id = mark,
      virt_text = { { frames[frame] .. " AI Polish: " .. label, "AiPolishProgress" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end

  timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      frame = frame % #frames + 1
      pcall(draw)
    end)
  )

  local handle = {}
  function handle.update(l)
    label = l
    pcall(draw)
  end
  function handle.stop()
    stopped = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if vim.api.nvim_buf_is_valid(bufnr) and mark then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
    end
  end
  return handle
end

return M
