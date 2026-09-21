describe("zeddit", function()
  it("exposes setup and accept", function()
    local zeddit = require("zeddit")
    assert.is_function(zeddit.setup)
    assert.is_function(zeddit.accept)
    assert.is_function(zeddit.has)
    assert.is_function(zeddit.configure)
  end)

  it("applies defaults without a local model path", function()
    local zeddit = require("zeddit")
    zeddit.setup({
      provider_url = "http://localhost:8000",
      provider_model = "zeta-2.1",
      notify_errors = false,
    })
    assert.equals("http://localhost:8000", zeddit.get("provider_url"))
    assert.equals("zeta-2.1", zeddit.get("provider_model"))
    assert.is_nil(zeddit.get("api_key"))
  end)
end)
