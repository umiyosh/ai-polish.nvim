-- Minimal async HTTP POST over curl. Replaceable via `M.post` in tests.
local M = {}

local function write_private(path, content)
  local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
  vim.uv.fs_write(fd, content)
  vim.uv.fs_close(fd)
end

---@class AiPolishHttpResponse
---@field status integer HTTP status, 0 when the request never completed
---@field body string
---@field err? string transport-level error (timeout, curl failure)

---@param req { url: string, headers: table<string,string>, body: string, timeout_ms: integer }
---@param cb fun(res: AiPolishHttpResponse)
---@return { cancel: fun() }
function M.post(req, cb)
  -- Headers go through a 0600 temp file so the API key never shows up in `ps`.
  local header_file = vim.fn.tempname()
  local lines = {}
  for k, v in pairs(req.headers) do
    lines[#lines + 1] = k .. ": " .. v
  end
  write_private(header_file, table.concat(lines, "\n") .. "\n")

  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--max-time",
    tostring(math.ceil(req.timeout_ms / 1000)),
    "--request",
    "POST",
    "--header",
    "@" .. header_file,
    "--data-binary",
    "@-",
    "--write-out",
    "\n%{http_code}",
    req.url,
  }

  local cancelled = false
  local ok, proc = pcall(vim.system, cmd, { stdin = req.body, text = true }, function(out)
    os.remove(header_file)
    if cancelled then
      return
    end
    local stdout = out.stdout or ""
    local body, code = stdout:match("^(.*)\n(%d%d%d)$")
    local res
    if out.code ~= 0 then
      local msg = vim.trim(out.stderr or "")
      if out.code == 28 then
        msg = "request timed out"
      end
      res = { status = 0, body = stdout, err = msg ~= "" and msg or ("curl exited with " .. out.code) }
    else
      res = { status = tonumber(code) or 0, body = body or stdout }
    end
    vim.schedule(function()
      cb(res)
    end)
  end)

  if not ok then
    os.remove(header_file)
    vim.schedule(function()
      cb({ status = 0, body = "", err = "failed to run curl: " .. tostring(proc) })
    end)
    return { cancel = function() end }
  end

  return {
    cancel = function()
      cancelled = true
      pcall(function()
        proc:kill("sigterm")
      end)
    end,
  }
end

return M
