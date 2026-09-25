import { withDenops } from "@denops/test";
import type { Denops } from "@denops/core";
import { fromFileUrl } from "@std/path";

const pluginRoot = fromFileUrl(new URL("../../", import.meta.url));

const prelude = [
  `set runtimepath^=${pluginRoot}`,
  "runtime! plugin/diffundo.lua",
  "set nohidden",
];

function plain(v: unknown): unknown {
  if (typeof v === "bigint") return Number(v);
  if (Array.isArray(v)) return v.map(plain);
  if (v && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      out[k] = plain(val);
    }
    return out;
  }
  return v;
}

async function state(denops: Denops, lines: string[]): Promise<void> {
  const quoted = lines.map((l) => `'${l.replaceAll("'", "''")}'`).join(", ");
  await denops.cmd(`call setline(1, [${quoted}])`);
  await denops.cmd("let &undolevels = &undolevels");
}

async function show(
  denops: Denops,
  name: string,
  srcTree: Record<string, unknown>,
  srcSeqCur: number,
): Promise<void> {
  console.log(`===== ${name} =====`);
  console.log(`--- undotree (source) seq_cur=${srcSeqCur} ---`);
  console.log(JSON.stringify(srcTree, null, 1));
  const rows = plain(await denops.eval("t:diffundo_history_rows")) as unknown[];
  console.log(`--- rows (seq parent save added removed) ---`);
  for (
    const r of rows as {
      seq: number;
      parent: number;
      save: number | null;
      added: string[];
      removed: string[];
    }[]
  ) {
    console.log(
      `  ${r.seq} ${r.parent} ${
        r.save ?? "-"
      } +${r.added.length} -${r.removed.length} :: add=${
        JSON.stringify(r.added)
      } rem=${JSON.stringify(r.removed)}`,
    );
  }

  const wins = await denops.call("nvim_list_wins") as number[];
  const floats: { lines: string[]; height: number }[] = [];
  for (const win of wins) {
    const config = await denops.call("nvim_win_get_config", win) as Record<
      string,
      unknown
    >;
    if (config.relative !== "editor") continue;
    const buf = await denops.call("nvim_win_get_buf", win) as number;
    const lines = await denops.call(
      "nvim_buf_get_lines",
      buf,
      0,
      -1,
      false,
    ) as string[];
    floats.push({ lines, height: config.height as number });
  }
  floats.sort((a, b) => a.height - b.height);
  const footer = floats.find((f) =>
    f.lines[f.lines.length - 1]?.endsWith("help: g?")
  );
  const treeFloat = floats.find((f) => f !== footer);
  console.log(`--- tree float (${treeFloat?.lines.length ?? 0} lines) ---`);
  for (const l of treeFloat?.lines ?? []) console.log(`  |${l}|`);
  console.log(`--- footer ---`);
  for (const l of footer?.lines ?? []) console.log(`  |${l}|`);

  const disp = plain(await denops.eval("t:diffundo_history_display")) as {
    folds: { start: number; stop: number }[];
    captions: Record<string, string>;
    row_to_line: number[];
  };
  console.log(`--- folds: ${JSON.stringify(disp?.folds ?? null)} ---`);
  console.log(`--- captions: ${JSON.stringify(disp?.captions ?? null)} ---`);
  console.log(
    `--- row_to_line: ${JSON.stringify(disp?.row_to_line ?? null)} ---`,
  );
  console.log();
}

interface Scenario {
  name: string;
  build: (denops: Denops) => Promise<void>;
}

