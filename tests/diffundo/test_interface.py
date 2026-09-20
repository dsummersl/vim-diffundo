from unittest.mock import patch

import pytest
from diffundo import interface as interface_module
from diffundo.interface import VimInterface

from tests.fakevim import FakeVim, UndoHistory

from .fixtures import undotree


@pytest.fixture
def interface():
    return VimInterface()


@pytest.fixture
def opened(interface, vim):
    interface.open_split()
    return interface


def test_open_split_refuses_a_buffer_without_undo_history(interface, monkeypatch, capsys):
    vim = FakeVim(UndoHistory([[]]))
    monkeypatch.setattr(interface_module, "vim", vim)

    assert interface.open_split() is False
    assert capsys.readouterr().out.strip() == "No changes to view!"
    assert len(vim.windows) == 1
    assert "t:diffundo_diff_bn" not in vim.vars


def test_open_split_accepts_history_the_buffer_has_already_undone(interface, vim):
    vim.history.undo(0)

    assert interface.open_split() is True
    assert len(vim.windows) == 2
    assert vim.vars["t:diffundo_diff_undonr"] == "0"


def test_earlier_opens_the_split_itself(interface, vim):
    interface.earlier()

    assert vim.diff_buffer[:] == ["first", "second"]


def test_earlier_reports_a_buffer_without_undo_history(interface, monkeypatch, capsys):
    vim = FakeVim(UndoHistory([[]]))
    monkeypatch.setattr(interface_module, "vim", vim)

    interface.earlier()

    assert capsys.readouterr().out.strip() == "No changes to view!"
    assert "t:diffundo_diff_bn" not in vim.vars


def test_earlier_reopens_the_split_when_the_source_tab_variable_is_gone(opened, interface, vim):
    # WHY: a tab holding a stale t:diffundo_diff_bn used to raise E121 on the missing source.
    del vim.vars["t:diffundo_source_bn"]

    interface.earlier()

    assert vim.vars["t:diffundo_source_bn"] == str(vim.source_buffer.number)
    assert vim.diff_buffer[:] == ["first", "second"]


def test_earlier_reopens_the_split_when_the_diff_window_was_closed(opened, interface, vim):
    diff_bn = vim.vars["t:diffundo_diff_bn"]
    vim.close_window(vim.window_of_buffer(diff_bn))

    interface.earlier()

    assert vim.vars["t:diffundo_diff_bn"] != diff_bn
    assert vim.diff_buffer[:] == ["first", "second"]
    assert len(vim.windows) == 2


def test_earlier_reports_a_source_window_that_is_gone(opened, interface, vim, capsys):
    vim.close_window(vim.window_of_buffer(vim.source_buffer.number))
    vim.vars["t:diffundo_source_bn"] = str(vim.source_buffer.number)

    interface.earlier()

    assert "no longer open" in capsys.readouterr().out


def test_open_split_creates_a_scratch_buffer(opened, vim):
    assert len(vim.windows) == 2
    assert vim.vars["t:diffundo_source_bn"] == str(vim.source_buffer.number)
    assert vim.vars["t:diffundo_diff_bn"] != vim.vars["t:diffundo_source_bn"]
    assert vim.vars["t:diffundo_diff_undonr"] == "3"


def test_open_split_configures_the_scratch_buffer(opened, vim):
    options = vim.diff_buffer.options
    assert options["buftype"] == "nofile"
    assert options["bufhidden"] == "wipe"
    assert options["filetype"] == "python"
    assert "diff" in options
    assert "readonly" in options


def test_open_split_leaves_the_cursor_in_the_source_window(opened, vim):
    assert vim.current.buffer.number == vim.source_buffer.number


def test_open_split_is_idempotent(opened, interface, vim):
    diff_bn = vim.vars["t:diffundo_diff_bn"]
    windows = len(vim.windows)

    interface.open_split()

    assert vim.vars["t:diffundo_diff_bn"] == diff_bn
    assert len(vim.windows) == windows


def test_earlier_shows_the_previous_undo_state(opened, interface, vim):
    interface.earlier()

    assert vim.diff_buffer[:] == ["first", "second"]
    assert vim.vars["t:diffundo_diff_undonr"] == "2"


def test_earlier_accepts_a_count(opened, interface, vim):
    interface.earlier("2")

    assert vim.diff_buffer[:] == ["first"]
    assert vim.vars["t:diffundo_diff_undonr"] == "1"


