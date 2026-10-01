local polish = require("ai-polish")
local eval = require("ai-polish.evaluation")
local panel = require("ai-polish.evaluation_panel")
local http = require("ai-polish.http")
local function reply(req)
  local a = {
    type = "score",
    score = 2,
    confidence = 0.8,
    probabilities = { ["0"] = 0, ["1"] = 0, ["2"] = 1, ["3"] = 0, ["4"] = 0 },
    legend = { ["0"] = "a", ["1"] = "b", ["2"] = "c", ["3"] = "d", ["4"] = "e" },
  }
  local answers = { unnaturalness = a, ai_style = a }
  for id, q in pairs(vim.json.decode(req.body).questions) do
    if q.type == "noul" then
      answers[id] = { type = "noul", noul = 0.6 }
    end
  end
  return { status = 200, body = vim.json.encode({ answers = answers }) }
end

describe("evaluation lifecycle", function()
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
    callbacks[1](reply(requests[1]))
    panel.refresh()
    assert.is_false(panel.is_open())
    eval.toggle()
    assert.equals(1, #requests)
    assert.equals(3, eval.get(buf).result.unnaturalness.level)
  end)
  it("keeps a selected target through edits and never falls back after deletion", function()
    eval.evaluate({ range = { 1, 0, 1, 12 }, kind = "selection" })
    callbacks[1](reply(requests[1]))
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 12, { "修改後" })
    assert.equals("stale", eval.snapshot(buf).status)
    eval.evaluate()
    assert.equals("修改後", vim.json.decode(requests[2].body).state.text)
    callbacks[2](reply(requests[2]))
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
    callbacks[1](reply(requests[1]))
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
    callbacks[1](reply(requests[1]))
    assert.equals(1, cancelled)
    assert.is_nil(eval.get(buf).result)
  end)
  it("debounces normal-mode deletions and undo without duplicating pending requests", function()
    eval.evaluate()
    callbacks[1](reply(requests[1]))
    vim.cmd("normal! gg0x")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.wait(250, function()
      return false
    end)
    assert.equals(1, #requests)
    vim.cmd("normal! dw")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.wait(250, function()
      return false
    end)
    assert.equals(1, #requests)
    assert.is_true(vim.wait(500, function()
      return #requests == 2
    end))
    assert.equals(
      table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
      vim.json.decode(requests[2].body).state.text
    )
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.wait(500, function()
      return false
    end)
    assert.equals(2, #requests)
    callbacks[2](reply(requests[2]))
    vim.cmd("normal! u")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    assert.is_true(vim.wait(700, function()
      return #requests == 3
    end))
  end)
  it("does not send a queued normal edit after hiding or clearing evaluation", function()
    eval.evaluate()
    callbacks[1](reply(requests[1]))
    vim.cmd("normal! gg0x")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eval.toggle()
    vim.wait(500, function()
      return false
    end)
    assert.equals(1, #requests)
    eval.toggle()
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eval.clear(buf)
    vim.wait(500, function()
      return false
    end)
    assert.equals(1, #requests)
  end)
  it("reevaluates changed text on InsertLeave only while an evaluated panel is visible", function()
    local function leave()
      vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
    end
    eval.toggle()
    leave()
    assert.equals(0, #requests)
    eval.evaluate()
    callbacks[1](reply(requests[1]))
    leave()
    assert.equals(1, #requests)
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 6, { "edited" })
    leave()
    assert.equals(2, #requests)
    leave()
    assert.equals(2, #requests) -- no duplicate while pending
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 6, { "latest" })
    leave()
    assert.equals(3, #requests)
    assert.equals(1, cancelled)
    callbacks[2](reply(requests[2]))
    assert.equals("loading", eval.snapshot(buf).status)
    callbacks[3](reply(requests[3]))
    assert.is_truthy(eval.get(buf).text:find("latest", 1, true))
    eval.toggle()
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 6, { "hidden" })
    leave()
    assert.equals(3, #requests)
  end)
  it("keeps the retained selection on InsertLeave and skips outside edits or a deleted range", function()
    eval.evaluate({ range = { 1, 0, 1, 12 }, kind = "selection" })
    callbacks[1](reply(requests[1]))
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 6, { "outside" })
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
    assert.equals(1, #requests)
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 12, { "修改後" })
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
    assert.equals(2, #requests)
    assert.equals("修改後", vim.json.decode(requests[2].body).state.text)
    callbacks[2](reply(requests[2]))
    assert.equals("selection", eval.get(buf).target.kind)
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 9, {})
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
    assert.equals(2, #requests)
  end)
  it("applies automatic size limits on InsertLeave without asking or sending", function()
    local original_confirm = polish._confirm
    local confirmations = 0
    polish._confirm = function()
      confirmations = confirmations + 1
      return true
    end
    eval.evaluate()
    callbacks[1](reply(requests[1]))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("文", 3001) })
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
    assert.equals(1, #requests)
    assert.equals(0, confirmations)
    assert.equals("stale", eval.snapshot(buf).status)
    polish._confirm = original_confirm
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
  it("automatically evaluates the proofreading target and each accepted correction", function()
    eval.evaluate({ range = { 1, 0, 1, 12 } })
    callbacks[1](reply(requests[1]))
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
    assert.equals(3, #requests)
    assert.equals("測試文書", vim.json.decode(requests[3].body).state.text)
    assert.is_true(eval.view().visible)
    -- Accept while the initial automatic evaluation is still pending.
    require("ai-polish.popup")._actions.accept()
    assert.equals(4, #requests)
    assert.equals("測定文書", vim.json.decode(requests[4].body).state.text)
    callbacks[3](reply(requests[3]))
    assert.equals("loading", eval.snapshot(buf).status)
    callbacks[4](reply(requests[4]))
    assert.equals("ready", eval.snapshot(buf).status)
    assert.equals("測定文書", eval.get(buf).text)
  end)
  it("automatically shows evaluation even when proofreading finds no issues", function()
    polish.proofread()
    callbacks[1]({
      status = 200,
      body = vim.json.encode({
        candidates = {
          { content = { parts = { { text = '{"suggestions":[]}' } } }, finishReason = "STOP" },
        },
      }),
    })
    assert.equals(2, #requests)
    assert.is_truthy(requests[2].url:find("api.typesafe.ai", 1, true))
    callbacks[2](reply(requests[2]))
    panel.refresh()
    assert.is_true(panel.is_open())
    assert.equals("ready", eval.snapshot(buf).status)
  end)
  it("skips automatic checks beyond character/request budgets without confirmation", function()
    local old = polish._confirm
    local confirmations = 0
    polish._confirm = function()
      confirmations = confirmations + 1
      return true
    end
    polish.setup({ evaluation = { api_key = "test", auto_max_chars = 3 } })
    eval.evaluate({ bufnr = buf, whole = true, automatic = true, show = true })
    assert.equals(0, #requests)
    polish.setup({ evaluation = { api_key = "test" }, guard = { confirm_requests = 0 } })
    eval.evaluate({ bufnr = buf, whole = true, automatic = true, show = true })
    assert.equals(0, #requests)
    assert.equals(0, confirmations)
    polish._confirm = old
    -- The manual route remains available above the automatic size threshold.
    polish.setup({ evaluation = { api_key = "test", auto_max_chars = 3 } })
    eval.evaluate({ whole = true })
    assert.equals(1, #requests)
  end)
  it("does not resolve passive key callbacks or display UI without a key", function()
    local calls = 0
    polish.setup({
      evaluation = {
        api_key = function()
          calls = calls + 1
          return "test"
        end,
      },
    })
    eval.evaluate({ bufnr = buf, whole = true, automatic = true, show = true })
    assert.equals(0, calls)
    assert.equals(0, #requests)
    assert.is_false(panel.is_open())
    polish.setup({ evaluation = { api_key = "test", enabled = false } })
    eval.evaluate({ bufnr = buf, whole = true, automatic = true, show = true })
    assert.equals(0, #requests)
  end)
  it("reevaluates each accept, once for accept-all, never for rejection or stale edits", function()
    local sessions = require("ai-polish.session")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a b c" })
    local items = {}
    for i, letter in ipairs({ "a", "b", "c" }) do
      items[i] = {
        row = 0,
        col = (i - 1) * 2,
        end_row = 0,
        end_col = (i - 1) * 2 + 1,
        before = letter,
        after = { letter:upper() },
        severity = "warning",
      }
    end
    local s = sessions.create(buf, items, { whole = true })
    s:accept()
    assert.equals("A b c", vim.json.decode(requests[1].body).state.text)
    s:accept()
    assert.equals("A B c", vim.json.decode(requests[2].body).state.text)
    s:reject()
    assert.equals(2, #requests)
    eval.cancel(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a b c" })
    s = sessions.create(buf, items, { range = { 0, 0, 0, 5 } })
    s:accept_all()
    assert.equals(3, #requests)
    assert.equals("A B C", vim.json.decode(requests[3].body).state.text)
    callbacks[3](reply(requests[3]))
    assert.equals("ready", eval.snapshot(buf).status)
    -- An unsuccessful adoption sends nothing.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a b c" })
    s = sessions.create(buf, items, { whole = true })
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 1, { "z" })
    assert.is_false(s:accept())
    assert.equals(3, #requests)
  end)
  it("keeps a manually hidden panel hidden during acceptance evaluation", function()
    eval.evaluate({ whole = true, automatic = true, show = true })
    eval.toggle()
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 6, { "new" })
    eval.evaluate({ whole = true, automatic = true })
    callbacks[2](reply(requests[2]))
    panel.refresh()
    assert.equals(2, #requests)
    assert.is_false(panel.is_open())
  end)
  it("does not cancel manual evaluation when automatic checks are disabled", function()
    polish.setup({ evaluation = { api_key = "test", auto_max_chars = 0 } })
    eval.evaluate({ whole = true })
    eval.evaluate({ whole = true, automatic = true, show = true })
    assert.equals(1, #requests)
    assert.equals(0, cancelled)
    callbacks[1](reply(requests[1]))
    assert.equals("ready", eval.snapshot(buf).status)
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
    callbacks[1](reply(requests[1]))
    assert.is_nil(eval.get(buf).result)
    callbacks[2](reply(requests[2]))
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
