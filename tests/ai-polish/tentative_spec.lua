local tentative = require("ai-polish.tentative")

local function open_buffer(lines)
  vim.cmd("enew!")
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function shown(b)
  return vim.tbl_map(function(m)
    local d = m[4]
    return table.concat(vim.api.nvim_buf_get_text(b, m[2], m[3], d.end_row, d.end_col, {}), "\n")
  end, vim.api.nvim_buf_get_extmarks(b, tentative.ns, 0, -1, { details = true }))
end

local function at(b, row, col, end_row, end_col)
  return { row = row, col = col, end_row = end_row, end_col = end_col, bufnr = b }
end

describe("tentative marks", function()
  local b, content

  before_each(function()
    b = open_buffer({ "誤りは一つ。", "直す所は二つ目。" })
    content = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  end)

  after_each(function()
    tentative.clear(b)
  end)

  local function range(s)
    local from = content:find(s, 1, true) - 1
    return { from = from, to = from + #s }
  end

  it("underlines each request's marks as they come, in the region's coordinates", function()
    local t = tentative.start(b, content, 0, 0)
    t:add({ range("誤りは") })
    t:add({ range("二つ目。") })
    assert.same({ "誤りは", "二つ目。" }, shown(b))
    local m = vim.api.nvim_buf_get_extmarks(b, tentative.ns, 0, -1, { details = true })[1]
    assert.equals("AiPolishTentative", m[4].hl_group)
  end)

  it("moves marks with edits and drops answers to a text that has changed since", function()
    local t = tentative.start(b, content, 0, 0)
    t:add({ range("二つ目。") })
    vim.api.nvim_buf_set_text(b, 1, 0, 1, 0, { "まず、" })
    assert.same({ "二つ目。" }, shown(b))
    t:add({ range("誤りは") })
    assert.same({ "二つ目。" }, shown(b))
  end)

  it("gives way to fixes that land on a mark and drops marks the fixes have passed", function()
    local t = tentative.start(b, content, 0, 0)
    t:add({ range("誤りは"), range("一つ。"), range("直す所は"), range("二つ目。") })
    -- A fix on 一 (row 0) and one on 直す (row 1): 誤りは was passed, 二つ目。 is still ahead.
    t:reached({ at(b, 0, #"誤りは", 0, #"誤りは一"), at(b, 1, 0, 1, #"直す") })
    assert.same({ "二つ目。" }, shown(b))
  end)

  it("keeps every mark when no fix has arrived, and clears them all at the end", function()
    local t = tentative.start(b, content, 0, 0)
    t:add({ range("誤りは") })
    t:reached({})
    assert.same({ "誤りは" }, shown(b))
    tentative.clear(b)
    assert.same({}, shown(b))
    t:add({ range("一つ。") })
    assert.same({}, shown(b))
  end)

  it("replaces the marks of an earlier check when a new one starts", function()
    tentative.start(b, content, 0, 0):add({ range("誤りは") })
    tentative.start(b, content, 0, 0)
    assert.same({}, shown(b))
  end)
end)
