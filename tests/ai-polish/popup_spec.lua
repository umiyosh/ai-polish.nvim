local config = require("ai-polish.config")
local popup = require("ai-polish.popup")
local session = require("ai-polish.session")

local function setup_window(lines, width)
  vim.cmd("only")
  vim.cmd("enew!")
  vim.bo.bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.wo.wrap = true
  vim.api.nvim_win_set_width(0, width)
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

local function item(before, row, col)
  return {
    before = before,
    after = { "X" },
    message = "",
    category = "typo",
    severity = "warning",
    row = row,
    col = col,
    end_row = row,
    end_col = col + #before,
  }
end

describe("popup", function()
  after_each(function()
    popup.close()
    vim.o.winblend = 0
    config.setup({})
  end)

  it("stays opaque even with a global 'winblend'", function()
    vim.o.winblend = 10
    local win, buf = setup_window({ "teh cat" }, 60)
    popup.open(session.create(buf, { item("teh", 0, 0) }), win)
    assert.is_true(popup.is_open())
    assert.equals(0, vim.wo[vim.api.nvim_get_current_win()].winblend)
  end)

  it("honours ui.winblend", function()
    config.setup({ ui = { winblend = 25 } })
    local win, buf = setup_window({ "teh cat" }, 60)
    popup.open(session.create(buf, { item("teh", 0, 0) }), win)
    assert.equals(25, vim.wo[vim.api.nvim_get_current_win()].winblend)
  end)

  it("undoes and redoes an accept with u and <C-r>", function()
    local win, buf = setup_window({ "teh colour" }, 60)
    local colour = item("colour", 0, 4)
    colour.after = { "color", "hue" }
    popup.open(session.create(buf, { item("teh", 0, 0), colour }), win)
    vim.cmd("normal ]")
    vim.cmd("normal 2")
    assert.same({ "teh hue" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

    vim.cmd("normal u")
    assert.same({ "teh colour" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local ctx = popup.context()
    assert.equals("colour", ctx.session:current().before)
    -- The cursor returns to the candidate that was accepted.
    assert.equals(2, ctx.candidate_rows[vim.api.nvim_win_get_cursor(ctx.win)[1]])

    vim.cmd("normal " .. vim.keycode("<C-r>"))
    assert.same({ "teh hue" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equals("teh", popup.context().session:current().before)
  end)

  it("lists undo and redo in the hint line", function()
    local _, buf = setup_window({ "teh" }, 60)
    local lines = popup.render_lines(session.create(buf, { item("teh", 0, 0) }), 60)
    assert.matches("u undo  <C%-r> redo", lines[#lines])
  end)

  it("opens below the last screen row of a wrapped line", function()
    local long = string.rep("word ", 40) -- 200 cols
    local win = setup_window({ long, "next" }, 50)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("redraw")
    -- A lone window cannot be narrowed, so derive the wrap count from the real width.
    local rows = math.ceil(#long / vim.api.nvim_win_get_width(win))
    assert.is_true(rows > 1)
    local place = popup._placement(win, 0, 0, 5)
    assert.equals("NW", place.anchor)
    assert.equals(rows, place.row) -- just below the wrapped line, not below its first row
  end)

  it("opens above the line when there is no room below", function()
    local filler = {}
    for i = 1, vim.o.lines do
      filler[i] = "line " .. i
    end
    local win = setup_window(filler, 50)
    local last = vim.fn.line("w$", win)
    vim.api.nvim_win_set_cursor(win, { last, 0 })
    vim.cmd("redraw")
    local place = popup._placement(win, last - 1, 0, 8)
    assert.equals("SW", place.anchor)
    assert.equals(0, place.row)
  end)
end)
