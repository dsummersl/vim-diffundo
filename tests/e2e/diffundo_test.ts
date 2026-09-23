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

async function winIds(denops: Denops): Promise<number[]> {
  return await denops.call("nvim_list_wins") as number[];
}

async function isFloat(denops: Denops, win: number): Promise<boolean> {
  const config = await denops.call("nvim_win_get_config", win) as {
    relative?: string;
  };
  return config.relative === "editor";
}

// WHY: the plugin reports its own failures with print() rather than raising,
// so they never reject the denops call and only show up in :messages.
async function assertNoErrors(denops: Denops): Promise<void> {
  assertEquals(await denops.eval("v:errmsg"), "");
  assertEquals(await denops.call("execute", "messages"), "");
}

async function assertDiffSplit(
  denops: Denops,
  expected: {
    undoLines: string[];
    sourceLines: string[];
    undonr: number;
    floats?: number;
  },
): Promise<void> {
  await assertNoErrors(denops);

  // WHY: :Diffundo opens the floating history by default alongside the split;
  // -no-history commands pass floats: 0 for the minimal layout.
  const floats: number[] = [];
  for (const win of await winIds(denops)) {
    if (await isFloat(denops, win)) floats.push(win);
  }
  assertEquals(floats.length, expected.floats ?? 1, "expected history float count");

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

// WHY: :Diffundo now opens the floating history by default.
async function assertHistory(
  denops: Denops,
  expected: string[],
): Promise<void> {
  await assertNoErrors(denops);
  const wins = await winIds(denops);
  const floats: number[] = [];
  for (const win of wins) {
    if (await isFloat(denops, win)) floats.push(win);
  }
  assertEquals(floats.length, 1, "expected exactly one history float");
  const buf = await denops.call("nvim_win_get_buf", floats[0]) as number;
  const lines = await denops.call("nvim_buf_get_lines", buf, 0, -1, false) as string[];
  assertEquals(lines, expected);
  // WHY: the user lands in the float, keyboard-first.
  assertEquals(await denops.call("nvim_get_current_win"), floats[0]);
}

// WHY: :only errors (E5601) while a float is open.
async function closeHistory(denops: Denops): Promise<void> {
  await denops.cmd("Diffundo history");
}

// WHY: closing via the float's own 'q' keeps last_args intact, so a following
// '.' still repeats the original command; `Diffundo history` would overwrite it.
async function closeFloat(denops: Denops): Promise<void> {
  await denops.call("feedkeys", "q", "x");
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
    await closeHistory(denops);
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

    await closeHistory(denops);
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

    await closeHistory(denops);
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

    await closeHistory(denops);
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

    await closeHistory(denops);
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
    await closeFloat(denops);
    await pressDot(denops);

    await assertDiffSplit(denops, {
      undoLines: ["one", "two"],
      sourceLines: ["one", "two", "three", "four"],
      undonr: 2,
    });

    await closeFloat(denops);
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
    await closeFloat(denops);
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
    await closeHistory(denops);
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
    await closeHistory(denops);
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
    await closeHistory(denops);
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

    await closeHistory(denops);
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

    await closeFloat(denops);
    await pressDot(denops);
    await assertDiffSplit(denops, {
      undoLines: ["a", "x"],
      sourceLines: ["a", "x", "b", "x"],
      undonr: 2,
    });
  },
});

test({
  mode: "nvim",
  name: ":Diffundo history toggles a floating sidebar on and off",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"]]);

    await denops.cmd("Diffundo history");

    const lines = await denops.eval(
      "getbufline(winbufnr(0), 1, '$')",
    ) as string[];
    assert(lines.length >= 1, "the float shows the newest state first");
    // WHY: the label is followed by the row preview ("  + two"), so match the
    // labelled sequence rather than the row's very end.
    assert(lines[0].includes("- 2"), lines[0]);
    await assertHistory(denops, lines);

    await denops.cmd("Diffundo history");
    // WHY: toggled off, the current window is the source again.
    assertEquals((await denops.eval("&buftype")) as string, "");
  },
});

test({
  mode: "nvim",
  name: "moving in the history and confirming with <cr> changes the diff",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["one"],
      ["one", "two"],
      ["one", "two", "three"],
    ]);

    await denops.cmd("Diffundo earlier");

    // WHY: the float is current, its selected row (seq 2 / line 2) is the state
    // the diff shows, and jj from there lands on the oldest row (seq 1).
    assertEquals(await denops.eval("[line('.'), col('.')]"), [2, 1]);
    // Move to the oldest row and confirm it into the diff.
    // WHY: feedkeys never translates the <CR> keycode, so the Enter has to go
    // through nvim_input to reach the float's <cr> map.
    await denops.call("feedkeys", "jj", "x");
    await denops.call("nvim_input", "<CR>");

    const window = (await windowStates(denops)).find((w) => w.buftype === "nofile");
    assert(window, "diff split still open");
    assertEquals(window.lines, ["one"]);
    assertEquals(await denops.eval("t:diffundo_diff_undonr"), 1);
  },
});

test({
  mode: "nvim",
  name: ":Diffundo -no-history earlier keeps the minimal layout",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"]]);

    await denops.cmd("Diffundo -no-history earlier");

    const floats: number[] = [];
    for (const win of await winIds(denops)) {
      if (await isFloat(denops, win)) floats.push(win);
    }
    assertEquals(floats.length, 0, "no history float with -no-history");
    await assertDiffSplit(denops, {
      undoLines: ["one"],
      sourceLines: ["one", "two"],
      undonr: 1,
      floats: 0,
    });
  },
});
