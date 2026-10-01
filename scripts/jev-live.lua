-- Explicit paid comparison: TYPESAFE_API_KEY must already be set locally.
-- nvim -l scripts/jev-live.lua /tmp/jev-results.json
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local config = require("ai-polish.config")
config.setup({})
local key, err = config.evaluation_key()
if not key then
  io.stderr:write("Jev comparison not run: " .. err .. ". Set TYPESAFE_API_KEY locally.\n")
  vim.cmd("cquit 2")
end
local output = arg[1]
if not output or vim.uv.fs_stat(output) then
  io.stderr:write("Pass a NEW output JSON path; existing reports are never overwritten.\n")
  vim.cmd("cquit 2")
end
local cases = vim.json.decode(table.concat(vim.fn.readfile(root .. "/tests/fixtures/jev-cases.json"), "\n"))
local report = {
  timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  model = config.options.evaluation.model,
  rubric_version = require("ai-polish.jev").rubric_version,
  results = {},
}
for _, case in ipairs(cases) do
  config.options.evaluation.language = case.language
  local finished, result, failure = false
  local planned = require("ai-polish.jev").plan(case.text)
  local started = vim.uv.hrtime()
  local handle = require("ai-polish.jev").evaluate(case.text, key, function(value, error_code)
    result, failure, finished = value, error_code, true
  end, planned)
  if
    not vim.wait(config.options.evaluation.timeout_ms * math.ceil(#planned.batches / 4) + 2000, function()
      return finished
    end, 20)
  then
    handle.cancel()
    failure = "timeout"
  end
  -- Findings contain source excerpts; omit them from this safe comparison report.
  if result then
    result.unnaturalness.findings = nil
  end
  report.results[#report.results + 1] = {
    id = case.id,
    result = result,
    planned_requests = #planned.batches,
    error = failure,
    latency_ms = math.floor((vim.uv.hrtime() - started) / 1000000),
  }
  -- No raw provider errors, API keys, submitted text or headers in the report.
  io.stdout:write(case.id .. ": " .. (failure or "received") .. "\n")
  if failure == "bad_key" then
    break
  end
end
vim.fn.writefile({ vim.json.encode(report) }, output)
vim.cmd("qa!")
