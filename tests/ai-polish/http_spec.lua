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
