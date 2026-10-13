-- Cases ported from Kotobae's src-tauri/src/services/jev/level_tests.rs.
local level = require("ai-polish.jev_level")

local TEXT = "一文目です。二文目です。"

local function check(lvl, value, sentence)
  return {
    level = lvl,
    value = value,
    findings = { { kind = "phrase", text = sentence, sentence = sentence, value = value } },
  }
end

local function mark_on(part)
  local s = TEXT:find(part, 1, true) - 1
  return { from = s, to = s + #part }
end

local function marks(n)
  local out = {}
  for i = 1, n do
    out[i] = mark_on("二文目")
  end
  return out
end

local W = level.WRITTEN

describe("jev_level", function()
  it("is level one for a text without errors and with two marks at most", function()
    local clean = check(1, 0.2, "一文目です。")
    assert.equals(1, level.level(clean, TEXT, marks(2), 10, W))
    assert.equals(2, level.level(clean, TEXT, marks(3), 10, W))
  end)

  it("keeps level one with the marks Jev puts on correct long texts", function()
    local clean = check(1, 0.2, "一文目です。")
    assert.equals(1, level.level(clean, TEXT, marks(6), 200, W))
    assert.equals(2, level.level(clean, TEXT, marks(7), 200, W))
  end)

  it("counts an error toward three only when its sentence is marked", function()
    local err = check(3, 1.0, "二文目です。")
    assert.equals(3, level.level(err, TEXT, { mark_on("二文目") }, 10, W))
    assert.equals(2, level.level(err, TEXT, { mark_on("一文目") }, 10, W))
    assert.equals(2, level.level(err, TEXT, {}, 10, W))
  end)

  it("rises by the share of bunsetsu beyond the background marks", function()
    local clean = check(1, 0.1, "一文目です。")
    assert.equals(2, level.level(clean, TEXT, marks(5), 100, W))
    assert.equals(3, level.level(clean, TEXT, marks(9), 100, W))
    assert.equals(4, level.level(clean, TEXT, marks(18), 100, W))
    assert.equals(5, level.level(clean, TEXT, marks(33), 100, W))
  end)

  it("reaches five only for a text mostly to rewrite", function()
    assert.equals(4, level.level(check(1, 0.1, "一文目です。"), TEXT, marks(23), 100, W))
  end)

  it("counts the marks of a short text as if it had twenty bunsetsu", function()
    assert.equals(2, level.level(check(1, 0.2, "一文目です。"), TEXT, marks(3), 5, W))
  end)

  it("is the larger of the errors and the rewriting", function()
    local errors = check(4, 0.9, "二文目です。")
    assert.equals(4, level.level(errors, TEXT, marks(4), 100, W))
    assert.equals(5, level.level(errors, TEXT, marks(33), 100, W))
  end)

  it("confirms errors with the marks given apart", function()
    local err = check(3, 1.0, "二文目です。")
    -- Default level: errors marks count the rewriting; marks of either measure confirm.
    assert.equals(3, level.level_with(err, TEXT, {}, { mark_on("二文目") }, 10, level.ERRORS))
    assert.equals(2, level.level_with(err, TEXT, {}, {}, 10, level.ERRORS))
  end)
end)

describe("jev.evaluate with marks (Japanese)", function()
  local jev = require("ai-polish.jev")
  local http = require("ai-polish.http")
  local orig = http.post
  local TEXT2 = "今日は良い天気です。明日も晴れるでしょう。"

  -- Answers every question: the local check finds nothing; marks follow `mark(key)`.
  local function serve(mark, fail_marks)
    http.post = function(req, cb)
      local body = vim.json.decode(req.body)
      local answers, is_mark = {}, false
      for k, q in pairs(body.questions) do
        if q.type == "score" then
          local p = { ["0"] = 1, ["1"] = 0, ["2"] = 0, ["3"] = 0, ["4"] = 0 }
          answers[k] = { type = "score", score = 0, confidence = 0.9, probabilities = p, legend = p }
          answers[k].legend = { ["0"] = "a", ["1"] = "b", ["2"] = "c", ["3"] = "d", ["4"] = "e" }
        else
          is_mark = is_mark or k:match("^[eb]%d") ~= nil
          answers[k] = { type = "noul", noul = k:match("^[eb]%d") and mark(k) or 0.99 }
        end
      end
      vim.schedule(function()
        if is_mark and fail_marks then
          return cb({ status = 500, body = "" })
        end
        cb({ status = 200, body = vim.json.encode({ answers = answers }) })
      end)
      return { cancel = function() end }
    end
  end

  after_each(function()
    http.post = orig
  end)

  local function run()
    local result, err, done
    jev.evaluate(TEXT2, "key", function(r, e)
      result, err, done = r, e, true
    end)
    vim.wait(1000, function()
      return done
    end)
    return result, err
  end

  it("is level one with no marks, keeping the local level apart", function()
    serve(function()
      return 0
    end)
    local r = run()
    assert.equals(1, r.unnaturalness.level)
    assert.equals(1, r.unnaturalness.local_level)
    assert.equals(1, r.written_level)
    assert.equals(0, r.unnaturalness.marks)
  end)

  it("rises with the marks of each measure", function()
    serve(function(k)
      return k:sub(1, 1) == "b" and 0.9 or 0
    end)
    local r = run()
    assert.equals(1, r.unnaturalness.level)
    assert.is_true(r.written_level >= 2)
    assert.is_true(r.unnaturalness.written_marks > 0)
  end)

  it("fails the evaluation when a mark request fails", function()
    serve(function()
      return 0
    end, true)
    local r, err = run()
    assert.is_nil(r)
    assert.equals("service_error", err)
  end)
end)
