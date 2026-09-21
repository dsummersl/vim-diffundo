local diffundo = require("diffundo")
local fakevim = require("spec.fakevim")
local split = require("diffundo.split")

local function three_states()
  return fakevim.history({ {}, { "first" }, { "first", "second" }, { "first", "second", "third" } })
end

describe("diffundo", function()
  local vim

  before_each(function()
    vim = fakevim.new(three_states())
    vim:install()
  end)

  describe("earlier", function()
    it("opens the split itself", function()
      diffundo.earlier()

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
    end)

    it("reports a buffer without undo history", function()
      vim = fakevim.new(fakevim.history({ {} }))
      vim:install()

      diffundo.earlier()

      assert.are.equal("No changes to view!", vim:last_notification())
      assert.is_nil(vim.t.diffundo_diff_bn)
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
      assert.are.equal(2, #vim.win_order)
    end)

    it("reports a source window that is gone", function()
      split.open()
      vim:close_window(vim:window_of_buffer(vim.source_bn))
      vim.t.diffundo_source_bn = vim.source_bn

      diffundo.earlier()

      assert.matches("no longer open", vim:last_notification())
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

    it("reports an invalid count", function()
      diffundo.earlier("1w")

      assert.matches("invalid count: 1w", vim:last_notification())
      assert.is_nil(vim.t.diffundo_diff_bn)
    end)

    it("treats an empty count as one", function()
      split.open()

      diffundo.earlier("")

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
    end)

    it("reports a vim error", function()
      split.open()
      vim.history.earlier = function()
        error("Vim(earlier):E475: Invalid argument", 0)
      end

      diffundo.earlier()

      assert.matches("E475", vim:last_notification())
    end)

    it("restores the source buffer when the undo fails", function()
      split.open()
      vim.history.earlier = function()
        error("Vim(earlier):E475: Invalid argument", 0)
      end

      diffundo.earlier()

      assert.are.equal(3, vim.history.seq)
      assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
      assert.are.equal(vim.source_bn, vim:current_buffer().number)
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
      assert.are.same("diffupdate", vim.commands[#vim.commands])
    end)

    it("names and labels the diff buffer after the undo entry", function()
      split.open()

      diffundo.earlier()

      local name = vim:diff_buffer().name
      assert.matches("%- 2$", name)
      assert.are.equal(name, vim:diff_window().options.statusline)
      assert.are.equal(name, vim:diff_window().options.winbar)
    end)
  end)

  describe("later", function()
    it("reports an invalid count", function()
      diffundo.later("-3")

      assert.matches("invalid count: %-3", vim:last_notification())
      assert.is_nil(vim.t.diffundo_diff_bn)
    end)

    it("walks back towards the newest state", function()
      split.open()

      diffundo.earlier("2")
      diffundo.later()

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
      assert.are.equal(2, vim.t.diffundo_diff_undonr)
    end)
  end)

  describe("search_earlier", function()
    it("finds the undo that added the term", function()
      split.open()

      diffundo.search_earlier("second")

      assert.are.same({ "first", "second" }, vim:diff_buffer().lines)
      assert.are.equal(1, vim.t.diffundo_diff_undonr)
      assert.are.same({ "\\Vsecond" }, vim.searches)
    end)

    it("skips states without the term", function()
      split.open()

      diffundo.search_earlier("first")

      assert.are.same({ "first" }, vim:diff_buffer().lines)
      assert.are.equal(0, vim.t.diffundo_diff_undonr)
    end)

    it("reports when nothing matches", function()
      split.open()

      diffundo.search_earlier("nonesuch")

      assert.are.equal("No match found", vim:last_notification())
    end)

    it("restores the source buffer", function()
      split.open()

      diffundo.search_earlier("nonesuch")

      assert.are.equal(3, vim.history.seq)
      assert.are.same({ "first", "second", "third" }, vim:source_buffer().lines)
    end)

    it("continues from the previous match", function()
      vim = fakevim.new(
        fakevim.history({ {}, { "a" }, { "a", "x" }, { "a", "x", "b" }, { "a", "x", "b", "x" } })
      )
      vim:install()
      split.open()

      diffundo.search_earlier("x")
      assert.are.same({ "a", "x", "b", "x" }, vim:diff_buffer().lines)

      diffundo.search_earlier("x")
      assert.are.same({ "a", "x" }, vim:diff_buffer().lines)
    end)
  end)

  describe("repeat_last", function()
    it("does nothing before any command ran", function()
      diffundo.repeat_last()

      assert.are.equal(0, #vim.commands)
    end)

    it("replays the last command with its argument", function()
      diffundo.command_earlier("1")
      diffundo.repeat_last()

      assert.are.same({ "first" }, vim:diff_buffer().lines)
      assert.are.equal(1, vim.t.diffundo_diff_undonr)
    end)

    it("registers with vim-repeat when it is installed", function()
      local registered = {}
      vim.fn["repeat#set"] = function(keys)
        table.insert(registered, keys)
      end

      diffundo.command_search("second")

      assert.are.same({ "<Plug>(DiffundoRepeat)" }, registered)
    end)

    it("registers with vim-repeat again on every repeat", function()
      local registered = 0
      vim.fn["repeat#set"] = function()
        registered = registered + 1
      end

      diffundo.command_earlier("1")
      diffundo.repeat_last()

      assert.are.equal(2, registered)
    end)
  end)
end)
