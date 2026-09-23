-- End-to-end: command/API -> (stubbed) Gemini -> session + popup -> buffer edits.
local polish = require("ai-polish")
local http = require("ai-polish.http")
local popup = require("ai-polish.popup")
local session = require("ai-polish.session")

local function gemini_reply(suggestions)
  return {
    status = 200,
    body = vim.json.encode({
      candidates = {
        { content = { parts = { { text = vim.json.encode({ suggestions = suggestions }) } } }, finishReason = "STOP" },
      },
    }),
  }
end

local function sug(before, after, cb, ca)
  return {
    before = before,
    after = { after },
    context_before = cb or "",
    context_after = ca or "",
    message = "fix",
    category = "typo",
    severity = "warning",
  }
end

local function open_buffer(lines)
  vim.cmd("enew!")
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

describe("proofreading flow", function()
  local orig_post, orig_confirm, orig_notify = http.post, polish._confirm, vim.notify
  local requests, reply, messages

  before_each(function()
    polish.setup({ api_key = "k" })
    requests, messages = {}, {}
    reply = function()
      return gemini_reply({})
    end
    http.post = function(req, cb)
      requests[#requests + 1] = req
      local res = reply(req)
      vim.schedule(function()
        cb(res)
      end)
      return { cancel = function() end }
    end
    vim.notify = function(msg, level)
      messages[#messages + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    popup.close()
    http.post, polish._confirm, vim.notify = orig_post, orig_confirm, orig_notify
  end)

  local function wait_idle()
    vim.wait(1000, function()
      return polish.status() == "" or polish.status():match("^AI Polish: %d")
    end)
  end

  local function last_message()
    return messages[#messages] and messages[#messages].msg or ""
  end

  it("proofreads the buffer, opens the popup and applies accepted edits", function()
    local b = open_buffer({ "今日わ良い天気です。", "明日わ雨です。" })
    reply = function()
      return gemini_reply({ sug("わ", "は", "今日", "良い"), sug("わ", "は", "明日", "雨") })
    end
    vim.cmd("AiPolish")
    wait_idle()
    assert.equals(1, #requests)
    assert.is_true(popup.is_open())
    assert.equals("AI Polish: 2", polish.status(b))

    popup._actions.accept()
    assert.same({ "今日は良い天気です。", "明日わ雨です。" }, lines(b))
    popup._actions.reject()
    assert.same({ "今日は良い天気です。", "明日わ雨です。" }, lines(b))
    assert.is_false(popup.is_open())
    assert.is_nil(session.get(b))
  end)

  it("proofreads only a charwise visual selection", function()
    local b = open_buffer({ "teh start, teh middle, teh end" })
    reply = function(req)
      local text = vim.json.decode(req.body).contents[1].parts[1].text
      assert.matches("TEXT\nteh middle\nTEXT", text)
      return gemini_reply({ sug("teh", "the", "", " middle") })
    end
    vim.api.nvim_win_set_cursor(0, { 1, 11 })
    vim.cmd("normal! v9l\27")
    vim.cmd("'<,'>AiPolish")
    wait_idle()
    popup._actions.accept()
    assert.same({ "teh start, the middle, teh end" }, lines(b))
  end)

  it("reports when there is nothing to fix", function()
    open_buffer({ "完璧な文章。" })
    vim.cmd("AiPolish")
    wait_idle()
    assert.is_false(popup.is_open())
    assert.matches("no issues found", last_message())
  end)

  it("surfaces API errors", function()
    open_buffer({ "text" })
    reply = function()
      return { status = 401, body = "" }
    end
    vim.cmd("AiPolish")
    wait_idle()
    assert.matches("HTTP 401", last_message())
    assert.equals(vim.log.levels.ERROR, messages[#messages].level)
  end)

  it("asks before sending large text and sends nothing when declined", function()
    polish.setup({ api_key = "k", guard = { confirm_chars = 100 } })
    open_buffer({ string.rep("長い文章。", 50) })
    local asked
    polish._confirm = function(msg)
      asked = msg
      return false
    end
    vim.cmd("AiPolish")
    assert.matches("chars", asked)
    assert.matches("cost", asked)
    assert.equals(0, #requests)
    assert.matches("cancelled", last_message())
  end)

  it("splits large text into chunks after confirmation", function()
    polish.setup({ api_key = "k", chunk = { max_chars = 500 }, guard = { confirm_chars = 100 } })
    local para = string.rep("あ", 400)
    local b = open_buffer({ para, "", para, "", "最後わ誤字。" })
    polish._confirm = function()
      return true
    end
    reply = function(req)
      local text = vim.json.decode(req.body).contents[1].parts[1].text
      if text:find("最後わ", 1, true) then
        return gemini_reply({ sug("わ", "は", "最後", "誤字") })
      end
      return gemini_reply({})
    end
    vim.cmd("AiPolish")
    wait_idle()
    assert.is_true(#requests >= 2)
    popup._actions.accept()
    assert.equals("最後は誤字。", lines(b)[5])
  end)

  it("refuses text beyond guard.max_chars", function()
    polish.setup({ api_key = "k", guard = { max_chars = 10 } })
    open_buffer({ string.rep("x", 50) })
    vim.cmd("AiPolish")
    assert.equals(0, #requests)
    assert.matches("too large", last_message())
  end)

  it("cancels an in-flight request", function()
    open_buffer({ "text" })
    local cancelled = false
    http.post = function()
      return {
        cancel = function()
          cancelled = true
        end,
      }
    end
    vim.cmd("AiPolish")
    assert.equals("AI Polish…", polish.status())
    vim.cmd("AiPolish cancel")
    assert.is_true(cancelled)
    assert.equals("", polish.status())
  end)
end)
