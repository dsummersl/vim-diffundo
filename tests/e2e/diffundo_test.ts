import { test } from "@denops/test";
import type { Denops } from "@denops/core";
import { assert, assertEquals } from "@std/assert";
import { fromFileUrl } from "@std/path";

// WHY: denops.vim only drives a real editor here -- the plugin under test is
// Lua, so the host just needs the repo on the runtimepath.
const pluginRoot = fromFileUrl(new URL("../../", import.meta.url));

// WHY: `make e2e` clones tpope/vim-repeat here so the suite can press `.`.
const repeatRoot = `${pluginRoot}.cache/vim-repeat`;

const prelude = [
  `set runtimepath^=${pluginRoot}`,
  `set runtimepath^=${repeatRoot}`,
  "runtime! plugin/diffundo.lua",
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

// Records `lines` as one undo state even when it is shorter than the buffer.
async function setState(denops: Denops, lines: string[]): Promise<void> {
  const quoted = lines.map((l) => `'${l.replaceAll("'", "''")}'`).join(", ");
  // WHY: RPC calls bracket their own undo block, so the shrink must run
  // inside a single :undojoin'd command.
  await denops.cmd(`call setline(1, [${quoted}])`);
  await denops.cmd(`silent undojoin | call deletebufline("%", ${lines.length + 1}, "$")`);
  await denops.cmd("let &undolevels = &undolevels");
}

async function assertCursor(
  denops: Denops,
  expected: { lnum: number; col: number },
): Promise<void> {
  // WHY: the command must leave the user in their own buffer, not the diff.
  assertEquals(await denops.eval("&buftype"), "");
  assertEquals(await denops.eval("[line('.'), col('.')]"), [
    expected.lnum,
    expected.col,
  ]);
}

async function assertNoMatch(denops: Denops, verb: string, pattern: string): Promise<void> {
  const messages = await denops.call("execute", "messages") as string;
  assert(
    messages.includes(`diffundo: no state ${verb} a line matching ${pattern}`),
    messages,
  );
  await denops.cmd("messages clear");
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
  name: ":Diffundo earlier opens a diff split against the previous undo state",
  prelude,
  fn: async (denops) => {
    assertEquals(await denops.call("exists", ":Diffundo"), 2);

    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"], [
      "one",
      "two",
      "three",
    ]]);

    await denops.cmd("Diffundo earlier");

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "two", "three"],
      undonr: 2,
    });
  },
});

test({
  mode: "nvim",
  name: ":only after :Diffundo earlier leaves the source buffer at its latest state",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"], [
      "one",
      "two",
      "three",
    ]]);

    await denops.cmd("Diffundo earlier");
    await denops.cmd("only");

    await assertSourceAlone(denops, {
      lines: ["one", "two", "three"],
      changenr: 3,
    });

    // WHY: the split must reopen cleanly rather than trip over the stale t: vars.
    await denops.cmd("Diffundo earlier");

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
  name: ":Diffundo earlier {count} steps back that many undo states",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["one"],
      ["one", "two"],
      ["one", "two", "three"],
      ["one", "two", "three", "four"],
    ]);

    await denops.cmd("Diffundo earlier 2");

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "two", "three", "four"],
      undonr: 2,
    });

    // WHY: a second call walks further back from the state the split shows.
    await denops.cmd("Diffundo earlier");

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
  name: ":Diffundo earlier {N}f steps back to the state of an earlier file write",
  prelude,
  fn: async (denops) => {
    const path = await denops.call("tempname") as string;
    await denops.cmd(`edit ${path}`);

    await appendState(denops, ["one"]);
    await denops.cmd("write");
    await appendState(denops, ["one", "two"]);
    await denops.cmd("write");
    await appendState(denops, ["one", "two", "three"]);

    await denops.cmd("Diffundo earlier 1f");

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

    await denops.cmd("Diffundo earlier 2f");

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

// WHY: vim-repeat replays through feedkeys(), so the queued keys only run once
// typeahead is flushed.
async function pressDot(denops: Denops): Promise<void> {
  await denops.call("feedkeys", ".", "x");
}

test({
  mode: "nvim",
  name: "`.` repeats the last :Diffundo earlier through vim-repeat",
  prelude,
  fn: async (denops) => {
    // WHY: vim-repeat has no plugin/ file, so only its autoload script proves
    // the clone is on the runtimepath.
    assert(await denops.eval("globpath(&rtp, 'autoload/repeat.vim')"));

    await denops.cmd("enew");
    await buildHistory(denops, [
      ["one"],
      ["one", "two"],
      ["one", "two", "three"],
      ["one", "two", "three", "four"],
    ]);

    await denops.cmd("Diffundo earlier");
    await pressDot(denops);

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "two", "three", "four"],
      undonr: 2,
    });

    await pressDot(denops);

    await assertDiffSplit(denops, {
      undoLines: ["one"],
      sourceLines: ["one", "two", "three", "four"],
      undonr: 1,
    });
  },
});

