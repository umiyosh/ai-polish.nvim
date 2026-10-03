local config = require("ai-polish.config")
local http = require("ai-polish.http")
local jev = require("ai-polish.jev")

local function answer()
  return {
    type = "score",
    score = 1.4,
    confidence = 0.25,
    probabilities = { ["0"] = 0.05, ["1"] = 0.35, ["2"] = 0.5, ["3"] = 0.1, ["4"] = 0 },
    legend = { ["0"] = "a", ["1"] = "b", ["2"] = "c", ["3"] = "d", ["4"] = "e" },
  }
end
local function response()
  return { answers = { unnaturalness = answer(), ai_style = answer() } }
end

describe("Jev boundary", function()
  local orig_post = http.post
  after_each(function()
    http.post = orig_post
    config.setup({})
  end)
  it("uses the most probable level, preserving confidence separately", function()
    local result = assert(jev.decode(vim.json.encode(response())))
    assert.equals(3, result.unnaturalness.level)
    assert.equals(0.25, result.unnaturalness.confidence)
    assert.equals(0.5, result.unnaturalness.probabilities[3])
  end)
  it("accepts the rounding drift Jev returns but rejects a broken distribution", function()
    -- About 1% of real Score answers sum to 1 +- 0.01 (measured on 8,538 answers).
    local r = response()
    r.answers.unnaturalness.probabilities["4"] = 0.01
    assert.is_not_nil(jev.decode(vim.json.encode(r)))
    r.answers.unnaturalness.probabilities["4"] = 0.03
    assert.is_nil(jev.decode(vim.json.encode(r)))
  end)
  it("rejects missing answers, incomplete distributions and non-finite/out-of-range values", function()
    assert.is_nil(jev.decode("{}"))
    for _, change in ipairs({
      function(a)
        a.probabilities["4"] = nil
      end,
      function(a)
        a.probabilities["5"] = 0
      end,
      function(a)
        a.probabilities["0"] = 0.9
      end,
      function(a)
        a.confidence = 1.1
      end,
      function(a)
        a.score = -1
      end,
      function(a)
        a.type = "choice"
      end,
      function(a)
        a.legend = {}
      end,
    }) do
      local r = response()
      change(r.answers.unnaturalness)
      assert.is_nil(jev.decode(vim.json.encode(r)))
    end
  end)
  it("sends both independent questions once and never retries or leaks server errors", function()
    config.setup({ evaluation = { api_key = "test-key" } })
    local calls, err = 0
    http.post = function(req, cb)
      calls = calls + 1
      local body = vim.json.decode(req.body)
      assert.equals("jev-latest", body.model)
      assert.equals("我們在線上開會。", body.state.text)
      assert.equals(5, #body.questions.unnaturalness.criteria)
      assert.equals(5, #body.questions.ai_style.criteria)
      assert.equals("Bearer test-key", req.headers.Authorization)
      cb({ status = 429, body = "private-text test-key" })
      return { cancel = function() end }
    end
    jev.evaluate("我們在線上開會。", "test-key", function(_, e)
      err = e
    end)
    assert.equals("busy", err)
    assert.equals(1, calls)
  end)
  it("does not expose a credential callback exception", function()
    config.setup({ evaluation = {
      api_key = function()
        error("secret-token")
      end,
    } })
    local key, err = config.evaluation_key()
    assert.is_nil(key)
    assert.is_nil(err:find("secret-token", 1, true))
  end)
end)
