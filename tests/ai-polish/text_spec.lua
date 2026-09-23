local text = require("ai-polish.text")

local function sug(before, cb, ca)
  return { before = before, after = { "X" }, context_before = cb or "", context_after = ca or "" }
end

describe("text.chunk", function()
  it("keeps short text in one chunk", function()
    local c = text.chunk("hello", 100)
    assert.same({ { text = "hello", offset = 0 } }, c)
  end)

  it("splits at paragraph boundaries and chunks reassemble to the original", function()
    local para = string.rep("あ", 300)
    local src = table.concat({ para, para, para, para }, "\n\n")
    local chunks = text.chunk(src, 700)
    assert.is_true(#chunks >= 2)
    local joined = {}
    for i, c in ipairs(chunks) do
      assert.is_true(text.chars(c.text) <= 700)
      assert.equals(#table.concat(joined), c.offset)
      joined[i] = c.text
    end
    assert.equals(src, table.concat(joined))
    -- first chunk ends right after a blank line, not mid-paragraph
    assert.truthy(chunks[1].text:match("\n\n$"))
  end)

  it("splits at Japanese sentence ends when a paragraph is too long", function()
    local src = string.rep("これは長い文です。", 100)
    local chunks = text.chunk(src, 200)
    for i = 1, #chunks - 1 do
      assert.truthy(vim.endswith(chunks[i].text, "。"))
    end
  end)

  it("hard-splits without breaking UTF-8 when there is no boundary", function()
    local src = string.rep("漢", 1000)
    local chunks = text.chunk(src, 300)
    for _, c in ipairs(chunks) do
      assert.is_true(vim.fn.strchars(c.text) <= 300)
      -- every chunk is whole 3-byte characters
      assert.equals(#c.text, vim.fn.strchars(c.text) * 3)
    end
    local all = ""
    for _, c in ipairs(chunks) do
      all = all .. c.text
    end
    assert.equals(src, all)
  end)
end)

describe("text.estimate", function()
  it("scales cost with size and counts requests", function()
    local p = { input_per_mtok = 1, output_per_mtok = 10 }
    local small = text.estimate(text.chunk("短い文。", 6000), p)
    local big = text.estimate(text.chunk(string.rep("長い文章です。", 5000), 6000), p)
    assert.equals(1, small.requests)
    assert.is_true(big.requests > 1)
    assert.is_true(big.cost_usd > small.cost_usd)
    assert.is_true(big.input_tokens >= 35000) -- CJK is counted ~1 token/char
  end)

  it("counts ASCII at ~4 chars per token", function()
    assert.equals(25, text.estimate_tokens(string.rep("a", 100)))
  end)
end)

describe("text.locate / resolve", function()
  it("uses context to pick among duplicates", function()
    local src = "猫が好き。犬が好き。鳥が好き。"
    local a, b = text.locate(src, sug("好き", "犬が", "。鳥"))
    assert.equals("好き", src:sub(a + 1, b))
    assert.equals(src:find("犬が好き", 1, true) - 1 + #"犬が", a)
  end)

  it("drops unlocatable and overlapping suggestions", function()
    local src = "abc def ghi"
    local out, dropped = text.resolve(src, { sug("def"), sug("zzz"), sug("c de"), sug("abc") }, 10)
    assert.equals(2, #out)
    assert.equals(2, dropped)
    assert.equals("abc", out[1].before)
    assert.equals(10, out[1].start)
    assert.equals("def", out[2].before)
    assert.equals(14, out[2].start)
  end)
end)

describe("text.pos_at", function()
  it("maps byte offsets to buffer positions", function()
    local src = "ab\ncdé\nf"
    assert.same({ 2, 7 }, { text.pos_at(src, 2, 2, 5) })
    assert.same({ 3, 1 }, { text.pos_at(src, 4, 2, 5) })
    assert.same({ 4, 0 }, { text.pos_at(src, #"ab\ncdé\n", 2, 5) })
  end)
end)
