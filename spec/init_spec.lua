local fresh = require
local fakevim = require("spec.fakevim")
local split = require("diffundo.split")

local diffundo

---@param commands string[]
---@return string|nil
local function after_last_undo(commands)
  local found
  for index, command in ipairs(commands) do
    if command:match("^silent undo ") then
      found = commands[index + 1]
    end
  end
  return found
end

local function three_states()
  return fakevim.history({ {}, { "first" }, { "first", "second" }, { "first", "second", "third" } })
end

describe("diffundo", function()
  local vim

  before_each(function()
    vim = fakevim.new(three_states())
    vim:install()
    package.loaded["diffundo"] = nil
    diffundo = fresh("diffundo")
  end)

  describe("earlier", function()
    it("opens the split itself", function()
      diffundo.earlier()

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
    end)

    it("reopens the split when the source tab variable is gone", function()
      split.open()
      vim.t.diffundo_source_bn = nil

      diffundo.earlier()

      assert.are.equal(vim.source_bn, vim.t.diffundo_source_bn)
      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
    end)

    it("reopens the split when the diff window was closed", function()
      split.open()
      local diff_bn = vim.t.diffundo_diff_bn
      vim:close_window(vim:window_of_buffer(diff_bn))

      diffundo.earlier()

      assert.are_not.equal(diff_bn, vim.t.diffundo_diff_bn)
      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
      assert.are.equal(3, #vim.win_order)
    end)

    it("shows the previous undo state", function()
      split.open()

      diffundo.earlier()

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
      assert.are.equal(2, vim.t.diffundo_diff_undonr)
    end)

    it("accepts a count", function()
      split.open()

      diffundo.earlier("2")

      assert.are.same({ "first" }, vim:diff_buffer().lines)
      assert.are.equal(1, vim.t.diffundo_diff_undonr)
    end)

    it("accepts a unit suffix", function()
      split.open()

      diffundo.earlier("2f")

      assert.are.same({ "first" }, vim:diff_buffer().lines)
    end)

    it("treats an empty count as one", function()
      split.open()

      diffundo.earlier("")

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
    end)

    it("is relative to the last diffed state", function()
      split.open()

      diffundo.earlier()
      diffundo.earlier()

      assert.are.same({ "first" }, vim:diff_buffer().lines)
      assert.are.equal(1, vim.t.diffundo_diff_undonr)
    end)

    it("restores the source buffer", function()
      split.open()

      diffundo.earlier("2")

      assert.are.equal(3, vim.history.seq)
      assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
      assert.are.equal(vim.source_bn, vim:current_buffer().number)
      assert.are.equal("diffupdate", after_last_undo(vim.commands))
    end)

    it("names the diff buffer after the undo entry without a label bar", function()
      split.open()

      diffundo.earlier()

      assert.matches("/#2$", vim:diff_buffer().name)
      assert.is_nil(vim:diff_window().options.statusline)
      assert.is_nil(vim:diff_window().options.winbar)
    end)
  end)

  describe("later", function()
    it("walks back towards the newest state", function()
      split.open()

      diffundo.earlier("2")
      diffundo.later()

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
      assert.are.equal(2, vim.t.diffundo_diff_undonr)
    end)
  end)

  describe("undo", function()
    it("jumps straight to the given undo number", function()
      diffundo.undo("1")

      assert.are.same({ "first" }, vim:diff_buffer().lines)
      assert.are.equal(1, vim.t.diffundo_diff_undonr)
      assert.are.equal(3, vim.history.seq)
      assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
    end)

    it("opens the split itself", function()
      diffundo.undo("2")

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
    end)

    it("rejects a unit suffix", function()
      assert.has_error(function()
        diffundo.undo("2f")
      end, "invalid undo number: 2f (expected a plain number)")
      assert.is_nil(vim.t.diffundo_diff_bn)
    end)

    it("rejects a missing number", function()
      assert.has_error(function()
        diffundo.undo("")
      end, "invalid undo number:  (expected a plain number)")
    end)
  end)

  describe("close", function()
    it("closes the diff split", function()
      split.open()

      diffundo.close()

      assert.is_false(split.is_open())
    end)

    it("is a no-op when nothing is open", function()
      diffundo.close()

      assert.is_false(split.is_open())
    end)
  end)

  describe("earlier errors", function()
    it("raises an invalid count", function()
      assert.has_error(function()
        diffundo.earlier("1w")
      end, "invalid count: 1w (expected a number, optionally followed by s, m, h, d or f)")
      assert.is_nil(vim.t.diffundo_diff_bn)
    end)

    it("raises a vim error and restores the source buffer", function()
      split.open()
      vim.history.earlier = function()
        error("Vim(earlier):E475: Invalid argument", 0)
      end

      assert.has_error(function()
        diffundo.earlier()
      end, "Vim(earlier):E475: Invalid argument")
      assert.are.equal(3, vim.history.seq)
      assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
    end)

    it("raises when the source window is gone", function()
      split.open()
      vim:close_window(vim:window_of_buffer(vim.source_bn))
      vim.t.diffundo_source_bn = vim.source_bn

      assert.has_error(function()
        diffundo.earlier()
      end, "The diffundo source window is no longer open in this tab.")
    end)

    it("diffs a buffer without undo history against #0", function()
      vim = fakevim.new(fakevim.history({ {} }))
      vim:install()

      diffundo.earlier()

      assert.are.equal(0, vim.t.diffundo_diff_undonr)
      assert.are.same({ "@                                   #0" }, vim:pane_lines())
    end)
  end)

  describe("cursor neutrality", function()
    it("leaves the window and cursor where they were", function()
      vim.windows[vim.current_win].cursor = { 3, 1 }
      local win = vim.current_win

      diffundo.earlier()
      diffundo.search("second")

      assert.are.equal(win, vim.current_win)
      assert.are.same({ 3, 1 }, vim.windows[win].cursor)
    end)

    it("restores the window even when the body raises", function()
      split.open()
      local win = vim.current_win
      vim.history.earlier = function()
        error("Vim(earlier):E475: Invalid argument", 0)
      end

      pcall(diffundo.earlier)

      assert.are.equal(win, vim.current_win)
    end)
  end)

  describe("search", function()
    it("shows the state whose edit added the line", function()
      split.open()

      local hit = diffundo.search("second")

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
      assert.are.equal(2, vim.t.diffundo_diff_undonr)
      assert.are.same(
        { seq = 2, time = vim.history.entries[2].time, line = "second", col = 0, lnum = 2 },
        hit
      )
    end)

    it("opens the split itself and considers the live state first", function()
      local hit = assert(diffundo.search("third"))

      assert.are.equal(3, hit.seq)
      assert.are.same({ "first", "second", "third" }, vim:diff_buffer().lines)
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
    end)

    it("starts behind the displayed state when the split is already open", function()
      split.open()

      assert.is_nil(diffundo.search("third"))
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
    end)

    it("skips states that did not add the line", function()
      split.open()

      local hit = assert(diffundo.search("first"))

      assert.are.equal(1, hit.seq)
      assert.are.same({ "first" }, vim:diff_buffer().lines)
    end)

    it("returns nil and leaves the split alone when nothing matches", function()
      split.open()

      assert.is_nil(diffundo.search("nonesuch"))
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
      assert.are.same({ "first", "second", "third" }, vim:diff_buffer().lines)
    end)

    it("restores the source buffer", function()
      split.open()

      diffundo.search("nonesuch")

      assert.are.equal(3, vim.history.seq)
      assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
      assert.are.equal("diffupdate", after_last_undo(vim.commands))
    end)

    it("continues from the previous match", function()
      vim = fakevim.new(
        fakevim.history({ {}, { "a" }, { "a", "x" }, { "a", "x", "b" }, { "a", "x", "b", "x" } })
      )
      vim:install()

      assert.are.equal(4, assert(diffundo.search("x")).seq)
      assert.are.equal(2, assert(diffundo.search("x")).seq)
      assert.is_nil(diffundo.search("x"))
    end)

    it("finds removals with opts.removed", function()
      vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a" } }))
      vim:install()

      local hit = diffundo.search("b", { removed = true })

      assert.are.same(
        { seq = 3, time = vim.history.entries[3].time, line = "b", col = 0, lnum = 2 },
        hit
      )
      assert.are.same({ "a" }, vim:diff_buffer().lines)
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
    end)

    it("does not report a branch switch as a removal", function()
      vim.history:branch(1, { "first", "other" })

      assert.is_nil(diffundo.search("second", { removed = true }))
    end)

    it("reports the match column", function()
      vim = fakevim.new(fakevim.history({ {}, { "xx needle" } }))
      vim:install()

      assert.are.equal(3, assert(diffundo.search("needle")).col)
    end)

    it("returns nil for a buffer without undo history", function()
      vim = fakevim.new(fakevim.history({ {} }))
      vim:install()

      assert.is_nil(diffundo.search("x"))
      assert.are.equal(0, vim.t.diffundo_diff_undonr)
    end)

    it("compiles the pattern before touching anything", function()
      vim.regex = function()
        error("Vim:E54: Unmatched \\(", 0)
      end

      assert.has_error(function()
        diffundo.search("\\(")
      end, "Vim:E54: Unmatched \\(")
      assert.is_nil(vim.t.diffundo_diff_bn)
      assert.are.same({}, vim.commands)
    end)
  end)

  describe("command", function()
    it("dispatches earlier with its count", function()
      diffundo.command("earlier 2")

      assert.are.same({ "first" }, vim:diff_buffer().lines)
      assert.are.equal(1, vim.t.diffundo_diff_undonr)
    end)

    it("dispatches later", function()
      diffundo.command("earlier 2")
      diffundo.command("later")

      assert.are.equal(2, vim.t.diffundo_diff_undonr)
    end)

    it("dispatches undo with the given number", function()
      diffundo.command("undo 2")

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
      assert.are.equal(2, vim.t.diffundo_diff_undonr)
    end)

    it("requires a number for undo", function()
      diffundo.command("undo")

      assert.are.equal("diffundo: undo needs a number", vim:last_notification())
      assert.is_nil(vim.t.diffundo_diff_bn)
    end)

    it("dispatches close", function()
      diffundo.command("earlier")

      diffundo.command("close")

      assert.is_false(split.is_open())
    end)

    it("reports an unknown subcommand", function()
      diffundo.command("nonesuch 1")

      assert.are.equal(
        'diffundo: unknown subcommand "nonesuch" (earlier, later, undo, search, search!, focus, close)',
        vim:last_notification()
      )
    end)

    it("reports a missing subcommand", function()
      diffundo.command("")

      assert.matches('unknown subcommand ""', vim:last_notification())
    end)

    it("reports an invalid count", function()
      diffundo.command("earlier 1w")

      assert.matches("^diffundo: invalid count: 1w", vim:last_notification())
    end)

    it("reports a vim error", function()
      split.open()
      vim.history.earlier = function()
        error("Vim(earlier):E475: Invalid argument", 0)
      end

      diffundo.command("earlier")

      assert.are.equal("diffundo: Vim(earlier):E475: Invalid argument", vim:last_notification())
    end)

    it("requires a pattern for search", function()
      diffundo.command("search")

      assert.are.equal("diffundo: search needs a pattern", vim:last_notification())
      assert.is_nil(vim.t.diffundo_diff_bn)
    end)

    it("moves the source cursor onto the match", function()
      vim = fakevim.new(
        fakevim.history({ {}, { "a" }, { "a", "xx needle" }, { "a", "xx needle", "b" } })
      )
      vim:install()

      diffundo.command("search needle")
      diffundo.command("history")

      local source_win = vim:window_of_buffer(vim.source_bn)
      assert.are.equal(source_win, vim.current_win)
      assert.are.same({ 2, 3 }, vim.windows[source_win].cursor)
    end)

    it("falls back to the old line number when the line is gone", function()
      vim = fakevim.new(fakevim.history({ {}, { "a" }, { "a", "b" }, { "a" } }))
      vim:install()

      diffundo.command("search! b")

      assert.are.same({ 1, 0 }, vim.windows[vim:window_of_buffer(vim.source_bn)].cursor)
      assert.are.equal(3, vim.t.diffundo_diff_undonr)
    end)

    it("reports no match for additions and removals", function()
      diffundo.command("search nonesuch")
      assert.are.equal("diffundo: no state adds a line matching nonesuch", vim:last_notification())

      diffundo.command("search! nonesuch")
      assert.are.equal(
        "diffundo: no state removes a line matching nonesuch",
        vim:last_notification()
      )
    end)

    it("reports no match once for a buffer without undo history", function()
      vim = fakevim.new(fakevim.history({ {} }))
      vim:install()

      diffundo.command("search x")

      assert.are.same({ "diffundo: no state adds a line matching x" }, vim.notifications)
    end)
  end)

  describe("repeat_last", function()
    it("does nothing before any command ran", function()
      diffundo.repeat_last()

      assert.are.equal(0, #vim.commands)
    end)

    it("replays the last command with its arguments", function()
      diffundo.command("earlier 1")
      diffundo.repeat_last()

      assert.are.same({ "first" }, vim:diff_buffer().lines)
      assert.are.equal(1, vim.t.diffundo_diff_undonr)
    end)

    it("registers with vim-repeat when it is installed", function()
      local registered = {}
      vim.fn["repeat#set"] = function(keys)
        table.insert(registered, keys)
      end

      diffundo.command("search second")

      assert.are.same({ "<Plug>(DiffundoRepeat)" }, registered)
    end)

    it("registers with vim-repeat again on every repeat", function()
      local registered = 0
      vim.fn["repeat#set"] = function()
        registered = registered + 1
      end

      diffundo.command("earlier 1")
      diffundo.repeat_last()

      assert.are.equal(2, registered)
    end)
  end)
end)

describe("the history pane from commands", function()
  local vim

  before_each(function()
    vim = fakevim.new(
      fakevim.history({ {}, { "first" }, { "first", "second" }, { "first", "second", "third" } })
    )
    vim:install()
  end)

  it("opens collapsed after earlier and leaves the cursor in the source", function()
    local source = vim.current_win

    diffundo.command("earlier")

    assert.are.equal(2, vim.t.diffundo_diff_undonr)
    assert.are.equal(source, vim.current_win)
    assert.are.same({
      "@ + third                           #3",
      "╷ + second                          #2",
      "┆   1 undo",
    }, vim:pane_lines())
  end)

  it("follows each earlier so . can keep walking back", function()
    diffundo.command("earlier")
    diffundo.repeat_last()

    assert.are.same({
      "@ + third                           #3",
      "┆   1 undo",
      "╷ + first                           #1",
    }, vim:pane_lines())
  end)

  it("search narrows the pane to the matching states and footers the filter", function()
    diffundo.command("search second")

    assert.are.same({
      "┆   1 undo",
      "╷ + second                          #2",
      "┆   1 undo",
    }, vim:pane_lines())
    local config = vim.windows[vim:pane_window()].config
    assert.are.equal(" filter: second ", config.footer)
  end)

  it("search! footers the removed-line filter and earlier clears it", function()
    diffundo.command("search! nonesuch")
    assert.are.equal(" filter!: nonesuch ", vim.windows[vim:pane_window()].config.footer)

    diffundo.command("earlier")

    assert.are.equal(" +1 -0 lines ", vim.windows[vim:pane_window()].config.footer)
    assert.are.equal(3, #vim:pane_lines())
  end)

  it("stays closed when g:diffundo_history is false", function()
    vim.g.diffundo_history = false

    diffundo.command("search first")

    assert.are.equal(1, vim.t.diffundo_diff_undonr)
    assert.is_nil(vim:pane_window())
  end)

  it("focus opens the split at the buffer's state and enters the expanded pane", function()
    diffundo.command("focus")

    assert.are.equal(3, vim.t.diffundo_diff_undonr)
    assert.are.same({ "first", "second", "third" }, vim:diff_buffer().lines)
    assert.are.equal(vim:pane_window(), vim.current_win)
    assert.are.equal(4, #vim:pane_lines())
  end)
end)
