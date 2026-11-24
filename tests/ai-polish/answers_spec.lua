local answers = require("ai-polish.answers")
local gemini = require("ai-polish.gemini")

local function fix(from, before)
  return { from = from, to = from, before = before, after = { "x" }, category = "typo", message = "m" }
end

describe("answers.stream", function()
  local orig_stream, orig_grace = gemini.proofread_stream, answers.GRACE_MS
  local calls, got, done
  local ja = { language = "ja", split = { units = {} } }

  before_each(function()
    calls, got, done = {}, {}, nil
    -- Each request is answered by hand: `give` hands over fixes, `finish` ends it.
    gemini.proofread_stream = function(text, ctx, on_suggestions, on_done)
      local call = { text = text, ctx = ctx, give = on_suggestions, finish = on_done, cancelled = false }
      calls[ctx.kind or "main"] = call
      calls[#calls + 1] = call
      return {
        cancel = function()
          call.cancelled = true
        end,
      }
    end
  end)

  after_each(function()
    gemini.proofread_stream, answers.GRACE_MS = orig_stream, orig_grace
  end)

  local function start(ctx)
    return answers.stream("本文", ctx or ja, function(sugs)
      vim.list_extend(got, sugs)
    end, function(err)
      done = { err = err }
    end)
  end

  local function shown()
    return vim.tbl_map(function(s)
      return s.before
    end, got)
  end

  it("asks only the main question about text that is not Japanese", function()
    start({ language = "en" })
    assert.equals(1, #calls)
    assert.is_nil(calls[1].ctx.kind)
  end)

  it("asks for homophones in the same numbered text, alongside the main answer", function()
    start()
    assert.equals(2, #calls)
    assert.equals("本文", calls.homophones.text)
    assert.equals(ja.split, calls.homophones.ctx.split)
    assert.equals("ja", calls.homophones.ctx.language)
  end)

  -- Jev's marks go once fixes have moved past them (tentative.lua), so a homophone fix further
  -- on would wipe marks the main answer has yet to reach.
  it("holds a homophone fix until the main answer has passed its place", function()
    start()
    calls.homophones.give({ fix(5, "h5") })
    assert.same({}, shown())
    calls.main.give({ fix(3, "m3") })
    assert.same({ "m3" }, shown())
    calls.main.give({ fix(5, "m5") })
    assert.same({ "m3", "m5", "h5" }, shown())
    calls.homophones.give({ fix(2, "h2") })
    assert.same({ "m3", "m5", "h5", "h2" }, shown())
  end)

  it("hands over what is left in text order when the main answer ends", function()
    start()
    calls.homophones.give({ fix(9, "h9"), fix(nil, "h?"), fix(4, "h4") })
    calls.main.finish(nil)
    assert.same({ "h4", "h9", "h?" }, shown())
    assert.is_nil(done)
    calls.homophones.give({ fix(7, "h7") })
    assert.same({ "h4", "h9", "h?", "h7" }, shown())
    calls.homophones.finish(nil)
    assert.same({}, done)
  end)

  it("marks the homophone fixes apart from the main answer's", function()
    start()
    calls.main.give({ fix(1, "m1") })
    calls.homophones.give({ fix(1, "h1") })
    assert.is_nil(got[1].homophone)
    assert.is_true(got[2].homophone)
  end)

  it("ends at once when the main answer fails, without waiting for homophones", function()
    start()
    calls.main.finish("HTTP 500")
    assert.same({ err = "HTTP 500" }, done)
    assert.is_true(calls.homophones.cancelled)
  end)

  it("waits for the homophone answer only a short while after the main one", function()
    answers.GRACE_MS = 20
    start()
    calls.main.finish(nil)
    assert.is_nil(done)
    vim.wait(1000, function()
      return done ~= nil
    end)
    assert.same({}, done)
    assert.is_true(calls.homophones.cancelled)
  end)

  it("ends with the main answer alone when the homophone request fails", function()
    start()
    calls.homophones.finish("HTTP 500")
    assert.is_nil(done)
    calls.main.finish(nil)
    assert.same({}, done)
  end)

  it("stops both requests when cancelled, and reports nothing after", function()
    local handle = start()
    handle.cancel()
    assert.is_true(calls.main.cancelled)
    assert.is_true(calls.homophones.cancelled)
    calls.main.finish(nil)
    calls.homophones.finish(nil)
    assert.is_nil(done)
  end)
end)
