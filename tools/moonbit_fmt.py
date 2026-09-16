#!/usr/bin/env python3
"""Helpers for emitting MoonBit source that `moon fmt` leaves alone.

Generated files are checked in and verified with `--check`, so they must
be byte-identical to the generator's output AND already formatted: if
fmt rewrites them, the next `--check` calls them stale and the gate
fails for a reason that has nothing to do with the data.

The rules below reproduce moon fmt's layout for the literals the
generators emit (flat structs of scalars and short arrays):
  * a line of at most FMT_WIDTH columns stays on one line;
  * an over-width struct literal expands to one field per line;
  * an over-width array literal wraps its items inside the brackets,
    packed to fit, each packed line ending in a comma.
"""

FMT_WIDTH = 80  # moon fmt's max line width


def mbt_str(s: str) -> str:
    """A MoonBit string literal for `s`."""
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def array_literal(items: list, prefix: str, elem_indent: str) -> str:
    """Renders an array literal of pre-rendered items. `prefix` is
    everything that precedes it on the field's line (indent + "name: ")
    and `elem_indent` is where wrapped items go — both matter because
    moon fmt measures the whole line, not the literal."""
    inline = "[%s]" % ", ".join(items)
    if len(prefix) + len(inline) <= FMT_WIDTH:
        return inline
    lines = []
    current = ""
    for item in items:
        candidate = item if not current else current + ", " + item
        if current and len(elem_indent) + len(candidate) + 1 > FMT_WIDTH:
            lines.append(current + ",")
            current = item
        else:
            current = candidate
    lines.append(current + ",")
    return "[\n%s%s]" % (
        "".join("%s%s\n" % (elem_indent, line) for line in lines),
        elem_indent[:-2],
    )


def struct_literal(name: str, fields: list, indent: int) -> str:
    """Renders `Name::{ f: v, ... },` as moon fmt would: inline when it
    fits, otherwise one field per line. Array values (passed as lists)
    are wrapped as needed."""
    pad = " " * indent
    inline = "%s::{ %s }," % (
        name,
        ", ".join("%s: %s" % (k, v) for k, v in fields),
    )
    if indent + len(inline) <= FMT_WIDTH:
        return pad + inline + "\n"
    field_pad = pad + "  "
    out = pad + "%s::{\n" % name
    for key, value in fields:
        prefix = "%s%s: " % (field_pad, key)
        if isinstance(value, list):
            value = array_literal(value, prefix, field_pad + "  ")
        out += "%s%s,\n" % (prefix, value)
    out += pad + "},\n"
    return out