const scenarios: Scenario[] = [
  {
    name: "linear a, ab, abc",
    build: async (denops) => {
      await state(denops, ["a"]);
      await state(denops, ["a", "b"]);
      await state(denops, ["a", "b", "c"]);
    },
  },
  {
    name: "branch off middle (a, ab, abc; undo 1; ax)",
    build: async (denops) => {
      await state(denops, ["a"]);
      await state(denops, ["a", "b"]);
      await state(denops, ["a", "b", "c"]);
      await denops.cmd("silent undo 1");
      await state(denops, ["a", "x"]);
    },
  },
  {
    name: "two siblings off middle (undo 1; ax then ay)",
    build: async (denops) => {
      await state(denops, ["a"]);
      await state(denops, ["a", "b"]);
      await state(denops, ["a", "b", "c"]);
      await denops.cmd("silent undo 1");
      await state(denops, ["a", "x"]);
      await denops.cmd("silent undo 1");
      await state(denops, ["a", "y"]);
    },
  },
  {
    name: "nested branch (a, ab, abc; undo 1; ax; undo 4; axx)",
    build: async (denops) => {
      await state(denops, ["a"]);
      await state(denops, ["a", "b"]);
      await state(denops, ["a", "b", "c"]);
      await denops.cmd("silent undo 1");
      await state(denops, ["a", "x"]);
      await denops.cmd("silent undo 4");
      await state(denops, ["a", "x", "xx"]);
    },
  },
  {
    name: "branch off original (a; undo 0; z)",
    build: async (denops) => {
      await state(denops, ["a"]);
      await denops.cmd("silent undo 0");
      await state(denops, ["z"]);
    },
  },
  {
    name: "saves on trunk then branch (write each; undo 1; ax)",
    build: async (denops) => {
      const path = await denops.call("tempname") as string;
      await denops.cmd(`edit ${path}`);
      await state(denops, ["a"]);
      await denops.cmd("write");
      await state(denops, ["a", "b"]);
      await denops.cmd("write");
      await state(denops, ["a", "b", "c"]);
      await denops.cmd("write");
      await denops.cmd("silent undo 1");
      await state(denops, ["a", "x"]);
    },
  },
  {
    name:
      "current on the trunk below a branch (a, ab, abc; undo 1; ax; undo to trunk 2)",
    build: async (denops) => {
      await state(denops, ["a"]);
      await state(denops, ["a", "b"]);
      await state(denops, ["a", "b", "c"]);
      await denops.cmd("silent undo 1");
      await state(denops, ["a", "x"]);
      await denops.cmd("silent undo 2");
    },
  },
  {
    name: "foldable branch chain (trunk 1..8; undo 2; new 9)",
    build: async (denops) => {
      await state(denops, ["a"]);
      await state(denops, ["a", "b"]);
      await state(denops, ["a", "b", "c"]);
      await state(denops, ["a", "b", "c", "d"]);
      await state(denops, ["a", "b", "c", "d", "e"]);
      await state(denops, ["a", "b", "c", "d", "e", "f"]);
      await state(denops, ["a", "b", "c", "d", "e", "f", "g"]);
      await state(denops, ["a", "b", "c", "d", "e", "f", "g", "h"]);
      await denops.cmd("silent undo 2");
      await state(denops, ["a", "b", "i"]);
    },
  },
  {
    name: "long alternate off early trunk (trunk 1..7; undo 1; alt 8..14)",
    build: async (denops) => {
      await state(denops, ["a"]);
      await state(denops, ["a", "b"]);
      await state(denops, ["a", "b", "c"]);
      await state(denops, ["a", "b", "c", "d"]);
      await state(denops, ["a", "b", "c", "d", "e"]);
      await state(denops, ["a", "b", "c", "d", "e", "f"]);
      await state(denops, ["a", "b", "c", "d", "e", "f", "g"]);
      await denops.cmd("silent undo 1");
      await state(denops, ["a", "u"]);
      await state(denops, ["a", "u", "v"]);
      await state(denops, ["a", "u", "v", "w"]);
      await state(denops, ["a", "u", "v", "w", "q"]);
      await state(denops, ["a", "u", "v", "w", "q", "r"]);
      await state(denops, ["a", "u", "v", "w", "q", "r", "s"]);
      await state(denops, ["a", "u", "v", "w", "q", "r", "s", "t"]);
    },
  },
];

await withDenops("nvim", async (denops) => {
  await denops.cmd("enew");
  for (const scenario of scenarios) {
    await scenario.build(denops);
    const srcTree = plain(await denops.call("undotree")) as Record<
      string,
      unknown
    >;
    const srcSeqCur = await denops.eval("undotree().seq_cur") as number;
    await denops.cmd("Diffundo history");
    await show(denops, scenario.name, srcTree, srcSeqCur);
    await denops.cmd("Diffundo history");
    await denops.cmd("enew!");
  }
}, { prelude });
