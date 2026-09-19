"""Make ``import vim`` work outside of vim.

``pythonx/diffundo/interface.py`` imports ``vim`` at module scope, which only
exists inside a vim process.  Register a placeholder module before the test
modules are imported; individual tests then patch
``pythonx.diffundo.interface.vim`` with a :class:`tests.fakevim.FakeVim`.
"""
import sys
import types

import pytest

from tests.fakevim import FakeError, FakeVim, UndoHistory

if "vim" not in sys.modules:
    stub = types.ModuleType("vim")
    stub.error = FakeError
    sys.modules["vim"] = stub


@pytest.fixture
def history():
    """Four undo states; each one appends a line."""
    return UndoHistory(
        [
            [],
            ["first"],
            ["first", "second"],
            ["first", "second", "third"],
        ]
    )


@pytest.fixture
def vim(history, monkeypatch):
    from pythonx.diffundo import interface

    fake = FakeVim(history)
    monkeypatch.setattr(interface, "vim", fake)
    return fake
