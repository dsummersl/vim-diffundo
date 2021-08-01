from unittest.mock import patch

from pythonx.diffundo.interface import VimInterface


@patch('pythonx.diffundo.interface.vim')
@patch('pythonx.diffundo.interface.VimInterface._new_buffer')
def test_vert_diffs(new_buffer_mock, vim_mock):
    vi = VimInterface()
    vi.vert_diffs()

    assert vim_mock.called_with("vert diffs")
    assert new_buffer_mock.called
