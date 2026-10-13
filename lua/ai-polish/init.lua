local config = require("ai-polish.config")
local gemini = require("ai-polish.gemini")
local text = require("ai-polish.text")
local session = require("ai-polish.session")
local popup = require("ai-polish.popup")
local progress = require("ai-polish.progress")
local tentative = require("ai-polish.tentative")
local arrivals = require("ai-polish.arrivals")

local M = {}

local region_ns = vim.api.nvim_create_namespace("ai-polish-region")

---@type table<integer, { cancel: fun(), done: integer, total: integer }>
local jobs = {}

local function notify(msg, level)
  level = level or vim.log.levels.INFO
  msg = "ai-polish: " .. msg
  if level >= vim.log.levels.ERROR then
    -- The default vim.notify reports ERROR via nvim_err_writeln, which inside vim.cmd()
    -- (e.g. lazy.nvim's `cmd` loader running :AiPolish) turns into an exception with a
    -- traceback. Deferring it shows a plain error message instead.
    return vim.schedule(function()
      vim.notify(msg, level)
    end)
  end
  vim.notify(msg, level)
end

local function set_highlights()
  local links = {
    AiPolishCritical = "DiagnosticUnderlineError",
    AiPolishWarning = "DiagnosticUnderlineWarn",
    AiPolishSuggestion = "DiagnosticUnderlineInfo",
    AiPolishInfo = "DiagnosticUnderlineHint",
    AiPolishCurrent = "Visual",
    AiPolishDelete = "DiffDelete",
    AiPolishAdd = "DiffAdd",
    AiPolishTitle = "Title",
    AiPolishHint = "Comment",
    AiPolishNormal = "NormalFloat",
    AiPolishBorder = "FloatBorder",
    AiPolishProgress = "DiagnosticVirtualTextInfo",
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  -- Jev's tentative marks. A red wave stands out while Gemini writes; terminals that lack dotted
  -- underlines draw it as a plain one that reads like ordinary text. Suggestions replace the
  -- marks, so the two never show together.
  local err = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  vim.api.nvim_set_hl(0, "AiPolishTentative", { undercurl = true, sp = err.fg or "Red", default = true })
end

function M.setup(opts)
  config.setup(opts)
  if package.loaded["ai-polish.evaluation"] then
    require("ai-polish.evaluation").reset()
  end
  set_highlights()
end

---Ask before sending. Replaceable in tests.
---@return boolean
function M._confirm(msg)
  return vim.fn.confirm(msg, "&Send\n&Cancel", 2, "Warning") == 1
end

local function guard_message(est, model)
  return table.concat({
    "AI Polish: this text is large.",
    "",
    ("  size:      %d chars"):format(est.chars),
    ("  requests:  %d (chunks of ≤%d chars)"):format(est.requests, config.options.chunk.max_chars),
    ("  tokens:    ~%d in / ~%d out (rough estimate)"):format(est.input_tokens, est.output_tokens),
    ("  cost:      ~$%.3f with %s"):format(est.cost_usd, model),
    "",
    "Send it to Gemini?",
  }, "\n")
end

---Decide whether the request may be sent. Exposed for tests.
---@return "send"|"confirm"|"refuse"
function M._guard(est)
  local g = config.options.guard
  if est.chars > g.max_chars then
    return "refuse"
  end
  if est.chars > g.confirm_chars or est.cost_usd > g.confirm_cost_usd or est.requests > g.confirm_requests then
    return "confirm"
  end
  return "send"
end

---Run `chunks` through Gemini with bounded concurrency, handing over each chunk's suggestions
---as Gemini writes them (`on_arrive(i, suggestions)`).
local function run_chunks(chunks, ctx, on_arrive, on_progress, on_done)
  local errors = {}
  local next_i, running, finished = 1, 0, 0
  local handles, cancelled = {}, false

  local function pump()
    while not cancelled and running < config.options.chunk.concurrency and next_i <= #chunks do
      local i = next_i
      next_i = next_i + 1
      running = running + 1
      -- Each chunk numbers its own units from 1.
      local chunk_ctx = vim.tbl_extend("force", ctx, { split = chunks[i].split })
      handles[i] = gemini.proofread_stream(chunks[i].text, chunk_ctx, function(sugs)
        if not cancelled then
          on_arrive(i, sugs)
        end
      end, function(err)
        if cancelled then
          return
        end
        running = running - 1
        finished = finished + 1
        handles[i] = nil
        if err then
          errors[#errors + 1] = err
        end
        on_progress(finished, #chunks)
        if finished == #chunks then
          on_done(errors)
        else
          pump()
        end
      end)
    end
  end
  pump()

  return function()
    cancelled = true
    for _, h in pairs(handles) do
      h.cancel()
    end
  end
end

---Region text currently covered by the region extmark, or nil when it is gone.
local function region_text(bufnr, mark)
  local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, region_ns, mark, { details = true })
  if not m[1] then
    return nil
  end
  -- Replacing whole lines can leave the mark's end past the new text.
  local ok, lines = pcall(vim.api.nvim_buf_get_text, bufnr, m[1], m[2], m[3].end_row, m[3].end_col, {})
  if not ok then
    return nil
  end
  return table.concat(lines, "\n"), m[1], m[2]
end

---Clear what is left of this check's Jev marks.
local function clear_marks(bufnr, req)
  -- Marks a later check started (an explicit evaluation) are not this check's to clear.
  if req.marks and tentative.get(bufnr) == req.marks then
    tentative.clear(bufnr)
  end
end

---The region a check covers now, for evaluating it after proofreading or an accepted fix.
local function evaluation_target(bufnr, req)
  local cur, row0, col0 = region_text(bufnr, req.mark)
  if not cur then
    return nil
  end
  local er, ec = text.pos_at(cur, #cur, row0, col0)
  return { whole = req.whole, range = { row0, col0, er, ec } }
end

---Open the review on suggestions that just came in, when the user is still looking at the
---buffer in Normal mode (as before streaming).
local function open_review(bufnr, req, s)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == bufnr and vim.api.nvim_get_mode().mode == "n" then
    req.opened = true
    popup.open(s, win)
  end
end

---Checks Jev found nothing to fix in, per buffer: Gemini's suggestions are held until
---`:AiPolish review` (Kotobae src/proofread/core/quiet.ts).
---@type table<integer, table>
local quiet = {}

---Go quiet when Jev rates the text 1, put no underline, and nothing is shown yet: the user sees
---"no issues found" instead of waiting for Gemini, as in Kotobae. Once Gemini's answer ended or
---a suggestion is under review, the check is not quiet any more.
local function consider(bufnr, req)
  if req.quiet or req.revealed or req.done then
    return
  end
  local marks = req.marks
  if req.rating == 1 and marks and marks.done and marks.total == 0 and req.received == 0 then
    req.quiet, req.held = true, {}
    quiet[bufnr] = req
    req.spinner.stop()
    -- Checking again is the way back to Gemini, as Kotobae's C; name the user's own key for it.
    local panel = require("ai-polish.evaluation_panel")
    local key = req.whole and panel.mapping(bufnr, "n", "buffer") or panel.mapping(bufnr, "x", "selection")
    notify(("no issues found — %s again shows Gemini's suggestions"):format(key or ":AiPolish"))
  end
end

---Suggestions of chunk `i` as Gemini writes them, as in Kotobae: the first opens the review
---right away, later ones join it by position, and Jev's marks give way to each.
local function arrive(bufnr, req, i, sugs)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if req.quiet then
    -- Placed only when revealed, where the anchors are then.
    req.held[#req.held + 1] = { i = i, sugs = sugs }
    return
  end
  local items, dropped = req.arrivals:place(i, sugs)
  req.dropped = req.dropped + dropped
  if req.marks and tentative.get(bufnr) == req.marks then
    req.marks:reached(items, req.arrivals:scope(i))
  end
  if #items == 0 then
    return
  end
  req.received = req.received + #items
  req.on_received()
  local s = req.session
  if not s then
    s = session.create(bufnr, items, evaluation_target(bufnr, req))
    s.streaming, req.session = true, s
    return open_review(bufnr, req, s)
  end
  s:add(items)
  if s.waiting then
    open_review(bufnr, req, s)
  else
    popup.update(s)
  end
end

local function finish(bufnr, req, errors)
  if req.quiet then
    -- Keep the anchors and what Gemini wrote for `:AiPolish review`.
    req.finished, req.errors = true, errors
    return
  end
  req.done = true
  pcall(vim.api.nvim_buf_del_extmark, bufnr, region_ns, req.mark)
  req.arrivals:clear()
  clear_marks(bufnr, req)
  local s, received = req.session, req.received
  if s then
    s.streaming, s.waiting = nil, nil
    popup.update(s)
  end

  if #errors > 0 and received == 0 and #errors == #req.chunks then
    return notify("proofreading failed: " .. errors[1], vim.log.levels.ERROR)
  end
  if #errors > 0 then
    -- Suggestions already under review stay (Kotobae: 校正が途中で止まりました).
    local msg = received > 0
        and ("stopped partway (showing the %d suggestion(s) received): %s"):format(received, errors[1])
      or ("%d of %d request(s) failed: %s"):format(#errors, #req.chunks, errors[1])
    notify(msg, vim.log.levels.WARN)
  end
  local dropped = req.dropped
  if received == 0 then
    return notify(
      "no issues found" .. (dropped > 0 and (" (%d unlocatable suggestion(s) ignored)"):format(dropped) or "")
    )
  end
  local msg = ("%d suggestion(s)"):format(received)
  if dropped > 0 then
    msg = msg .. (" (%d unlocatable ignored)"):format(dropped)
  end
  notify(req.opened and msg or (msg .. " — run :AiPolish review to review them"))
end

---Forget what a quiet check held.
local function drop_quiet(bufnr)
  local req = quiet[bufnr]
  if req then
    quiet[bufnr] = nil
    req.arrivals:clear()
    pcall(vim.api.nvim_buf_del_extmark, bufnr, region_ns, req.mark)
  end
end

---Show what a quiet check held, and what Gemini still writes (Kotobae: C / 今すぐチェック).
local function reveal(bufnr)
  local req = quiet[bufnr]
  quiet[bufnr] = nil
  req.quiet, req.revealed = false, true
  if not req.finished then
    req.spinner = progress.start(bufnr)
    req.on_received()
  end
  for _, h in ipairs(req.held) do
    arrive(bufnr, req, h.i, h.sugs)
  end
  req.held = {}
  if req.finished then
    finish(bufnr, req, req.errors)
  end
end

---Proofread a region of a buffer (0-based, end-exclusive). Omit `range` for the whole buffer.
---@param opts? { bufnr?: integer, range?: { integer, integer, integer, integer } }
function M.proofread(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local r = opts.range
  if not r then
    local last = vim.api.nvim_buf_line_count(bufnr) - 1
    local last_line = vim.api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ""
    r = { 0, 0, last, #last_line }
  end
  local content = table.concat(vim.api.nvim_buf_get_text(bufnr, r[1], r[2], r[3], r[4], {}), "\n")
  -- Checking a text Jev found fine again shows what Gemini wrote instead of asking again, as
  -- Kotobae's C does; an edited text is checked anew.
  local held = quiet[bufnr]
  if held and region_text(bufnr, held.mark) == content then
    return reveal(bufnr)
  end
  if jobs[bufnr] then
    return notify("already proofreading this buffer (:AiPolish cancel to stop)", vim.log.levels.WARN)
  end
  if vim.trim(content) == "" then
    return notify("nothing to proofread", vim.log.levels.WARN)
  end
  local key_ok, key_err = config.api_key()
  if not key_ok then
    return notify(key_err, vim.log.levels.ERROR)
  end

  local chunks = text.chunk(content, config.options.chunk.max_chars)
  local model = config.options.model
  local est = text.estimate(chunks, config.pricing(model))
  local verdict = M._guard(est)
  if verdict == "refuse" then
    return notify(
      ("text too large (%d chars > guard.max_chars %d); select a smaller range"):format(
        est.chars,
        config.options.guard.max_chars
      ),
      vim.log.levels.ERROR
    )
  elseif verdict == "confirm" and not M._confirm(guard_message(est, model)) then
    return notify("cancelled")
  end

  session.clear(bufnr)
  popup.close()
  drop_quiet(bufnr)

  -- Japanese text names fixes by bunsetsu number (numbered.lua); other languages quote context.
  local language = require("ai-polish.jev_segment").language(content, config.options.evaluation.language)
  if language == "ja" then
    local units = require("ai-polish.units")
    for _, c in ipairs(chunks) do
      c.split = units.split(c.text)
    end
  end

  local req = {
    whole = opts.range == nil,
    chunks = chunks,
    mark = vim.api.nvim_buf_set_extmark(bufnr, region_ns, r[1], r[2], {
      end_row = r[3],
      end_col = r[4],
      right_gravity = false,
      end_right_gravity = true,
    }),
    arrivals = arrivals.start(bufnr, chunks, content, r[1], r[2]),
    received = 0,
    dropped = 0,
  }
  req.marks = tentative.ask(bufnr, content, r[1], r[2])
  req.spinner = progress.start(bufnr)
  local job = { done = 0, total = #chunks }
  local function label()
    local done = #chunks > 1 and (" %d/%d"):format(job.done, #chunks) or ""
    -- Kotobae shows 受信中 · N件 while suggestions keep coming.
    return req.received > 0 and ("proofreading%s · %d received…"):format(done, req.received)
      or ("proofreading%s…"):format(done)
  end
  req.spinner.update(label())
  function req.on_received()
    req.spinner.update(label())
  end
  -- Jev evaluates alongside Gemini, as Kotobae's popup does, so a text it finds nothing in can
  -- go quiet before Gemini's first suggestion.
  if req.marks then
    function req.marks.on_done()
      consider(bufnr, req)
    end
  end
  require("ai-polish.evaluation").evaluate({
    bufnr = bufnr,
    whole = req.whole,
    range = not req.whole and r or nil,
    automatic = true,
    show = true,
    on_result = function(result)
      req.rating = result.unnaturalness.level
      consider(bufnr, req)
    end,
  })

  jobs[bufnr] = job
  local ctx = { filetype = vim.bo[bufnr].filetype, language = language }
  local cancel = run_chunks(chunks, ctx, function(i, sugs)
    arrive(bufnr, req, i, sugs)
  end, function(done)
    job.done = done
    req.spinner.update(label())
  end, function(errors)
    jobs[bufnr] = nil
    req.spinner.stop()
    if vim.api.nvim_buf_is_valid(bufnr) then
      finish(bufnr, req, errors)
    end
  end)

  function job.cancel()
    cancel()
    req.done = true
    if quiet[bufnr] == req then
      quiet[bufnr] = nil
    end
    req.arrivals:clear()
    clear_marks(bufnr, req)
    if req.session then
      req.session.streaming, req.session.waiting = nil, nil
      popup.update(req.session)
    end
    req.spinner.stop()
    jobs[bufnr] = nil
    pcall(vim.api.nvim_buf_del_extmark, bufnr, region_ns, req.mark)
  end
end

---Proofread the last visual selection ('< and '> marks).
function M.proofread_selection(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local mode = vim.fn.visualmode()
  local s = vim.api.nvim_buf_get_mark(bufnr, "<")
  local e = vim.api.nvim_buf_get_mark(bufnr, ">")
  if s[1] == 0 or e[1] == 0 then
    return notify("no visual selection", vim.log.levels.WARN)
  end
  M.proofread({ bufnr = bufnr, range = M._selection_range(bufnr, mode, s, e) })
end

---Convert marks to a 0-based end-exclusive range. Line-wise and block-wise selections
---cover whole lines. Exposed for tests.
function M._selection_range(bufnr, mode, s, e)
  local end_line = vim.api.nvim_buf_get_lines(bufnr, e[1] - 1, e[1], false)[1] or ""
  if mode ~= "v" then
    return { s[1] - 1, 0, e[1] - 1, #end_line }
  end
  local end_col
  if e[2] >= #end_line then
    end_col = #end_line
  else
    -- '> points at the first byte of the last selected character.
    end_col = e[2] + 1 + vim.str_utf_end(end_line, e[2] + 1)
  end
  return { s[1] - 1, s[2], e[1] - 1, end_col }
end

function M.proofread_lines(bufnr, line1, line2)
  local last = vim.api.nvim_buf_get_lines(bufnr, line2 - 1, line2, false)[1] or ""
  M.proofread({ bufnr = bufnr, range = { line1 - 1, 0, line2 - 1, #last } })
end

function M.cancel(bufnr)
  local evaluation = package.loaded["ai-polish.evaluation"]
  bufnr = bufnr or (evaluation and evaluation.source()) or vim.api.nvim_get_current_buf()
  local eval_cancelled = evaluation and evaluation.cancel(bufnr)
  local job = jobs[bufnr]
  if not job then
    return notify(eval_cancelled and "cancelled" or "nothing to cancel")
  end
  job.cancel()
  notify("cancelled")
end

function M.review(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if quiet[bufnr] then
    return reveal(bufnr)
  end
  local s = session.get(bufnr)
  if not s then
    return notify(jobs[bufnr] and "still proofreading…" or "no suggestions for this buffer")
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  s:focus_near(cursor[1] - 1, cursor[2])
  popup.open(s, vim.api.nvim_get_current_win())
end

function M.clear(bufnr)
  local evaluation = package.loaded["ai-polish.evaluation"]
  bufnr = bufnr or (evaluation and evaluation.source()) or vim.api.nvim_get_current_buf()
  if package.loaded["ai-polish.evaluation"] then
    require("ai-polish.evaluation").clear(bufnr)
  end
  popup.close()
  session.clear(bufnr)
  tentative.clear(bufnr)
  drop_quiet(bufnr)
end

---Short status for statuslines: "" when idle.
function M.status(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local job = jobs[bufnr]
  if job then
    return job.total > 1 and ("AI Polish %d/%d"):format(job.done, job.total) or "AI Polish…"
  end
  local s = session.get(bufnr)
  return s and ("AI Polish: %d"):format(#s.items) or ""
end

set_highlights()

return M
