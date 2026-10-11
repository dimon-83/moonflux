#!/bin/bash
# AUDIT-SDF-COVERAGE: the coverage claim, checked instead of asserted.
#
# docs/sdf-catalog-coverage.md is the authoritative answer to "is the example
# catalog done?". This script makes that answer falsifiable:
#
#   1  every table row has a status of `ported` or `non-goal` (nothing else)
#   2  a `ported` row names an example directory that EXISTS
#   3  a `ported` row's example is reachable from the example gate (the case
#      directory appears in scripts/e2e-p29-examples.sh)
#   4  a `non-goal` row explains itself (a reason/alternative in the last
#      column): a silent non-goal is exactly what this file is here to stop
#   5  the manifest's ported-case count equals the example gate's own count
#      ("N case specs across N example applications"), so the two cannot drift
#      apart in opposite directions
#
# The reference checkout (~/workspace/stateful-dataflow-examples) is NOT
# required: the manifest is ours, and this checks it against our own artifacts.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MANIFEST="docs/sdf-catalog-coverage.md"
SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    *) echo "usage: $0 [--manifest PATH] [--selftest]" >&2; exit 2 ;;
  esac
done
GATE="scripts/e2e-p29-examples.sh"
GATE2="scripts/e2e-p30-connector-examples.sh"

fail() { echo "AUDIT-SDF-COVERAGE FAIL: $*" >&2; exit 1; }
pass() { echo "AUDIT-SDF-COVERAGE PASS: $*"; }

[ -f "$MANIFEST" ] || fail "$MANIFEST is missing"
[ -f "$GATE" ] || fail "$GATE is missing"

ROWS_FILE="$(mktemp)"
trap 'rm -f "$ROWS_FILE"' EXIT
# the catalog and extension tables live above the non-goal section
awk '/^## 覆盖之外的三个明示非目标/ {exit} {print}' "$MANIFEST" > "$ROWS_FILE"
rows=$(grep -cE '^\|[^|]+\|[^|]+\|[^|]+\|' "$ROWS_FILE")
[ "$rows" -gt 0 ] || fail "the manifest has no catalog rows"

# ---- 1..4: every row is honest and its evidence exists -----------------
ported_cases=""
extension_cases=""
non_goals=0
data_rows=0
while IFS= read -r line; do
  # every table row is a catalog entry; headers and separators are not. The
  # filter must not require a backticked first column: rows without a
  # reference counterpart start with prose (measured — one extension row was
  # silently skipped by the stricter pattern, which is exactly the kind of
  # hole this audit exists to close).
  case "$line" in
    '|'*)
      printf '%s' "$line" | grep -qE '^\| *(:?-{3,}|参考条目|条目)' && continue
      ;;
    *) continue ;;
  esac
  printf '%s' "$line" | awk -F'|' '{print $2}' | grep -q '[^ 	]' || continue
  data_rows=$((data_rows + 1))
  item=$(printf '%s' "$line" | awk -F'|' '{print $2}' | sed 's/^ *//; s/ *$//')
  status=$(printf '%s' "$line" | awk -F'|' '{print $4}' | sed 's/^ *//; s/ *$//')
  case_dir=$(printf '%s' "$line" | awk -F'|' '{print $5}' | sed 's/^ *//; s/ *$//')
  note=$(printf '%s' "$line" | awk -F'|' '{print $6}' | sed 's/^ *//; s/ *$//')
  case "$status" in
    ported)
      [ -n "$case_dir" ] || fail "$item: ported but names no artifact"
      # a row may cite several artifacts, separated by " + "
      printf '%s' "$case_dir" | tr '+' '\n' | sed 's/^ *//; s/ *$//' | while IFS= read -r artefact; do
        [ -n "$artefact" ] || continue
        [ -e "$artefact" ] || { echo "MISSING $item $artefact"; exit 1; }
      done | grep -q MISSING && fail "$item: one of its artefacts does not exist"
      printf '%s' "$case_dir" | tr '+' '\n' | sed 's/^ *//; s/ *$//' | while IFS= read -r artefact; do
        [ -n "$artefact" ] || continue
        [ -e "$artefact" ] || fail "$item: $artefact does not exist"
      done
      for artefact in $(printf '%s' "$case_dir" | tr '+' ' '); do
        case "$artefact" in
          examples/sdf/*)
            base=$(basename "$artefact")
            grep -q "$base" "$GATE" || fail "$item: $base is not referenced by $GATE"
            ported_cases="$ported_cases $base"
            ;;
        esac
      done
      [ -n "$note" ] || fail "$item: ported but no gate leg is recorded"
      ;;
    extension)
      [ -n "$case_dir" ] || fail "$item: extension but names no artifact"
      [ -e "$case_dir" ] || fail "$item: names $case_dir, which does not exist"
      base=$(basename "$case_dir")
      # an extension case may live in either example gate (the connector
      # cases need their own peers, so they are gated by p30)
      grep -q "$base" "$GATE" || grep -q "$base" "$GATE2" ||
        fail "$item: $base is not referenced by $GATE or $GATE2"
      extension_cases="$extension_cases $base"
      ;;
    non-goal)
      non_goals=$((non_goals + 1))
      # the EXPLANATION lives in the last column for non-goal rows
      printf '%s' "$line" | awk -F'|' '{print $6 $7}' | grep -qE '理由|替代|明示不做|non-goal' ||
        fail "$item: non-goal without a reason or alternative"
      ;;
    *)
      fail "$item: status is '$status', and only ported/non-goal exist"
      ;;
  esac
done < "$ROWS_FILE"

unique_cases=$(printf '%s\n' $ported_cases | sort -u | wc -l | tr -d ' ')
[ "$unique_cases" -gt 0 ] || fail "no ported example cases found in the manifest"
unique_ext=$(printf '%s\n' $extension_cases | sort -u | wc -l | tr -d ' ')
total_cases=$((unique_cases + unique_ext))

# ---- 5: the manifest and the example gate agree on the count -----------
# The example cases are gated by two scripts: p29 (the catalog) and p30 (the
# connector cases, which need their own peers). The manifest covers both, so
# the count has to be the sum — an earlier version of this audit compared the
# manifest against p29 alone and caught that p29's own summary line was
# claiming the other gate's cases.
gate_line=$(grep -E "E2E-P29-EXAMPLES: [0-9]+ legs green" "$GATE" | tail -1)
[ -n "$gate_line" ] || fail "the example gate has no final count line"
gate_cases=$(printf '%s' "$gate_line" | sed -E 's/.*legs green \(([0-9]+) case specs.*/\1/')
gate2_cases=$(grep -o "EXAMPLES/[0-9][0-9]-[a-z-]*" "$GATE2" | sort -u | wc -l | tr -d ' ')
both=$((gate_cases + gate2_cases))
[ "$both" = "$total_cases" ] ||
  fail "the manifest lists $unique_cases catalog cases + $unique_ext extensions = $total_cases; the gates report $gate_cases + $gate2_cases = $both"

