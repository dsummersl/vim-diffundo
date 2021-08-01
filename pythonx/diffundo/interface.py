import vim


class VimInterface:
    """An active 'diff' of the current buffer (one diff per tab)"""

    def __init__(self, count: str = "1"):
        self.vert_diffs()
        self.earlier(count)

    def _undotree(self):
        return vim.eval("undotree()")

    def earlier(self, count: str = "1"):
        undonr = vim.eval("changenr()")
        # vim.command(f"earlier {count}")

    def later(self, count: str = "1"):
        vim.command(f"later {count}")

    def _focus_window(self, source=True):
        window_var = "t:diffundo_source_bn" if source else "t:diffundo_diff_bn"
        vim.current.window = next(
            w for w in vim.windows if w.buffer.number == int(vim.eval(window_var))
        )

    def _new_buffer(self):
        # Set a string that says which undo this is, and its time.
        vim.command("enew")
        vim.command(f"let t:diffundo_diff_bn={vim.current.buffer.number}")
        vim.command("setlocal buftype=nofile")
        vim.command("setlocal bufhidden=wipe")
        vim.command("setlocal noswapfile")
        vim.command("setlocal readonly")

        self._focus_window()

    def vert_diffs(self):
        """Open a vertical diffsplit if one doesn't already exist."""
        try:
            if int(vim.eval(f"bufexists(t:diffundo_diff_bn)")):
                return
        except vim.error:
            # probably the t:diffundo_diff_bn isn't defined
            pass

        # TODO if there is already a scratch buffer open, then don't allow this
        # to be called again.
        vim.command(f"let t:diffundo_source_bn={vim.current.buffer.number}")
        vim.command("vert diffsplit")

        self._new_buffer()
