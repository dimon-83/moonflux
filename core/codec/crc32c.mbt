// SPDX-License-Identifier: Apache-2.0
// moonflux — core/codec: CRC-32C (Castagnoli, reflected polynomial
// 0x82F63B78), table-driven, deterministic.
//
// Kafka checksums its record batches with THIS polynomial (P20), not
// the IEEE CRC-32 next door — and the difference is a silent integrity
// bug on the far side of the wire, not a style choice. Anchored by the
// standard check vector: crc32c("123456789") == 0xE3069283.

///|
/// 256-entry lookup table, computed once at package initialization.
/// Pure function of the polynomial, so package init stays deterministic
/// on every backend.
let crc32c_table : FixedArray[UInt] = crc32c_build_table()

///|
fn crc32c_build_table() -> FixedArray[UInt] {
  let table : FixedArray[UInt] = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut c = i.reinterpret_as_uint()
    for _j in 0..<8 {
      c = if (c & 1U) == 1U { 0x82F63B78U ^ (c >> 1) } else { c >> 1 }
    }
    table[i] = c
  }
  table
}

///|
/// CRC-32C of a byte view, in one shot.
pub fn crc32c_view(data : BytesView) -> UInt {
  crc32c_extend_view(0U, data)
}

///|
/// CRC-32C of owned bytes, in one shot.
pub fn crc32c(data : Bytes) -> UInt {
  crc32c_view(data[0:data.length()])
}

///|
/// Continues a CRC-32C run over `data`, same composition law as the
/// IEEE variant: `crc32c(a ++ b) == crc32c_extend(crc32c(a), b)`.
pub fn crc32c_extend(crc : UInt, data : Bytes) -> UInt {
  crc32c_extend_view(crc, data[0:data.length()])
}

///|
/// View-taking variant of `crc32c_extend`.
pub fn crc32c_extend_view(crc : UInt, data : BytesView) -> UInt {
  let mut c = crc.lnot()
  for i in 0..<data.length() {
    let idx = ((c ^ data[i].to_int().reinterpret_as_uint()) & 0xFFU).reinterpret_as_int()
    c = crc32c_table[idx] ^ (c >> 8)
  }
  c.lnot()
}
