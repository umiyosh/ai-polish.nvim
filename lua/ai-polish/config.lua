local M = {}

-- Result of an `api_key` function. Cached because it may be slow or interactive
-- (password managers); only a successful result is kept so a failure can be retried.
local cached_key, cached_evaluation_key

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
  -- en / ja / zh (Hans alias) / zh-Hans / zh-Hant: UI and Gemini explanation language.
  -- nil = detect from v:lang ($LANG), falling back to "en".
  locale = nil,
  -- Extra instructions appended to the system prompt (style guide, terminology, ...).
  instructions = nil,

  -- Optional Jev evaluation; bounded automatic checks after proofreading/acceptance.
  evaluation = {
    enabled = true,
    api_key = nil, -- string/callback, otherwise $TYPESAFE_API_KEY
    model = "jev-latest",
    timeout_ms = 20000,
    max_chars = 12000,
    auto_max_chars = 3000, -- 0 disables automatic checks; also limited to two requests
    language = "auto", -- source text hint; independent of UI locale
    panel_width = 30, -- 30..60 cells; compact two-row display by default
    uncertainty_threshold = 0.5, -- presentation heuristic, not calibrated accuracy
  },

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
    -- Transparency of the popup (0-100). 0 keeps it readable regardless of the global 'winblend'.
    winblend = 0,
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
    undo = "u",
    redo = "<C-r>",
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
  vim.validate("locale", opts.locale, "string", true)
  if opts.locale and not require("ai-polish.locale").normalize(opts.locale) then
    error(("ai-polish: locale must be en, ja, zh, zh-Hans or zh-Hant (got %q)"):format(opts.locale))
  end
  local ev = opts.evaluation
  if type(ev.panel_width) ~= "number" or ev.panel_width % 1 ~= 0 or ev.panel_width < 30 or ev.panel_width > 60 then
    error("ai-polish: evaluation.panel_width must be an integer from 30 to 60")
  end
  vim.validate("evaluation.enabled", ev.enabled, "boolean")
  vim.validate("evaluation.api_key", ev.api_key, { "string", "function" }, true)
  vim.validate("evaluation.model", ev.model, "string")
  if
    type(ev.auto_max_chars) ~= "number"
    or ev.auto_max_chars < 0
    or ev.auto_max_chars == math.huge
    or ev.auto_max_chars ~= ev.auto_max_chars
  then
    error("ai-polish: evaluation.auto_max_chars must be a finite non-negative number")
  end
  for _, name in ipairs({ "timeout_ms", "max_chars", "uncertainty_threshold" }) do
    local v = ev[name]
    if type(v) ~= "number" or v ~= v or v == math.huge or v <= 0 then
      error("ai-polish: evaluation." .. name .. " must be a finite positive number")
    end
  end
  if ev.uncertainty_threshold > 1 then
    error("ai-polish: evaluation.uncertainty_threshold must be <= 1")
  end
  if not vim.tbl_contains({ "auto", "en", "ja", "zh-Hans", "zh-Hant" }, ev.language) then
    error("ai-polish: unsupported evaluation.language")
  end
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
  cached_key, cached_evaluation_key = nil, nil
  return merged
end

---@return AiPolishPricing
function M.pricing(model)
  return M.options.pricing[model] or M.options.default_pricing
end

local function nonempty(v)
  if type(v) == "string" and vim.trim(v) ~= "" then
    return vim.trim(v)
  end
end

---@return string|nil key, string|nil err
function M.api_key()
  local key = M.options.api_key
  if type(key) == "function" then
    if not cached_key then
      local ok, res = pcall(key)
      if not ok then
        return nil, "api_key function failed: " .. tostring(res)
      end
      cached_key = nonempty(res)
    end
    key = cached_key
  else
    key = nonempty(key)
  end
  -- An exported-but-empty variable counts as unset.
  key = key or nonempty(vim.env.GEMINI_API_KEY) or nonempty(vim.env.GOOGLE_API_KEY)
  if not key then
    return nil, "Gemini API key is not set (set $GEMINI_API_KEY or `api_key` in setup())"
  end
  return key
end

-- Passive UI checks never invoke an interactive password-manager callback.
function M.evaluation_available()
  if not M.options.evaluation.enabled then
    return false
  end
  local key = M.options.evaluation.api_key
  return (type(key) == "function" and cached_evaluation_key ~= nil)
    or (type(key) ~= "function" and (nonempty(key) or nonempty(vim.env.TYPESAFE_API_KEY)) ~= nil)
end

function M.evaluation_key()
  if not M.options.evaluation.enabled then
    return nil, "disabled"
  end
  local key = M.options.evaluation.api_key
  if type(key) == "function" then
    if not cached_evaluation_key then
      local ok, value = pcall(key)
      if not ok then
        return nil, "key_error"
      end
      cached_evaluation_key = nonempty(value)
    end
    key = cached_evaluation_key
  else
    key = nonempty(key) or nonempty(vim.env.TYPESAFE_API_KEY)
  end
  if not key then
    return nil, "missing_key"
  end
  if key:find("[\r\n]") then
    cached_evaluation_key = nil
    return nil, "key_error"
  end
  return key
end

return M
