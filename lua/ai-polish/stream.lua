--- Turns Gemini's server-sent events into suggestions one at a time, ported from Kotobae's
--- gemini/stream.rs. The answer is a single JSON object streamed in arbitrary pieces; handing
--- over each suggestion as soon as its object closes lets the review start seconds before the
--- answer ends.
local M = {}

--- Collects the `data` payload of each server-sent event.
function M.decoder()
  local pending, data = "", {}
  local d = {}

  local function line(l, events)
    if l == "" then
      if #data > 0 then
        events[#events + 1] = table.concat(data, "\n")
        data = {}
      end
    elseif l:sub(1, 5) == "data:" then
      local value = l:sub(6)
      data[#data + 1] = value:sub(1, 1) == " " and value:sub(2) or value
    end
    -- Comments and the other fields (event, id, retry) carry nothing Gemini's answer needs.
  end

  ---@param bytes string
  ---@return string[] events completed by these bytes
  function d.push(bytes)
    pending = pending .. bytes
    local events = {}
    -- Lines end at an ASCII newline, so a complete line never splits a UTF-8 character.
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      line((pending:sub(1, nl - 1):gsub("\r$", "")), events)
      pending = pending:sub(nl + 1)
    end
    return events
  end

  --- A stream may end without the blank line that closes its last event.
  function d.finish()
    return d.push("\n\n")
  end

  return d
end

-- The answer object, then its suggestions array, then each suggestion.
local SUGGESTION_DEPTH = 3
local QUOTE, BACKSLASH = ('"'):byte(), ("\\"):byte()
local OPEN = { [("{"):byte()] = true, [("["):byte()] = true }
local CLOSE = { [("}"):byte()] = true, [("]"):byte()] = true }
local BRACE = ("{"):byte()

--- Finds each element of the `suggestions` array once its object closes. JSON structure is
--- ASCII, so scanning bytes is safe for text that contains multi-byte characters.
function M.scanner()
  local text, scanned, depth, in_string, escaped, start = "", 0, 0, false, false, nil
  local s = {}

  ---@param piece string
  ---@return string[] suggestion objects completed by this piece
  function s.push(piece)
    text = text .. piece
    local found = {}
    while scanned < #text do
      scanned = scanned + 1
      local b = text:byte(scanned)
      if in_string then
        if escaped then
          escaped = false
        elseif b == BACKSLASH then
          escaped = true
        elseif b == QUOTE then
          in_string = false
        end
      elseif b == QUOTE then
        in_string = true
      elseif OPEN[b] then
        depth = depth + 1
        if depth == SUGGESTION_DEPTH and b == BRACE then
          start = scanned
        end
      elseif CLOSE[b] then
        if depth == SUGGESTION_DEPTH and start then
          found[#found + 1] = text:sub(start, scanned)
          start = nil
        end
        depth = math.max(depth - 1, 0)
      end
    end
    return found
  end

  function s.text()
    return text
  end

  return s
end

-- Thought summaries are not part of the JSON answer.
local function answer_text(candidate)
  local parts = type(candidate.content) == "table" and candidate.content.parts or {}
  local out = {}
  for _, p in ipairs(type(parts) == "table" and parts or {}) do
    if type(p) == "table" and type(p.text) == "string" and not p.thought then
      out[#out + 1] = p.text
    end
  end
  return table.concat(out)
end

--- One streamed answer: reads events, returns the suggestions each completed, and tells how
--- Gemini ended it. `usage` holds the last usageMetadata seen.
function M.answer()
  local scanner = M.scanner()
  local finish_reason
  local a = { usage = nil, invalid = 0 }

  ---@param data string one event's payload
  ---@return table[]|nil suggestions (decoded, not yet validated), string|nil err
  function a.read(data)
    local ok, chunk = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
    if not ok or type(chunk) ~= "table" then
      return nil, "invalid JSON from Gemini API"
    end
    if type(chunk.usageMetadata) == "table" then
      a.usage = chunk.usageMetadata
    end
    local feedback = chunk.promptFeedback
    if type(feedback) == "table" and feedback.blockReason then
      return nil, "prompt was blocked by Gemini (" .. tostring(feedback.blockReason) .. ")"
    end
    local candidate = type(chunk.candidates) == "table" and chunk.candidates[1] or nil
    if type(candidate) ~= "table" then
      return {}
    end
    finish_reason = candidate.finishReason or finish_reason
    local out = {}
    for _, object in ipairs(scanner.push(answer_text(candidate))) do
      -- A suggestion already under review cannot be taken back, so a malformed one is dropped on
      -- its own instead of failing the whole answer.
      local good, item = pcall(vim.json.decode, object, { luanil = { object = true, array = true } })
      if good and type(item) == "table" then
        out[#out + 1] = item
      else
        a.invalid = a.invalid + 1
      end
    end
    return out
  end

  --- The answer is complete only when Gemini stopped normally and the whole text parses.
  ---@return boolean ok, string|nil err
  function a.finish()
    if finish_reason ~= "STOP" then
      if finish_reason == "MAX_TOKENS" then
        return false, "response was truncated (MAX_TOKENS); lower `chunk.max_chars`"
      end
      return false,
        finish_reason and ("response stopped by Gemini (" .. tostring(finish_reason) .. ")") or "the answer ended early"
    end
    local ok, whole = pcall(vim.json.decode, scanner.text())
    if not ok or type(whole) ~= "table" or type(whole.suggestions) ~= "table" then
      return false, "could not parse suggestions from Gemini response"
    end
    return true
  end

  return a
end

return M
