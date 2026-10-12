-- Cases ported from Kotobae's src-tauri/src/services/gemini/numbered_tests.rs.
local numbered = require("ai-polish.numbered")

---Units cut at the given substrings, all in one sentence.
local function split(text, cuts)
  local starts = {}
  for i, c in ipairs(cuts) do
    starts[i] = assert(text:find(c, starts[i - 1] and starts[i - 1] + 2 or 1, true)) - 1
  end
  local units = {}
  for i, s in ipairs(starts) do
    units[i] = { n = i, from = s, to = starts[i + 1] or #text, sentence = 1 }
  end
  return { units = units, sentences = { { from = 0, to = #text } } }
end

local function fix(from, to, before, after, category)
  return { from = from, to = to, before = before, after = after, category = category or "typo", message = "理由" }
end

describe("numbered", function()
  it("numbers each bunsetsu in the text sent", function()
    local text = "訓練日程に確認した。"
    assert.equals(
      "〔1〕訓練日程に〔2〕確認した。",
      numbered.text(text, split(text, { "訓練", "確認" }))
    )
  end)

  it("keeps what lies between units, such as spaces and line breaks", function()
    local text = "前の文。\n次 の文。"
    local s = {
      units = {
        { n = 1, from = 0, to = #"前の文。" },
        { n = 2, from = #"前の文。\n", to = #"前の文。\n次" },
        { n = 3, from = #"前の文。\n次 ", to = #text },
      },
    }
    assert.equals("〔1〕前の文。\n〔2〕次 〔3〕の文。", numbered.text(text, s))
  end)

  it("places a fix on the exact text it names inside its range", function()
    local text = "訓練日程に確認した。"
    local s = numbered.place(
      text,
      split(text, { "訓練", "確認" }),
      fix(1, 2, "日程に確認", { "日程を確認" }, "grammar")
    )
    assert.equals("日程に確認", s.before)
    assert.equals(#"訓練", s.start)
    assert.equals(#"訓練日程に確認", s.finish)
    assert.equals("訓練", s.context_before)
    assert.equals("した。", s.context_after)
    assert.same({ "日程を確認" }, s.after)
    assert.equals("grammar", s.category)
  end)

  it("ignores numbers Gemini copied into before", function()
    local text = "いまいち、いまいち理解できない"
    local s = numbered.place(
      text,
      split(text, { "いまいち、", "いまいち理解", "できない" }),
      fix(1, 2, "いまいち、〔2〕いまいち", { "いまいち" }, "style")
    )
    assert.equals("いまいち、いまいち", s.before)
  end)

  it("drops a fix whose text is not inside its range", function()
    -- Applying it would replace text Gemini never quoted.
    local text = "訓練日程に確認した。"
    local units = split(text, { "訓練", "確認" })
    assert.is_nil(numbered.place(text, units, fix(1, 1, "確認した", { "確認する" })))
    assert.is_nil(numbered.place(text, units, fix(1, 2, "考えらえる", { "考えられる" })))
  end)

  it("takes in the mark that already follows a fix ending with it", function()
    -- Adopting 「すすん」→「。」 before an existing 「。」 left 「。。」 (Kotobae #76).
    local text = "設定を進めたすすん。"
    local units = split(text, { "設定を", "進めたすすん。" })
    local s = numbered.place(text, units, fix(2, 2, "すすん", { "。" }))
    assert.equals("すすん。", s.before)
    assert.same({ "。" }, s.after)
    assert.equals("", s.context_after)
    -- Other alternatives keep the mark they would have kept.
    s = numbered.place(text, units, fix(2, 2, "すすん", { "。", "ね" }))
    assert.same({ "。", "ね。" }, s.after)
    -- Part of a run of marks: the fix now covers the whole run.
    text = "進めた。。。。"
    s = numbered.place(text, split(text, { "進めた" }), fix(1, 1, "。。。", { "。" }, "punctuation"))
    assert.equals("。。。。", s.before)
  end)

  it("leaves a fix alone when the next mark differs", function()
    local text = "進めたすすん、次へ。"
    local s =
      numbered.place(text, split(text, { "進めたすすん、", "次へ。" }), fix(1, 1, "すすん", { "。" }))
    assert.equals("すすん", s.before)
  end)

  it("drops alternatives that change nothing", function()
    local text = "洗濯ばさみを使う。"
    local units = split(text, { "洗濯", "使う" })
    assert.is_nil(numbered.place(text, units, fix(1, 1, "洗濯ばさみ", { "洗濯ばさみ" })))
    local kept =
      numbered.place(text, units, fix(1, 1, "洗濯ばさみ", { "洗濯ばさみ", "洗濯バサミ" }, "style"))
    assert.same({ "洗濯バサミ" }, kept.after)
  end)

  it("places a repeated text in the unit Gemini named", function()
    local text = "ああ。ああ。"
    local s = numbered.place(text, split(text, { "ああ。", "ああ。" }), fix(2, 2, "ああ", { "いい" }))
    assert.equals(#"ああ。", s.start)
  end)

  it("rejects numbers outside the text", function()
    local text = "訓練日程に確認した。"
    local units = split(text, { "訓練", "確認" })
    assert.is_nil(numbered.place(text, units, fix(0, 1, "訓練", { "演習" })))
    assert.is_nil(numbered.place(text, units, fix(2, 3, "確認", { "承認" })))
    assert.is_nil(numbered.place(text, units, fix(2, 1, "確認", { "承認" })))
  end)

  it("places every fix and counts the ones it drops", function()
    local text = "訓練日程に確認した。"
    local units = split(text, { "訓練", "確認" })
    local placed, dropped = numbered.place_all(text, units, {
      fix(2, 2, "確認した", { "確認する" }),
      fix(1, 1, "確認", { "承認" }),
    })
    assert.equals(1, #placed)
    assert.equals(1, dropped)
  end)
end)
