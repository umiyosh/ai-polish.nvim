--- Runs the main answer and the homophone check side by side for one chunk of Japanese text, as
--- Kotobae does (src-tauri/src/commands/proofread/answers.rs and merge.rs, umiyosh/kotobae#89).
--- The main request at low thinking lets a real word that does not fit its context pass (正読
--- for 精読, #23); a request that looks for nothing else finds it in about as long as the main
--- answer takes, so the first suggestion comes no later.
---
--- The main answer comes in text order, and Jev's marks go once fixes have moved past them
--- (tentative.lua), so a homophone fix further on would wipe marks the main answer has yet to
--- reach. It waits until the main answer has passed its place or ended.
local gemini = require("ai-polish.gemini")

local M = {}

-- Past this wait after the main answer, the homophone answer is given up so the check can end:
-- it took 2.6 s in the median and 3.8 s at the 90th percentile in Kotobae's measurements.
M.GRACE_MS = 5000

---Holds homophone fixes until the main answer, which names places by unit number, lets them go.
local function merge()
  local passed, ended, waiting, seen = 0, false, {}, 0

  -- In text order; a fix whose place is unknown goes last.
  local function release(ready)
    local out, keep = {}, {}
    for _, w in ipairs(waiting) do
      table.insert(ready(w.fix) and out or keep, w)
    end
    waiting = keep
    table.sort(out, function(a, b)
      local x, y = a.fix.from or math.huge, b.fix.from or math.huge
      return x < y or (x == y and a.seen < b.seen)
    end)
    return vim.tbl_map(function(w)
      return w.fix
    end, out)
  end

  local function behind(fix)
    return fix.from ~= nil and fix.from <= passed
  end

  return {
    ---The main answer handed over `fixes`; returns the waiting ones it passed.
    reached = function(fixes)
      for _, f in ipairs(fixes) do
        passed = math.max(passed, f.from or 0)
      end
      return release(behind)
    end,
    ---The main answer is over; returns everything still waiting.
    ended = function()
      ended = true
      return release(function()
        return true
      end)
    end,
    ---Homophone fixes that just came; returns the ones that may go now.
    offer = function(fixes)
      local out = {}
      for _, f in ipairs(fixes) do
        if ended or behind(f) then
          out[#out + 1] = f
        else
          seen = seen + 1
          waiting[#waiting + 1] = { fix = f, seen = seen }
        end
      end
      return out
    end,
  }
end

---Stream the suggestions for one chunk, like `gemini.proofread_stream`. Japanese text is also
---asked for homophones; those fixes carry `homophone = true`, since both answers often find the
---same word. A failed main answer ends the check at once. A failed or late homophone answer
---leaves the main answer's result as it is.
---@param text string
---@param ctx ai_polish.RequestContext
---@param on_suggestions fun(suggestions: table[])
---@param on_done fun(err: string|nil, usage: table|nil)
---@return { cancel: fun() }
function M.stream(text, ctx, on_suggestions, on_done)
  -- Kana-kanji conversion mistakes are a Japanese problem, and the request names places by number.
  if ctx.language ~= "ja" or not ctx.split then
    return gemini.proofread_stream(text, ctx, on_suggestions, on_done)
  end

  local order = merge()
  local main, homophones, timer
  local main_ended, homophones_ended, finished = false, false, false
  local main_usage

  local function hand_over(fixes)
    if #fixes > 0 and not finished then
      on_suggestions(fixes)
    end
  end

  -- Both requests answer asynchronously, so both handles are set by the first callback.
  local function stop()
    finished = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    main.cancel()
    homophones.cancel()
  end

  local function finish(err)
    if not finished then
      stop()
      on_done(err, main_usage)
    end
  end

  main = gemini.proofread_stream(text, ctx, function(fixes)
    hand_over(fixes)
    hand_over(order.reached(fixes))
  end, function(err, usage)
    main_ended, main_usage = true, usage
    if err then
      return finish(err)
    end
    hand_over(order.ended())
    if homophones_ended then
      return finish(nil)
    end
    timer = vim.defer_fn(function()
      finish(nil)
    end, M.GRACE_MS)
  end)

  homophones = gemini.proofread_stream(text, vim.tbl_extend("force", ctx, { kind = "homophones" }), function(fixes)
    hand_over(order.offer(vim.tbl_map(function(f)
      return vim.tbl_extend("force", f, { homophone = true })
    end, fixes)))
  end, function()
    homophones_ended = true
    if main_ended then
      finish(nil)
    end
  end)

  return { cancel = stop }
end

return M
