local fakevim = require("spec.fakevim")
local pattern = require("diffundo.pattern")

describe("pattern.compile", function()
  local vim

  before_each(function()
    vim = fakevim.new(fakevim.history({ {} }))
    vim:install()
  end)

  local function capture(compile_this)
    local given
    vim.regex = function(p)
      given = p
      return {
        match_str = function()
          return 0, 1
        end,
      }
    end
    pattern.compile(compile_this)
    return given
  end

  it("forces case sensitivity when ignorecase is off", function()
    assert.are.equal("\\Cfoo", capture("foo"))
  end)

  it("forces case sensitivity for a smartcase uppercase pattern", function()
    vim.o.ignorecase = true
    vim.o.smartcase = true

    assert.are.equal("\\CFoo", capture("Foo"))
  end)

  it("celebrates a lowercase pattern under smartcase", function()
    vim.o.ignorecase = true
    vim.o.smartcase = true

    assert.are.equal("\\cfoo", capture("foo"))
  end)
end)
