local config = require("ai-polish.config")
local locale = require("ai-polish.locale")
local prompt = require("ai-polish.prompt")
local popup = require("ai-polish.popup")
local session = require("ai-polish.session")

describe("locale", function()
  local orig_env = locale._environment
  local env = {}
  before_each(function()
    locale._environment = function()
      return { env.v_lang, env.LANG }
    end
  end)
  after_each(function()
    locale._environment = orig_env
    env = {}
    config.setup({})
  end)

  it("normalizes environment locale strings", function()
    assert.equals("ja", locale.normalize("ja_JP.UTF-8"))
    assert.equals("zh", locale.normalize("zh_CN.UTF-8"))
    assert.equals("en", locale.normalize("en_US"))
    assert.is_nil(locale.normalize("C"))
    assert.is_nil(locale.normalize("fr_FR.UTF-8"))
  end)

  it("prefers the configured locale over the environment", function()
    env.v_lang = "ja_JP.UTF-8"
    config.setup({ locale = "zh" })
    assert.equals("zh", locale.current())
  end)

  it("detects from v:lang, then $LANG, then falls back to English", function()
    config.setup({})
    env.v_lang = "ja_JP.UTF-8"
    assert.equals("ja", locale.current())
    env.v_lang = "C"
    env.LANG = "zh_CN.UTF-8"
    assert.equals("zh", locale.current())
    env.LANG = "fr_FR.UTF-8"
    assert.equals("en", locale.current())
  end)

  it("rejects unsupported locales", function()
    assert.has_error(function()
      config.setup({ locale = "fr" })
    end)
  end)

  it("asks Gemini to explain in the locale's language", function()
    assert.matches("Write `message` in Japanese", prompt.system({ language = locale.language("ja") }))
    assert.matches("Write `message` in Simplified Chinese", prompt.system({ language = locale.language("zh") }))
  end)

  it("localizes popup labels but keeps key hints in English", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "teh" })
    local s = session.create(buf, {
      {
        before = "teh",
        after = { "the" },
        message = "",
        category = "typo",
        severity = "warning",
        row = 0,
        col = 0,
        end_row = 0,
        end_col = 3,
      },
    })
    local function render(loc)
      config.setup({ locale = loc })
      return popup.render_lines(s, 60)
    end
    assert.matches("^誤字 · 警告", render("ja")[1])
    assert.matches("^错别字 · 警告", render("zh")[1])
    local en = render("en")
    assert.matches("^typo · warning", en[1])
    assert.matches("a accept", en[#en])
    local ja = render("ja")
    assert.matches("a accept", ja[#ja])
  end)
end)