# the manifest's own statistics block must agree with its rows
grep -q "参考条目：\*\*26\*\*" "$MANIFEST" || fail "the manifest does not state the 26 catalog items"
grep -q "\`ported\` 案例目录：\*\*$unique_cases\*\*" "$MANIFEST" ||
  fail "the manifest's ported-case line does not say $unique_cases"
grep -q "\*\*扩展案例\*\*：\*\*$unique_ext\*\*" "$MANIFEST" ||
  fail "the manifest's extension count line does not say $unique_ext"
grep -q "\*\*案例合计：$total_cases\*\*" "$MANIFEST" ||
  fail "the manifest's total-case line does not say $total_cases"

for needed in "SQL 引擎" "wasm32-wasip2" "Rust 工具链"; do
  grep -q "$needed" "$MANIFEST" || fail "the non-goal section does not mention $needed"
done
grep -q "^| SQL 引擎" "$MANIFEST" || fail "the SQL non-goal row is missing"

if [ "$SELFTEST" = "1" ]; then
  # The audit is only worth having if a wrong manifest turns it red. Three
  # mutations, one per rule that matters: a missing artifact, a silent
  # non-goal, and a count that disagrees with the gate.
  ST="$(mktemp -d)"
  sed 's|examples/sdf/25-hackernews-notify|examples/sdf/99-does-not-exist|' "$MANIFEST" > "$ST/missing.md"
  if "$0" --manifest "$ST/missing.md" > /dev/null 2>&1; then
    fail "selftest: a ported row with a missing artifact was accepted"
  fi
  sed 's|理由：SQL 引擎不是本项目的目标（AGENTS §9）；替代：mbel 表达式 + 状态算子（`counter`/`average`/`balance`）+ 消费者侧查询，见缺口语录 §缺口 3|missing|' "$MANIFEST" > "$ST/silent.md"
  if grep -q "missing" "$ST/silent.md" && "$0" --manifest "$ST/silent.md" > /dev/null 2>&1; then
    fail "selftest: a non-goal without a reason was accepted"
  fi
  sed 's|`ported` 案例目录：\*\*21\*\*|`ported` 案例目录：**20**|' "$MANIFEST" > "$ST/count.md"
  if grep -q '案例目录：\*\*20\*\*' "$ST/count.md" && "$0" --manifest "$ST/count.md" > /dev/null 2>&1; then
    fail "selftest: a wrong ported count was accepted"
  fi
  rm -rf "$ST"
  pass "selftest: a missing artifact, a silent non-goal and a wrong count are all rejected"
fi

pass "catalog rows checked: $data_rows ($unique_cases reference cases ported, $unique_ext extensions, $non_goals non-goals)"
pass "the gates agree: $gate_cases example cases (p29) + $gate2_cases connector cases (p30) = $both"
echo "AUDIT-SDF-COVERAGE: manifest and artifacts agree"
