-- Test bootstrap: this plugin + plenary.nvim on the runtimepath, nothing else.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = vim.env.PLENARY_DIR or (root .. "/.tests/plenary.nvim")
if vim.fn.isdirectory(plenary) == 0 then
  vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-lua/plenary.nvim", plenary })
end
vim.opt.runtimepath:prepend(plenary)
vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/ai-polish.lua")
