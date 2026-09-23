local gemini = require("ai-polish.gemini")
local http = require("ai-polish.http")
local config = require("ai-polish.config")

local function response(payload, extra)
  return vim.json.encode(vim.tbl_extend("force", {
    candidates = {
      { content = { parts = { { text = vim.json.encode(payload) } } }, finishReason = "STOP" },
    },
  }, extra or {}))
end

describe("gemini.parse_response", function()
  it("returns normalized suggestions", function()
    local body = response({
      suggestions = {
        {
          before = "誤字",
          after = { "誤字", "正字", "正字" },
          context_before = "",
          context_after = "",
          message = "m",
          category = "typo",
          severity = "warning",
        },
        { before = "", after = { "x" } }, -- empty before: dropped
        { before = "a", after = { "a" } }, -- no-op: dropped
        { before = "b", after = { "c" }, category = "bogus" },
      },
    })
    local out, err = gemini.parse_response(body)
    assert.is_nil(err)
    assert.equals(2, #out)
    assert.same({ "正字" }, out[1].after) -- identity and duplicates removed
    assert.equals("style", out[2].category) -- unknown category falls back
    assert.equals("suggestion", out[2].severity)
  end)

  it("reports blocked prompts", function()
    local out, err = gemini.parse_response(vim.json.encode({ promptFeedback = { blockReason = "SAFETY" } }))
    assert.is_nil(out)
    assert.matches("blocked.*SAFETY", err)
  end)

  it("reports safety stops and truncation", function()
    local _, err = gemini.parse_response(vim.json.encode({ candidates = { { finishReason = "SAFETY" } } }))
    assert.matches("SAFETY", err)
    local trunc = vim.json.encode({
      candidates = { { content = { parts = { { text = '{"suggestions":[{"bef' } } }, finishReason = "MAX_TOKENS" } },
    })
    local _, err2 = gemini.parse_response(trunc)
    assert.matches("truncated", err2)
  end)

  it("rejects malformed bodies", function()
    local _, err = gemini.parse_response("<html>")
    assert.matches("invalid JSON", err)
  end)
end)

describe("gemini.http_error", function()
  it("maps statuses and API messages", function()
    assert.is_nil(gemini.http_error({ status = 200, body = "" }))
    local err = gemini.http_error({ status = 403, body = vim.json.encode({ error = { message = "API key invalid" } }) })
    assert.matches("HTTP 403", err)
    assert.matches("API key invalid", err)
    assert.equals("request timed out", gemini.http_error({ status = 0, body = "", err = "request timed out" }))
  end)
end)

describe("gemini.proofread", function()
  local orig_post = http.post
  local orig_defer = vim.defer_fn
  before_each(function()
    config.setup({ api_key = "test-key" })
    vim.defer_fn = function(fn)
      fn()
      return { stop = function() end }
    end
  end)
  after_each(function()
    http.post = orig_post
    vim.defer_fn = orig_defer
  end)

  it("sends the key in a header and the schema in generationConfig", function()
    local seen
    http.post = function(req, cb)
      seen = req
      cb({ status = 200, body = response({ suggestions = {} }) })
      return { cancel = function() end }
    end
    local result
    gemini.proofread("text", { filetype = "markdown" }, function(s)
      result = s
    end)
    assert.same({}, result)
    assert.equals("test-key", seen.headers["x-goog-api-key"])
    assert.matches(":generateContent$", seen.url)
    assert.is_nil(seen.url:find("test-key", 1, true))
    local body = vim.json.decode(seen.body)
    assert.equals("application/json", body.generationConfig.responseMimeType)
    assert.is_table(body.generationConfig.responseJsonSchema)
    assert.equals("low", body.generationConfig.thinkingConfig.thinkingLevel)
    assert.matches("markdown", body.systemInstruction.parts[1].text)
  end)

  it("retries 429/5xx and gives up after the retry budget", function()
    local calls = 0
    http.post = function(_, cb)
      calls = calls + 1
      cb({ status = 503, body = "" })
      return { cancel = function() end }
    end
    local err
    gemini.proofread("text", {}, function(_, e)
      err = e
    end)
    assert.equals(3, calls)
    assert.matches("HTTP 503", err)
  end)

  it("does not retry client errors", function()
    local calls = 0
    http.post = function(_, cb)
      calls = calls + 1
      cb({ status = 400, body = "" })
      return { cancel = function() end }
    end
    gemini.proofread("text", {}, function() end)
    assert.equals(1, calls)
  end)

  it("fails fast without an API key", function()
    local env = vim.env.GEMINI_API_KEY
    local genv = vim.env.GOOGLE_API_KEY
    vim.env.GEMINI_API_KEY, vim.env.GOOGLE_API_KEY = nil, nil
    config.setup({})
    local err
    gemini.proofread("text", {}, function(_, e)
      err = e
    end)
    vim.wait(100, function()
      return err ~= nil
    end)
    vim.env.GEMINI_API_KEY, vim.env.GOOGLE_API_KEY = env, genv
    assert.matches("API key", err)
  end)
end)
