# ai-polish.nvim

English | [日本語](README.ja.md)

Proofread and polish prose in Neovim with Gemini.

Send the visual selection or the whole buffer to Gemini, see the suggested fixes as underlines in the buffer plus a floating window, and accept or reject them one by one from the keyboard. No main window, no extra UI.

```
The quick brown fox jumsp over the lazy dog.
╭ AI Polish ───────────────────────────────────────╮
│typo · warning                                 1/2│
│Letters are transposed.                           │
│                                                  │
│- jumsp                                           │
│1 jumps                                           │
│                                                  │
│a accept  x reject  ] next  [ prev  A all  q close│
╰──────────────────────────────────────────────────╯
```

## Requirements

- Neovim 0.11+
- `curl`
- A Gemini API key (see [Creating a Gemini API key](docs/api-key.md))

No other plugin dependencies.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "umiyosh/ai-polish.nvim",
  cmd = "AiPolish",
  keys = {
    { "<leader>ap", "<Plug>(ai-polish-selection)", mode = "x", desc = "Proofread selection" },
    { "<leader>ap", "<Plug>(ai-polish-buffer)", mode = "n", desc = "Proofread buffer" },
    { "<leader>ar", "<Plug>(ai-polish-review)", mode = "n", desc = "Review suggestions" },
  },
  opts = {},
}
```

Calling `setup()` is optional; the plugin works with the defaults.

## Setting the API key

The key is looked up in this order:

1. `setup({ api_key = ... })`: a string, or a function returning one
2. `$GEMINI_API_KEY`
3. `$GOOGLE_API_KEY`

Do not hard-code the key in your config. Export it from your shell, or read it from a password manager with a function. The function is called on first use and its result is cached until the next `setup()`; a failed or empty result is retried next time. An exported but empty variable counts as unset.

```sh
# ~/.zshrc etc.
export GEMINI_API_KEY="..."
```

```lua
-- macOS Keychain
opts = {
  api_key = function()
    return vim.trim(vim.fn.system({ "security", "find-generic-password", "-s", "gemini-api-key", "-w" }))
  end,
}
```

```lua
-- 1Password CLI
api_key = function()
  return vim.trim(vim.fn.system({ "op", "read", "op://Private/Gemini/credential" }))
