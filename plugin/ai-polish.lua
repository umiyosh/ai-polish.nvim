if vim.g.loaded_ai_polish then
  return
end
vim.g.loaded_ai_polish = true

local subcommands = {
  buffer = function(_, _)
    require("ai-polish").proofread()
  end,
  selection = function()
    require("ai-polish").proofread_selection()
  end,
  review = function()
    require("ai-polish").review()
  end,
  cancel = function()
    require("ai-polish").cancel()
  end,
  clear = function()
    require("ai-polish").clear()
  end,
}

local function evaluation()
  return require("ai-polish.evaluation")
end

subcommands.evaluate = function(cmd)
  local opts = {}
  if cmd.fargs[2] == "buffer" then
    if cmd.range > 0 then
      return evaluation().notify("invalid_request")
    end
    opts.whole = true
  elseif cmd.fargs[2] then
    return evaluation().notify("invalid_request")
  end
  if cmd.range > 0 then
    local target = require("ai-polish.evaluation_target")
    if cmd.line1 == vim.fn.line("'<") and cmd.line2 == vim.fn.line("'>") then
      local err
      opts.range, err, opts.kind = target.visual(vim.api.nvim_get_current_buf(), false)
      if not opts.range then
        return evaluation().notify(err)
      end
    else
      local line = vim.api.nvim_buf_get_lines(0, cmd.line2 - 1, cmd.line2, false)[1] or ""
      opts.range, opts.kind = { cmd.line1 - 1, 0, cmd.line2 - 1, #line }, "lines"
    end
  end
  evaluation().evaluate(opts)
end
subcommands.toggle = function()
  evaluation().toggle()
end
subcommands.polish = function()
  evaluation().polish()
end
subcommands.details = function()
  evaluation().details()
end

vim.api.nvim_create_user_command("AiPolish", function(cmd)
  local sub = cmd.fargs[1]
  if #cmd.fargs > 2 or (#cmd.fargs > 1 and sub ~= "evaluate") then
    return vim.notify("ai-polish: unexpected arguments", vim.log.levels.INFO)
  end
  if cmd.range > 0 and (sub == "toggle" or sub == "polish" or sub == "details") then
    return vim.notify("ai-polish: this action does not accept a range", vim.log.levels.INFO)
  end
  if sub then
    local fn = subcommands[sub]
    if not fn then
      return vim.notify("ai-polish: unknown subcommand: " .. sub, vim.log.levels.ERROR)
    end
    return fn(cmd)
  end
  if cmd.range == 0 then
    return require("ai-polish").proofread()
  end
  -- A range that matches the last visual selection means ":'<,'>AiPolish" from visual
  -- mode: honour a charwise selection instead of widening it to whole lines.
  local s, e = vim.fn.line("'<"), vim.fn.line("'>")
  if cmd.line1 == s and cmd.line2 == e then
    return require("ai-polish").proofread_selection()
  end
  require("ai-polish").proofread_lines(0, cmd.line1, cmd.line2)
end, {
  nargs = "*",
  range = true,
  desc = "Proofread the selection or buffer with Gemini",
  complete = function(arg, line)
    if line:match("AiPolish%s+evaluate%s+") then
      return vim.startswith("buffer", arg) and { "buffer" } or {}
    end
    return vim.tbl_filter(function(k)
      return vim.startswith(k, arg)
    end, vim.tbl_keys(subcommands))
  end,
})

vim.keymap.set(
  "x",
  "<Plug>(ai-polish-selection)",
  ":<C-u>AiPolish selection<CR>",
  { silent = true, desc = "ai-polish: proofread selection" }
)
vim.keymap.set(
  "n",
  "<Plug>(ai-polish-buffer)",
  "<Cmd>AiPolish buffer<CR>",
  { silent = true, desc = "ai-polish: proofread buffer" }
)
vim.keymap.set(
  "n",
  "<Plug>(ai-polish-review)",
  "<Cmd>AiPolish review<CR>",
  { silent = true, desc = "ai-polish: review suggestions" }
)

vim.keymap.set("n", "<Plug>(ai-polish-evaluate)", function()
  evaluation().evaluate()
end, { desc = "ai-polish: evaluate text with Jev" })
vim.keymap.set(
  "x",
  "<Plug>(ai-polish-evaluate)",
  "<Cmd>lua require('ai-polish.evaluation').evaluate({ visual = true })<CR>",
  { desc = "ai-polish: evaluate selection with Jev" }
)
vim.keymap.set(
  { "n", "x" },
  "<Plug>(ai-polish-evaluation-toggle)",
  "<Cmd>AiPolish toggle<CR>",
  { desc = "ai-polish: toggle evaluation panel (no request)" }
)
vim.keymap.set(
  "n",
  "<Plug>(ai-polish-proofread-target)",
  "<Cmd>AiPolish polish<CR>",
  { desc = "ai-polish: proofread evaluated target with Gemini" }
)
