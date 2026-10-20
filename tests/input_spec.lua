---@module "luassert"

local input = require("anvim.input")

describe("input", function()
  it("labels models", function()
    assert.are.same("Opus 5.5", input.model_label("claude-opus-5-5"))
    assert.are.same("Sonnet 4.5", input.model_label("claude-sonnet-4-5-20250929"))
    assert.are.same("opus", input.model_label("opus"))
    assert.are.same("Claude", input.model_label(nil))
  end)
end)
