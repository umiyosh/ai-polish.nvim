local progress = require("ai-polish.progress")

describe("progress", function()
  local ns = vim.api.nvim_create_namespace("ai-polish-progress")

  local function marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  end

  it("leaves no spinner behind after stop, even with ticks already queued", function()
    for _ = 1, 5 do
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
      -- Arm the stop timer before the spinner's timer: both fire at 100ms, so stop() is
      -- queued just ahead of a spinner tick, which then runs after stop().
      local spinner, stopped
      vim.defer_fn(function()
        spinner.stop()
        stopped = true
      end, 100)
      spinner = progress.start(buf, 0)
      spinner.update("proofreading…")
      assert.equals(1, #marks(buf))
      vim.wait(1000, function()
        return stopped
      end)
      vim.wait(50) -- let any tick queued behind stop() run
      assert.same({}, marks(buf))
    end
  end)
end)
