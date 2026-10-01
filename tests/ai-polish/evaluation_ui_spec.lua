local polish = require("ai-polish")
local ev = require("ai-polish.evaluation")
local panel = require("ai-polish.evaluation_panel")
local target = require("ai-polish.evaluation_target")
local function axis(level)
  return { level = level, confidence = 0.9, probabilities = { 0, 0, 1, 0, 0 } }
end

describe("evaluation targets and UI", function()
  local buf, columns, lines, selection, ambiwidth
  before_each(function()
    columns, lines, selection, ambiwidth = vim.o.columns, vim.o.lines, vim.o.selection, vim.o.ambiwidth
    polish.setup({ locale = "ja", evaluation = { api_key = "test" } })
    vim.cmd("enew!")
    buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "前漢字🙂後", "第二行" })
  end)
  after_each(function()
    vim.cmd("normal! \27")
    ev.reset()
    vim.o.columns, vim.o.lines, vim.o.selection, vim.o.ambiwidth = columns, lines, selection, ambiwidth
  end)

  it("reads active reversed UTF-8 selections without exiting Visual mode", function()
    vim.api.nvim_win_set_cursor(0, { 1, 9 })
    vim.cmd("normal! v2h")
    local range = target.visual(buf, true)
    assert.equals("漢字🙂", target.read(buf, range))
    assert.equals("v", vim.fn.mode())
  end)
  it("honors exclusive and linewise selections and refuses blocks", function()
    vim.o.selection = "exclusive"
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    vim.cmd("normal! v2l")
    assert.equals("漢字", target.read(buf, target.visual(buf, true)))
    vim.cmd("normal! \27ggVj")
    assert.equals("前漢字🙂後\n第二行", target.read(buf, target.visual(buf, true)))
    vim.cmd("normal! \27gg\22j")
    local range, err = target.visual(buf, true)
    assert.is_nil(range)
    assert.equals("unsupported", err)
  end)
  it("retains its anchor through edits above the selection", function()
    local t = target.set(buf, { 1, 0, 1, 9 })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
    assert.equals("第二行", target.read(buf, target.range(buf, t)))
  end)
  it("fits every language and state in 30 cells with stable height", function()
    vim.o.ambiwidth = "double"
    for _, locale in ipairs({ "en", "ja", "zh-Hans", "zh-Hant" }) do
      polish.setup({ locale = locale, evaluation = { api_key = "test" } })
      for _, status in ipairs({ "none", "loading", "ready", "stale", "error" }) do
        for level = 1, 5 do
          local snap = {
            status = status,
            error = "bad_key",
            target = { kind = "whole" },
            result = { unnaturalness = axis(level), ai_style = axis(level) },
          }
          local rendered = panel.render(buf, snap, 30)
          assert.equals(3, #rendered)
          for _, line in ipairs(rendered) do
            assert.is_true(vim.fn.strdisplaywidth(line) <= 30, locale .. ": " .. line)
          end
          if status == "ready" then
            local copy = require("ai-polish.evaluation_copy").get()
            assert.is_truthy(rendered[1]:find(copy.stages[1][level], 1, true))
            assert.is_truthy(rendered[2]:find(copy.stages[2][level], 1, true))
          end
        end
      end
    end
  end)
  it("uses actual mappings and respects a buffer-local shadow", function()
    vim.keymap.set("n", "<Space>ap", "<Plug>(ai-polish-buffer)")
    assert.equals("<Space>ap", panel.mapping(buf, "n", "buffer"))
    vim.keymap.set("n", "<Space>ap", "<Nop>", { buffer = buf })
    assert.is_nil(panel.mapping(buf, "n", "buffer"))
    vim.keymap.del("n", "<Space>ap")
  end)
  it("keeps passive focus and per-tab visibility, hiding special buffers", function()
    local win = vim.api.nvim_get_current_win()
    ev.toggle()
    assert.is_true(panel.is_open())
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.is_false(vim.api.nvim_win_get_config(panel.window()).focusable)
    vim.cmd("tabnew")
    panel.refresh()
    assert.is_false(panel.is_open())
    vim.cmd("tabclose")
    panel.refresh()
    assert.is_true(panel.is_open())
    vim.bo[buf].buftype = "nofile"
    panel.refresh()
    assert.is_false(panel.is_open())
    vim.bo[buf].buftype = ""
  end)
  it("shows cached details without accepting text and clears from the source", function()
    ev.states[buf] = {
      target = { kind = "whole" },
      text = target.read(buf, target.whole(buf)),
      result = { unnaturalness = axis(3), ai_style = axis(2) },
    }
    local win = vim.api.nvim_get_current_win()
    ev.details()
    local detail = panel.context()
    assert.equals(buf, ev.source())
    assert.equals("<Nop>", vim.fn.maparg("<CR>", "n"))
    assert.is_truthy(detail)
    polish.clear()
    assert.is_nil(ev.get(buf))
    panel.close_details()
    assert.equals(win, vim.api.nvim_get_current_win())
  end)
  it("stacks Gemini progress above the panel and suppresses an overlapping correction float", function()
    ev.toggle()
    local pwin = panel.window()
    local spinner = require("ai-polish.progress").start(buf)
    spinner.update("proofreading")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= pwin and vim.api.nvim_win_get_config(win).relative ~= "" then
        local pos = vim.api.nvim_win_get_position(win)
        assert.is_true(pos[1] + vim.api.nvim_win_get_height(win) + 2 <= vim.api.nvim_win_get_position(pwin)[1])
      end
    end
    spinner.stop()
    local session = require("ai-polish.session").create(buf, {
      {
        row = 0,
        col = 0,
        end_row = 0,
        end_col = 3,
        before = "前",
        after = { "先" },
        message = "example",
        category = "typo",
        severity = "warning",
      },
    })
    local popup = require("ai-polish.popup")
    local source = vim.api.nvim_get_current_win()
    popup.open(session, source)
    assert.equals(buf, ev.source())
    local pos = { vim.o.lines - vim.o.cmdheight - 2 - 5, vim.o.columns - 33 }
    vim.api.nvim_win_set_config(popup.context().win, {
      relative = "editor",
      anchor = "NW",
      row = pos[1],
      col = pos[2],
      width = 30,
      height = 3,
    })
    panel.refresh()
    assert.is_false(panel.is_open())
    popup.close()
    panel.refresh()
    assert.is_true(panel.is_open())
  end)
  it("shows uncertainty separately and refuses too-small panels before sending", function()
    local snap =
      { status = "ready", target = { kind = "whole" }, result = { unnaturalness = axis(3), ai_style = axis(2) } }
    snap.result.unnaturalness.confidence = 0.28
    assert.is_truthy(panel.render(buf, snap, 30)[1]:find("判定に迷い", 1, true))
    vim.o.columns = 33
    assert.is_false(panel.fits())
    vim.o.columns = 34
    assert.is_true(panel.fits())
  end)
  it("shows local evidence and coverage without borrowing whole-Score confidence", function()
    local c = {
      level = 3,
      method = "local",
      value = 0.4,
      evaluated_sentences = 2,
      sentences = 3,
      omitted_spans = 0,
      provisional = true,
      findings = { { kind = "phrase", text = "用語を誤った" } },
    }
    ev.states[buf] = {
      target = { kind = "whole" },
      text = target.read(buf, target.whole(buf)),
      result = { unnaturalness = c, ai_style = axis(2) },
    }
    for _, locale in ipairs({ "ja", "zh-Hans", "zh-Hant", "en" }) do
      require("ai-polish.config").options.locale = locale
      c.coverage_unit = "segments"
      local copy = require("ai-polish.evaluation_copy").get()
      local rendered = panel.render(buf, ev.snapshot(buf), 30)
      assert.is_truthy(rendered[1]:find(copy.partial, 1, true))
      assert.is_true(vim.fn.strdisplaywidth(rendered[1]) <= 30)
      ev.details()
      local detail_lines = vim.api.nvim_buf_get_lines(panel.context().buf, 0, -1, false)
      local text = table.concat(detail_lines, "\n")
      assert.is_truthy(text:find(copy.coverage_segments:format(2, 3), 1, true))
      assert.is_truthy(text:find(copy.provisional, 1, true))
      assert.is_truthy(text:find("用語を誤った", 1, true))
      local first = text:sub(1, assert(text:find(copy.axes[2], 1, true)) - 1)
      assert.is_nil(first:find(copy.confidence, 1, true))
      panel.close_details()
    end
  end)
end)
