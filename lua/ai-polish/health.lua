local M = {}

function M.check()
  local h = vim.health
  local config = require("ai-polish.config")
  h.start("ai-polish")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.11+ is required")
  end
  if vim.fn.executable("curl") == 1 then
    h.ok("curl found")
  else
    h.error("curl not found in $PATH")
  end
  local key, err = config.api_key()
  if key then
    h.ok(("API key found (%d chars)"):format(#key))
  else
    h.error(err)
  end
  h.info("model: " .. config.options.model)
  local loc = require("ai-polish.locale").current()
  h.info(
    ("locale: %s (%s)%s"):format(
      loc,
      require("ai-polish.locale").language(loc),
      config.options.locale and "" or ", detected from v:lang"
    )
  )
end

return M
