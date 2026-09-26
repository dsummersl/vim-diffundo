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
  await denops.cmd(
    `silent undojoin | call deletebufline("%", ${lines.length + 1}, "$")`,
  );
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

async function assertNoMatch(
  denops: Denops,
  verb: string,
  pattern: string,
): Promise<void> {
  const messages = await denops.call("execute", "messages") as string;
  assert(
    messages.includes(`diffundo: no state ${verb} a line matching ${pattern}`),
    messages,
  );
  await denops.cmd("messages clear");
}

// WHY: only the two split windows; the pane float is checked on its own.
async function windowStates(denops: Denops): Promise<WindowState[]> {
  return await denops.eval(
    "map(filter(range(1, winnr('$')), {_, w -> win_gettype(w) !=# 'popup'}), {_, w -> {" +
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

interface FloatConfig {
  relative?: string;
  win?: number;
  anchor?: string;
  focusable?: boolean;
  title?: [string][];
  footer?: [string][];
}

async function floatConfig(
  denops: Denops,
  win: number,
): Promise<FloatConfig> {
  return await denops.call("nvim_win_get_config", win) as FloatConfig;
}

async function floats(denops: Denops): Promise<number[]> {
  const found: number[] = [];
  for (const win of await winIds(denops)) {
    if ((await floatConfig(denops, win)).relative) found.push(win);
  }
  return found;
}

async function paneWin(denops: Denops): Promise<number> {
  const all = await floats(denops);
  assertEquals(all.length, 1, "expected exactly one pane float");
  return all[0];
}

async function paneLines(denops: Denops): Promise<string[]> {
  const buf = await denops.call(
    "nvim_win_get_buf",
    await paneWin(denops),
  ) as number;
  return await denops.call("nvim_buf_get_lines", buf, 0, -1, false) as string[];
}

// WHY: the border title carries the diff's `#seq  date`, which varies per run.
async function paneLabels(
  denops: Denops,
): Promise<{ title: string; footer: string }> {
  const config = await floatConfig(denops, await paneWin(denops));
  return {
    title: (config.title ?? []).map((c) => c[0]).join(""),
    footer: (config.footer ?? []).map((c) => c[0]).join(""),
  };
}

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
    pane?: boolean;
  },
): Promise<void> {
  await assertNoErrors(denops);

  const panes = await floats(denops);
  if (expected.pane === false) {
    assertEquals(panes.length, 0, "no pane with g:diffundo_history off");
  } else {
    // WHY: the pane rides the diff window and never takes the focus.
    assertEquals(panes.length, 1, "expected exactly one pane float");
    const config = await floatConfig(denops, panes[0]);
    assertEquals(config.relative, "win");
    assertEquals(config.win, await denops.call("bufwinid", "diffundo://*"));
    assert(
      (await denops.call("nvim_get_current_win")) !== panes[0],
      "the pane must not take the focus",
    );
  }

  const windows = await windowStates(denops);
  assertEquals(windows.length, 2, "only the two split windows");
  const undoBuffer = windows.find((w) => w.buftype === "nofile");
  const sourceBuffer = windows.find((w) => w.buftype === "");

  assert(undoBuffer, "the undo history buffer is not open");
  assert(sourceBuffer, "the source buffer is not open");
  assertEquals(undoBuffer.lines, expected.undoLines);
  assertEquals(sourceBuffer.lines, expected.sourceLines);
  assertEquals([undoBuffer.diff, sourceBuffer.diff], [1, 1]);

  // WHY: no statusline or winbar label on the diff window, so its lines stay
  // on the same screen rows as the source window's.
  assert(undoBuffer.name.endsWith(`/#${expected.undonr}`), undoBuffer.name);
  assertEquals([undoBuffer.statusline, undoBuffer.winbar], ["", ""]);
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

// WHY: :Diffundo focus expands the pane into the whole tree and enters it.
async function assertExpanded(
  denops: Denops,
  expected: string[],
): Promise<void> {
  await assertNoErrors(denops);
  assertEquals(await paneLines(denops), expected);
  assertEquals(
    await denops.call("nvim_get_current_win"),
    await paneWin(denops),
  );
  assert((await floatConfig(denops, await paneWin(denops))).focusable);
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
  name: "the diff split keeps source and diff lines on the same screen row",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"], [
      "one",
      "two",
      "three",
    ]]);

    await denops.cmd("set winbar=");
    await denops.cmd("Diffundo earlier");

    // WHY: a winbar on the diff window alone would push its buffer down a
    // row; the source and diff line 1 must land on the same screen row.
    await denops.cmd("redraw");
    const rows = await denops.eval(
      "map(filter(range(1, winnr('$')), {_, w -> win_gettype(w) !=# 'popup'}), " +
        "{_, w -> screenpos(win_getid(w), 1, 1).row})",
    ) as number[];
    assertEquals(rows.length, 2);
    assertEquals(rows[0], rows[1]);
  },
});

