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

async function floatLines(denops: Denops, win: number): Promise<string[]> {
  const buf = await denops.call("nvim_win_get_buf", win) as number;
  return await denops.call("nvim_buf_get_lines", buf, 0, -1, false) as string[];
}

// WHY: the sidebar opens two floats: a tall tree float holding just the
// row/caption lines, and a 2-row footer float pinned below it (`enter=false`)
// whose last line carries the `help: g?` key hint.
async function isFooterFloat(denops: Denops, win: number): Promise<boolean> {
  const config = await denops.call("nvim_win_get_config", win) as {
    height?: number;
  };
  if (config.height !== 2) return false;
  const lines = await floatLines(denops, win);
  const last = lines[lines.length - 1];
  return last !== undefined && last.endsWith("help: g?");
}

interface FloatRoster {
  tree: number | null;
  footer: number | null;
  count: number;
}

// WHY: every history panel is one tree float plus one footer float; the tree
// is distinguished as the float that is not the 2-row footer.
async function floatRoster(denops: Denops): Promise<FloatRoster> {
  const roster: FloatRoster = { tree: null, footer: null, count: 0 };
  for (const win of await winIds(denops)) {
    if (!(await isFloat(denops, win))) continue;
    roster.count += 1;
    if (await isFooterFloat(denops, win)) {
      roster.footer = win;
    } else {
      roster.tree = win;
    }
  }
  return roster;
}

// WHY: the plugin reports its own failures with print() rather than raising,
// so they never reject the denops call and only show up in :messages.
function captionStrings(captions: unknown): string[] {
  if (Array.isArray(captions)) {
    return (captions as (string | null)[]).filter((v): v is string =>
      typeof v === "string"
    );
  }
  return Object.values(captions as Record<string, unknown>).filter(
    (v): v is string => typeof v === "string",
  );
}

async function treeFloatLines(denops: Denops): Promise<string[]> {
  const { tree } = await floatRoster(denops);
  assert(tree, "the tree float is open");
  return await floatLines(denops, tree);
}

