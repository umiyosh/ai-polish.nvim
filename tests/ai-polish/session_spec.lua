local session = require("ai-polish.session")

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function item(before, after, row, col)
  return {
    before = before,
    after = type(after) == "table" and after or { after },
    message = "",
    category = "typo",
    severity = "warning",
    row = row,
    col = col,
    end_row = row,
    end_col = col + #before,
  }
end

local function lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

describe("session", function()
  it("accepts a candidate and keeps later suggestions anchored", function()
    local b = buf_with({ "teh cat adn dog" })
    local s = session.create(b, { item("teh", "the", 0, 0), item("adn", "and", 0, 8) })
    assert.is_true(s:accept())
    s:accept()
    assert.same({ "the cat and dog" }, lines(b))
    assert.is_nil(session.get(b))
  end)

  it("picks the requested candidate", function()
    local b = buf_with({ "colour" })
    local s = session.create(b, { item("colour", { "color", "hue" }, 0, 0) })
    s:accept(2)
    assert.same({ "hue" }, lines(b))
  end)

  it("rejects without editing", function()
    local b = buf_with({ "teh" })
    local s = session.create(b, { item("teh", "the", 0, 0) })
    s:reject()
    assert.same({ "teh" }, lines(b))
    assert.is_nil(session.get(b))
  end)

  it("refuses to apply when the anchored text was edited", function()
    local b = buf_with({ "teh cat" })
    local s = session.create(b, { item("teh", "the", 0, 0) })
    vim.api.nvim_buf_set_text(b, 0, 1, 0, 2, { "E" })
    local ok, err = s:accept()
    assert.is_false(ok)
    assert.matches("changed", err)
    assert.same({ "tEh cat" }, lines(b))
  end)

  it("follows edits made above the suggestion", function()
    local b = buf_with({ "intro", "teh end" })
    local s = session.create(b, { item("teh", "the", 1, 0) })
    vim.api.nvim_buf_set_lines(b, 0, 0, false, { "new line" })
    assert.is_true(s:accept())
    assert.same({ "new line", "intro", "the end" }, lines(b))
  end)

  local function undo(b)
    vim.api.nvim_buf_call(b, function()
      vim.cmd("silent undo")
    end)
  end

  it("makes each accept its own undo step", function()
    local b = buf_with({ "teh cat adn dog" })
    local s = session.create(b, { item("teh", "the", 0, 0), item("adn", "and", 0, 8) })
    s:accept()
    s:accept()
    undo(b)
    assert.same({ "the cat adn dog" }, lines(b))
    undo(b)
    assert.same({ "teh cat adn dog" }, lines(b))
  end)

  it("accept_all applies everything as one undo step", function()
    local b = buf_with({ "teh cat adn dog fsh" })
    local s = session.create(b, { item("teh", "the", 0, 0), item("adn", "and", 0, 8), item("fsh", "fish", 0, 16) })
    s:accept() -- separate step
    local applied, skipped = s:accept_all()
    assert.equals(2, applied)
    assert.equals(0, skipped)
    assert.same({ "the cat and dog fish" }, lines(b))
    undo(b)
    assert.same({ "the cat adn dog fsh" }, lines(b))
  end)

  it("prune drops suggestions whose text was removed", function()
    local b = buf_with({ "teh cat adn" })
    local s = session.create(b, { item("teh", "the", 0, 0), item("adn", "and", 0, 8) })
    vim.api.nvim_buf_set_text(b, 0, 0, 0, 4, { "" })
    assert.equals(1, s:prune())
    assert.equals("adn", s:current().before)
  end)

  it("moves cyclically", function()
    local b = buf_with({ "a b c" })
    local s = session.create(b, { item("a", "A", 0, 0), item("b", "B", 0, 2), item("c", "C", 0, 4) })
    s:move(-1)
    assert.equals("c", s:current().before)
    s:move(1)
    assert.equals("a", s:current().before)
  end)
end)