test({
  mode: "nvim",
  name:
    ":only after :Diffundo earlier leaves the source buffer at its latest state",
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
  name:
    ":Diffundo earlier {N}f steps back to the state of an earlier file write",
  prelude,
  fn: async (denops) => {
    const path = await denops.call("tempname") as string;
    await denops.cmd(`edit ${path}`);

    await appendState(denops, ["one"]);
    await denops.cmd("silent write");
    await appendState(denops, ["one", "two"]);
    await denops.cmd("silent write");
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
  name:
    "`.` repeats :Diffundo earlier 1f from one file write to the previous one",
  prelude,
  fn: async (denops) => {
    const path = await denops.call("tempname") as string;
    await denops.cmd(`edit ${path}`);

    await appendState(denops, ["one"]);
    await denops.cmd("silent write");
    await appendState(denops, ["one", "two"]);
    await denops.cmd("silent write");
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
  name:
    ":Diffundo search shows the state that added the line and puts the cursor on it",
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
  name:
    ":Diffundo search diffs each state against its parent across undo branches",
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

test({
  mode: "nvim",
  name: "the collapsed pane shows the buffer and diff states and follows `.`",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["one"],
      ["one", "two"],
      ["one", "two", "three"],
      ["one", "two", "three", "four"],
    ]);

    await denops.cmd("Diffundo earlier");
    assertEquals(await paneLines(denops), [
      "@ + four                              #4",
      "╷ + three                             #3",
      "┆   2 undos",
    ]);
    const labels = await paneLabels(denops);
    assert(
      /^ #3  \d{4}-\d\d-\d\d \d\d:\d\d:\d\d $/.test(labels.title),
      labels.title,
    );
    assertEquals(labels.footer, " +1 -0 lines ");

    await pressDot(denops);
    assertEquals(await paneLines(denops), [
      "@ + four                              #4",
      "┆   1 undo",
      "╷ + two                               #2",
      "┆   1 undo",
    ]);
    assertEquals((await paneLabels(denops)).footer, " +2 -0 lines ");
    // WHY: the focus never left the source, so it stays editable.
    assertEquals(await denops.eval("&buftype"), "");
  },
});

test({
  mode: "nvim",
  name: "a buffer without changes diffs against #0 and follows new edits",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");

    await denops.cmd("Diffundo earlier");
    await assertDiffSplit(denops, {
      undoLines: [""],
      sourceLines: [""],
      undonr: 0,
    });
    assertEquals(await paneLines(denops), [
      "@                                     #0",
    ]);
    assertEquals(await paneLabels(denops), {
      title: " #0 ",
      footer: " +0 -0 lines ",
    });

    await appendState(denops, ["hello"]);
    await denops.cmd("doautocmd TextChanged");
    // WHY: the pane re-renders on a scheduled callback.
    await denops.call("wait", 100, "v:false");
    assertEquals(await paneLines(denops), [
      "@ +1 -1 lines                         #1",
      "╷                                     #0",
    ]);
    assertEquals((await paneLabels(denops)).footer, " +1 -1 lines ");
  },
});

