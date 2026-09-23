local M = {}

---@class AiPolishPricing
---@field input_per_mtok number  USD per 1M input tokens
---@field output_per_mtok number USD per 1M output tokens

---@class AiPolishConfig
M.defaults = {
  -- string, or function returning a string. nil falls back to $GEMINI_API_KEY / $GOOGLE_API_KEY.
  api_key = nil,
  model = "gemini-3.8-flash",
  endpoint = "https://generativelanguage.googleapis.com/v1beta",
  -- "low" | "medium" | "high" | nil (model default). Proofreading rarely needs deep reasoning.
  thinking_level = "low",
  temperature = nil,
  timeout_ms = 120000,
  -- Language for the `reason` field. nil = same language as the text.
  language = nil,
  -- Extra instructions appended to the system prompt (style guide, terminology, ...).
  instructions = nil,

  chunk = {
    -- Texts longer than this are split at paragraph boundaries and sent as separate requests.
    max_chars = 6000,
    concurrency = 2,
  },

  guard = {
    -- Ask before sending when any of these is exceeded.
    confirm_chars = 12000,
    confirm_cost_usd = 0.05,
    confirm_requests = 4,
    -- Refuse outright above this size.
    max_chars = 400000,
  },

  -- Used only for the pre-send estimate. Defaults are the published standard rates of
  -- gemini-3.8-flash (the introductory rate is lower until 2026-12-31), so the
  -- estimate errs on the high side.
  pricing = {
    ["gemini-3.8-flash"] = { input_per_mtok = 1.50, output_per_mtok = 7.50 },
    ["gemini-3.7-flash"] = { input_per_mtok = 1.50, output_per_mtok = 7.50 },
    ["gemini-3.5-flash"] = { input_per_mtok = 1.50, output_per_mtok = 9.00 },
    ["gemini-3.5-flash-lite"] = { input_per_mtok = 0.30, output_per_mtok = 2.50 },
  },
  -- Fallback when `model` has no pricing entry.
  default_pricing = { input_per_mtok = 1.50, output_per_mtok = 9.00 },

  ui = {
    border = "rounded",
    max_width = 80,
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  },

  -- Keys inside the review popup. Set a key to false to disable it.
  keymaps = {
    accept = "a",
    reject = "x",
    next = "]",
    prev = "[",
    accept_all = "A",
    reject_all = "X",
    close = "q",
  },
}

M.options = vim.deepcopy(M.defaults)

local function validate(opts)
  vim.validate("model", opts.model, "string")
  vim.validate("endpoint", opts.endpoint, "string")
  vim.validate("timeout_ms", opts.timeout_ms, "number")
  vim.validate("chunk.max_chars", opts.chunk.max_chars, "number")
  vim.validate("chunk.concurrency", opts.chunk.concurrency, "number")
  vim.validate("guard.confirm_chars", opts.guard.confirm_chars, "number")
  vim.validate("guard.confirm_cost_usd", opts.guard.confirm_cost_usd, "number")
  vim.validate("guard.confirm_requests", opts.guard.confirm_requests, "number")
  vim.validate("guard.max_chars", opts.guard.max_chars, "number")
  vim.validate("api_key", opts.api_key, { "string", "function" }, true)
  vim.validate("thinking_level", opts.thinking_level, "string", true)
  if opts.chunk.max_chars < 500 then
    error("ai-polish: chunk.max_chars must be >= 500")
  end
  if opts.chunk.concurrency < 1 then
    error("ai-polish: chunk.concurrency must be >= 1")
  end
end

---@param opts? table
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  validate(merged)
  M.options = merged
  return merged
end

---@return AiPolishPricing
function M.pricing(model)
  return M.options.pricing[model] or M.options.default_pricing
end

---@return string|nil key, string|nil err
function M.api_key()
  local key = M.options.api_key
  if type(key) == "function" then
    local ok, res = pcall(key)
    if not ok then
      return nil, "api_key function failed: " .. tostring(res)
    end
    key = res
  end
  key = key or vim.env.GEMINI_API_KEY or vim.env.GOOGLE_API_KEY
  if type(key) ~= "string" or vim.trim(key) == "" then
    return nil, "Gemini API key is not set (set $GEMINI_API_KEY or `api_key` in setup())"
  end
  return vim.trim(key)
end

return M
