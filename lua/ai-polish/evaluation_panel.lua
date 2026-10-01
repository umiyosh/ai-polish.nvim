-- Passive corner panel. It owns no unmodified-letter mappings and never sends requests.
local config = require("ai-polish.config")
local copy = require("ai-polish.evaluation_copy")
local target = require("ai-polish.evaluation_target")
local jev = require("ai-polish.jev")
local M = {}
local state, details
local ns = vim.api.nvim_create_namespace("ai-polish-evaluation-ui")

local function controller()
  return require("ai-polish.evaluation")
end

local function clip(s, width)
  if width <= 0 then
    return ""
  end
  local result = ""
  for i = 0, vim.fn.strchars(s) - 1 do
    local c = vim.fn.strcharpart(s, i, 1)
    if vim.fn.strdisplaywidth(result .. c) > width then
      break
    end
    result = result .. c
  end
  return result
end

local function highlights()
  for name, link in pairs({
    Low = "DiagnosticOk",
    Mid = "DiagnosticWarn",
    Label = "NormalFloat",
    Stale = "NormalFloat",
    Empty = "NonText",
    Error = "DiagnosticWarn",
  }) do
    vim.api.nvim_set_hl(0, "AiPolishEval" .. name, { link = link, default = true })
  end
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  vim.api.nvim_set_hl(0, "AiPolishEvalHigh", { fg = warn.fg, bold = true, default = true })
end

