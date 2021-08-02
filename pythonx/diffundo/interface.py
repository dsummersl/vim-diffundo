from contextlib import contextmanager
import time

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

    def _find_undotree_entry(self, undonr: str):
        if undonr == "0":
            return None

        undotree = vim.eval("undotree()")
        return next(e for e in undotree["entries"] if e["seq"] == undonr)

    def _update_buffer_name(self, entry):
        if entry is None:
            vim.command("file 0 - ")
            return

        time_description = time.strftime('%Y-%m-%d %I:%M:%S %p', time.localtime(float(entry["time"])))
        vim.command(f"file {entry['seq']} - {time_description}")

    def _early_late(self, command: str, count: str = "1"):
        with within_source(self):
            undonr = vim.eval("t:diffundo_diff_undonr")
            vim.command(f"silent undo {undonr}")
            vim.command(f"silent {command} {count}")
            undonr = vim.eval("changenr()")
            entry = self._find_undotree_entry(undonr)
            lines = vim.current.buffer[0 : len(vim.current.buffer)]

            self._focus_window_of_buffer(False)
            vim.command("setlocal noreadonly")
            vim.current.buffer[:] = lines
            vim.command("setlocal readonly")
            vim.command(f"let t:diffundo_diff_undonr={undonr}")
            self._update_buffer_name(entry)

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
        undonr = vim.eval("changenr()")
        vim.command(f"let t:diffundo_diff_undonr={undonr}")
        entry = self._find_undotree_entry(undonr)

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
        self._update_buffer_name(entry)

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
