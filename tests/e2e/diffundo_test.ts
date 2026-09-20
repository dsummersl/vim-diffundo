import { test } from "@denops/test";
import { assert, assertEquals } from "@std/assert";
import { fromFileUrl } from "@std/path";

// WHY: denops.vim only drives a real editor here -- the plugin under test is
// vimscript plus pythonx, so the host needs +python3 (pynvim) and the repo on
// the runtimepath.
const pluginRoot = fromFileUrl(new URL("../../", import.meta.url));

test({
  mode: "nvim",
  name: ":DiffEarlier opens a diff split against the previous undo state",
  prelude: [
    `set runtimepath^=${pluginRoot}`,
    "runtime! plugin/diffundo.vim",
  ],
  fn: async (denops) => {
    assertEquals(await denops.call("has", "python3"), 1);

    await denops.cmd("enew");
    for (const lines of [["one"], ["one", "two"], ["one", "two", "three"]]) {
      await denops.call("setline", 1, lines);
      // WHY: every RPC write would otherwise land in a single undo block.
      await denops.cmd("let &undolevels = &undolevels");
    }

    await denops.cmd("DiffEarlier");

    assertEquals(await denops.call("winnr", "$"), 2);

    const windows = await denops.eval(
      "map(range(1, winnr('$')), {_, w -> {" +
        "'lines': getbufline(winbufnr(w), 1, '$')," +
        "'diff': getwinvar(w, '&diff')," +
        "'buftype': getbufvar(winbufnr(w), '&buftype')," +
        "'modifiable': getbufvar(winbufnr(w), '&modifiable')}})",
    ) as {
      lines: string[];
      diff: number;
      buftype: string;
      modifiable: number;
    }[];

    const undoBuffer = windows.find((w) => w.buftype === "nofile");
    const sourceBuffer = windows.find((w) => w.buftype === "");

    assert(undoBuffer, "the undo history buffer is not open");
    assert(sourceBuffer, "the source buffer is not open");
    assertEquals(undoBuffer.lines, ["one", "two"]);
    assertEquals(sourceBuffer.lines, ["one", "two", "three"]);
    assertEquals([undoBuffer.diff, sourceBuffer.diff], [1, 1]);

    assertEquals(await denops.eval("t:diffundo_diff_undonr"), 2);
  },
});
