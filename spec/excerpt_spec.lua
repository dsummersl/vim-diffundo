local excerpt = require("diffundo.excerpt")

describe("excerpt.changed", function()
  local function hls(marks)
    local result = {}
    for _, mark in ipairs(marks) do
      result[#result + 1] = mark.hl
    end
    return result
  end

  it("shows the changed word between its neighbours", function()
    local text, marks = excerpt.changed("one two three four five", "one two 3 four five", "…")

    assert.are.equal("…two ~3~ four…", text)
    assert.are.same({ "DiffChange", "DiffText", "DiffChange" }, hls(marks))
    assert.are.equal("…two ~", text:sub(1, marks[1].to))
    assert.are.equal("3", text:sub(marks[2].from + 1, marks[2].to))
    assert.are.equal("~ four…", text:sub(marks[3].from + 1, marks[3].to))
  end)

  it("widens a change inside a word to the whole word", function()
    assert.are.equal(
      "…two ~thr3e~ four…",
      excerpt.changed("one two three four five", "one two thr3e four five", "…")
    )
  end)

  it("drops the ellipsis when the neighbour is the line's edge", function()
    assert.are.equal("~3~ two", excerpt.changed("one two", "3 two", "…"))
    assert.are.equal("one ~3~", excerpt.changed("one two", "one 3", "…"))
    assert.are.equal("~bar()~", excerpt.changed("    foo()", "    bar()", "…"))
  end)

  it("shows the whole line when nothing is shared", function()
    assert.are.equal("~hello~", excerpt.changed("", "hello", "…"))
    assert.are.equal("~06~", excerpt.changed("SIX", "06", "…"))
  end)

  it("shows removed text colored DiffDelete when nothing was added", function()
    local text, marks = excerpt.changed("one two three", "one three", "…")

    assert.are.equal("one ~two ~three", text)
    assert.are.equal("DiffDelete", marks[2].hl)
    assert.are.equal("two ", text:sub(marks[2].from + 1, marks[2].to))
  end)

  it("keeps multibyte characters whole", function()
    assert.are.equal("a ~ê~ b", excerpt.changed("a é b", "a ê b", "…"))
  end)
end)
