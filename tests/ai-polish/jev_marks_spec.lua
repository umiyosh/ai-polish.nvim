local marks = require("ai-polish.jev_marks")
local http = require("ai-polish.http")
local units = require("ai-polish.units")

-- Stands in for BudouX: every sentence is cut into the given chunks, or kept whole.
local function split(text, chunks)
  return units.split(text, {
    parse = function(sentence)
      return chunks and chunks[sentence] or { sentence }
    end,
  })
end

local function shown(body, key)
  return body.questions[key].instructions.sentence
end

describe("jev_marks", function()
  describe("bodies", function()
    it("asks 40 bunsetsu per request, in text order, keyed by measure and number", function()
      local text = string.rep("あい。", 41)
      local bodies = marks.bodies(text, split(text))
      assert.equals(2, #bodies)
      assert.equals(40, vim.tbl_count(bodies[1].questions))
      assert.is_not_nil(bodies[1].questions.e0001)
      assert.is_not_nil(bodies[1].questions.e0040)
      assert.same({ "e0041" }, vim.tbl_keys(bodies[2].questions))
      assert.equals("あい。", bodies[2].state)
      assert.equals("jev-latest", bodies[1].model)
    end)

    it("brackets the asked bunsetsu and shows up to 12 on each side within its sentence", function()
      local chunks = {}
      for i = 1, 30 do
        chunks[i] = ("%02d"):format(i)
      end
      local sentence = table.concat(chunks) .. "。"
      chunks[30] = "30。"
      local text = "前の文。" .. sentence
      local body = marks.bodies(text, split(text, { [sentence] = chunks }))[1]
      -- Unit 1 is the sentence before; the long sentence's 15th unit is number 16.
      assert.equals(
        table.concat(chunks, "", 3, 14) .. "【15】" .. table.concat(chunks, "", 16, 27),
        shown(body, "e0016")
      )
      assert.equals("【01】" .. table.concat(chunks, "", 2, 13), shown(body, "e0002"))
      assert.equals(table.concat(chunks, "", 18, 29) .. "【30。】", shown(body, "e0031"))
    end)

    it("asks with the errors measure and adds the spelling reference for repeated kana", function()
      local text = "それはよよよよい。"
      local q = marks.bodies(text, split(text))[1].questions.e0001
      assert.equals("noul", q.type)
      assert.truthy(q.instructions.question:find("書き手の文体", 1, true))
      assert.is_table(q.instructions.spelling_reference)
    end)
  end)

  describe("picks", function()
    it("keeps the bunsetsu at or above the threshold as byte ranges, in text order", function()
      local text = "今日は天気が良い。"
      local s = split(text, { [text] = { "今日は", "天気が", "良い。" } })
      local picked = marks.picks(s, {
        e0003 = { type = "noul", noul = 0.9 },
        e0001 = { type = "noul", noul = 0.55 },
        e0002 = { type = "noul", noul = 0.54 },
        b0002 = { type = "noul", noul = 0.99 },
      }, 0.55)
      assert.same({ { from = 0, to = #"今日は" }, { from = #"今日は天気が", to = #text } }, picked)
    end)
  end)

  describe("ask", function()
    local orig_post = http.post
    local posted

    before_each(function()
      posted = {}
      http.post = function(req, cb)
        local entry = { req = req, cb = cb, body = vim.json.decode(req.body) }
        posted[#posted + 1] = entry
        return {
          cancel = function()
            entry.cancelled = true
          end,
        }
      end
    end)

    after_each(function()
      http.post = orig_post
    end)

    local function answer(i, values)
      local answers = {}
      for k in pairs(posted[i].body.questions) do
        answers[k] = { type = "noul", noul = values[k] or 0 }
      end
      posted[i].cb({ status = 200, body = vim.json.encode({ answers = answers }) })
    end

    it("keeps a bounded number of requests in flight and hands over each request's marks", function()
      local text = string.rep("あい。", 120)
      local found, total = {}, nil
      marks.ask(text, "key", { in_flight = 2, max_requests = 20, threshold = 0.55 }, function(m)
        found[#found + 1] = m
      end, function(n)
        total = n
      end)
      assert.equals(2, #posted)
      assert.equals("Bearer key", posted[1].req.headers.Authorization)
      answer(2, { e0041 = 0.9 })
      assert.equals(3, #posted)
      assert.same({ { { from = 360, to = 369 } } }, found)
      answer(1, {})
      answer(3, { e0081 = 0.7, e0082 = 0.7 })
      assert.equals(#found, 2)
      assert.equals(3, total)
    end)

    it("stops at max_requests, so a long text is only marked from its start", function()
      local text = string.rep("あい。", 120)
      marks.ask(text, "key", { in_flight = 16, max_requests = 2, threshold = 0.55 }, function() end, function() end)
      assert.equals(2, #posted)
    end)

    it("loses only a failed request's marks and retries once when Jev is busy", function()
      local text = string.rep("あい。", 80)
      local total
      marks.ask(
        text,
        "key",
        { in_flight = 2, max_requests = 20, threshold = 0.55, retry_ms = 0 },
        function() end,
        function(n)
          total = n
        end
      )
      posted[1].cb({ status = 500, body = "" })
      posted[2].cb({ status = 429, body = "" })
      vim.wait(100, function()
        return #posted == 3
      end)
      answer(3, { e0041 = 0.9 })
      assert.equals(1, total)
    end)

    it("cancels requests in flight and reports nothing afterwards", function()
      local text = string.rep("あい。", 80)
      local called = false
      local job = marks.ask(text, "key", { in_flight = 2, max_requests = 20, threshold = 0.55 }, function()
        called = true
      end, function()
        called = true
      end)
      job.cancel()
      assert.is_true(posted[1].cancelled and posted[2].cancelled)
      answer(1, { e0001 = 0.9 })
      assert.is_false(called)
    end)
  end)
end)
