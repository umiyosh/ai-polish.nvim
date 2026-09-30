-- Manual-only controller: observers invalidate/render, never issue HTTP requests.
local config = require("ai-polish.config")
local target = require("ai-polish.evaluation_target")
local jev = require("ai-polish.jev")
local copy = require("ai-polish.evaluation_copy")
local M = { states = {}, views = {} }
local attached, queued = {}, false

local function panel()
  return require("ai-polish.evaluation_panel")
end

function M.notify(code)
  vim.notify("ai-polish: " .. (copy.get().errors[code] or code), vim.log.levels.INFO)
end

function M.source()
  local win = vim.api.nvim_get_current_win()
  local popup = require("ai-polish.popup").context()
  local detail = package.loaded["ai-polish.evaluation_panel"]
  detail = detail and detail.context()
  if popup and popup.win == win then
    win = popup.source_win
  elseif detail and detail.win == win then
    win = detail.source_win
  end
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" then
    return nil
  end
  return buf, win
end

function M.schedule()
  if queued then
    return
  end
  queued = true
  vim.schedule(function()
    queued = false
    panel().refresh()
  end)
end

function M.view()
  local tab = vim.api.nvim_get_current_tabpage()
  M.views[tab] = M.views[tab] or { visible = false }
  return M.views[tab]
end

function M.get(buf)
  return M.states[buf]
end

function M.snapshot(buf)
  local s = M.states[buf]
  if not s then
    return { status = "none" }
  end
  local range = target.range(buf, s.target)
  if not range then
    return { status = "error", error = "invalid_target", target = s.target }
  end
  local content = target.read(buf, range)
  local status = s.pending and "loading" or (s.error and "error") or (s.result and "ready") or "none"
  if status == "ready" and content ~= s.text then
    status = "stale"
  end
  return { status = status, error = s.error, result = s.result, target = s.target, range = range }
end

function M.cancel(buf)
  local s = M.states[buf]
  if not s or not s.pending then
    return false
  end
  local job = s.pending
  s.pending, s.error = nil, "cancelled"
  if job.cancel then
    job.cancel()
  end
  M.schedule()
  return true
end

function M.clear(buf)
  M.cancel(buf)
  M.states[buf] = nil
  target.clear(buf)
  M.schedule()
end

function M.reset()
  for buf in pairs(M.states) do
    M.clear(buf)
  end
  M.states, M.views = {}, {}
  panel().close_details()
  panel().close()
end

local function observe(buf)
  if attached[buf] then
    return
  end
  attached[buf] = true
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      M.schedule()
    end,
    on_detach = function()
      attached[buf] = nil
      M.clear(buf)
    end,
  })
end

function M.evaluate(opts)
  opts = opts or {}
  local buf = opts.bufnr or M.source()
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not buf then
    return M.notify("invalid_target")
  end
  local key, err = config.evaluation_key()
  if not key then
    panel().close()
    return M.notify(err)
  end
  if not panel().fits() then
    return M.notify("small")
  end
  local s = M.states[buf]
  if s and s.pending then
    return
  end -- one explicit request in flight per buffer
  local range, kind = opts.range, opts.kind
  if opts.visual then
    range, err, kind = target.visual(buf, true)
    if not range then
      return M.notify(err)
    end
  end
  if opts.whole or range or not s then
    target.clear(buf)
    if opts.whole then
      range = nil
    end
    s = { target = target.set(buf, range, kind) }
    M.states[buf] = s
  end
  M.view().visible = true
  observe(buf)
  range = target.range(buf, s.target)
  if not range then
    panel().refresh()
    return M.notify("invalid_target")
  end
  local content = target.read(buf, range)
  if not content or vim.trim(content) == "" then
    s.error = "empty"
    panel().refresh()
    return M.notify("empty")
  end
  if vim.fn.strchars(content) > math.min(config.options.evaluation.max_chars, config.options.guard.max_chars) then
    s.error = "too_long"
    panel().refresh()
    return
  end
  if vim.fn.strchars(content) > config.options.guard.confirm_chars then
    local msg = ("Send %d characters to TypeSafe (Jev)? One request for two evaluations."):format(
      vim.fn.strchars(content)
    )
    if not require("ai-polish")._confirm(msg) then
      return
    end
  end
  local job = {}
  s.pending, s.error = job, nil
  panel().refresh()
  local ok, handle = pcall(jev.evaluate, content, key, function(result, failure)
    if M.states[buf] ~= s or s.pending ~= job or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    s.pending, s.error = nil, failure
    if result then
      s.result, s.text = result, content
    end
    M.schedule() -- honor visibility and active tab; never focus/open here directly
  end)
  if not ok then
    s.pending, s.error = nil, "transport"
    panel().refresh()
  elseif s.pending == job then
    job.cancel = handle.cancel
  end
end

function M.toggle()
  local key, err = config.evaluation_key()
  if not key then
    panel().close()
    return M.notify(err)
  end
  if not M.source() then
    return
  end
  local v = M.view()
  v.visible = not v.visible
  if v.visible and not panel().fits() then
    M.notify("small")
  end
  panel().refresh()
end

function M.polish()
  local buf = M.source()
  local s = buf and M.states[buf]
  if not s then
    return M.notify("no_target")
  end
  local range = target.range(buf, s.target)
  if not range then
    return M.notify("invalid_target")
  end
  require("ai-polish").proofread({ bufnr = buf, range = range })
end

function M.details()
  if not config.evaluation_available() then
    local _, err = config.evaluation_key()
    if err then
      return M.notify(err)
    end
  end
  local buf, win = M.source()
  if not buf or not M.states[buf] then
    return M.notify("no_target")
  end
  panel().open_details(buf, win)
end

local group = vim.api.nvim_create_augroup("AiPolishEvaluation", { clear = true })
vim.api.nvim_create_autocmd({
  "BufEnter",
  "WinEnter",
  "WinClosed",
  "TabEnter",
  "VimResized",
  "ModeChanged",
  "CursorMoved",
  "CursorMovedI",
  "TextChanged",
  "TextChangedI",
  "CmdlineEnter",
  "CmdlineLeave",
  "CompleteChanged",
  "CompleteDone",
  "ColorScheme",
}, {
  group = group,
  callback = M.schedule,
})
vim.api.nvim_create_autocmd("BufWipeout", {
  group = group,
  callback = function(ev)
    M.clear(ev.buf)
  end,
})
vim.api.nvim_create_autocmd("TabClosed", {
  group = group,
  callback = function()
    for tab in pairs(M.views) do
      if not vim.api.nvim_tabpage_is_valid(tab) then
        M.views[tab] = nil
      end
    end
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    for buf in pairs(M.states) do
      M.cancel(buf)
    end
  end,
})
return M
