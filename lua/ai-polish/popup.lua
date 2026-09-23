-- Review popup: a focused floating window anchored to the current suggestion.
local config = require("ai-polish.config")

local M = {}

local ns = vim.api.nvim_create_namespace("ai-polish-popup")

---@type { win: integer, buf: integer, source_win: integer, session: AiPolishSession, candidate_rows: table<integer, integer> }|nil
local state

local function oneline(s)
  return (s:gsub("\n", "↵"))
end

local function hint_line(keys)
  local parts = {}
  local labels = {
    { "accept", "accept" },
    { "reject", "reject" },
    { "next", "next" },
    { "prev", "prev" },
    { "accept_all", "all" },
    { "close", "close" },
  }
  for _, l in ipairs(labels) do
    if keys[l[1]] then
      parts[#parts + 1] = keys[l[1]] .. " " .. l[2]
    end
  end
  return table.concat(parts, "  ")
end

---Build popup lines and highlight spans. Exposed for tests.
---@return string[] lines, table[] highlights { row, col, end_col, group }, table<integer, integer> candidate_rows
function M.render_lines(session, width)
  local item = session:current()
  local lines, hls, rows = {}, {}, {}
  local function add(text, group)
    lines[#lines + 1] = text
    if group then
      hls[#hls + 1] = { #lines - 1, 0, #text, group }
    end
  end

  local head = ("%s · %s"):format(item.category, item.severity)
  local count = ("%d/%d"):format(session.index, #session.items)
  local pad = math.max(2, width - vim.fn.strdisplaywidth(head) - #count)
  add(head .. string.rep(" ", pad) .. count, "AiPolishTitle")
  if item.message ~= "" then
    for _, l in ipairs(vim.split(item.message, "\n", { plain = true })) do
      add(l)
    end
  end
  add("")
  add("- " .. oneline(item.before), "AiPolishDelete")
  for i, a in ipairs(item.after) do
    add(("%d " .. "%s"):format(i, oneline(a)), "AiPolishAdd")
    rows[#lines] = i
  end
  add("")
  add(hint_line(config.options.keymaps), "AiPolishHint")
  return lines, hls, rows
end

function M.is_open()
  return state ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.close()
  if not state then
    return
  end
  local s = state
  state = nil
  if vim.api.nvim_win_is_valid(s.win) then
    vim.api.nvim_win_close(s.win, true)
  end
  if vim.api.nvim_win_is_valid(s.source_win) then
    vim.api.nvim_set_current_win(s.source_win)
  end
end

local function notify(msg, level)
  vim.notify("ai-polish: " .. msg, level or vim.log.levels.INFO)
end

local open -- forward declaration

local function refresh()
  if not state then
    return
  end
  local session, win = state.session, state.source_win
  if #session.items == 0 then
    M.close()
    notify("review finished")
    return
  end
  open(session, win)
end

local function candidate_under_cursor()
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.candidate_rows[row] or 1
end

local actions = {}

function actions.accept(n)
  local ok, err = state.session:accept(n or candidate_under_cursor())
  if not ok then
    notify("skipped: " .. err, vim.log.levels.WARN)
  end
  refresh()
end

function actions.reject()
  state.session:reject()
  refresh()
end

function actions.next()
  state.session:move(1)
  refresh()
end

function actions.prev()
  state.session:move(-1)
  refresh()
end

function actions.accept_all()
  local session = state.session
  M.close()
  local applied, skipped = session:accept_all()
  notify(("applied %d suggestion(s)%s"):format(applied, skipped > 0 and (", skipped %d stale"):format(skipped) or ""))
end

function actions.reject_all()
  local session = state.session
  M.close()
  session:reject_all()
  notify("dismissed all suggestions")
end

function actions.close()
  M.close()
end

local function set_keymaps(buf)
  local keys = config.options.keymaps
  local function map(lhs, fn, desc)
    if lhs then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "ai-polish: " .. desc })
    end
  end
  map(keys.accept, function()
    actions.accept()
  end, "accept suggestion")
  map("<CR>", function()
    actions.accept()
  end, "accept candidate under cursor")
  map(keys.reject, actions.reject, "reject suggestion")
  map(keys.next, actions.next, "next suggestion")
  map(keys.prev, actions.prev, "previous suggestion")
  map(keys.accept_all, actions.accept_all, "accept all suggestions")
  map(keys.reject_all, actions.reject_all, "reject all suggestions")
  map(keys.close, actions.close, "close popup")
  map("<Esc>", actions.close, "close popup")
  for i = 1, 3 do
    map(tostring(i), function()
      actions.accept(i)
    end, "accept candidate " .. i)
  end
end

---@param session AiPolishSession
---@param source_win integer
open = function(session, source_win)
  session:prune()
  if #session.items == 0 then
    M.close()
    notify("no suggestions left")
    return
  end
  local item = session:current()
  local row, col = session:range(item)
  vim.api.nvim_win_set_cursor(source_win, { row + 1, col })

  local opts = config.options.ui
  local win_width = vim.api.nvim_win_get_width(source_win)
  local width = math.max(30, math.min(opts.max_width, win_width - 4))
  -- Measure the natural width first (title unpadded), then right-align the counter.
  local content_w = 0
  for _, l in ipairs((M.render_lines(session, 0))) do
    content_w = math.max(content_w, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, math.max(30, content_w))
  local lines, hls, rows = M.render_lines(session, width)

  local buf = state and vim.api.nvim_buf_is_valid(state.buf) and state.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "ai-polish"
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end

  -- Wrapped lines take more screen rows than buffer lines.
  local height = 0
  for _, l in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end

  -- Open below the suggestion, or above when there is no room.
  local screen_row = vim.fn.screenpos(source_win, row + 1, col + 1).row
  local win_top = vim.fn.win_screenpos(source_win)[1]
  local below = vim.api.nvim_win_get_height(source_win) - (screen_row - win_top + 1)
  local fits_below = below >= height + 2
  local win_cfg = {
    relative = "win",
    win = source_win,
    bufpos = { row, col },
    row = fits_below and 1 or 0,
    col = 0,
    anchor = fits_below and "NW" or "SW",
    width = width,
    height = height,
    style = "minimal",
    border = opts.border,
    title = " AI Polish ",
    title_pos = "left",
    zindex = 50,
  }

  local win
  if state and vim.api.nvim_win_is_valid(state.win) then
    win = state.win
    vim.api.nvim_win_set_config(win, win_cfg)
  else
    win = vim.api.nvim_open_win(buf, true, win_cfg)
    vim.wo[win].wrap = true
    vim.wo[win].cursorline = true
    vim.wo[win].winhighlight = "NormalFloat:AiPolishNormal,FloatBorder:AiPolishBorder"
    set_keymaps(buf)
    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = buf,
      once = true,
      callback = function()
        -- Leaving the popup (e.g. <C-w>w) closes it; the session stays for :AiPolish review.
        vim.schedule(function()
          if state and state.win == win then
            M.close()
          end
        end)
      end,
    })
  end

  state = { win = win, buf = buf, source_win = source_win, session = session, candidate_rows = rows }
  -- Put the cursor on the first candidate so <CR> / accept picks it.
  for r, n in pairs(rows) do
    if n == 1 then
      vim.api.nvim_win_set_cursor(win, { r, 0 })
    end
  end
end

---@param session AiPolishSession
---@param source_win integer
function M.open(session, source_win)
  open(session, source_win)
end

M._actions = actions

return M
