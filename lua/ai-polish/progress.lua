-- Editor-relative progress indicators, independent of buffer text and decorations.
local config = require("ai-polish.config")

local M = {}

local active = {}

---@param bufnr integer
---@return { update: fun(label: string), stop: fun() }
function M.start(bufnr)
  local opts = config.options.ui
  local frames = opts.spinner
  local frame, label = 1, ""
  local buf, win
  local tab = vim.api.nvim_get_current_tabpage()
  local stopped = false
  local timer = assert(vim.uv.new_timer())
  local handle = { tab = tab }
  active[#active + 1] = handle

  function handle.stop()
    stopped = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    for i, item in ipairs(active) do
      if item == handle then
        table.remove(active, i)
        break
      end
    end
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local function draw()
    -- A tick queued by vim.schedule_wrap can run after stop(); drawing then would
    -- re-create the float and leave the spinner behind.
    if stopped then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) or (win and not vim.api.nvim_win_is_valid(win)) then
      handle.stop()
      return
    end

    local slot = 0
    for _, item in ipairs(active) do
      if item == handle then
        break
      end
      if item.tab == tab then
        slot = slot + 1
      end
    end
    local text = " " .. frames[frame] .. " AI Polish: " .. label .. " "
    -- Reserve space for the border, command line and statusline. Recompute on
    -- each tick so resizing never leaves the indicator outside the editor.
    local cfg = {
      relative = "editor",
      anchor = "SE",
      row = math.max(3, vim.o.lines - vim.o.cmdheight - 2 - slot * 3),
      col = math.max(1, vim.o.columns - 1),
      width = math.max(1, math.min(vim.fn.strdisplaywidth(text), vim.o.columns - 4)),
      height = 1,
      style = "minimal",
      border = opts.border,
      focusable = false,
      zindex = 60,
    }
    if not buf then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    if win then
      vim.api.nvim_win_set_config(win, cfg)
    else
      win = vim.api.nvim_open_win(buf, false, cfg)
      vim.wo[win].winhighlight = "NormalFloat:AiPolishProgress,FloatBorder:AiPolishBorder"
      vim.wo[win].winblend = opts.winblend
      vim.wo[win].wrap = false
    end
  end

  timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      frame = frame % #frames + 1
      pcall(draw)
    end)
  )

  function handle.update(l)
    label = l
    pcall(draw)
  end
  return handle
end

return M
