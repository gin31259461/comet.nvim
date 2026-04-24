local config = require("comet.config")

describe("comet.config", function()
  before_each(function()
    -- Reset to pristine defaults before each test
    config.setup({})
  end)

  it("has sensible defaults", function()
    local cfg = config.resolve()
    assert.are.equal("Comet", cfg.session_id)
    assert.is_false(cfg.insert_mode)
    assert.is_true(cfg.remember_page)
  end)

  it("merges user options in global setup", function()
    config.setup({
      insert_mode = true,
      session_id = "Global Tasks",
    })

    local cfg = config.resolve()
    assert.is_true(cfg.insert_mode)
    assert.are.equal("Global Tasks", cfg.session_id)
    assert.is_true(cfg.remember_page) -- Keeps default
  end)

  it("overrides global defaults when local opts are passed to open()", function()
    -- Global setup
    config.setup({
      insert_mode = true,
      session_id = "Global Tasks",
    })

    -- Local override (simulating what happens inside M.open(commands, opts))
    local cfg = config.resolve({ session_id = "Local Override", remember_page = false })

    assert.is_true(cfg.insert_mode) -- Falls back to global setup
    assert.are.equal("Local Override", cfg.session_id) -- Overridden by local opts
    assert.is_false(cfg.remember_page) -- Overridden by local opts
  end)
end)