end
```

The key is sent in the `x-goog-api-key` header. It is passed to curl through a temporary file with mode 0600, so it never appears on the `ps` command line.

Run `:checkhealth ai-polish` to check for curl and the API key.

> [!IMPORTANT]
> The text you proofread is sent to Google's Gemini API. On the free tier, Google may use submitted content to improve its products (see the [terms](https://ai.google.dev/gemini-api/terms)). Use a paid-tier key for confidential documents.

## Usage

| Command | Action |
| --- | --- |
| `:AiPolish` | Proofread the whole buffer |
| `:'<,'>AiPolish` | Proofread the visual selection (a charwise `v` selection is honoured exactly) |
| `:AiPolish review` | Reopen the popup for the remaining suggestions, starting at the cursor |
| `:AiPolish cancel` | Cancel the running request |
| `:AiPolish clear` | Remove all suggestions and highlights |

`:AiPolish buffer` and `:AiPolish selection` are explicit forms of the first two.

### Popup keys

The popup takes focus. These keys work only inside it:

| Key | Action |
| --- | --- |
| `a` / `<CR>` | Accept the candidate under the cursor (the cursor starts on the first one) |
| `1` `2` `3` | Accept candidate N |
| `x` | Reject |
| `]` / `[` | Next / previous suggestion |
| `A` | Accept the first candidate of every remaining suggestion (one undo step) |
| `X` | Reject all remaining suggestions |
| `q` / `<Esc>` | Close. Suggestions stay; resume with `:AiPolish review` |

Each accept is its own undo step. You can keep editing while suggestions are pending. Suggestions are tracked with extmarks, and each one is checked against the current text before it is applied, so a suggestion whose text you changed is dropped rather than misapplied.

### States

| State | What you see |
| --- | --- |
| In progress | A spinner at the end of the target's first line (`⠋ AI Polish: proofreading 2/5…`) |
| Done | A notification with the count, then the popup. If the popup cannot open (for example, you are in insert mode), you are told to run `:AiPolish review` |
| Nothing found | `no issues found` |
| Error | `vim.notify` at ERROR level with the HTTP status, the API error message, or the safety block reason |
| Partial failure | A WARN when some chunks fail; suggestions from the successful chunks are still shown |
| Cancelled | `:AiPolish cancel`, or Cancel in the confirmation dialog |

For a statusline, use `require("ai-polish").status()`. It returns `""` when idle, `AI Polish 2/5` while running, and `AI Polish: 3` while suggestions remain.

```lua
-- lualine
sections = { lualine_x = { function() return require("ai-polish").status() end } }
```

## Large documents

- Size and cost are estimated locally before anything is sent. No API call (such as countTokens) is made for the estimate, so no text leaves your machine before you approve.
- A `confirm()` dialog asks for explicit approval when any of these is exceeded:
  - `guard.confirm_chars` characters (default 12,000)
  - `guard.confirm_cost_usd` estimated cost (default $0.05)
  - `guard.confirm_requests` requests (default 4)
- Text over `guard.max_chars` (default 400,000 characters) is refused, and you are asked to select a smaller range.
- Text over `chunk.max_chars` (default 6,000 characters) is split and sent as separate requests, `chunk.concurrency` (default 2) at a time. Split points are searched in this order: paragraph, line, sentence end (`.` `。` and similar), clause, whitespace. Splitting keeps each response small enough that the JSON is not truncated (MAX_TOKENS), and keeps the suggestions accurate.

Tokens are estimated at about 4 ASCII characters per token and 1 token per character for other scripts (such as Japanese). Output is estimated at 60% of the input plus a fixed overhead. The estimate errs on the high side and is not a bill. Override the rates with `pricing`.

## Configuration

Defaults:

```lua
require("ai-polish").setup({
  api_key = nil,                 -- string | fun(): string; nil = $GEMINI_API_KEY / $GOOGLE_API_KEY
  model = "gemini-3.8-flash",
  endpoint = "https://generativelanguage.googleapis.com/v1beta",
  thinking_level = "low",        -- "low" | "medium" | "high" | nil (model default)
  temperature = nil,
  timeout_ms = 120000,
  language = nil,                -- language of the explanations; nil = same as the text
  instructions = nil,            -- extra instructions (style guide, terminology, ...)

  chunk = { max_chars = 6000, concurrency = 2 },
  guard = {
    confirm_chars = 12000,
    confirm_cost_usd = 0.05,
    confirm_requests = 4,
    max_chars = 400000,
  },

  -- Rates for the estimate, USD per 1M tokens
  pricing = {
    ["gemini-3.8-flash"] = { input_per_mtok = 1.50, output_per_mtok = 7.50 },
    -- ...
  },
  default_pricing = { input_per_mtok = 1.50, output_per_mtok = 9.00 },

  ui = { border = "rounded", max_width = 80, winblend = 0 }, -- winblend: popup transparency (0-100)

  -- Keys inside the popup; false disables a key
  keymaps = {
    accept = "a", reject = "x", next = "]", prev = "[",
    accept_all = "A", reject_all = "X", close = "q",
  },
})
```

Example:

```lua
require("ai-polish").setup({
  model = "gemini-3.5-flash-lite", -- a cheaper model
  language = "English",
  instructions = [[
- Use American spelling.
- Keep product names as written.
]],
  guard = { confirm_chars = 30000, confirm_cost_usd = 0.2 },
  keymaps = { next = "n", prev = "p" },
})
```

The default `pricing` for gemini-3.8-flash uses the standard rate that starts in January 2027. It is higher than the introductory rate ($0.75 / $3.75) that applies through the end of 2026, so estimates come out high.

### Highlights

All groups are linked with `default = true`, so your colorscheme can override them.

| Group | Default link |
| --- | --- |
| `AiPolishCritical` / `AiPolishWarning` / `AiPolishSuggestion` / `AiPolishInfo` | `DiagnosticUnderline{Error,Warn,Info,Hint}` |
| `AiPolishCurrent` | `Visual` |
| `AiPolishDelete` / `AiPolishAdd` | `DiffDelete` / `DiffAdd` |
| `AiPolishTitle` / `AiPolishHint` | `Title` / `Comment` |
| `AiPolishProgress` | `DiagnosticVirtualTextInfo` |

## Design notes

- **Locating fixes**: The model does not return offsets. It returns `before`, an exact substring of the input, together with the surrounding `context_before` / `context_after`. The plugin finds every occurrence of `before` and picks the one whose surroundings match the context best. Suggestions that cannot be found, or that overlap another suggestion, are dropped.
- **Tracking fixes**: Suggestions are anchored as extmarks, so they follow edits and earlier accepts. Just before applying, the anchored text is compared with `before`; on a mismatch, nothing is applied.
- **Response format**: Gemini structured output (`responseMimeType: application/json` with `responseJsonSchema`). `promptFeedback.blockReason` and a `finishReason` such as SAFETY or MAX_TOKENS are reported as errors.
- **Retries**: 429, 5xx, and network errors are retried up to twice, after 1 s and then 2 s. Timeouts are not retried.

## Development

```sh
make test       # busted tests via plenary.nvim (cloned into .tests/ on first run)
make lint       # luacheck
make fmt        # format with stylua
make fmt-check  # fail on formatting differences
make check      # lint + fmt-check + test
```

To use an existing plenary checkout, run `PLENARY_DIR=/path/to/plenary.nvim make test`.

CI (GitHub Actions) runs on every push and pull request:

- test: a matrix of Neovim v0.11.0 and stable
- lint: luacheck
- format: stylua `--check`

## License

MIT
