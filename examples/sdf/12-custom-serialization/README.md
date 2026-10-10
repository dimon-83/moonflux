# 12 · custom serialization — read a field, write a new shape, round-trip

**Ported from** `stateful-dataflow-examples`: `primitives/custom-serialization/struct/{deserialize,serialize}`
（两个子示例：把一行 JSON 反序列化进一个带类型的结构体；把结构体再序列化出去）。

**Why this case did not exist before**: it was blocked, and the blocker was ours, not a
missing capability. The publish-time static check probed the record variable with the
literal `"a"` — a claim that the record is not JSON — so `fromJSON(value)` was rejected
before a single record flowed, even though the engine has always supported it. T108
replaced that single literal with two probe shapes built from the literals the expression
itself names (`{"maker":"maker"}` and `{"maker":1}`), so field access publishes while every
literal, type and name rejection stays (`scripts/e2e-p1-rules.sh` holds those).

**Three specs, matching the two SDF directions plus the strongest form of "faithful":**

| spec | expression | claim |
| :--- | :--- | :--- |
| `spec-deserialize.json` | `get(fromJSON(value), "maker")` | a named field comes out of the record |
| `spec-projection.json` | `toJSON(fromPairs([["car", get(fromJSON(value), "maker")], ["fast", get(fromJSON(value), "mph") > 60]]))` | fields go back out as a **new** shape, and a JSON number is compared as a number (that is the numeric probe shape earning its keep) |
| `spec-roundtrip.json` | `toJSON(fromPairs(toPairs(fromJSON(value))))` | parse → pairs → object → serialize is the input **byte for byte** |

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
for s in deserialize projection roundtrip; do
  $EXE pipeline run --data-dir "$(mktemp -d)" --spec "examples/sdf/12-custom-serialization/spec-$s.json"
done
```

**The difference worth knowing**: SDF's converter generates a typed struct and the
serde path enforces it at compile time; moonflux keeps the payload **opaque** and the
expression does the work, so a malformed record fails **closed at runtime** (per record,
bounded error text) rather than being rejected at publish. The round-trip leg is how we
state that the JSON view itself is faithful; it is not a schema guarantee.