def test_earlier_is_relative_to_the_last_diffed_state(opened, interface, vim):
    interface.earlier()
    interface.earlier()

    assert vim.diff_buffer[:] == ["first"]
    assert vim.vars["t:diffundo_diff_undonr"] == "1"


def test_later_walks_back_towards_the_newest_state(opened, interface, vim):
    interface.earlier("2")
    interface.later()

    assert vim.diff_buffer[:] == ["first", "second"]
    assert vim.vars["t:diffundo_diff_undonr"] == "2"


def test_earlier_restores_the_source_buffer(opened, interface, vim):
    interface.earlier("2")

    assert vim.history.seq == 3
    assert vim.source_buffer[:] == ["first", "second", "third"]
    assert vim.current.buffer.number == vim.source_buffer.number
    assert "diffupdate" in vim.commands


def test_earlier_names_the_diff_buffer_after_the_undo_entry(opened, interface, vim):
    interface.earlier()

    assert vim.diff_buffer.name.endswith("- 2")


def test_search_earlier_finds_the_undo_that_added_the_term(opened, interface, vim):
    interface.search_earlier("second")

    assert vim.diff_buffer[:] == ["first", "second"]
    assert vim.vars["t:diffundo_diff_undonr"] == "1"
    assert "/second" in vim.commands


def test_search_earlier_skips_states_without_the_term(opened, interface, vim):
    interface.search_earlier("first")

    assert vim.diff_buffer[:] == ["first"]
    assert vim.vars["t:diffundo_diff_undonr"] == "0"


def test_search_earlier_reports_when_nothing_matches(opened, interface, vim, capsys):
    interface.search_earlier("nonesuch")

    assert capsys.readouterr().out.strip() == "No match found"


def test_search_earlier_restores_the_source_buffer(opened, interface, vim):
    interface.search_earlier("nonesuch")

    assert vim.history.seq == 3
    assert vim.source_buffer[:] == ["first", "second", "third"]


def test_search_earlier_continues_from_the_previous_match(interface, monkeypatch):
    history = UndoHistory([[], ["a"], ["a", "x"], ["a", "x", "b"], ["a", "x", "b", "x"]])
    vim = FakeVim(history)
    monkeypatch.setattr(interface_module, "vim", vim)
    interface.open_split()

    interface.search_earlier("x")
    assert vim.diff_buffer[:] == ["a", "x", "b", "x"]

    interface.search_earlier("x")
    assert vim.diff_buffer[:] == ["a", "x"]


def test_match_in_lines():
    vi = VimInterface()
    assert vi._match_in_lines("needle", [], [" a needle"]) == " a needle"


def test_match_in_lines_no_removals():
    vi = VimInterface()
    assert not vi._match_in_lines("needle", [" a needle"], [])


def test_match_in_lines_ignores_unchanged_lines():
    vi = VimInterface()
    assert not vi._match_in_lines("needle", [" a needle"], [" a needle"])


def test_match_in_lines_returns_the_first_addition_only():
    vi = VimInterface()
    before = ["keep"]
    after = ["keep", "a needle here", "another needle"]
    assert vi._match_in_lines("needle", before, after) == "a needle here"


def test_find_undotree_entry(interface):
    with patch("diffundo.interface.vim") as vim_mock:
        vim_mock.eval.return_value = undotree.history

        assert interface._find_undotree_entry("14") == {
            "seq": "14",
            "time": "1627828780",
        }


def test_find_undotree_entry_of_the_original_state(interface):
    assert interface._find_undotree_entry("0") is None


@pytest.mark.xfail(reason="undotree() nests alternate branches under 'alt'", strict=True)
def test_find_undotree_entry_on_an_alternate_branch(interface):
    with patch("diffundo.interface.vim") as vim_mock:
        vim_mock.eval.return_value = undotree.history

        assert interface._find_undotree_entry("21")["save"] == "11"


def test_focus_window_of_buffer_reports_a_tab_without_the_split(interface, vim):
    with pytest.raises(interface_module.DiffundoError):
        interface._focus_window_of_buffer(False)


def test_open_split_returns_to_the_source_window_before_reopening(opened, interface, vim):
    vim.current.window = vim.window_of_buffer(vim.vars["t:diffundo_diff_bn"])
    del vim.vars["t:diffundo_diff_undonr"]

    interface.earlier()

    assert vim.vars["t:diffundo_source_bn"] == str(vim.source_buffer.number)
    assert vim.diff_buffer[:] == ["first", "second"]