-- Resolve direct Plug/command mappings; never guess what a Lua wrapper does.
function M.mapping(buf, mode, plug, command)
  local seen, matches = {}, {}
  for _, maps in ipairs({ vim.api.nvim_buf_get_keymap(buf, mode), vim.api.nvim_get_keymap(mode) }) do
    for _, map in ipairs(maps) do
      local rhs = (map.rhs or ""):lower()
      local direct = command
        and (rhs == "<cmd>aipolish " .. command .. "<cr>" or rhs == ":aipolish " .. command .. "<cr>")
      if not seen[map.lhs] and (map.rhs == "<Plug>(ai-polish-" .. plug .. ")" or direct) then
        matches[#matches + 1] = vim.fn.keytrans(map.lhs)
      end
      seen[map.lhs] = true
    end
  end
  table.sort(matches, function(a, b)
    return #a == #b and a < b or (#a ~= #b and #a < #b)
  end)
  return matches[1]
end

-- Pack complete hints, never truncate a key sequence into an unusable shortcut.
local function shortcuts(buf, width)
  local t, mode = copy.get(), vim.fn.mode()
  mode = (mode == "v" or mode == "V") and "x" or "n"
  local lines = {}
  for _, action in ipairs({
    { t.evaluate, "evaluate", "evaluate" },
    { t.hide, "evaluation-toggle", "toggle" },
    { t.details, "evaluation-details", "details" },
  }) do
    local key = M.mapping(buf, mode, action[2], action[3])
    local command = (mode == "x" and action[3] ~= "evaluate" and ":<C-u>" or ":") .. "AiPolish " .. action[3]
    local entry = action[1] .. " " .. (key or command)
    if vim.fn.strdisplaywidth(entry) > width then
      entry = action[1] .. " " .. command
    end
    if vim.fn.strdisplaywidth(entry) > width then
      entry = command
    end
    if #lines > 0 and vim.fn.strdisplaywidth(lines[#lines] .. "  " .. entry) <= width then
      lines[#lines] = lines[#lines] .. "  " .. entry
    else
      lines[#lines + 1] = entry
    end
  end
  return lines
end

local function hint(buf, snap, width)
  local t, mode = copy.get(), vim.fn.mode()
  local action, fallback, map = t.proofread, ":AiPolish polish"
  if snap.status ~= "ready" then
    return ""
  end
  if snap.status == "ready" then
    action, fallback = t.proofread, ":AiPolish polish"
    if buf == vim.api.nvim_get_current_buf() then
      if snap.target.kind == "whole" and mode == "n" then
        map = M.mapping(buf, "n", "buffer")
      elseif mode == "v" or mode == "V" then
        local range = target.visual(buf, true)
        -- The existing selection-proofreading action uses inclusive '< / '> marks.
        -- With exclusive selection, the retained-target command is the safe path.
        if vim.o.selection ~= "exclusive" and vim.deep_equal(range, snap.range) then
          map = M.mapping(buf, "x", "selection")
        end
      end
    end
  end
  local line = action .. ": " .. (map or fallback)
  if vim.fn.strdisplaywidth(line) > width then
    line = action .. ": " .. fallback
  end
  return clip(line, width)
end

local function axis_line(t, index, snap)
  local label_width = math.max(vim.fn.strdisplaywidth(t.axes[1]), vim.fn.strdisplaywidth(t.axes[2]))
  local label = t.axes[index] .. string.rep(" ", label_width - vim.fn.strdisplaywidth(t.axes[index]))
  local a = snap.result and snap.result[jev.axes[index]]
  local level, word, group = 0, t[snap.status] or t.none, "AiPolishEvalLabel"
  if a and (snap.status == "ready" or snap.status == "stale") then
    level = a.level
    word = t.stages[index][level]
    group = level <= 2 and "AiPolishEvalLow" or (level == 3 and "AiPolishEvalMid" or "AiPolishEvalHigh")
    if snap.status == "stale" then
      word, group = t.stale .. " " .. level .. "/5", "AiPolishEvalStale"
    elseif a.method == "local" and (a.evaluated_sentences < a.sentences or a.omitted_spans > 0) then
      word = t.partial
    elseif a.confidence and a.confidence < config.options.evaluation.uncertainty_threshold then
      word = t.uncertain
    end
  end
  return label .. " [" .. string.rep("#", level) .. string.rep("-", 5 - level) .. "] " .. word, group, #label + 2
end

local function wide_layout(width)
  local t, max = copy.get(), {}
  for axis = 1, 2 do
    local longest = 0
    for _, word in
      ipairs(
        vim.list_extend(vim.deepcopy(t.stages[axis]), { t.none, t.loading, t.stale .. " 5/5", t.uncertain, t.partial })
      )
    do
      longest = math.max(longest, vim.fn.strdisplaywidth(word))
    end
    max[axis] = math.max(vim.fn.strdisplaywidth(t.axes[1]), vim.fn.strdisplaywidth(t.axes[2])) + 9 + longest
  end
  return max[1] + max[2] + 2 <= width
end

function M.render(buf, snap, width)
  local first, fg, fc = axis_line(copy.get(), 1, snap)
  local second, sg, sc = axis_line(copy.get(), 2, snap)
  local lines, spans
  if wide_layout(width) then
    lines = { first .. "  " .. second }
    spans = { { 0, fc, #first, fg }, { 0, #first + 2 + sc, #lines[1], sg } }
  else
    lines = { clip(first, width), clip(second, width) }
    spans = { { 0, fc, #lines[1], fg }, { 1, sc, #lines[2], sg } }
  end
  if snap.status == "error" then
    local msg = copy.get().errors[snap.error] or copy.get().errors.service_error
    lines[1] = clip(msg, width)
    if #lines == 2 then
      lines[2] = snap.error == "bad_key" and (copy.get().check .. ": :checkhealth ai-polish") or ""
    end
    spans = { { 0, 0, #lines[1], "AiPolishEvalError" } }
  else
    local split = {}
    for _, h in ipairs(spans) do
      local row, start, finish, group = unpack(h)
      local bar = lines[row + 1]:sub(start + 1, start + 5)
      local filled = #(bar:match("^#*") or "")
      split[#split + 1] = { row, start, start + filled, group }
      split[#split + 1] = { row, start + filled, start + 5, "AiPolishEvalEmpty" }
      split[#split + 1] = { row, start + 7, finish, group }
    end
    spans = split
  end
  lines[#lines + 1] = hint(buf, snap, width)
  for _, line in ipairs(shortcuts(buf, width)) do
    spans[#spans + 1] = { #lines, 0, #line, "AiPolishHint" }
    lines[#lines + 1] = line
  end
  return lines, spans
end

function M.title(buf, snap, width)
  local t = copy.get()
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if name == "" then
    name = t.unnamed
  end
  local scope = t.whole
  if snap.target and snap.target.kind ~= "whole" then
    scope = t.selected
    if snap.range then
      scope = scope .. " " .. (copy.get().line_range):format(snap.range[1] + 1, snap.range[3] + 1)
    end
  end
  local prefix = t.title .. ": "
  local room = width - vim.fn.strdisplaywidth(prefix .. " " .. scope) - 2
  if room < 6 then
    prefix, room = "", width - vim.fn.strdisplaywidth(scope) - 3
  end
  if room < 6 then
    return " " .. clip(scope, width - 2) .. " "
  end
  if vim.fn.strdisplaywidth(name) > room then
    name = clip(name, room - 1):gsub("-+$", "") .. "~"
  end
  return " " .. prefix .. name .. " " .. scope .. " "
end

local function dimensions()
  local width = math.min(config.options.evaluation.panel_width, vim.o.columns - 4)
  local height = (wide_layout(width) and 2 or 3)
    + #shortcuts(controller().source() or vim.api.nvim_get_current_buf(), width)
  return width, height, vim.o.lines - vim.o.cmdheight - 2
end

function M.fits()
  local width, height, bottom = dimensions()
  return width >= 30 and bottom >= height + 2
end

function M.is_open()
  return state ~= nil and vim.api.nvim_win_is_valid(state.win)
end
function M.context()
  return details
end
function M.window()
  return state and state.win
end
function M.reserved_height(tab)
  return M.is_open() and state.tab == tab and vim.api.nvim_win_get_height(state.win) + 2 or 0
end

function M.close()
  local old = state
  state = nil
  if old and vim.api.nvim_win_is_valid(old.win) then
    vim.api.nvim_win_close(old.win, true)
  end
end

local function overlaps(win, top, left, height, width)
  local pos = vim.api.nvim_win_get_position(win)
  return pos[1] < top + height
    and pos[1] + vim.api.nvim_win_get_height(win) + 2 > top
    and pos[2] < left + width
    and pos[2] + vim.api.nvim_win_get_width(win) + 2 > left
end

local function write(buf, lines)
  if vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function detail_lines(buf)
  local t, snap = copy.get(), controller().snapshot(buf)
  local lines = { M.title(buf, snap, 70) }
  if snap.status == "stale" then
    lines[#lines + 1] = t.stale_notice
  elseif snap.status == "loading" then
    lines[#lines + 1] = t.loading
  end
  lines[#lines + 1] = ""
  if snap.result and (snap.status == "ready" or snap.status == "stale") then
    for i, id in ipairs(jev.axes) do
      local a = snap.result[id]
      lines[#lines + 1] = ("%s %d/5 %s"):format(t.axes[i], a.level, t.stages[i][a.level])
      lines[#lines + 1] = t.criteria[i][a.level]
      if a.method == "local" then
        lines[#lines + 1] = t.findings .. ":"
        if #a.findings == 0 then
          lines[#lines + 1] = t.no_findings
        end
        for _, finding in ipairs(a.findings) do
          lines[#lines + 1] = "- " .. (finding.kind == "structure" and (t.structure .. ": ") or "") .. finding.text
        end
        lines[#lines + 1] = t.local_method
        lines[#lines + 1] = (a.coverage_unit == "segments" and t.coverage_segments or t.coverage):format(
          a.evaluated_sentences,
          a.sentences
        )
        if a.omitted_spans > 0 then
          lines[#lines + 1] = t.omitted:format(a.omitted_spans)
        end
        if a.provisional then
          lines[#lines + 1] = t.provisional
        end
        lines[#lines + 1] = t.local_rule
      else
        local uncertain = a.confidence < config.options.evaluation.uncertainty_threshold
        lines[#lines + 1] = ("%s: %.0f%%%s"):format(
          t.confidence,
          a.confidence * 100,
          uncertain and (" (" .. t.uncertain .. ")") or ""
        )
        local longest = 0
        for _, label in ipairs(t.stages[i]) do
          longest = math.max(longest, vim.fn.strdisplaywidth(label))
        end
        for level = 1, 5 do
          lines[#lines + 1] = ("%s %d %s%s %3.0f%%"):format(
            level == a.level and ">" or " ",
            level,
            t.stages[i][level],
            string.rep(" ", longest - vim.fn.strdisplaywidth(t.stages[i][level])),
            a.probabilities[level] * 100
          )
        end
      end
      lines[#lines + 1] = ""
    end
  end
  if snap.error then
    lines[#lines + 1] = t.errors[snap.error] or t.errors.service_error
  end
  lines[#lines + 1], lines[#lines + 2], lines[#lines + 3] = t.direction, t.caveat, t.close
  return lines
end

function M.close_details()
  local old = details
  details = nil
  if not old then
    return
  end
  local focused = vim.api.nvim_get_current_win() == old.win
  if vim.api.nvim_win_is_valid(old.win) then
    vim.api.nvim_win_close(old.win, true)
  end
  if focused and vim.api.nvim_win_is_valid(old.source_win) then
    vim.api.nvim_set_current_win(old.source_win)
  end
  controller().schedule()
end

function M.open_details(buf, source_win)
  M.close_details()
  M.close()
  local width, height = math.min(70, vim.o.columns - 4), math.min(24, vim.o.lines - vim.o.cmdheight - 4)
  if width < 30 or height < 3 then
    return controller().notify("small")
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  write(b, detail_lines(buf))
  local w = vim.api.nvim_open_win(b, true, {
    relative = "editor",
    row = 1,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = config.options.ui.border,
    title = " " .. copy.get().details .. "  " .. copy.get().close .. " ",
    zindex = 65,
  })
  details = { win = w, buf = b, source_win = source_win, source_buf = buf }
  vim.wo[w].wrap, vim.wo[w].winblend = true, config.options.ui.winblend
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, M.close_details, { buffer = b, nowait = true, silent = true })
  end
  for _, key in ipairs({ "a", "x", "A", "X", "1", "2", "3", "<CR>", "[", "]" }) do
    vim.keymap.set("n", key, "<Nop>", { buffer = b, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = b,
    once = true,
    callback = function()
      vim.schedule(function()
        if details and details.win == w then
          M.close_details()
        end
      end)
    end,
  })
end

function M.refresh()
  highlights()
  if not config.evaluation_available() then
    M.close()
    M.close_details()
    return
  end
  if details and vim.api.nvim_win_is_valid(details.win) then
    if vim.api.nvim_buf_is_valid(details.source_buf) then
      write(details.buf, detail_lines(details.source_buf))
    else
      M.close_details()
    end
    M.close()
    return
  end
  local ev, tab = controller(), vim.api.nvim_get_current_tabpage()
  local buf = ev.source()
  local mode = vim.fn.mode()
  if not ev.view().visible or not buf or not M.fits() or mode == "c" or vim.fn.pumvisible() == 1 then
    M.close()
    return
  end
  local width, height, bottom = dimensions()
  local popup = require("ai-polish.popup").context()
  if popup and overlaps(popup.win, bottom - height - 2, vim.o.columns - width - 3, height + 2, width + 2) then
    M.close()
    return
  end
  if state and (state.tab ~= tab or not vim.api.nvim_win_is_valid(state.win)) then
    M.close()
  end
  local snap = ev.snapshot(buf)
  local lines, spans = M.render(buf, snap, width)
  local b = state and state.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  write(b, lines)
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  for _, h in ipairs(spans) do
    if h[2] < h[3] then
      vim.api.nvim_buf_set_extmark(b, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
    end
  end
  local cfg = {
    relative = "editor",
    anchor = "SE",
    row = bottom,
    col = vim.o.columns - 1,
    width = width,
    height = #lines,
    style = "minimal",
    border = config.options.ui.border,
    title = M.title(buf, snap, width),
    focusable = false,
    zindex = 40,
  }
  if state then
    vim.api.nvim_win_set_config(state.win, cfg)
  else
    state = { buf = b, win = vim.api.nvim_open_win(b, false, cfg), tab = tab }
  end
  vim.wo[state.win].wrap, vim.wo[state.win].winblend = false, config.options.ui.winblend
end
return M
