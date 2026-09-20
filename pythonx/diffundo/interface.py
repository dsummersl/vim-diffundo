from __future__ import annotations

import difflib
import re
import time
from contextlib import contextmanager
from typing import Any, Dict, Iterator

import vim

__all__ = ["DiffundoError", "VimInterface"]

UndoEntry = Dict[str, Any]

# WHY: :earlier and :later accept a plain count, a time span or a file write count.
COUNT_PATTERN = re.compile(r"^\d+[smhdf]?$")


class DiffundoError(Exception):
    pass


@contextmanager
def reporting_errors() -> Iterator[None]:
    try:
        yield
    except DiffundoError as error:
        print(error)
    except vim.error as error:
        # WHY: an unhandled vim.error surfaces as a python traceback instead of a message.
        print(f"diffundo: {error}")


def normalized_count(count: str) -> str:
    count = str(count).strip()
    if count == "":
        return "1"

    if not COUNT_PATTERN.match(count):
        raise DiffundoError(
            f"diffundo: invalid count: {count} "
            "(expected a number, optionally followed by s, m, h, d or f)"
        )

    return count


@contextmanager
def within_source(interface: VimInterface) -> Iterator[None]:
    interface._focus_window_of_buffer(True)
    undonr = vim.eval("changenr()")

    try:
        yield
    finally:
        # WHY: a failed undo command must not strand the source buffer in the past.
        interface._focus_window_of_buffer(True)
        vim.command(f"silent undo {undonr}")
        vim.command("diffupdate")


class VimInterface:
    def _find_undotree_entry(self, undonr: str) -> UndoEntry | None:
        # WHY: vim.eval() hands back strings under vim and numbers under neovim.
        if int(undonr) == 0:
            return None

        undotree = vim.eval("undotree()")
        entry: UndoEntry = next(e for e in undotree["entries"] if int(e["seq"]) == int(undonr))
        return entry

    def _update_buffer_name(self, entry: UndoEntry | None) -> None:
        if entry is None:
            label = "{original} - 0"
        else:
            time_description = time.strftime(
                "%Y-%m-%d %I:%M:%S %p", time.localtime(float(entry["time"]))
            )
            label = f"{time_description} - {entry['seq']}"

        vim.command(f"file {label}")
        self._label_window(label)

    def _label_window(self, label: str) -> None:
        # WHY: 'laststatus' 3 draws only the focused statusline; the winbar (neovim) stays visible.
        item = label.replace("%", "%%")
        vim.command(f"let &l:statusline = '{item}'")
        if int(vim.eval("exists('+winbar')")):
            vim.command(f"let &l:winbar = '{item}'")

    def _place_changenr(self, lines: list[str], undonr: str) -> None:
        entry = self._find_undotree_entry(undonr)
        self._focus_window_of_buffer(False)
        vim.command("setlocal noreadonly")
        vim.current.buffer[:] = lines
        vim.command("setlocal readonly")
        vim.command(f"let t:diffundo_diff_undonr={undonr}")
        self._update_buffer_name(entry)

    def _early_late(self, command: str, count: str = "1") -> None:
        with within_source(self):
            undonr = vim.eval("t:diffundo_diff_undonr")
            vim.command(f"silent undo {undonr}")
            vim.command(f"silent {command} {count}")
            undonr = vim.eval("changenr()")
            lines = vim.current.buffer[:]

            self._place_changenr(lines, undonr)

    def _match_in_lines(
        self, search_term: str, before_lines: list[str], after_lines: list[str]
    ) -> str | bool:
        additions = [
            line[2:] for line in difflib.ndiff(before_lines, after_lines) if line.startswith("+")
        ]

        matches = (line for line in additions if search_term in line)

        return next(matches, False)

    def _tab_var(self, name: str) -> str | None:
        try:
            return str(vim.eval(name))
        except vim.error:
            # WHY: the t: variables are unset in tabs that never opened a diff split.
            return None

    def _window_of_buffer(self, bufnr: str | None) -> Any | None:
        if bufnr is None:
            return None

        return next((w for w in vim.windows if w.buffer.number == int(bufnr)), None)

    def _focus_window_of_buffer(self, source: bool) -> None:
        window_var = "t:diffundo_source_bn" if source else "t:diffundo_diff_bn"
        window = self._window_of_buffer(self._tab_var(window_var))
        if window is None:
            raise DiffundoError("The diffundo split is no longer open in this tab.")

        vim.current.window = window

    def _split_is_open(self) -> bool:
        diff_bn = self._tab_var("t:diffundo_diff_bn")
        if diff_bn is None or not int(vim.eval(f"bufexists({diff_bn})")):
            return False

        if self._tab_var("t:diffundo_diff_undonr") is None:
            return False

        return (
            self._window_of_buffer(self._tab_var("t:diffundo_source_bn")) is not None
            and self._window_of_buffer(diff_bn) is not None
        )

    def _new_buffer(self) -> None:
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

    def earlier(self, count: str = "1") -> None:
        with reporting_errors():
            count = normalized_count(count)
            if self.open_split():
                self._early_late("earlier", count)

    def later(self, count: str = "1") -> None:
        with reporting_errors():
            count = normalized_count(count)
            if self.open_split():
                self._early_late("later", count)

    def search_earlier(self, search_term: str) -> None:
        with reporting_errors():
            if self.open_split():
                self._search_earlier(search_term)

    def _search_earlier(self, search_term: str) -> None:
        with within_source(self):
            next_undonr = vim.eval("t:diffundo_diff_undonr")
            vim.command(f"silent undo {next_undonr}")
            next_lines = vim.current.buffer[:]

            found_match: str | bool = False
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

    def _leave_stale_diff_window(self) -> None:
        diff_bn = self._tab_var("t:diffundo_diff_bn")
        if diff_bn is None or vim.current.buffer.number != int(diff_bn):
            return

        source_window = self._window_of_buffer(self._tab_var("t:diffundo_source_bn"))
        if source_window is None:
            raise DiffundoError("The diffundo source window is no longer open in this tab.")

        vim.current.window = source_window

    def open_split(self) -> bool:
        if self._split_is_open():
            return True

        self._leave_stale_diff_window()

        if int(vim.eval("undotree()")["seq_last"]) == 0:
            print("No changes to view!")
            return False

        vim.command(f"let t:diffundo_source_bn={vim.current.buffer.number}")
        vim.command("vert diffsplit")

        self._new_buffer()
        return True
