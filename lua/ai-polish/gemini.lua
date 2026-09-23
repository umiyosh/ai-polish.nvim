-- Gemini generateContent client: request building, response parsing, error mapping.
local config = require("ai-polish.config")
local prompt = require("ai-polish.prompt")
local http = require("ai-polish.http")
local locale = require("ai-polish.locale")

local M = {}

local RETRYABLE = { [429] = true, [500] = true, [502] = true, [503] = true, [504] = true }
local MAX_RETRIES = 2
local MAX_OUTPUT_TOKENS = 16384

---@param text string
---@param ctx { filetype?: string }
function M.build_body(text, ctx)
  local opts = config.options
  local generation = {
    responseMimeType = "application/json",
    responseJsonSchema = prompt.schema,
    maxOutputTokens = MAX_OUTPUT_TOKENS,
    temperature = opts.temperature,
  }
  if opts.thinking_level then
    generation.thinkingConfig = { thinkingLevel = opts.thinking_level }
  end
  return {
    systemInstruction = {
      parts = {
        {
          text = prompt.system({
            filetype = ctx.filetype,
            language = locale.language(),
            instructions = opts.instructions,
          }),
        },
      },
    },
    contents = { { role = "user", parts = { { text = prompt.user(text) } } } },
    generationConfig = generation,
  }
end

local function api_error_message(body)
  local ok, decoded = pcall(vim.json.decode, body)
  if ok and type(decoded) == "table" and type(decoded.error) == "table" then
    return decoded.error.message
  end
end

local STATUS_HINT = {
  [400] = "invalid request",
  [401] = "authentication failed (check the API key)",
  [403] = "permission denied (check the API key and that the Gemini API is enabled)",
  [404] = "model not found (check `model`)",
  [429] = "rate limit or quota exceeded",
}

---Map an HTTP response to an error string, or nil when status is 2xx.
function M.http_error(res)
  if res.err then
    return res.err
  end
  if res.status >= 200 and res.status < 300 then
    return nil
  end
  local hint = STATUS_HINT[res.status] or (res.status >= 500 and "Gemini service error" or "request failed")
  local detail = api_error_message(res.body)
  return ("HTTP %d: %s%s"):format(res.status, hint, detail and (" — " .. detail) or "")
end

local function str(v)
  return type(v) == "string" and v or nil
end

---Validate one raw suggestion. Returns nil for items that are unusable.
local function normalize(item)
  if type(item) ~= "table" then
    return nil
  end
  local before = str(item.before)
  if not before or before == "" then
    return nil
  end
  local after = {}
  local seen = {}
  for _, a in ipairs(type(item.after) == "table" and item.after or { item.after }) do
    if type(a) == "string" and a ~= before and not seen[a] then
      seen[a] = true
      after[#after + 1] = a
    end
  end
  if #after == 0 then
    return nil
  end
  return {
    before = before,
    after = after,
    context_before = str(item.context_before) or "",
    context_after = str(item.context_after) or "",
    message = str(item.message) or "",
    category = vim.tbl_contains(prompt.categories, item.category) and item.category or "style",
    severity = vim.tbl_contains(prompt.severities, item.severity) and item.severity or "suggestion",
  }
end

---Parse a generateContent response body.
---@return table[]|nil suggestions, string|nil err, table|nil usage
function M.parse_response(body)
  local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    return nil, "invalid JSON from Gemini API"
  end
  local usage = decoded.usageMetadata
  local feedback = decoded.promptFeedback
  if type(feedback) == "table" and feedback.blockReason then
    return nil, "prompt was blocked by Gemini (" .. tostring(feedback.blockReason) .. ")", usage
  end
  local cand = type(decoded.candidates) == "table" and decoded.candidates[1] or nil
  if type(cand) ~= "table" then
    return nil, "Gemini returned no candidates", usage
  end
  local reason = cand.finishReason
  local texts = {}
  local parts = type(cand.content) == "table" and cand.content.parts or {}
  for _, p in ipairs(parts or {}) do
    if type(p) == "table" and type(p.text) == "string" and not p.thought then
      texts[#texts + 1] = p.text
    end
  end
  local text = table.concat(texts)
  if reason and reason ~= "STOP" and reason ~= "MAX_TOKENS" then
    return nil, "response stopped by Gemini (" .. tostring(reason) .. ")", usage
  end
  local ok2, payload = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok2 or type(payload) ~= "table" or type(payload.suggestions) ~= "table" then
    if reason == "MAX_TOKENS" then
      return nil, "response was truncated (MAX_TOKENS); lower `chunk.max_chars`", usage
    end
    return nil, "could not parse suggestions from Gemini response", usage
  end
  local out = {}
  for _, item in ipairs(payload.suggestions) do
    local s = normalize(item)
    if s then
      out[#out + 1] = s
    end
  end
  return out, nil, usage
end

---Send one proofreading request.
---@param text string
---@param ctx { filetype?: string }
---@param cb fun(suggestions: table[]|nil, err: string|nil, usage: table|nil)
---@return { cancel: fun() }
function M.proofread(text, ctx, cb)
  local key, key_err = config.api_key()
  if not key then
    vim.schedule(function()
      cb(nil, key_err)
    end)
    return { cancel = function() end }
  end
  local opts = config.options
  local req = {
    url = ("%s/models/%s:generateContent"):format(opts.endpoint, opts.model),
    headers = { ["Content-Type"] = "application/json", ["x-goog-api-key"] = key },
    body = vim.json.encode(M.build_body(text, ctx)),
    timeout_ms = opts.timeout_ms,
  }

  local handle = { cancelled = false }
  local current, timer

  local function attempt(n)
    current = http.post(req, function(res)
      if handle.cancelled then
        return
      end
      local retryable = res.err or RETRYABLE[res.status]
      if retryable and n < MAX_RETRIES and res.err ~= "request timed out" then
        timer = vim.defer_fn(function()
          if not handle.cancelled then
            attempt(n + 1)
          end
        end, 1000 * 2 ^ n)
        return
      end
      local err = M.http_error(res)
      if err then
        return cb(nil, err)
      end
      cb(M.parse_response(res.body))
    end)
  end
  attempt(0)

  function handle.cancel()
    handle.cancelled = true
    if timer then
      pcall(function()
        timer:stop()
      end)
    end
    if current then
      current.cancel()
    end
  end
  return handle
end

return M
