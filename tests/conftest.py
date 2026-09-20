import pytest
from diffundo import interface

from tests.fakevim import FakeVim, UndoHistory


@pytest.fixture
def history():
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
    fake = FakeVim(history)
    monkeypatch.setattr(interface, "vim", fake)
    return fake
