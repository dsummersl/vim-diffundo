import { test } from "@denops/test";
import type { Denops } from "@denops/core";
import { assert, assertEquals } from "@std/assert";
import { fromFileUrl } from "@std/path";

// WHY: denops.vim only drives a real editor here -- the plugin under test is
// vimscript plus pythonx, so the host needs +python3 (pynvim) and the repo on
// the runtimepath.
const pluginRoot = fromFileUrl(new URL("../../", import.meta.url));

const prelude = [
  `set runtimepath^=${pluginRoot}`,
  "runtime! plugin/diffundo.vim",
  // WHY: nvim defaults to 'hidden', which hides the E445 that Vim's default
  // raises when a window holding a modified buffer is closed.
  "set nohidden",
];

interface WindowState {
  lines: string[];
  diff: number;
  buftype: string;
  modifiable: number;
  name: string;
  statusline: string;
  winbar: string;
}

// Records `lines` as one undo state. Each state must extend the previous one:
// clearing the buffer first would cost a second undo block per state.
async function appendState(denops: Denops, lines: string[]): Promise<void> {
  await denops.call("setline", 1, lines);
  // WHY: every RPC write would otherwise land in a single undo block.
  await denops.cmd("let &undolevels = &undolevels");
}

// Builds one undo state per entry, so changenr() ends at states.length.
async function buildHistory(denops: Denops, states: string[][]): Promise<void> {
  for (const lines of states) {
    await appendState(denops, lines);
  }
}

async function windowStates(denops: Denops): Promise<WindowState[]> {
  return await denops.eval(
    "map(range(1, winnr('$')), {_, w -> {" +
      "'lines': getbufline(winbufnr(w), 1, '$')," +
      "'diff': getwinvar(w, '&diff')," +
      "'buftype': getbufvar(winbufnr(w), '&buftype')," +
      "'modifiable': getbufvar(winbufnr(w), '&modifiable')," +
      "'name': bufname(winbufnr(w))," +
      "'statusline': getwinvar(w, '&statusline')," +
      "'winbar': getwinvar(w, '&winbar')}})",
  ) as WindowState[];
}

// WHY: the plugin reports its own failures with print() rather than raising,
// so they never reject the denops call and only show up in :messages.
async function assertNoErrors(denops: Denops): Promise<void> {
  assertEquals(await denops.eval("v:errmsg"), "");
  assertEquals(await denops.call("execute", "messages"), "");
}

async function assertDiffSplit(
  denops: Denops,
  expected: { undoLines: string[]; sourceLines: string[]; undonr: number },
): Promise<void> {
  await assertNoErrors(denops);
  assertEquals(await denops.call("winnr", "$"), 2);

  const windows = await windowStates(denops);
  const undoBuffer = windows.find((w) => w.buftype === "nofile");
  const sourceBuffer = windows.find((w) => w.buftype === "");

  assert(undoBuffer, "the undo history buffer is not open");
  assert(sourceBuffer, "the source buffer is not open");
  assertEquals(undoBuffer.lines, expected.undoLines);
  assertEquals(sourceBuffer.lines, expected.sourceLines);
  assertEquals([undoBuffer.diff, sourceBuffer.diff], [1, 1]);

  // WHY: the label must stay visible under 'laststatus' 3, where only the
  // focused window's statusline is drawn.
  assert(undoBuffer.name.endsWith(`- ${expected.undonr}`), undoBuffer.name);
  assertEquals(undoBuffer.statusline, undoBuffer.name);
  assertEquals(undoBuffer.winbar, undoBuffer.name);
  // WHY: the source window must keep the editor's global values untouched.
  assertEquals(
    [sourceBuffer.statusline, sourceBuffer.winbar],
    await denops.eval("[&g:statusline, &g:winbar]"),
  );

  assertEquals(await denops.eval("t:diffundo_diff_undonr"), expected.undonr);
}

async function assertSourceAlone(
  denops: Denops,
  expected: { lines: string[]; changenr: number },
): Promise<void> {
  await assertNoErrors(denops);
  assertEquals(await denops.call("winnr", "$"), 1);

  const [window] = await windowStates(denops);
  assertEquals(window.buftype, "");
  assertEquals(window.lines, expected.lines);
  assertEquals(window.diff, 0);
  assertEquals(await denops.call("changenr"), expected.changenr);
}

test({
  mode: "nvim",
  name: ":DiffEarlier opens a diff split against the previous undo state",
  prelude,
  fn: async (denops) => {
    assertEquals(await denops.call("has", "python3"), 1);

    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"], [
      "one",
      "two",
      "three",
    ]]);

    await denops.cmd("DiffEarlier");

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "two", "three"],
      undonr: 2,
    });
  },
});

test({
  mode: "nvim",
  name: ":only after :DiffEarlier leaves the source buffer at its latest state",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"], [
      "one",
      "two",
      "three",
    ]]);

    await denops.cmd("DiffEarlier");
    await denops.cmd("only");

    await assertSourceAlone(denops, {
      lines: ["one", "two", "three"],
      changenr: 3,
    });

    // WHY: the split must reopen cleanly rather than trip over the stale t: vars.
    await denops.cmd("DiffEarlier");

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "two", "three"],
      undonr: 2,
    });

    await denops.cmd("only");

    await assertSourceAlone(denops, {
      lines: ["one", "two", "three"],
      changenr: 3,
    });
  },
});

test({
  mode: "nvim",
  name: ":DiffEarlier {count} steps back that many undo states",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["one"],
      ["one", "two"],
      ["one", "two", "three"],
      ["one", "two", "three", "four"],
    ]);

    await denops.cmd("DiffEarlier 2");

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "two", "three", "four"],
      undonr: 2,
    });

    // WHY: a second call walks further back from the state the split shows.
    await denops.cmd("DiffEarlier");

    await assertDiffSplit(denops, {
      undoLines: ["one"],
      sourceLines: ["one", "two", "three", "four"],
      undonr: 1,
    });

    await denops.cmd("only");

    await assertSourceAlone(denops, {
      lines: ["one", "two", "three", "four"],
      changenr: 4,
    });
  },
});

test({
  mode: "nvim",
  name: ":DiffEarlier {N}f steps back to the state of an earlier file write",
  prelude,
  fn: async (denops) => {
    const path = await denops.call("tempname") as string;
    await denops.cmd(`edit ${path}`);

    await appendState(denops, ["one"]);
    await denops.cmd("write");
    await appendState(denops, ["one", "two"]);
    await denops.cmd("write");
    await appendState(denops, ["one", "two", "three"]);

    await denops.cmd("DiffEarlier 1f");

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "two", "three"],
      undonr: 2,
    });

    await denops.cmd("only");

    await assertSourceAlone(denops, {
      lines: ["one", "two", "three"],
      changenr: 3,
    });

    await denops.cmd("DiffEarlier 2f");

    await assertDiffSplit(denops, {
      undoLines: ["one"],
      sourceLines: ["one", "two", "three"],
      undonr: 1,
    });

    await denops.cmd("only");

    await assertSourceAlone(denops, {
      lines: ["one", "two", "three"],
      changenr: 3,
    });
    assertEquals(await denops.eval("&modified"), 1);
  },
});
