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

-- A fix in the numbered form Japanese requests use: `before` (found inside `near`) named by the
-- number of the unit it lies in, whatever units BudouX made.
local function nsug(req, near, before, after)
  local text = vim.json.decode(req.body).contents[1].parts[1].text
  local starts, removed = {}, 0
  for pos, marker, num in text:gmatch("()(〔(%d+)〕)") do
    starts[#starts + 1] = { at = pos - removed, n = tonumber(num) }
    removed = removed + #marker
  end
  local plain = text:gsub("〔%d+〕", "")
  local at = assert(plain:find(near, 1, true), near) + assert(near:find(before, 1, true)) - 1
  local n
  for _, s in ipairs(starts) do
    if s.at <= at then
      n = s.n
    end
  end
  local s = sug(before, after)
  s.from, s.to, s.context_before, s.context_after = n, n, nil, nil
  return s
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
  local requests, reply, messages, jev_env

  before_each(function()
    jev_env, vim.env.TYPESAFE_API_KEY = vim.env.TYPESAFE_API_KEY, nil
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
    vim.env.TYPESAFE_API_KEY = jev_env
  end)

  local function wait_idle()
    vim.wait(1000, function()
      return polish.status() == "" or polish.status():match("^AI Polish: %d")
    end)
  end

  local function last_message()
    return messages[#messages] and messages[#messages].msg or ""
  end

  -- ERROR-level notifications are deferred with vim.schedule.
  local function wait_message(pattern)
    local found
    vim.wait(1000, function()
      for _, m in ipairs(messages) do
        if m.msg:match(pattern) then
          found = m
          return true
        end
      end
      return false
    end)
    return found or { msg = last_message() }
  end

  it("proofreads the buffer, opens the popup and applies accepted edits", function()
    local b = open_buffer({ "今日わ良い天気です。", "明日わ雨です。" })
    reply = function(req)
      return gemini_reply({ nsug(req, "今日わ", "わ", "は"), nsug(req, "明日わ", "わ", "は") })
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

  it("finds numbered fixes again when the buffer was edited while waiting", function()
    local b = open_buffer({ "今日わ良い天気です。" })
    reply = function(req)
      return gemini_reply({ nsug(req, "今日わ", "わ", "は") })
    end
    vim.cmd("AiPolish")
    -- Before the scheduled reply: the unit's offset in the sent text no longer holds.
    vim.api.nvim_buf_set_text(b, 0, 0, 0, 0, { "さて、" })
    wait_idle()
    popup._actions.accept()
    assert.same({ "さて、今日は良い天気です。" }, lines(b))
  end)

  it("sends the Japanese rules only with Japanese text", function()
    local function system_of(buffer_lines)
      requests = {}
      open_buffer(buffer_lines)
      vim.cmd("AiPolish")
      wait_idle()
      return vim.json.decode(requests[1].body).systemInstruction.parts[1].text
    end
    assert.truthy(system_of({ "今日わ良い天気です。" }):find("常体", 1, true))
    assert.falsy(system_of({ "teh weather is nice." }):find("常体", 1, true))
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
    local m = wait_message("HTTP 401")
    assert.matches("HTTP 401", m.msg)
    assert.equals(vim.log.levels.ERROR, m.level)
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
        return gemini_reply({ nsug(req, "最後わ", "わ", "は") })
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
    assert.matches("too large", wait_message("too large").msg)
  end)

  -- lazy.nvim loads the plugin on the first :AiPolish and runs it through vim.cmd();
  -- an ERROR notification must not turn into an exception there.
  it("does not raise when invoked through vim.cmd without an API key", function()
    local gemini_env, google_env = vim.env.GEMINI_API_KEY, vim.env.GOOGLE_API_KEY
    vim.env.GEMINI_API_KEY, vim.env.GOOGLE_API_KEY = nil, nil
    polish.setup({})
    open_buffer({ "text" })
    vim.notify = orig_notify -- the real one is what turns ERROR into an exception
    local ok, err = pcall(vim.cmd, "AiPolish")
    vim.env.GEMINI_API_KEY, vim.env.GOOGLE_API_KEY = gemini_env, google_env
    assert.is_true(ok, err)
    assert.equals(0, #requests)
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

  describe("with Jev's tentative marks", function()
    local tentative = require("ai-polish.tentative")
    local pending

    before_each(function()
      vim.env.TYPESAFE_API_KEY = "jev-key"
      polish.setup({ api_key = "k", evaluation = { auto_max_chars = 0 } })
      pending = {}
      http.post = function(req, cb)
        requests[#requests + 1] = req
        pending[#pending + 1] = { req = req, cb = cb, jev = req.url:find("typesafe", 1, true) ~= nil }
        return { cancel = function() end }
      end
    end)

    local function marked(b)
      return #vim.api.nvim_buf_get_extmarks(b, tentative.ns, 0, -1, {})
    end

    local function answer(jev, res)
      for _, p in ipairs(pending) do
        if p.jev == jev then
          p.cb(res(p))
        end
      end
    end

    local function answer_jev()
      answer(true, function(p)
        local answers = {}
        for k in pairs(vim.json.decode(p.req.body).questions) do
          answers[k] = { type = "noul", noul = 0.9 }
        end
        return { status = 200, body = vim.json.encode({ answers = answers }) }
      end)
    end

    it("asks Jev alongside Gemini and underlines its marks until Gemini's fixes arrive", function()
      local b = open_buffer({ "今日わ良い天気です。" })
      vim.cmd("AiPolish")
      assert.equals(2, #pending)
      answer_jev()
      assert.is_true(marked(b) > 0)
      answer(false, function(p)
        return gemini_reply({ nsug(p.req, "今日わ", "わ", "は") })
      end)
      wait_idle()
      assert.equals(0, marked(b))
      assert.equals("AI Polish: 1", polish.status(b))
    end)

    it("clears the marks when the check is cancelled", function()
      local b = open_buffer({ "今日わ良い天気です。" })
      vim.cmd("AiPolish")
      answer_jev()
      assert.is_true(marked(b) > 0)
      vim.cmd("AiPolish cancel")
      assert.equals(0, marked(b))
    end)

    it("does not ask Jev about text that is not Japanese, or when marks are disabled", function()
      open_buffer({ "teh start" })
      vim.cmd("AiPolish")
      assert.equals(1, #pending)
      vim.cmd("AiPolish cancel")
      polish.setup({ api_key = "k", evaluation = { auto_max_chars = 0, marks = { enabled = false } } })
      open_buffer({ "今日わ良い天気です。" })
      vim.cmd("AiPolish")
      assert.equals(2, #pending)
      vim.cmd("AiPolish cancel")
    end)

    local function mark_requests()
      return vim.tbl_filter(function(p)
        return p.jev and vim.json.decode(p.req.body).questions.e0001 ~= nil
      end, pending)
    end

    it("underlines marks on an explicit evaluation and keeps them until cleared", function()
      local eval = require("ai-polish.evaluation")
      local b = open_buffer({ "今日わ良い天気です。" })
      eval.evaluate({ bufnr = b, whole = true })
      assert.equals(1, #mark_requests())
      local p = mark_requests()[1]
      p.cb({ status = 200, body = vim.json.encode({ answers = { e0001 = { type = "noul", noul = 0.9 } } }) })
      assert.equals(1, marked(b))
      vim.cmd("AiPolish clear")
      assert.equals(0, marked(b))
    end)

    it("does not ask for marks on an automatic evaluation", function()
      polish.setup({ api_key = "k" })
      local b = open_buffer({ "今日わ良い天気です。" })
      require("ai-polish.evaluation").evaluate({ bufnr = b, whole = true, automatic = true })
      assert.is_true(#pending > 0)
      assert.equals(0, #mark_requests())
      vim.cmd("AiPolish clear")
    end)
  end)
end)
