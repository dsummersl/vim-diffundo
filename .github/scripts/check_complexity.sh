#!/usr/bin/env bash

# nounset: undefined variable outputs error message, and forces an exit
set -u
# errexit: abort script at first error
set -e

MAX_COMPLEXITY=5
MAX_LINES=80
SRC=(lua plugin)

functions() {
  ast-grep scan --json=compact --inline-rules "$(cat <<'RULE'
id: function
language: lua
rule:
  any:
    - kind: function_declaration
    - kind: function_definition
RULE
)" "${SRC[@]}"
}

branches() {
  ast-grep scan --json=compact --inline-rules "$(cat <<'RULE'
id: branch
language: lua
rule:
  any:
    - kind: if_statement
    - kind: elseif_statement
    - kind: while_statement
    - kind: for_statement
    - kind: repeat_statement
    - kind: binary_expression
      has:
        regex: '^(and|or)$'
RULE
)" "${SRC[@]}"
}

REPORT=$(jq -rn --argjson fns "$(functions)" --argjson brs "$(branches)" \
  --argjson maxcc "$MAX_COMPLEXITY" --argjson maxlines "$MAX_LINES" '
  def span: .range.end.line - .range.start.line;
  def name: .lines | split("\n")[0] | ltrimstr(" ") | .[0:60];
  def contains($b): .file == $b.file
    and .range.start.line <= $b.range.start.line
    and .range.end.line >= $b.range.end.line
    and (.range.byteOffset.start <= $b.range.byteOffset.start)
    and (.range.byteOffset.end >= $b.range.byteOffset.end);
  def innermost($b): [$fns[] | select(contains($b))] | min_by(span);
  ($brs | map(innermost(.) | select(. != null) | .range.byteOffset.start) | group_by(.) | map({key: (.[0] | tostring), value: length}) | from_entries) as $counts
  | $fns[]
  | (1 + ($counts[.range.byteOffset.start | tostring] // 0)) as $cc
  | (span + 1) as $len
  | select($cc > $maxcc or $len > $maxlines)
  | "\(.file):\(.range.start.line + 1) - \(name) (complexity \($cc), \($len) lines)"
')

echo "Functions over complexity $MAX_COMPLEXITY or $MAX_LINES lines:"
echo "$REPORT"
[[ -z "$REPORT" ]]