test({
  mode: "nvim",
  name: "the pane closes with the diff window",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"]]);
    await denops.cmd("Diffundo earlier");

    await denops.call(
      "nvim_win_close",
      await denops.call("bufwinid", "diffundo://*"),
      false,
    );
    await denops.call("wait", 100, "v:false");

    assertEquals((await floats(denops)).length, 0);
    assertEquals(await denops.call("winnr", "$"), 1);
  },
});

test({
  mode: "nvim",
  name: ":Diffundo focus expands the pane, q collapses it back to the source",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"]]);
    const source = await denops.call("nvim_get_current_win");

    await denops.cmd("Diffundo focus");

    await assertExpanded(denops, [
      "@ + two                               #2",
      "╷ +1 -1 lines                         #1",
      "╷                                     #0",
    ]);
    assertEquals(await denops.eval("t:diffundo_diff_undonr"), 2);

    await denops.call("feedkeys", "g?", "x");
    const hint = await denops.call("execute", "messages") as string;
    assert(hint.includes("J/K written"), hint);
    await denops.cmd("messages clear");

    await denops.call("feedkeys", "q", "x");
    assertEquals(await denops.call("nvim_get_current_win"), source);
    assertEquals(await paneLines(denops), [
      "@ + two                               #2",
      "┆   1 undo",
    ]);
    assertEquals(
      (await floatConfig(denops, await paneWin(denops))).focusable,
      false,
    );
  },
});

test({
  mode: "nvim",
  name: "moving in the expanded pane and confirming with <cr> changes the diff",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["one"],
      ["one", "two"],
      ["one", "two", "three"],
    ]);

    await denops.cmd("Diffundo earlier");
    await denops.cmd("Diffundo focus");

    // WHY: the cursor starts on the diff's row (#2, line 2).
    assertEquals(await denops.eval("[line('.'), col('.')]"), [2, 1]);
    await denops.call("feedkeys", "j", "x");
    // WHY: feedkeys never translates the <CR> keycode, so the Enter has to go
    // through nvim_input to reach the pane's <cr> map.
    await denops.call("nvim_input", "<CR>");
    await denops.call("wait", 100, "v:false");

    const window = (await windowStates(denops)).find((w) =>
      w.buftype === "nofile"
    );
    assert(window, "diff split still open");
    assertEquals(window.lines, ["one"]);
    assertEquals(await denops.eval("t:diffundo_diff_undonr"), 1);
    assertEquals(
      await denops.call("nvim_get_current_win"),
      await paneWin(denops),
    );
    assertEquals((await paneLabels(denops)).footer, " +2 -0 lines ");
  },
});

test({
  mode: "nvim",
  name: "a long branch stretch folds into a gap caption and zo unfolds it",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["one"],
      ["one", "two"],
      ["one", "two", "three"],
      ["one", "two", "three", "four"],
      ["one", "two", "three", "four", "five"],
      ["one", "two", "three", "four", "five", "six"],
      ["one", "two", "three", "four", "five", "six", "seven"],
      ["one", "two", "three", "four", "five", "six", "seven", "eight"],
    ]);
    await denops.cmd("silent undo 2");
    await appendState(denops, ["one", "two", "nine"]);

    await denops.cmd("Diffundo focus");

    assertEquals(
      await denops.eval("t:diffundo_pane_captions"),
      { "3": "┆    4 undos" },
    );
    assertEquals(await denops.call("foldclosed", 3), 3);
    assertEquals(await denops.call("foldtextresult", 3), "┆    4 undos");
    await denops.cmd("3normal! zo");
    assertEquals(await denops.call("foldclosed", 3), -1);

    // WHY: <cr> on a state inside the opened fold re-renders the pane; the
    // fold must stay open so the picked row stays visible.
    await denops.cmd("normal! 4G");
    await denops.call("nvim_input", "<CR>");
    await denops.call("wait", 100, "v:false");
    assertEquals(await denops.eval("t:diffundo_diff_undonr"), 6);
    assertEquals(await denops.call("foldclosed", 4), -1);
    assertEquals(await denops.call("line", "."), 4);
  },
});

