local progress = require("ai-polish.progress")
local config = require("ai-polish.config")

describe("progress", function()
  local handles, buffers
  local original_columns, original_lines, original_winblend

  local function floats()
    return vim.tbl_filter(function(win)
      return vim.api.nvim_win_get_config(win).relative ~= ""
    end, vim.api.nvim_list_wins())
  end

  local function start()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("text", 100), "last line" })
    buffers[#buffers + 1] = buf
    local spinner = progress.start(buf)
    handles[#handles + 1] = spinner
    spinner.update("proofreading…")
    return spinner, buf
  end

  before_each(function()
    handles, buffers = {}, {}
    original_columns, original_lines, original_winblend = vim.o.columns, vim.o.lines, vim.o.winblend
    config.setup({})
  end)

  after_each(function()
    for _, handle in ipairs(handles) do
      handle.stop()
    end
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.o.columns, vim.o.lines, vim.o.winblend = original_columns, original_lines, original_winblend
    config.setup({})
  end)

  it("keeps progress in an editor-relative float without taking focus or adding inline text", function()
    local current = vim.api.nvim_get_current_win()
    vim.o.winblend = 30
    local spinner, buf = start()
    assert.equals(1, #floats())
    local win = floats()[1]
    local cfg = vim.api.nvim_win_get_config(win)
    assert.equals("editor", cfg.relative)
    assert.equals("SE", cfg.anchor)
    assert.is_false(cfg.focusable)
    assert.equals(current, vim.api.nvim_get_current_win())
    assert.equals(0, vim.wo[win].winblend)
    assert.is_false(vim.wo[win].wrap)
    local ns = vim.api.nvim_create_namespace("ai-polish-progress")
    assert.same({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))

    spinner.update("proofreading 2/5…")
    local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)[1]
    assert.matches("AI Polish: proofreading 2/5…", text, 1, true)
    assert.is_true(vim.wait(500, function()
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)[1] ~= text
    end))
  end)

  it("fits inside the editor after resizing, even with a long label", function()
    local spinner = start()
    local win = floats()[1]
    vim.o.columns, vim.o.lines = 30, 10
    spinner.update(string.rep("校正中", 30))
    local cfg = vim.api.nvim_win_get_config(win)
    assert.is_true(cfg.row - cfg.height - 2 >= 0)
    assert.is_true(cfg.col - cfg.width - 2 >= 0)
    assert.is_true(cfg.row <= vim.o.lines - vim.o.cmdheight)
    assert.is_true(cfg.col <= vim.o.columns)
  end)

  it("honours the existing border and transparency options", function()
    config.setup({ ui = { border = "none", winblend = 25 } })
    start()
    local win = floats()[1]
    assert.is_nil(vim.api.nvim_win_get_config(win).border)
    assert.equals(25, vim.wo[win].winblend)
  end)

  it("cleans up the window and scratch buffer when the source buffer is wiped", function()
    local spinner, buf = start()
    local win = floats()[1]
    local scratch = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_true(vim.wait(500, function()
      return not vim.api.nvim_win_is_valid(win)
    end))
    assert.is_false(vim.api.nvim_buf_is_valid(scratch))
    spinner.update("late response")
    assert.same({}, floats())
  end)

  it("keeps concurrent buffers' indicators separate and stops them independently", function()
    local first = start()
    local second = start()
    local wins = floats()
    assert.equals(2, #wins)
    assert.is_not.same(vim.api.nvim_win_get_position(wins[1]), vim.api.nvim_win_get_position(wins[2]))
    first.stop()
    assert.equals(1, #floats())
    second.stop()
    assert.same({}, floats())
  end)

  it("leaves no spinner behind after stop, even with ticks already queued", function()
    for _ = 1, 5 do
      -- Arm the stop timer before the spinner's timer: both fire at 100ms, so stop() is
      -- queued just ahead of a spinner tick, which then runs after stop().
      local spinner, stopped
      vim.defer_fn(function()
        spinner.stop()
        stopped = true
      end, 100)
      spinner = start()
      assert.equals(1, #floats())
      local scratch = vim.api.nvim_win_get_buf(floats()[1])
      vim.wait(1000, function()
        return stopped
      end)
      vim.wait(50) -- let any tick queued behind stop() run
      spinner.stop()
      spinner.update("late response")
      assert.same({}, floats())
      assert.is_false(vim.api.nvim_buf_is_valid(scratch))
    end
  end)
end)
