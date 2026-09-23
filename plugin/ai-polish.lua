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

vim.api.nvim_create_user_command("AiPolish", function(cmd)
  local sub = cmd.fargs[1]
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
  nargs = "?",
  range = true,
  desc = "Proofread the selection or buffer with Gemini",
  complete = function(arg)
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
