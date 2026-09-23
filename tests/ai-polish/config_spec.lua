local config = require("ai-polish.config")

describe("config.api_key", function()
  local gemini_env, google_env
  before_each(function()
    gemini_env, google_env = vim.env.GEMINI_API_KEY, vim.env.GOOGLE_API_KEY
    vim.env.GEMINI_API_KEY, vim.env.GOOGLE_API_KEY = nil, nil
  end)
  after_each(function()
    vim.env.GEMINI_API_KEY, vim.env.GOOGLE_API_KEY = gemini_env, google_env
    config.setup({})
  end)

  it("calls an api_key function only once", function()
    local calls = 0
    config.setup({
      api_key = function()
        calls = calls + 1
        return " secret \n"
      end,
    })
    assert.equals("secret", config.api_key())
    assert.equals("secret", config.api_key())
    assert.equals(1, calls)
  end)

  it("retries an api_key function that failed or returned nothing", function()
    local calls = 0
    config.setup({
      api_key = function()
        calls = calls + 1
        if calls == 1 then
          error("locked")
        end
        return calls == 2 and "" or "secret"
      end,
    })
    local key, err = config.api_key()
    assert.is_nil(key)
    assert.matches("locked", err)
    assert.is_nil((config.api_key()))
    assert.equals("secret", config.api_key())
  end)

  it("treats an exported but empty variable as unset", function()
    vim.env.GEMINI_API_KEY = ""
    vim.env.GOOGLE_API_KEY = "google-key"
    config.setup({})
    assert.equals("google-key", config.api_key())
  end)

  it("reports a missing key", function()
    config.setup({})
    local key, err = config.api_key()
    assert.is_nil(key)
    assert.matches("GEMINI_API_KEY", err)
  end)
end)