function stripTime(line: string): string {
  return line.replace(/\s*(?:now|\d+[smhdw]) - (\d+)$/, " TIME-$1");
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
    floats?: number;
  },
): Promise<void> {
  await assertNoErrors(denops);

  // WHY: :Diffundo opens the two-float history by default alongside the split;
  // -no-history commands pass floats: 0 for the minimal layout.
  const { tree, footer, count } = await floatRoster(denops);
  const expectedFloats = expected.floats ?? 2;
  assertEquals(count, expectedFloats, "expected history float count");
  if (expectedFloats === 2) {
    // WHY: the panel is the focused tree float plus its pinned footer float.
    assert(tree, "the tree float is open");
    assert(footer, "the footer float is open");
    const columns = await denops.eval("&columns") as number;
    assertEquals(
      await denops.call("nvim_win_get_position", tree),
      [0, columns - 40],
    );
    const footerLines = await floatLines(denops, footer);
    assert(
      footerLines[footerLines.length - 1].endsWith("help: g?"),
      footerLines.join("\n"),
    );
  }

  const windows = await windowStates(denops);
  const undoBuffer = windows.find((w) => w.buftype === "nofile");
  const sourceBuffer = windows.find((w) => w.buftype === "");

  assert(undoBuffer, "the undo history buffer is not open");
  assert(sourceBuffer, "the source buffer is not open");
  assertEquals(undoBuffer.lines, expected.undoLines);
  assertEquals(sourceBuffer.lines, expected.sourceLines);
  assertEquals([undoBuffer.diff, sourceBuffer.diff], [1, 1]);

  // WHY: the label stays visible via the statusline; the winbar is only set
  // when the editor already uses one, so the diff lines never shift a row
  // below the source window's.
  assert(undoBuffer.name.endsWith(`- ${expected.undonr}`), undoBuffer.name);
  assertEquals(undoBuffer.statusline, undoBuffer.name);
  assertEquals(undoBuffer.winbar, "");
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

// WHY: :Diffundo history opens the two-float sidebar by default.
async function assertHistory(
  denops: Denops,
  expected: string[],
): Promise<void> {
  await assertNoErrors(denops);
  const { tree, footer, count } = await floatRoster(denops);
  assertEquals(count, 2, "expected exactly two history floats");
  assert(tree, "the tree float is open");
  assert(footer, "the footer float is open");

  // WHY: the sidebar defaults to the upper right of the editor, flush against
  // the right edge, with the default width of 40.
  const columns = await denops.eval("&columns") as number;
  assertEquals(
    await denops.call("nvim_win_get_position", tree),
    [0, columns - 40],
  );

  // WHY: the footer float pins the #N status and key hint under the tree.
  const footerLines = await floatLines(denops, footer);
  assert(
    footerLines[footerLines.length - 1].endsWith("help: g?"),
    footerLines.join("\n"),
  );

  const buf = await denops.call("nvim_win_get_buf", tree) as number;
  const lines = await denops.call(
    "nvim_buf_get_lines",
    buf,
    0,
    -1,
    false,
  ) as string[];
  assertEquals(lines, expected);
  // WHY: the user lands in the tree float, keyboard-first.
  assertEquals(await denops.call("nvim_get_current_win"), tree);
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
  name: "the diff split keeps source and diff lines on the same screen row",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["one"], ["one", "two"], [
      "one",
      "two",
      "three",
    ]]);

    // WHY: without -no-history the two floats add their own windows, so the
    // alignment check needs the minimal two-window layout.
    await denops.cmd("set winbar=");
    await denops.cmd("Diffundo -no-history earlier");

    // WHY: a winbar on the diff window alone would push its buffer down a
    // row; the source and diff line 1 must land on the same screen row.
    await denops.cmd("redraw");
    const rows = await denops.eval(
      "map(range(1, winnr('$')), {_, w -> screenpos(win_getid(w), 1, 1).row})",
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
  name:
    ":Diffundo earlier {N}f steps back to the state of an earlier file write",
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
  name:
    "`.` repeats :Diffundo earlier 1f from one file write to the previous one",
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
    assert(lines.length >= 1, "the tree float shows the newest state first");
    // WHY: the tree float holds only the rows, so the #N status and key hint
    // live in the separate footer float pinned below it.
    const { tree, footer, count } = await floatRoster(denops);
    assertEquals(count, 2, "expected tree + footer floats");
    assert(tree, "the tree float is open");
    assert(footer, "the footer float is open");
    assertEquals(
      await denops.call("nvim_get_current_win"),
      tree,
      "the tree float is focused",
    );
    const footerBlob = (await floatLines(denops, footer)).join("\n");
    assert(footerBlob.includes("#2"), footerBlob);
    assert(footerBlob.includes("help: g?"), footerBlob);
    await assertHistory(denops, lines);

    await denops.cmd("Diffundo history");
    // WHY: toggled off, the current window is the source again and both
    // floats are gone.
    assertEquals((await denops.eval("&buftype")) as string, "");
    assertEquals(
      (await floatRoster(denops)).count,
      0,
      "both floats close on toggle off",
    );
  },
});

test({
  mode: "nvim",
  name: "a long branch stretch folds into a caption and zo unfolds it",
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

    await denops.cmd("Diffundo history");

    const { tree, count } = await floatRoster(denops);
    assertEquals(count, 2, "expected tree + footer floats");
    assert(tree, "the tree float is open");
    const display = await denops.eval("t:diffundo_history_display") as {
      folds: { start: number; stop: number }[];
      captions: unknown;
      row_to_line: number[];
    };
    assertEquals(display.folds, [{ start: 3, stop: 6 }]);
    const caption = captionStrings(display.captions)[0];
    assertEquals(caption, "+4 states: +4 -0 lines 4 undos");
    assertEquals(
      display.row_to_line,
      [1, 2, 3, 4, 5, 6, 7, 8, 9],
    );

    const foldStart = display.folds[0].start;
    assertEquals(await denops.call("foldclosed", foldStart), foldStart);
    await denops.cmd(`${foldStart}normal! zo`);
    assertEquals(await denops.call("foldclosed", foldStart), -1);
  },
});

