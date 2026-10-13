local arrivals = require("ai-polish.arrivals")

local function open_buffer(lines)
  vim.cmd("enew!")
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

---Units cut at the given substrings of `text`, all in one sentence.
local function split(text, cuts)
  local units, at = {}, 0
  for i, c in ipairs(cuts) do
    local s = assert(text:find(c, at + 1, true)) - 1
    units[i] = { n = i, from = s, to = s + #c, sentence = 1 }
    at = s + #c
  end
  return { units = units, sentences = { { from = 0, to = #text } } }
end

local function fix(from, to, before, after)
  return { from = from, to = to, before = before, after = { after }, category = "typo", message = "m" }
end

local function shown(b, item)
  return table.concat(vim.api.nvim_buf_get_text(b, item.row, item.col, item.end_row, item.end_col, {}), "\n")
end

describe("arrivals", function()
  local b, a

  local function start(lines, cuts)
    b = open_buffer(lines)
    local content = table.concat(lines, "\n")
    local chunks = { { text = content, offset = 0, split = cuts and split(content, cuts) or nil } }
    a = arrivals.start(b, chunks, content, 0, 0)
  end

  after_each(function()
    a:clear()
  end)

  it("places a numbered fix where its units are now", function()
    start({ "訓練日程に確認した。" }, { "訓練日程に", "確認した。" })
    local items, dropped = a:place(1, { fix(1, 2, "日程に確認", "日程を確認") })
    assert.equals(0, dropped)
    assert.equals("日程に確認", shown(b, items[1]))
  end)

  it("follows edits made while the fix was on its way", function()
    start({ "訓練日程に確認した。" }, { "訓練日程に", "確認した。" })
    vim.api.nvim_buf_set_text(b, 0, 0, 0, 0, { "まず、" })
    local items = a:place(1, { fix(2, 2, "確認した", "確認する") })
    assert.equals("確認した", shown(b, items[1]))
    assert.equals(#"まず、訓練日程に", items[1].col)
  end)

  it("drops a fix whose text was edited, or whose units were deleted", function()
    start({ "訓練日程に確認した。" }, { "訓練日程に", "確認した。" })
    vim.api.nvim_buf_set_text(b, 0, #"訓練日程に", 0, #"訓練日程に確認", { "承認" })
    local items, dropped = a:place(1, { fix(2, 2, "確認した", "確認する") })
    assert.same({}, items)
    assert.equals(1, dropped)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "" })
    items, dropped = a:place(1, { fix(1, 1, "訓練", "演習") })
    assert.same({}, items)
    assert.equals(1, dropped)
  end)

  it("drops a fix overlapping one that already arrived, even after it was handled", function()
    start({ "訓練日程に確認した。" }, { "訓練日程に", "確認した。" })
    local first = a:place(1, { fix(1, 1, "日程に", "日程を") })[1]
    vim.api.nvim_buf_set_text(b, first.row, first.col, first.end_row, first.end_col, { "日程を" })
    local items, dropped = a:place(1, { fix(1, 2, "日程を確認", "日程の確認") })
    assert.same({}, items)
    assert.equals(1, dropped)
  end)

  it("finds fixes in the context form for text that is not split", function()
    start({ "teh cat and teh dog" })
    local items = a:place(1, { { before = "teh", after = { "the" }, context_before = "and ", context_after = " dog" } })
    assert.equals(#"teh cat and ", items[1].col)
  end)

  it("reports where a chunk lies now, for marks the fixes have passed", function()
    start({ "訓練日程に確認した。" }, { "訓練日程に", "確認した。" })
    vim.api.nvim_buf_set_text(b, 0, 0, 0, 0, { "まず、" })
    local s = a:scope(1)
    assert.same(
      { 0, #"まず、", 0, #"まず、訓練日程に確認した。" },
      { s.row, s.col, s.end_row, s.end_col }
    )
  end)
end)
