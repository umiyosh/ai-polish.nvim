-- Cases ported from Kotobae's src-tauri/src/services/gemini/stream_tests.rs.
local stream = require("ai-polish.stream")

local SUGGESTION =
  [[{"from":1,"to":1,"before":"ロゴ","after":["ログ"],"category":"typo","message":"括弧 {x} [y] と \"引用\" と \\"}]]
local SECOND = [[{"from":4,"to":4,"before":"いい","after":["良い","よい"],"category":"style","message":"表記"}]]
local ANSWER = ([[{"suggestions":[%s, %s]}]]):format(SUGGESTION, SECOND)

local function event(text, finish)
  local candidate = { content = { parts = { { text = text } } }, finishReason = finish }
  return vim.json.encode({ candidates = { candidate } })
end

describe("stream", function()
  it("decodes server-sent events whatever way the bytes are split", function()
    local s = 'data: {"a":"日本語"}\r\n\r\n: comment\nevent: message\ndata: {"b":1}\n\n'
    for split = 0, #s do
      local d = stream.decoder()
      local events = vim.list_extend(d.push(s:sub(1, split)), d.push(s:sub(split + 1)))
      vim.list_extend(events, d.finish())
      assert.same({ '{"a":"日本語"}', '{"b":1}' }, events, "split at " .. split)
    end
  end)

  it("keeps an event the stream ended without its closing blank line", function()
    local d = stream.decoder()
    assert.same({}, d.push('data: {"a":1}'))
    assert.same({ '{"a":1}' }, d.finish())
  end)

  it("finds each suggestion wherever the answer text is split", function()
    for split = 0, #ANSWER do
      local sc = stream.scanner()
      local found = vim.list_extend(sc.push(ANSWER:sub(1, split)), sc.push(ANSWER:sub(split + 1)))
      assert.same({ SUGGESTION, SECOND }, found, "split at " .. split)
    end
  end)

  it("hands over a suggestion as soon as its object closes", function()
    local sc = stream.scanner()
    assert.same({ SUGGESTION }, sc.push(([[{"suggestions":[%s,{"from":2,]]):format(SUGGESTION)))
    assert.same({}, sc.push([["before":]]))
  end)

  it("finds nothing in an empty answer", function()
    assert.same({}, stream.scanner().push([[{"suggestions":[]}]]))
  end)

  describe("answer", function()
    it("returns suggestions in order and finishes on STOP", function()
      local a = stream.answer()
      local got = {}
      for _, piece in ipairs({ ANSWER:sub(1, 40), ANSWER:sub(41, 120), ANSWER:sub(121) }) do
        vim.list_extend(got, assert(a.read(event(piece))))
      end
      vim.list_extend(got, assert(a.read(event("", "STOP"))))
      assert.same({ "ロゴ", "いい" }, { got[1].before, got[2].before })
      assert.is_true((a.finish()))
    end)

    it("skips thoughts but keeps the answer", function()
      local a = stream.answer()
      local data = vim.json.encode({
        candidates = { { content = { parts = { { text = "thinking {", thought = true }, { text = ANSWER } } } } },
      })
      assert.equals(2, #assert(a.read(data)))
    end)

    it("reports how an unfinished stream ended", function()
      local a = stream.answer()
      a.read(event(ANSWER:sub(1, 60)))
      local ok, err = a.finish()
      assert.is_false(ok)
      assert.truthy(err)
      a = stream.answer()
      a.read(event(ANSWER:sub(1, 60), "MAX_TOKENS"))
      ok, err = a.finish()
      assert.is_false(ok)
      assert.matches("MAX_TOKENS", err)
    end)

    it("rejects blocked prompts and data that is not JSON", function()
      local _, err = stream.answer().read([[{"promptFeedback":{"blockReason":"SAFETY"}}]])
      assert.matches("blocked", err)
      _, err = stream.answer().read("<html>")
      assert.truthy(err)
    end)

    it("keeps the usage reported by the last chunk", function()
      local a = stream.answer()
      a.read(vim.json.encode({
        candidates = { { content = { parts = { { text = ANSWER } } }, finishReason = "STOP" } },
        usageMetadata = { candidatesTokenCount = 42 },
      }))
      assert.equals(42, a.usage.candidatesTokenCount)
    end)
  end)
end)