async function assertRenderedTree(
  denops: Denops,
  expected: string[],
  status: RegExp,
  total: number,
): Promise<void> {
  const lines = await treeFloatLines(denops);
  assertEquals(lines.length, expected.length);
  for (let i = 0; i < expected.length; i++) {
    assertEquals(
      stripTime(lines[i]),
      stripTime(expected[i]),
      `tree line ${i + 1}`,
    );
  }
  const footer = await floatLines(denops, (await floatRoster(denops)).footer!);
  assert(status.test(footer[0]), footer[0]);
  assertEquals(
    footer[footer.length - 1],
    `${total}/${total}`.padEnd(40 - "help: g?".length) + "help: g?",
  );
}

test({
  mode: "nvim",
  name: "history renders a branch off the middle with junction gutters",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["a"], ["a", "b"], ["a", "b", "c"]]);
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "x"]);

    await denops.cmd("Diffundo history");

    await assertRenderedTree(
      denops,
      [
        "○  + x                           now - 4",
        "├┘ + c                           now - 3",
        "├┘ + b                           now - 2",
        "│  +1 -1 lines                   now - 1",
      ],
      /^#4 ○ .*\+1 -0$/,
      4,
    );
  },
});

test({
  mode: "nvim",
  name: "history renders two sibling branches on shared lanes",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["a"], ["a", "b"], ["a", "b", "c"]]);
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "x"]);
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "y"]);

    await denops.cmd("Diffundo history");

    await assertRenderedTree(
      denops,
      [
        "○  + y                           now - 5",
        "├┘ + x                           now - 4",
        "┊│ + c                           now - 3",
        "├┘ + b                           now - 2",
        "│  +1 -1 lines                   now - 1",
      ],
      /^#5 ○ .*\+1 -0$/,
      5,
    );
  },
});

test({
  mode: "nvim",
  name: "history renders a branch off a branch on its own lane",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["a"], ["a", "b"], ["a", "b", "c"]]);
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "x"]);
    await denops.cmd("silent undo 4");
    await appendState(denops, ["a", "x", "xx"]);

    await denops.cmd("Diffundo history");

    await assertRenderedTree(
      denops,
      [
        "○  + xx                          now - 5",
        "│  + x                           now - 4",
        "├┘ + c                           now - 3",
        "├┘ + b                           now - 2",
        "│  +1 -1 lines                   now - 1",
      ],
      /^#5 ○ .*\+1 -0$/,
      5,
    );
  },
});

test({
  mode: "nvim",
  name: "history renders a branch off the original text with two roots",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await appendState(denops, ["a"]);
    await denops.cmd("silent undo 0");
    await appendState(denops, ["z"]);

    await denops.cmd("Diffundo history");

    await assertRenderedTree(
      denops,
      [
        "○ +1 -1 lines                    now - 2",
        "│ +1 -1 lines                    now - 1",
      ],
      /^#2 ○ .*\+1 -1$/,
      2,
    );
  },
});

test({
  mode: "nvim",
  name: "history marks saved states with ● and shows the current in the footer",
  prelude,
  fn: async (denops) => {
    const path = await denops.call("tempname") as string;
    await denops.cmd(`edit ${path}`);
    await appendState(denops, ["a"]);
    await denops.cmd("write");
    await appendState(denops, ["a", "b"]);
    await denops.cmd("write");
    await appendState(denops, ["a", "b", "c"]);
    await denops.cmd("write");
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "x"]);

    await denops.cmd("Diffundo history");

    await assertRenderedTree(
      denops,
      [
        "○  + x                           now - 4",
        "├┘ + c                           now - 3",
        "├┘ + b                           now - 2",
        "●  +1 -1 lines                   now - 1",
      ],
      /^#4 ○ .*\+1 -0$/,
      4,
    );
  },
});

