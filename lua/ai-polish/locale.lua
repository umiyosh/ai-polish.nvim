-- UI locale: labels shown in the popup and the language Gemini writes explanations in.
local M = {}

M.supported = { "en", "ja", "zh" }

-- How the prompt names each language.
local LANGUAGE = {
  en = "English",
  ja = "Japanese",
  zh = "Simplified Chinese",
}

-- Category / severity labels. English uses the schema values as-is.
local LABELS = {
  ja = {
    typo = "誤字",
    grammar = "文法",
    style = "文体",
    punctuation = "句読点",
    clarity = "明瞭さ",
    consistency = "表記ゆれ",
    critical = "重大",
    warning = "警告",
    suggestion = "提案",
    info = "情報",
  },
  zh = {
    typo = "错别字",
    grammar = "语法",
    style = "文体",
    punctuation = "标点",
    clarity = "清晰度",
    consistency = "一致性",
    critical = "严重",
    warning = "警告",
    suggestion = "建议",
    info = "提示",
  },
}

---Map a locale string such as "ja_JP.UTF-8" to a supported locale, or nil.
function M.normalize(lang)
  if type(lang) ~= "string" then
    return nil
  end
  local code = lang:lower():match("^(%a%a)")
  if code and LANGUAGE[code] then
    return code
  end
end

---Locale strings from the environment, most specific first. Replaceable in tests
---(v:lang is read-only).
function M._environment()
  return { vim.v.lang, vim.env.LANG }
end

---The effective locale: `locale` from setup(), else the environment (v:lang, $LANG), else "en".
function M.current()
  local opt = M.normalize(require("ai-polish.config").options.locale)
  if opt then
    return opt
  end
  for _, lang in ipairs(M._environment()) do
    local loc = M.normalize(lang)
    if loc then
      return loc
    end
  end
  return "en"
end

function M.language(loc)
  return LANGUAGE[loc or M.current()]
end

---Localized label for a category or severity value; falls back to the value itself.
function M.label(key, loc)
  local t = LABELS[loc or M.current()]
  return t and t[key] or key
end

return M
