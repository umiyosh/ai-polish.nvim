local polish = require("ai-polish")
local eval = require("ai-polish.evaluation")
local panel = require("ai-polish.evaluation_panel")
local http = require("ai-polish.http")
local function reply()
  local a = {
    type = "score",
    score = 2,
    confidence = 0.8,
    probabilities = { ["0"] = 0, ["1"] = 0, ["2"] = 1, ["3"] = 0, ["4"] = 0 },
    legend = { ["0"] = "a", ["1"] = "b", ["2"] = "c", ["3"] = "d", ["4"] = "e" },
  }
  return { status = 200, body = vim.json.encode({ answers = { unnaturalness = a, ai_style = a } }) }
end

describe("manual evaluation lifecycle", function()
  local original_post, original_notify = http.post, vim.notify
  local requests, callbacks, cancelled, buf, env
  before_each(function()
    env = vim.env.TYPESAFE_API_KEY
    vim.env.TYPESAFE_API_KEY = nil
    polish.setup({ api_key = "gemini-test", evaluation = { api_key = "jev-test" } })
    vim.cmd("enew!")
    buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "before", "測試文書", "after" })
    requests, callbacks, cancelled = {}, {}, 0
    vim.notify = function() end
    http.post = function(req, cb)
      table.insert(requests, req)
      table.insert(callbacks, cb)
      return {
        cancel = function()
          cancelled = cancelled + 1
        end,
      }
    end
  end)
  after_each(function()
    polish.cancel(buf)
    require("ai-polish.popup").close()
    eval.reset()
    panel.close_details()
    http.post, vim.notify = original_post, original_notify
    vim.env.TYPESAFE_API_KEY = env
  end)
  it("shows no UI or request with an optional missing key", function()
    polish.setup({})
    eval.toggle()
    eval.evaluate()
    assert.equals(0, #requests)
    assert.is_false(panel.is_open())
  end)
  it("toggles without sending and cannot reopen after a hidden request completes", function()
    eval.toggle()
    assert.equals(0, #requests)
    eval.evaluate()
    assert.equals(1, #requests)
    eval.toggle()
    callbacks[1](reply())
    panel.refresh()
    assert.is_false(panel.is_open())
    eval.toggle()
    assert.equals(1, #requests)
    assert.equals(3, eval.get(buf).result.unnaturalness.level)
  end)
  it("keeps a selected target through edits and never falls back after deletion", function()
    eval.evaluate({ range = { 1, 0, 1, 12 }, kind = "selection" })
    callbacks[1](reply())
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 12, { "修改後" })
    assert.equals("stale", eval.snapshot(buf).status)
    eval.evaluate()
    assert.equals("修改後", vim.json.decode(requests[2].body).state.text)
    callbacks[2](reply())
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 9, {})
    eval.evaluate()
    assert.equals(2, #requests)
    eval.evaluate({ whole = true })
    assert.equals(3, #requests)
  end)
  it("does not send on edits, navigation, details or accepting stale results", function()
    eval.evaluate()
    eval.evaluate()
    assert.equals(1, #requests)
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 6, { "changed" })
    callbacks[1](reply())
    panel.refresh()
    assert.equals("stale", eval.snapshot(buf).status)
    eval.details()
    panel.close_details()
    panel.refresh()
    assert.equals(1, #requests)
  end)
  it("cancels and ignores a late response", function()
    eval.evaluate()
    eval.cancel(buf)
    callbacks[1](reply())
    assert.equals(1, cancelled)
    assert.is_nil(eval.get(buf).result)
  end)
  it("routes commands and rejects unsupported or contradictory requests", function()
    vim.cmd("AiPolish evaluate buffer")
    assert.equals(1, #requests)
    vim.cmd("AiPolish cancel")
    vim.cmd("AiPolish toggle")
    assert.equals(1, #requests)
    vim.cmd("AiPolish evaluate nonsense")
    assert.equals(1, #requests)
  end)
  it("evaluates, proofreads and accepts only the retained target without implicit Jev calls", function()
    eval.evaluate({ range = { 1, 0, 1, 12 } })
    callbacks[1](reply())
    eval.polish()
    assert.equals(2, #requests)
    assert.is_truthy(requests[2].url:find("generativelanguage.googleapis.com", 1, true))
    local content = vim.json.decode(requests[2].body).contents[1].parts[1].text
    assert.is_truthy(content:find("TEXT\n測試文書\nTEXT", 1, true))
    callbacks[2]({
      status = 200,
      body = vim.json.encode({
        candidates = {
          {
            content = {
              parts = {
                {
                  text = vim.json.encode({
                    suggestions = {
                      {
                        before = "測試",
                        after = { "測定" },
                        message = "fix",
                        category = "typo",
                        severity = "warning",
                      },
                    },
                  }),
                },
              },
            },
            finishReason = "STOP",
          },
        },
      }),
    })
    require("ai-polish.popup")._actions.accept()
    assert.equals(2, #requests)
    assert.equals("stale", eval.snapshot(buf).status)
    eval.evaluate()
    assert.equals("測定文書", vim.json.decode(requests[3].body).state.text)
    assert.equals(3, #requests)
  end)
  it("refuses excess text, disabled evaluation and declined TypeSafe confirmation", function()
    polish.setup({ evaluation = { api_key = "test", max_chars = 3 } })
    eval.evaluate()
    assert.equals("too_long", eval.snapshot(buf).error)
    polish.setup({ evaluation = { api_key = "test", enabled = false } })
    eval.evaluate()
    assert.is_false(panel.is_open())
    polish.setup({ evaluation = { api_key = "test" }, guard = { confirm_chars = 3 } })
    local old, message = polish._confirm
    polish._confirm = function(msg)
      message = msg
      return false
    end
    eval.evaluate()
    polish._confirm = old
    assert.is_truthy(message:find("TypeSafe", 1, true))
    assert.equals(0, #requests)
  end)
  it("isolates buffers and ignores a cleared request after a newer request", function()
    eval.evaluate()
    eval.clear(buf)
    eval.evaluate({ range = { 0, 0, 0, 6 } })
    callbacks[1](reply())
    assert.is_nil(eval.get(buf).result)
    callbacks[2](reply())
    assert.equals("before", eval.get(buf).text)
    vim.cmd("enew!")
    local other = vim.api.nvim_get_current_buf()
    panel.refresh()
    assert.equals("none", eval.snapshot(other).status)
    assert.equals(2, #requests)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_nil(eval.get(buf))
  end)
end)