test({
  mode: "nvim",
  name: "`.` repeats :Diffundo earlier 1f from one file write to the previous one",
  prelude,
  fn: async (denops) => {
    const path = await denops.call("tempname") as string;
    await denops.cmd(`edit ${path}`);

    await appendState(denops, ["one"]);
    await denops.cmd("write");
    await appendState(denops, ["one", "two"]);
    await denops.cmd("write");
    await appendState(denops, ["one", "two", "three"]);

    await denops.cmd("Diffundo earlier 1f");
    await pressDot(denops);

    await assertDiffSplit(denops, {
      undoLines: ["one"],
      sourceLines: ["one", "two", "three"],
      undonr: 1,
    });
  },
});

test({
  mode: "nvim",
  name: ":Diffundo search shows the state that added the line and puts the cursor on it",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "xx two"], [
      "one",
      "xx two",
      "three",
    ]]);

    await denops.cmd("Diffundo search two");

    await assertDiffSplit(denops, {
      undoLines: ["one", "xx two"],
      sourceLines: ["one", "xx two", "three"],
      undonr: 2,
    });
    await assertCursor(denops, { lnum: 2, col: 4 });
    assertEquals(await denops.eval("@/"), "");

    // WHY: the label and t:diffundo_diff_undonr agree, so earlier steps once.
    await denops.cmd("Diffundo earlier");

    await assertDiffSplit(denops, {
      undoLines: ["one"],
      sourceLines: ["one", "xx two", "three"],
      undonr: 1,
    });
  },
});

test({
  mode: "nvim",
  name: ":Diffundo search! shows the state that removed the line",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await setState(denops, ["a"]);
    await setState(denops, ["a", "b"]);
    await setState(denops, ["a"]);

    await denops.cmd("Diffundo search! b");

    await assertDiffSplit(denops, {
      undoLines: ["a"],
      sourceLines: ["a"],
      undonr: 3,
    });
    await assertCursor(denops, { lnum: 1, col: 1 });
  },
});

test({
  mode: "nvim",
  name: ":Diffundo search diffs each state against its parent across undo branches",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await setState(denops, ["one"]);
    await setState(denops, ["one", "two"]);
    await denops.cmd("silent undo 1");
    await setState(denops, ["one", "three"]);
    assertEquals(await denops.call("changenr"), 3);

    // WHY: no edit removed "two"; a chronological walk would blame seq 3.
    await denops.cmd("Diffundo search! two");
    await assertNoMatch(denops, "removes", "two");

    await denops.cmd("only");
    await denops.cmd("Diffundo search two");

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "three"],
      undonr: 2,
    });
    await assertCursor(denops, { lnum: 2, col: 1 });
  },
});

test({
  mode: "nvim",
  name: ":Diffundo search follows 'ignorecase' and 'smartcase' like /",
  prelude,
  fn: async (denops) => {
    await denops.cmd("set ignorecase smartcase");
    await denops.cmd("enew");
    await buildHistory(denops, [["x"], ["x", "Foo"]]);

    await denops.cmd("Diffundo search foo");

    await assertDiffSplit(denops, {
      undoLines: ["x", "Foo"],
      sourceLines: ["x", "Foo"],
      undonr: 2,
    });

    await denops.cmd("only");
    await denops.cmd("Diffundo search FOO");
    await assertNoMatch(denops, "adds", "FOO");
  },
});

test({
  mode: "nvim",
  name: "`.` repeats :Diffundo search to the next older match",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["a"], ["a", "x"], ["a", "x", "b"], [
      "a",
      "x",
      "b",
      "x",
    ]]);

    await denops.cmd("Diffundo search x");
    await assertDiffSplit(denops, {
      undoLines: ["a", "x", "b", "x"],
      sourceLines: ["a", "x", "b", "x"],
      undonr: 4,
    });

    await pressDot(denops);
    await assertDiffSplit(denops, {
      undoLines: ["a", "x"],
      sourceLines: ["a", "x", "b", "x"],
      undonr: 2,
    });
  },
});
