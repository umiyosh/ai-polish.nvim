local segment = require("ai-polish.jev_segment")
local local_check = require("ai-polish.jev_local")
local jev = require("ai-polish.jev")
local config = require("ai-polish.config")
local http = require("ai-polish.http")
local function answers(plan, noul)
  local result = {}
  for _, batch in ipairs(plan.batches) do
    for id, q in pairs(batch.questions) do
      if q.type == "noul" then
        result[id] = { type = "noul", noul = noul }
      end
    end
  end
  return result
end
local function response(req, noul)
  local result = answers({ batches = { vim.json.decode(req.body) } }, noul)
  for id, q in pairs(vim.json.decode(req.body).questions) do
    if q.type == "score" then
      result[id] = {
        type = "score",
        score = 0,
        confidence = 0.9,
        probabilities = { ["0"] = 1, ["1"] = 0, ["2"] = 0, ["3"] = 0, ["4"] = 0 },
        legend = { ["0"] = "a", ["1"] = "b", ["2"] = "c", ["3"] = "d", ["4"] = "e" },
      }
    end
  end
  return { status = 200, body = vim.json.encode({ answers = result }) }
end
describe("Jev local checks", function()
  local original_post = http.post
  after_each(function()
    http.post = original_post
    config.setup({})
  end)
  it("matches Kotobae's full segmentation and structure-rule golden corpus", function()
    local cases = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/jev-segment-golden.json"), "\n"))
    assert.equals(165, #cases)
    for _, c in ipairs(cases) do
      local result = {}
      for _, s in ipairs(segment.sentences(c.text, "ja")) do
        result[#result + 1] = { sentence = s, spans = segment.spans(s, "ja"), nejire = segment.nejire(s) }
      end
      assert.same(c.sentences, result, c.text)
    end
  end)
  it("adds bounded neutral repeated-kana references without changing the source or judging repetition", function()
    config.setup({ evaluation = { language = "ja" } })
    local text = "共有していたたただきありがとうございます。ここから始めます。"
    local p = jev.plan(text)
    assert.equals(text, p.batches[1].state.text)
    local ins = p.batches[1].questions.u_s0.instructions
    assert.is_truthy(ins.spelling_reference[1]:find("た た た", 1, true))
    assert.equals("こ こ か ら", segment.reference("ここから")[1])
    assert.equals(32, #segment.reference(string.rep("あ", 3000)))
    assert.equals(80, #vim.split(segment.reference(string.rep("あ", 90))[1], " "))
  end)
  it("keeps Chinese script and punctuation clauses, without Japanese structure rules", function()
    for _, lang in ipairs({ "zh-Hans", "zh-Hant" }) do
      config.setup({ evaluation = { language = lang } })
      local text = "目的は設定を変更しました。請先檢查設定，再儲存變更。"
      local p = jev.plan(text)
      assert.is_false(p.sentences[1].nejire)
      assert.same({ "請先檢查設定", "再儲存變更" }, p.sentences[2].spans)
      assert.equals(text, p.batches[1].state.text)
      local long = jev.plan(string.rep("第一行\n第二行\n", 30))
      assert.is_truthy(long.batches[2].state.text:find("第一行\n第二行", 1, true))
      assert.is_true(local_check.aggregate(p, answers(p, 1), 1).provisional)
    end
    assert.equals("ja", segment.language("設定を確認。", "auto"))
    assert.equals("zh", segment.language("請確認設定。", "auto"))
  end)
  it("reports English punctuation/line units as segments rather than claiming sentence counts", function()
    config.setup({ evaluation = { language = "en" } })
    local p = jev.plan("First sentence. Next sentence. Third sentence.")
    local r = local_check.aggregate(p, answers(p, 1), 1)
    assert.equals("segments", r.coverage_unit)
    assert.equals(1, r.evaluated_sentences)
  end)
  it("aggregates sentence/worst-span values with exact threshold and severe-Score gates", function()
    config.setup({ evaluation = { language = "ja" } })
    local p = jev.plan("文を確認します。")
    for _, c in ipairs({ { 0.751, 1 }, { 0.75, 2 }, { 0.631, 2 }, { 0.63, 3 } }) do
      assert.equals(c[2], local_check.aggregate(p, answers(p, c[1]), 3).level)
    end
    assert.equals(1, local_check.aggregate(p, answers(p, 1), 5).level)
    assert.equals(5, local_check.aggregate(p, answers(p, 0.7), 5).level)
    local a = answers(p, 1)
    a.u_s0.noul = 0.2
    assert.equals(3, local_check.aggregate(p, a, 1).level)
    a.u_s0 = nil
    assert.is_nil(local_check.aggregate(p, a, 1))
    local n = jev.plan("目的は、設定を変更しました。")
    local checked = local_check.aggregate(n, answers(n, 1), 1)
    assert.equals(3, checked.level)
    assert.equals("structure", checked.findings[1].kind)
  end)
  it("caps batches and spans and exposes partial coverage", function()
    config.setup({ evaluation = { language = "ja" } })
    local p = jev.plan(string.rep("文です。", 1000))
    assert.equals(16, #p.batches)
    assert.equals(450, p.evaluated)
    local result = local_check.aggregate(p, answers(p, 1), 1)
    assert.equals(1000, result.sentences)
    assert.equals(450, result.evaluated_sentences)
    for _, b in ipairs(p.batches) do
      assert.is_true(vim.tbl_count(b.questions) <= 60)
    end
    p = jev.plan(table.concat(vim.tbl_map(function(i)
      return "項目" .. i .. "を"
    end, vim.fn.range(1, 100))))
    assert.is_true(p.sentences[1].omitted_spans > 0)
  end)
  it("bounds concurrency, joins out-of-order responses and produces no Score confidence for local levels", function()
    config.setup({ evaluation = { language = "ja" } })
    local requests, callbacks, result = {}, {}
    http.post = function(req, cb)
      requests[#requests + 1], callbacks[#callbacks + 1] = req, cb
      return { cancel = function() end }
    end
    jev.evaluate(string.rep("文です。", 110), "test", function(r)
      result = r
    end)
    assert.equals(4, #requests)
    callbacks[2](response(requests[2], 0.6))
    assert.equals(5, #requests)
    for _, i in ipairs({ 5, 4, 3, 1 }) do
      callbacks[i](response(requests[i], 0.6))
    end
    assert.equals(3, result.unnaturalness.level)
    assert.is_nil(result.unnaturalness.confidence)
    assert.equals(1, result.ai_style.level)
    assert.equals(3, #result.unnaturalness.findings)
  end)
  it("cancels all active batches and ignores late callbacks without dispatching queued work", function()
    local callbacks, cancelled, calls, delivered = {}, 0, 0, 0
    http.post = function(_, cb)
      calls = calls + 1
      callbacks[#callbacks + 1] = cb
      return {
        cancel = function()
          cancelled = cancelled + 1
        end,
      }
    end
    local handle = jev.evaluate(string.rep("文です。", 110), "test", function()
      delivered = delivered + 1
    end)
    handle.cancel()
    callbacks[1]({ status = 500 })
    assert.equals(4, calls)
    assert.equals(4, cancelled)
    assert.equals(0, delivered)
  end)
  it("fails the whole run on one missing local answer or failed batch, with no retries", function()
    local requests, callbacks, cancelled, failure = {}, {}, 0
    http.post = function(req, cb)
      requests[#requests + 1], callbacks[#callbacks + 1] = req, cb
      return {
        cancel = function()
          cancelled = cancelled + 1
        end,
      }
    end
    jev.evaluate(string.rep("文です。", 110), "test", function(_, e)
      failure = e
    end)
    callbacks[2]({ status = 200, body = '{"answers":{}}' })
    assert.equals("invalid_response", failure)
    assert.equals(3, cancelled)
    assert.equals(4, #requests)
    callbacks[1](response(requests[1], 0.6))
    assert.equals(4, #requests)
  end)
end)
