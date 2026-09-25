#!/usr/bin/env python3
"""Probe the exported ABI surface of built operator modules.

Reads the WAT emitted by `moon build --target wasm --output-wat` and
verifies, for every built operator module:

  * NO import section — a guest cannot reach the world (no WASI, no
    clock, no random source). This is the structural fact the host's
    purity assumption rests on, and it is checked HERE because a
    documented structural claim that no gate checks is folklore (P26
    closed that gap: the claim predates the check).
  * every ABI v1 export exists with its exact i32 signature (the
    buffered-call protocol).
  * ABI v2 (P26) is OPTIONAL but SYMMETRIC: a module exporting one of
    `mf_op_scalar_abi_version` / `mf_op_eval` must export BOTH, with
    the right signatures. A v1-only module (neither) stays valid.

Ground truth over binary guesswork: the WAT is the compiler's own
lowering.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

EXPECTED = {
    "mf_op_abi_version": "() -> (i32)",
    "mf_op_alloc_input": "(i32) -> (i32)",
    "mf_op_init": "(i32) -> (i32)",
    "mf_op_process": "(i32) -> (i32)",
    "mf_op_output_len": "() -> (i32)",
    "mf_op_last_status": "() -> (i32)",
    "mf_op_last_error": "() -> (i32)",
}

# ABI v2 (P26): optional as a pair — a scalar-capable module must
# export both, a v1-only module neither.
SCALAR_EXPECTED = {
    "mf_op_scalar_abi_version": "() -> (i32)",
    "mf_op_eval": "(i32, i32) -> (i32)",
}


def probe(wat_path: pathlib.Path) -> list:
    problems = []
    text = wat_path.read_text()
    # 1. the structural fact: no import section. A guest with imports
    #    could reach the world, and every purity claim would have to be
    #    re-earned by inspection.
    for line in text.split("\n"):
        if re.match(r"\s*\(import ", line):
            problems.append(
                f"{wat_path.name}: has an import section ({line.strip()}) — "
                "guests must have no imports"
            )
            break
    # Line-based parse (moonc WAT): definitions start at column 0 as
    # "(func $name (param ...) (result ...)"; export lines are
    # '(export "name" (func $name))' and would otherwise poison a
    # whole-text regex with bare references.
    export_fn = {}
    sigs = {}
    lines = wat_path.read_text().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r'\(export "([^"]+)" \(func \$([\w.]*)\)\)', line)
        if m:
            export_fn[m.group(1)] = m.group(2)
            i += 1
            continue
        m = re.match(r"\(func \$([\w.]*)", line)
        if not m or "(func $" in line.replace(line.split(")")[0] + ")", "", 1) and False:
            i += 1
            continue
        # function definition: header may span lines — accumulate until
        # prologue_end (or a balanced line for one-liners)
        name = m.group(1)
        buffer = line
        i += 1
        while i < len(lines) and "prologue_end" not in buffer and not buffer.rstrip().endswith("))"):
            buffer += "\n" + lines[i]
            i += 1
        # strip a trailing bare-reference usage: definitions always
        # contain param/result or prologue_end; skip references
        if "(param " not in buffer and "(result " not in buffer:
            continue
        def vec(kind):
            # every group of that kind, not just the first: named
            # params come one per parenthesized group
            groups = re.findall(r"\(" + kind + r"[^)]*\)", buffer)
            out = []
            for group in groups:
                out += re.findall(r"i32|i64|f32|f64", group)
            return out
        sigs[name] = "({}) -> ({})".format(
            ", ".join(vec("param")), ", ".join(vec("result"))
        )
        continue
    def check(table, optional_pair=False):
        present = sum(1 for name in table if name in export_fn)
        if optional_pair and present == 0:
            return  # v1-only module: valid, and the pair stays absent
        if optional_pair and present != len(table):
            problems.append(
                f"{wat_path.name}: scalar exports are a PAIR — "
                f"{sorted(n for n in table if n in export_fn)} present, "
                f"{sorted(n for n in table if n not in export_fn)} missing"
            )
        for name, expected_sig in table.items():
            fn = export_fn.get(name)
            if fn is None:
                if not optional_pair:
                    problems.append(f"{wat_path.name}: missing export {name}")
                continue
            sig = sigs.get(fn, "signature-not-found")
            if sig != expected_sig:
                problems.append(
                    f"{wat_path.name}: {name} has {sig}, expected {expected_sig}"
                )

    check(EXPECTED)
    check(SCALAR_EXPECTED, optional_pair=True)
    return problems


def main() -> int:
    problems = []
    for wat in ROOT.glob("_build/wasm/release/build/apps/operator-*/*.wat"):
        problems += probe(wat)
    for wat in ROOT.glob("_build/wasm/debug/build/apps/operator-*/*.wat"):
        problems += probe(wat)
    if problems:
        for p in problems:
            print(p, file=sys.stderr)
        return 1
    print("operator ABI surface OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
