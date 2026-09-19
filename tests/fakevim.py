"""A small fake of the ``vim`` python module.

The plugin talks to vim through ``vim.eval``/``vim.command`` plus a handful of
objects (``vim.current``, ``vim.windows``).  Rather than asserting on mock call
lists, this fake models just enough of vim -- windows, buffers, tab-local
variables and a linear undo history -- that the interface code can be driven
end to end and the resulting buffer contents inspected.
"""


class FakeError(Exception):
    """Stand-in for ``vim.error``."""


class FakeBuffer:
    def __init__(self, number, lines=None, name=""):
        self.number = number
        self.name = name
        self.lines = list(lines if lines is not None else [])
        self.options = {}

    def __getitem__(self, index):
        return self.lines[index]

    def __setitem__(self, index, value):
        if isinstance(index, slice):
            self.lines[index] = list(value)
        else:
            self.lines[index] = value

    def __len__(self):
        return len(self.lines)

    def __repr__(self):
        return f"<FakeBuffer {self.number} {self.name!r}>"


class FakeWindow:
    def __init__(self, buffer):
        self.buffer = buffer

    def __repr__(self):
        return f"<FakeWindow buffer={self.buffer.number}>"


class FakeCurrent:
    """``vim.current``; assigning a window switches the current buffer too."""

    def __init__(self, vim):
        self._vim = vim

    @property
    def window(self):
        return self._vim._current_window

    @window.setter
    def window(self, window):
        self._vim._current_window = window

    @property
    def buffer(self):
        return self._vim._current_window.buffer

    @buffer.setter
    def buffer(self, buffer):
        self._vim._current_window.buffer = buffer


class UndoHistory:
    """A linear undo history: a list of (seq, lines) with a cursor."""

    def __init__(self, states, times=None):
        # states[0] is seq 0 -- the state before any change was made.
        self.states = [list(lines) for lines in states]
        self.times = times or [str(1627784659 + i * 60) for i in range(len(states))]
        self.seq = len(states) - 1

    @property
    def lines(self):
        return self.states[self.seq]

    def undo(self, seq):
        self.seq = max(0, min(int(seq), len(self.states) - 1))

    def earlier(self, count=1):
        self.undo(self.seq - int(count))

    def later(self, count=1):
        self.undo(self.seq + int(count))

    def undotree(self):
        return {
            "seq_last": str(len(self.states) - 1),
            "seq_cur": str(self.seq),
            "entries": [
                {"seq": str(i), "time": self.times[i]}
                for i in range(1, len(self.states))
            ],
        }


class FakeVim:
    """Implements the slice of the vim API that ``VimInterface`` uses."""

    error = FakeError

    def __init__(self, history, filetype="python", name="source.py"):
        self.history = history
        self.filetype = filetype
        self.vars = {}
        self.commands = []
        self.messages = []
        self._next_bufnr = 1
        source = self._new_buffer_object(list(history.lines), name)
        self.buffers = [source]
        self.source_buffer = source
        self.windows = [FakeWindow(source)]
        self._current_window = self.windows[0]
        self.current = FakeCurrent(self)

    # -- helpers -----------------------------------------------------------
    def _new_buffer_object(self, lines=None, name=""):
        buffer = FakeBuffer(self._next_bufnr, lines, name)
        self._next_bufnr += 1
        return buffer

    def buffer_named(self, number):
        return next(b for b in self.buffers if b.number == int(number))

    @property
    def diff_buffer(self):
        return self.buffer_named(self.vars["t:diffundo_diff_bn"])

    def _sync_source_buffer(self):
        """Mirror the undo history into whichever buffer is the source."""
        self.source_buffer[:] = list(self.history.lines)

    # -- the vim api -------------------------------------------------------
    def eval(self, expression):
        if expression == "changenr()":
            return str(self.history.seq)

        if expression == "undotree()":
            return self.history.undotree()

        if expression == "&filetype":
            return self.filetype

        if expression.startswith("t:"):
            if expression not in self.vars:
                raise FakeError(f"E121: Undefined variable: {expression}")
            return self.vars[expression]

        if expression.startswith("bufexists("):
            inner = expression[len("bufexists(") : -1]
            number = self.eval(inner) if inner.startswith("t:") else inner
            return "1" if any(b.number == int(number) for b in self.buffers) else "0"

        raise FakeError(f"unsupported eval: {expression}")

    def command(self, command):
        self.commands.append(command)
        stripped = command
        while stripped.startswith("silent "):
            stripped = stripped[len("silent ") :]
        head, _, rest = stripped.partition(" ")
        rest = rest.strip()

        if stripped.startswith("let "):
            name, _, value = stripped[len("let ") :].partition("=")
            self.vars[name.strip()] = value.strip()
            return

        if head == "undo":
            self.history.undo(rest)
            self._sync_source_buffer()
            return

        if head in ("earlier", "later"):
            getattr(self.history, head)(rest or "1")
            self._sync_source_buffer()
            return

        if head == "file":
            self.current.buffer.name = rest
            return

        if head == "enew":
            buffer = self._new_buffer_object()
            self.buffers.append(buffer)
            self.current.window.buffer = buffer
            return

        if stripped.startswith("vert diffsplit"):
            # vim shows the same buffer in the new window; :enew replaces it.
            window = FakeWindow(self.current.buffer)
            self.windows.insert(0, window)
            self._current_window = window
            return

        if stripped.startswith("setlocal "):
            option = stripped[len("setlocal ") :]
            name, _, value = option.partition("=")
            self.current.buffer.options[name] = value or True
            return

        if head == "diffupdate" or stripped.startswith("/"):
            return

        raise FakeError(f"unsupported command: {command}")