test({
  mode: "nvim",
  name: "history marks the current state that sits on the trunk below a branch",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [["a"], ["a", "b"], ["a", "b", "c"]]);
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "x"]);
    await denops.cmd("silent undo 2");

    await denops.cmd("Diffundo history");

    await assertRenderedTree(
      denops,
      [
        "│  + x                           now - 4",
        "├┘ + c                           now - 3",
        "├┘ + b                           now - 2",
        "│  +1 -1 lines                   now - 1",
      ],
      /^#2 ○ .*\+1 -0$/,
      4,
    );
  },
});

test({
  mode: "nvim",
  name: "history folds a long alternate chain hanging off an early trunk state",
  prelude,
  fn: async (denops) => {
    await denops.cmd("enew");
    await buildHistory(denops, [
      ["a"],
      ["a", "b"],
      ["a", "b", "c"],
      ["a", "b", "c", "d"],
      ["a", "b", "c", "d", "e"],
      ["a", "b", "c", "d", "e", "f"],
      ["a", "b", "c", "d", "e", "f", "g"],
    ]);
    await denops.cmd("silent undo 1");
    await appendState(denops, ["a", "u"]);
    await appendState(denops, ["a", "u", "v"]);
    await appendState(denops, ["a", "u", "v", "w"]);
    await appendState(denops, ["a", "u", "v", "w", "q"]);
    await appendState(denops, ["a", "u", "v", "w", "q", "r"]);
    await appendState(denops, ["a", "u", "v", "w", "q", "r", "s"]);
    await appendState(denops, ["a", "u", "v", "w", "q", "r", "s", "t"]);

    await denops.cmd("Diffundo history");

    await assertRenderedTree(
      denops,
      [
        "○  + t                          now - 14",
        "│  + s                          now - 13",
        "│  + r                          now - 12",
        "│  + q                          now - 11",
        "│  + w                          now - 10",
        "│  + v                           now - 9",
        "│  + u                           now - 8",
        "├┘ + g                           now - 7",
        "┊│ + f                           now - 6",
        "┊│ + e                           now - 5",
        "┊│ + d                           now - 4",
        "┊│ + c                           now - 3",
        "├┘ + b                           now - 2",
        "│  +1 -1 lines                   now - 1",
      ],
      /^#14 ○ .*\+1 -0$/,
      14,
    );

    const display = await denops.eval("t:diffundo_history_display") as {
      folds: { start: number; stop: number }[];
      row_to_line: number[];
    };
    assertEquals(display.folds, [{ start: 9, stop: 12 }]);
    assertEquals(
      display.row_to_line,
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14],
    );
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

    // WHY: the tree float is current and holds only the rows, one per undo
    // state; its selected row (seq 2 / line 2) is the state the diff shows.
    // The rows end at line 3, so a single j lands on the last row (line 3,
    // the oldest state, seq 1) while jj would overshoot onto the empty space
    // below the rows, where <cr> has no row.
    assertEquals(await denops.eval("[line('.'), col('.')]"), [2, 1]);
    // WHY: g? in the float must surface the key help, not an empty message.
    await denops.call("feedkeys", "g?", "x");
    const hint = await denops.call("execute", "messages") as string;
    assert(hint.includes("saved jumps"), hint);
    await denops.cmd("messages clear");
    // Move to the oldest row (the last real row) and confirm it into the diff.
    // WHY: feedkeys never translates the <CR> keycode, so the Enter has to go
    // through nvim_input to reach the float's <cr> map.
    await denops.call("feedkeys", "j", "x");
    await denops.call("nvim_input", "<CR>");

    const window = (await windowStates(denops)).find((w) =>
      w.buftype === "nofile"
    );
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
