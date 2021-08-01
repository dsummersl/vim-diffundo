import vim


class VimInterface:
    def _new_buffer(self):
        vim.command("enew")
        vim.command("setlocal buftype=nofile")
        vim.command("setlocal bufhidden=hide")
        vim.command("setlocal noswapfile")
        vim.command("setlocal readonly")

    def vert_diffs(self):
        """ Open a vertical diffsplit if one doesn't already exist. """
        vim.command("vert diffsplit")
        self._new_buffer()
