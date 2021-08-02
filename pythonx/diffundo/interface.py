from contextlib import contextmanager

import vim


@contextmanager
def within_source(interface):
    try:
        interface._focus_window_of_buffer(True)
        undonr = vim.eval("changenr()")

        yield

        interface._focus_window_of_buffer(True)
        vim.command(f"silent undo {undonr}")
        vim.command("diffupdate")
    finally:
        pass


class VimInterface:
    """An active 'diff' of the current buffer (one diff per tab)"""

    def __init__(self):
        if vim.eval("changenr()") == "0":
            print("No changes to view!")
        else:
            self.vert_diffs()

    def _undotree(self):
        return vim.eval("undotree()")

    def _early_late(self, command: str, count: str = "1"):
        with within_source(self):
            undonr = vim.eval("t:diffundo_diff_undonr")
            vim.command(f"silent undo {undonr}")
            vim.command(f"silent {command} {count}")
            undonr = vim.eval("changenr()")
            lines = vim.current.buffer[0 : len(vim.current.buffer)]

            self._focus_window_of_buffer(False)
            vim.command("setlocal noreadonly")
            vim.current.buffer[:] = lines
            vim.command("setlocal readonly")
            vim.command(f"let t:diffundo_diff_undonr={undonr}")

    def earlier(self, count: str = "1"):
        self._early_late("earlier", count)

    def later(self, count: str = "1"):
        self._early_late("later", count)

    def _focus_window_of_buffer(self, source: bool):
        window_var = "t:diffundo_source_bn" if source else "t:diffundo_diff_bn"
        vim.current.window = next(
            w for w in vim.windows if w.buffer.number == int(vim.eval(window_var))
        )

    def _new_buffer(self):
        # Set a string that says which undo this is, and its time.
        filetype = vim.eval("&filetype")
        vim.command("let t:diffundo_diff_undonr=changenr()")

        vim.command("enew")
        vim.command(f"let t:diffundo_diff_bn={vim.current.buffer.number}")
        vim.command(f"setlocal filetype={filetype}")
        vim.command("setlocal buftype=nofile")
        vim.command("setlocal bufhidden=wipe")
        vim.command("setlocal noswapfile")
        vim.command("setlocal diff")
        vim.command("setlocal scrollbind")
        vim.command("setlocal cursorbind")
        vim.command("setlocal foldmethod=diff")
        vim.command("setlocal readonly")

        self._focus_window_of_buffer(True)

    def vert_diffs(self):
        """Open a vertical diffsplit if one doesn't already exist."""
        try:
            if int(vim.eval(f"bufexists(t:diffundo_diff_bn)")):
                return
        except vim.error:
            # probably the t:diffundo_diff_bn isn't defined
            pass

        vim.command(f"let t:diffundo_source_bn={vim.current.buffer.number}")
        vim.command("vert diffsplit")

        self._new_buffer()
