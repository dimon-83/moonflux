// SPDX-License-Identifier: Apache-2.0
// moonflux — core/codec: IEEE CRC-32 (reflected polynomial 0xEDB88320),
// table-driven, deterministic. Used by the wire protocol and the
// partition log for frame integrity.

///|
/// 256-entry lookup table, computed once at package initialization.
/// The computation is a pure function of the polynomial, so package
/// init stays deterministic on every backend.
let crc32_table : FixedArray[UInt] = crc32_build_table()

///|
fn crc32_build_table() -> FixedArray[UInt] {
  let table : FixedArray[UInt] = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut c = i.reinterpret_as_uint()
    for _j in 0..<8 {
      c = if (c & 1U) == 1U { 0xEDB88320U ^ (c >> 1) } else { c >> 1 }
    }
    table[i] = c
  }
  table
}

///|
/// CRC-32 of a byte view, in one shot.
pub fn crc32_view(data : BytesView) -> UInt {
  crc32_extend_view(0U, data)
}

///|
/// CRC-32 of owned bytes, in one shot.
pub fn crc32(data : Bytes) -> UInt {
  crc32_view(data[0:data.length()])
}

///|
/// Continues a CRC-32 run over `data`. `crc` must be the FINAL value
/// of the previous run (e.g. the result of `crc32`); the composition
/// law `crc32(a ++ b) == crc32_extend(crc32(a), b)` holds.
pub fn crc32_extend(crc : UInt, data : Bytes) -> UInt {
  crc32_extend_view(crc, data[0:data.length()])
}

///|
/// View-taking variant of `crc32_extend`.
pub fn crc32_extend_view(crc : UInt, data : BytesView) -> UInt {
  let mut c = crc.lnot()
  for i in 0..<data.length() {
    let idx = ((c ^ data[i].to_int().reinterpret_as_uint()) & 0xFFU).reinterpret_as_int()
    c = crc32_table[idx] ^ (c >> 8)
  }
  c.lnot()
}
