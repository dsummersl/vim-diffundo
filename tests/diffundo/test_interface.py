from unittest.mock import patch

from pythonx.diffundo.interface import VimInterface
from .fixtures import undotree


@patch('pythonx.diffundo.interface.vim')
def test_open_split_already_open(vim_mock):
    vim_mock.eval.return_value = "0"
    
    vi = VimInterface()
    vi.open_split()

    assert vim_mock.eval.called_with("changenr()")


def test_match_in_lines():
    vi = VimInterface()
    assert vi._match_in_lines("needle", [], [" a needle"])

def test_match_in_lines_no_removals():
    vi = VimInterface()
    assert not vi._match_in_lines("needle", [" a needle"], [])
