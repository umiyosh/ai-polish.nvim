local config = require("ai-polish.config")
local gemini = require("ai-polish.gemini")
local text = require("ai-polish.text")
local session = require("ai-polish.session")
local popup = require("ai-polish.popup")
local progress = require("ai-polish.progress")

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
end

function M.setup(opts)
  config.setup(opts)
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

---Run `chunks` through Gemini with bounded concurrency.
local function run_chunks(chunks, ctx, on_progress, on_done)
  local results, errors = {}, {}
  local next_i, running, finished = 1, 0, 0
  local handles, cancelled = {}, false

  local function pump()
    while not cancelled and running < config.options.chunk.concurrency and next_i <= #chunks do
      local i = next_i
      next_i = next_i + 1
      running = running + 1
      handles[i] = gemini.proofread(chunks[i].text, ctx, function(sugs, err)
        if cancelled then
          return
        end
        running = running - 1
        finished = finished + 1
        handles[i] = nil
        if err then
          errors[#errors + 1] = err
        else
          results[i] = sugs
        end
        on_progress(finished, #chunks)
        if finished == #chunks then
          on_done(results, errors)
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

---Region text currently covered by the region extmark.
local function region_text(bufnr, mark)
  local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, region_ns, mark, { details = true })
  if not m[1] then
    return nil
  end
  local lines = vim.api.nvim_buf_get_text(bufnr, m[1], m[2], m[3].end_row, m[3].end_col, {})
  return table.concat(lines, "\n"), m[1], m[2]
end

local function finish(bufnr, req, results, errors)
  local cur, row0, col0 = region_text(bufnr, req.mark)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, region_ns, req.mark)
  if not cur then
    return notify("target text disappeared; results discarded", vim.log.levels.WARN)
  end

  local all, dropped = {}, 0
  if vim.api.nvim_buf_get_changedtick(bufnr) == req.tick then
    for i, c in ipairs(req.chunks) do
      local resolved, d = text.resolve(c.text, results[i] or {}, c.offset)
      vim.list_extend(all, resolved)
      dropped = dropped + d
    end
  else
    -- The buffer was edited while waiting: chunk offsets are unreliable, search the
    -- whole current region instead. Suggestions for edited spots will not be found.
    local flat = {}
    for i = 1, #req.chunks do
      vim.list_extend(flat, results[i] or {})
    end
    all, dropped = text.resolve(cur, flat, 0)
  end

  local items = {}
  for _, s in ipairs(all) do
    local r, c = text.pos_at(cur, s.start, row0, col0)
    local er, ec = text.pos_at(cur, s.finish, row0, col0)
    items[#items + 1] = vim.tbl_extend("force", s, { row = r, col = c, end_row = er, end_col = ec })
  end

  if #errors > 0 and #errors == #req.chunks then
    return notify("proofreading failed: " .. errors[1], vim.log.levels.ERROR)
  end
  if #errors > 0 then
    notify(("%d of %d request(s) failed: %s"):format(#errors, #req.chunks, errors[1]), vim.log.levels.WARN)
  end
  if #items == 0 then
    return notify(
      "no issues found" .. (dropped > 0 and (" (%d unlocatable suggestion(s) ignored)"):format(dropped) or "")
    )
  end

  local s = session.create(bufnr, items)
  local msg = ("%d suggestion(s)"):format(#s.items)
  if dropped > 0 then
    msg = msg .. (" (%d unlocatable ignored)"):format(dropped)
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == bufnr and vim.api.nvim_get_mode().mode == "n" then
    notify(msg)
    popup.open(s, win)
  else
    notify(msg .. " — run :AiPolish review to review them")
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
  if jobs[bufnr] then
    return notify("already proofreading this buffer (:AiPolish cancel to stop)", vim.log.levels.WARN)
  end
  local r = opts.range
  if not r then
    local last = vim.api.nvim_buf_line_count(bufnr) - 1
    local last_line = vim.api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ""
    r = { 0, 0, last, #last_line }
  end
  local content = table.concat(vim.api.nvim_buf_get_text(bufnr, r[1], r[2], r[3], r[4], {}), "\n")
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

  local req = {
    chunks = chunks,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    mark = vim.api.nvim_buf_set_extmark(bufnr, region_ns, r[1], r[2], {
      end_row = r[3],
      end_col = r[4],
      right_gravity = false,
      end_right_gravity = true,
    }),
  }
  local spinner = progress.start(bufnr, r[1])
  local function label(done, total)
    return total > 1 and ("proofreading %d/%d…"):format(done, total) or "proofreading…"
  end
  spinner.update(label(0, #chunks))

  local job = { done = 0, total = #chunks }
  jobs[bufnr] = job
  local ctx = { filetype = vim.bo[bufnr].filetype }
  local cancel = run_chunks(chunks, ctx, function(done, total)
    job.done = done
    spinner.update(label(done, total))
  end, function(results, errors)
    jobs[bufnr] = nil
    spinner.stop()
    if vim.api.nvim_buf_is_valid(bufnr) then
      finish(bufnr, req, results, errors)
    end
  end)

  function job.cancel()
    cancel()
    spinner.stop()
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
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local job = jobs[bufnr]
  if not job then
    return notify("nothing to cancel")
  end
  job.cancel()
  notify("cancelled")
end

function M.review(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local s = session.get(bufnr)
  if not s then
    return notify(jobs[bufnr] and "still proofreading…" or "no suggestions for this buffer")
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  s:focus_near(cursor[1] - 1, cursor[2])
  popup.open(s, vim.api.nvim_get_current_win())
end

function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  popup.close()
  session.clear(bufnr)
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
