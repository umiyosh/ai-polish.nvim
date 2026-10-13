local http = require("ai-polish.http")
describe("private HTTP transport", function()
  local system, done, path, killed, called
  before_each(function()
    system, killed, called = vim.system, false, false
    vim.system = function(cmd, opts, callback)
      assert.is_nil(table.concat(cmd, " "):find("secret-test-key", 1, true))
      assert.equals("private text", opts.stdin)
      for i, arg in ipairs(cmd) do
        if arg == "--header" then
          path = cmd[i + 1]:sub(2)
        end
      end
      assert.equals(384, vim.uv.fs_stat(path).mode % 512)
      done = callback
      return {
        kill = function()
          killed = true
        end,
      }
    end
  end)
  after_each(function()
    vim.system = system
  end)
  local function start()
    return http.post({
      url = "https://example.invalid",
      headers = { Authorization = "Bearer secret-test-key" },
      body = "private text",
      timeout_ms = 1000,
    }, function()
      called = true
    end)
  end
  it("removes key material immediately on cancellation and suppresses late completion", function()
    local request = start()
    request.cancel()
    assert.is_true(killed)
    assert.is_nil(vim.uv.fs_stat(path))
    done({ code = 0, stdout = "{}\n200" })
    vim.wait(10, function()
      return called
    end)
    assert.is_false(called)
  end)
  it("does not dispatch a completion queued before cancellation", function()
    local request = start()
    done({ code = 0, stdout = "{}\n200" })
    request.cancel()
    vim.wait(10, function()
      return called
    end)
    assert.is_false(called)
    assert.is_nil(vim.uv.fs_stat(path))
  end)
  it("cleans up after success", function()
    start()
    done({ code = 0, stdout = "{}\n200" })
    assert.is_true(vim.wait(100, function()
      return called
    end))
    assert.is_nil(vim.uv.fs_stat(path))
  end)
end)

describe("streaming HTTP transport", function()
  local system, opts_seen, cmd_seen, done
  before_each(function()
    system = vim.system
    vim.system = function(cmd, opts, callback)
      cmd_seen, opts_seen, done = cmd, opts, callback
      return { kill = function() end }
    end
  end)
  after_each(function()
    vim.system = system
  end)

  it("hands over stdout as it arrives and reports the status at the end", function()
    local chunks, res = {}, nil
    http.stream({ url = "https://example.invalid", headers = {}, body = "b", timeout_ms = 1000 }, function(c)
      chunks[#chunks + 1] = c
    end, function(r)
      res = r
    end)
    assert.truthy(vim.tbl_contains(cmd_seen, "--no-buffer"))
    opts_seen.stdout(nil, "data: {}\n\n")
    opts_seen.stdout(nil, "data: {}\n\n\n200")
    done({ code = 0 })
    assert.is_true(vim.wait(100, function()
      return res ~= nil
    end))
    assert.same({ "data: {}\n\n", "data: {}\n\n\n200" }, chunks)
    assert.equals(200, res.status)
    assert.equals("data: {}\n\ndata: {}\n\n", res.body)
  end)

  it("stops handing over chunks once cancelled", function()
    local chunks = {}
    local req = http.stream(
      { url = "https://example.invalid", headers = {}, body = "b", timeout_ms = 1000 },
      function(c)
        chunks[#chunks + 1] = c
      end,
      function() end
    )
    opts_seen.stdout(nil, "data: {}\n\n")
    req.cancel()
    vim.wait(20)
    assert.same({}, chunks)
  end)
end)
