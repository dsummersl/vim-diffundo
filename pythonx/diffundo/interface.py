from contextlib import contextmanager
import difflib
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

    def _find_undotree_entry(self, undonr: str):
        if undonr == "0":
            return None

        undotree = vim.eval("undotree()")
        return next(e for e in undotree["entries"] if e["seq"] == undonr)

    def _update_buffer_name(self, entry):
        if entry is None:
            vim.command("file {original} - 0")
            return

        time_description = time.strftime('%Y-%m-%d %I:%M:%S %p', time.localtime(float(entry["time"])))
        vim.command(f"file {time_description} - {entry['seq']}")

    def _place_changenr(self, lines, undonr):
        entry = self._find_undotree_entry(undonr)
        self._focus_window_of_buffer(False)
        vim.command("setlocal noreadonly")
        vim.current.buffer[:] = lines
        vim.command("setlocal readonly")
        vim.command(f"let t:diffundo_diff_undonr={undonr}")
        self._update_buffer_name(entry)

    def _early_late(self, command: str, count: str = "1"):
        with within_source(self):
            undonr = vim.eval("t:diffundo_diff_undonr")
            vim.command(f"silent undo {undonr}")
            vim.command(f"silent {command} {count}")
            undonr = vim.eval("changenr()")
            lines = vim.current.buffer[:]

            self._place_changenr(lines, undonr)

    def _match_in_lines(self, search_term: str, before_lines: list, after_lines: list):
        additions = [line[2:] for line in difflib.ndiff(before_lines, after_lines) if line.startswith('+')]

        matches = (line for line in additions if search_term in line)

        return next(matches, False)

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

    def earlier(self, count: str = "1"):
        self._early_late("earlier", count)

    def later(self, count: str = "1"):
        self._early_late("later", count)

    def search_earlier(self, search_term: str):
        """ Find the next undo that added 'search_term'. """
        with within_source(self):
            next_undonr = vim.eval("t:diffundo_diff_undonr")
            vim.command(f"silent undo {next_undonr}")
            next_lines = vim.current.buffer[:]

            found_match = False
            while int(next_undonr) > 0 and not found_match:
                vim.command("silent earlier")
                before_lines = vim.current.buffer[:]
                before_undonr = vim.eval("changenr()")
                found_match = self._match_in_lines(search_term, before_lines, next_lines)

                if found_match:
                    self._place_changenr(next_lines, next_undonr)
                    vim.command(f"let t:diffundo_diff_undonr={before_undonr}")
                    vim.command(f"/{found_match}")
                    return

                next_lines = before_lines
                next_undonr = before_undonr

            print("No match found")

    def open_split(self):
        """Open a vertical diffsplit if one doesn't already exist."""
        if vim.eval("changenr()") == "0":
            print("No changes to view!")
            return

        try:
            if int(vim.eval(f"bufexists(t:diffundo_diff_bn)")):
                return
        except vim.error:
            # probably the t:diffundo_diff_bn isn't defined
            pass

        vim.command(f"let t:diffundo_source_bn={vim.current.buffer.number}")
        vim.command("vert diffsplit")

        self._new_buffer()
