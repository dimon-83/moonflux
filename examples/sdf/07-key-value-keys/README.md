# 07 · keys — the key rides the log

**Ported from** `primitives/key-value/{input,output,chained}`: a key travels
beside the value through every hop, and a chained function that drops the key
from its return tuple does **not** clear it for the next function.

**What SDF does**: the key is part of the operator's calling convention
(`Option<String>` in, `(Option<String>, U)` out), and the engine carries it.

**What moonflux does here**: the key is a first-class column of the log. It is
stamped at ingress (`produce --key-separator '>'`) and survives storage, so it
is visible on the way out (`consume` prints `offset\ttimestamp\tkey\tvalue`).

```bash
EXE=_build/native/debug/build/apps/cli/cli.exe
D=$(mktemp -d)
$EXE produce --topic kv --file examples/sdf/07-key-value-keys/users.txt --key-separator '>' --data-dir "$D"
$EXE consume --topic kv --from 0 --data-dir "$D" | cut -f3,4   # == expected-keys-values.txt
```

**Difference worth knowing**: moonflux has no key-*producing* operator form (no
equivalent of returning a new key from a transform). The key is set by the
producer or not at all; a transform chain preserves it. `produce --key` stamps a
constant key, `--key-separator` splits each line into key and value.
