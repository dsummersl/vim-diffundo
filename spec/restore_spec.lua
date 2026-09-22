local fakevim = require("spec.fakevim")
local restore = require("diffundo.restore")
local split = require("diffundo.split")

local function history()
  return fakevim.history({ {}, { "first" }, { "first", "second" }, { "first", "second", "third" } })
end

describe("restore.within_source", function()
  it("runs the body with the source buffer current", function()
    local vim = fakevim.new(history())
    vim:install()
    split.open()

    local seen
    restore.within_source(function()
      seen = vim.history.seq
    end)

    assert.are.equal(3, seen)
  end)

  it("restores the live state and runs diffupdate afterwards", function()
    local vim = fakevim.new(history())
    vim:install()
    split.open()

    restore.within_source(function()
      vim.history:undo(1)
    end)

    assert.are.equal(3, vim.history.seq)
    assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
    assert.are.equal("diffupdate", vim.commands[#vim.commands])
  end)

  it("restores even when the body raises", function()
    local vim = fakevim.new(history())
    vim:install()
    split.open()

    assert.has_error(function()
      restore.within_source(function()
        error("boom", 0)
      end)
    end, "boom")
    assert.are.equal(3, vim.history.seq)
  end)

  it("acts on the current buffer when no split is open", function()
    local vim = fakevim.new(history())
    vim:install()

    restore.within_source(function()
      vim.history:undo(1)
    end)

    assert.are.equal(3, vim.history.seq)
    assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
  end)
end)