test({
  mode: "nvim",
  name: "the pane draws branches with junction lanes",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["a"], ["a", "b"], ["a", "b", "c"]]);
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "x"]);
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "y"]);

    await denops.cmd("Diffundo focus");
    await assertExpanded(denops, [
      "@  + y                                #5",
      "├╯ + x                                #4",
      "┊╷ + c                                #3",
      "├╯ + b                                #2",
      "╷  +1 -1 lines                        #1",
      "╷                                     #0",
    ]);

    await denops.call("feedkeys", "q", "x");
    await denops.cmd("Diffundo earlier");
    assertEquals(await paneLines(denops), [
      "@  + y                                #5",
      "├╯ + x                                #4",
      "┆    3 undos",
    ]);
  },
});

test({
  mode: "nvim",
  name: "the pane pips written states and counts writes in its gaps",
  prelude,
  fn: async (denops) => {
    const path = await denops.call("tempname") as string;
    await denops.cmd(`edit ${path}`);
    await appendState(denops, ["a"]);
    await denops.cmd("silent write");
    await appendState(denops, ["a", "b"]);
    await denops.cmd("silent write");
    await appendState(denops, ["a", "b", "c"]);
    await denops.cmd("silent write");
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "x"]);

    await denops.cmd("Diffundo focus");
    await assertExpanded(denops, [
      "@  + x                                #4",
      "├w + c                                #3",
      "├w + b                                #2",
      "w  +1 -1 lines                        #1",
      "╷                                     #0",
    ]);

    await denops.call("feedkeys", "q", "x");
    await denops.cmd("Diffundo earlier");
    assertEquals(await paneLines(denops), [
      "@  + x                                #4",
      "├w + c                                #3",
      "┆    2 undos 2w",
    ]);
  },
});

test({
  mode: "nvim",
  name: "the pane shows the redo stretch above a buffer that is mid-undo",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["a"], ["a", "b"], ["a", "b", "c"]]);
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "x"]);
    await denops.cmd("silent undo 2");

    await denops.cmd("Diffundo earlier");

    assertEquals(await paneLines(denops), [
      "┆    2 undos",
      "├@ + b                                #2",
      "╷  +1 -1 lines                        #1",
    ]);
  },
});

test({
  mode: "nvim",
  name: ":Diffundo search and / narrow the pane to the matching states",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["a"],
      ["a", "x1"],
      ["a", "x1", "b"],
      ["a", "x1", "b", "x2"],
      ["a", "x1", "b", "x2", "c"],
    ]);

    await denops.cmd("Diffundo search x");
    assertEquals(await paneLines(denops), [
      "┆   1 undo",
      "╷ + x2                                #4",
      "┆   1 undo",
      "╷ + x1                                #2",
      "┆   1 undo",
    ]);
    assertEquals((await paneLabels(denops)).footer, " filter: x ");

    // WHY: a plain step clears the filter; #3 is two lines behind the buffer.
    await denops.cmd("Diffundo earlier");
    assertEquals((await paneLabels(denops)).footer, " +2 -0 lines ");

    await denops.cmd("Diffundo focus");
    await denops.call("feedkeys", "/x\r", "x");
    assertEquals(await paneLines(denops), [
      "┆   1 undo",
      "╷ + x2                                #4",
      "┆   1 undo",
      "╷ + x1                                #2",
      "┆   1 undo",
    ]);
    assertEquals(await denops.call("line", "."), 2);
    assertEquals((await paneLabels(denops)).footer, " filter: x ");
  },
});

test({
  mode: "nvim",
  name: "g:diffundo_history = v:false keeps the minimal layout",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"]]);
    await denops.cmd("let g:diffundo_history = v:false");

    await denops.cmd("Diffundo earlier");

    await assertDiffSplit(denops, {
      undoLines: ["one"],
      sourceLines: ["one", "two"],
      undonr: 1,
      pane: false,
    });
  },
});
