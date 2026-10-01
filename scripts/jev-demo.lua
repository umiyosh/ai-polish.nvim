-- Offline UI demonstration: nvim -u scripts/jev-demo.lua
-- Every result is a fixture, NOT a live Jev judgment. Never sends HTTP.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.opt.termguicolors = true
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.laststatus = 2
vim.opt.statusline = " OFFLINE UI DEMO - FIXTURE RESULTS (no API calls) %=%l:%c "
vim.g.mapleader = " "
require("ai-polish").setup({ locale = "ja", evaluation = { api_key = "offline-fixture" } })
vim.keymap.set({ "n", "x" }, "<leader>ae", "<Plug>(ai-polish-evaluate)")
vim.keymap.set({ "n", "x" }, "<leader>at", "<Plug>(ai-polish-evaluation-toggle)")
vim.keymap.set("n", "<leader>ap", "<Plug>(ai-polish-buffer)")
vim.keymap.set("x", "<leader>ap", "<Plug>(ai-polish-selection)")
require("ai-polish.http").post = function(req, cb)
  assert(req.url == "https://api.typesafe.ai/v1/systemone", "Offline demo supports Jev only")
  local function a(probabilities)
    return {
      type = "score",
      score = 2,
      confidence = 0.83,
      probabilities = probabilities,
      legend = { ["0"] = "1", ["1"] = "2", ["2"] = "3", ["3"] = "4", ["4"] = "5" },
    }
  end
  local cancelled = false
  vim.defer_fn(function()
    if not cancelled then
      local answers = {}
      for id, q in pairs(vim.json.decode(req.body).questions) do
        if q.type == "noul" then
          answers[id] = { type = "noul", noul = 0.6 }
        else
          answers[id] = a({ ["0"] = 0.07, ["1"] = 0.83, ["2"] = 0.08, ["3"] = 0.01, ["4"] = 0.01 })
        end
      end
      cb({ status = 200, body = vim.json.encode({ answers = answers }) })
    end
  end, 600)
  return {
    cancel = function()
      cancelled = true
    end,
  }
end
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.api.nvim_buf_set_name(0, "jev-demo.md")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "# オフラインUI確認（数値は表示例です）",
      "",
      "ご連絡いただき、ありがとうございます。",
      "設定を確認してから、変更を保存します。",
      "",
      "選択して Space ae: 選択範囲を評価",
      "Space ae: 同じ対象を再評価 / Space at: 表示切替",
      ":AiPolish polish: 保持した対象を校正（このデモでは送信禁止）",
      ":AiPolish details: 結果の詳細 / q: 詳細を閉じる",
    })
    vim.bo.modified = false
    require("ai-polish.evaluation").evaluate({ range = { 2, 0, 3, #vim.api.nvim_buf_get_lines(0, 3, 4, false)[1] } })
  end,
})
