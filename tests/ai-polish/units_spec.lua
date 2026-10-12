local units = require("ai-polish.units")

-- Stands in for BudouX so the rules around it are tested apart from the model.
local function parser(chunks)
  return function(sentence)
    return assert(chunks[sentence], "no chunks for " .. sentence)
  end
end

local function texts(text, opts)
  return vim.tbl_map(function(u)
    return text:sub(u.from + 1, u.to)
  end, units.split(text, opts).units)
end

describe("units", function()
  it("splits Japanese into BudouX phrases", function()
    assert.same(
      { "今日は", "天気が", "いいから", "散歩しましょう。" },
      texts("今日は天気がいいから散歩しましょう。")
    )
  end)

  it("numbers units from 1 with 0-based byte ranges, end exclusive", function()
    local text = "絵😀を描く。次に塗る。"
    local split = units.split(text, {
      parse = parser({
        ["絵😀を描く。"] = { "絵😀を", "描く。" },
        ["次に塗る。"] = { "次に", "塗る。" },
      }),
    })
    assert.same(
      { 1, 2, 3, 4 },
      vim.tbl_map(function(u)
        return u.n
      end, split.units)
    )
    assert.equals(0, split.units[1].from)
    assert.equals(#"絵😀を", split.units[1].to)
    assert.equals(#text, split.units[4].to)
  end)

  it("ends sentences at 。！？ (kept) and at line breaks (dropped), skipping blank ones", function()
    local text = "一文目です。\n\n二文目は短い"
    local split = units.split(text, {
      parse = parser({
        ["一文目です。"] = { "一文目です。" },
        ["二文目は短い"] = { "二文目は", "短い" },
      }),
    })
    assert.same(
      { "一文目です。", "二文目は短い" },
      vim.tbl_map(function(s)
        return text:sub(s.from + 1, s.to)
      end, split.sentences)
    )
    assert.same(
      { 1, 2, 2 },
      vim.tbl_map(function(u)
        return u.sentence
      end, split.units)
    )
  end)

  it("keeps closing marks with the unit before them and opening brackets with the one after", function()
    local text = "北海道産の「とよまさり」にした、"
    local opts = { parse = parser({ [text] = { "北海道産の「", "とよまさり", "」に", "した", "、" } }) }
    assert.same({ "北海道産の", "「とよまさり」に", "した、" }, texts(text, opts))
  end)

  it("leaves spaces out of every unit and covers every other character once", function()
    local text = "Tauri で アプリを作る。"
    local opts = { parse = parser({ [text] = { "Tauri で ", "アプリを", "作る。" } }) }
    local split = units.split(text, opts)
    assert.same({ "Tauri", "で", "アプリを", "作る。" }, texts(text, opts))
    local covered = {}
    for _, u in ipairs(split.units) do
      for i = u.from + 1, u.to do
        assert.is_nil(covered[i])
        covered[i] = true
      end
    end
    for i = 1, #text do
      assert.equals(text:sub(i, i) ~= " ", covered[i] == true, "byte " .. i)
    end
  end)

  it("keeps formal nouns, postpositions and small kana with the unit before", function()
    local text = "その日のうちに旧バージョンとして直した。"
    local opts = {
      parse = parser({
        [text] = { "その日の", "うちに", "旧バージ", "ョンと", "して", "直した。" },
      }),
    }
    assert.same({ "その日のうちに", "旧バージョンとして", "直した。" }, texts(text, opts))
  end)

  it("stays close to Kotobae's lindera units (agreement floor on its golden subset)", function()
    local golden = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/units-golden.json"), "\n"))
    local gold, ours, hit = 0, 0, 0
    for _, case in ipairs(golden) do
      local starts = {}
      for _, u in ipairs(case.units) do
        starts[u[1]] = true
      end
      local split = units.split(case.text).units
      gold, ours = gold + #case.units, ours + #split
      for _, u in ipairs(split) do
        hit = hit + (starts[u.from] and 1 or 0)
      end
    end
    local p, r = hit / ours, hit / gold
    -- 0.91 when added (scripts/units-agreement.lua); a drop means the rules or model changed.
    assert.is_true(2 * p * r / (p + r) >= 0.89, string.format("unit start F1 %.3f", 2 * p * r / (p + r)))
  end)

  it("has no units for empty or blank text", function()
    assert.same({}, units.split("").units)
    assert.same({}, units.split("  \n ").units)
  end)
end)
