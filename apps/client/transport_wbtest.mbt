// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the native transports. The interesting case is
// not "a socket works" — it is "a socket answered in five pieces", and
// that is what `fill_exact` is for: it takes the source as a closure,
// so a scripted source can hand over a few bytes at a time without a
// peer, a thread, or a sleep (P15).

///|
priv struct ReadCursor {
  mut at : Int
  mut piece : Int
}

///|
/// A source that answers with the given piece sizes, repeating the
/// last one if the reader asks for more.
fn scripted_source(
  pieces : Array[Int],
  bytes : Bytes,
) -> (FixedArray[Byte], Int) -> Result[Int, String] {
  let cursor = ReadCursor::{ at: 0, piece: 0 }
  fn(buf, want) {
    if cursor.at >= bytes.length() {
      return Ok(0)
    }
    let index = cursor.piece
    let size = if index < pieces.length() {
      pieces[index]
    } else {
      pieces[pieces.length() - 1]
    }
    cursor.piece = index + 1
    let take = if size < want { size } else { want }
    let start = cursor.at
    let stop = if start + take < bytes.length() {
      start + take
    } else {
      bytes.length()
    }
    let got = stop - start
    cursor.at = stop
    // the pull contract: the bytes land in the caller's buffer, and
    // only the count comes back — a scripted source that skipped this
    // would be testing a different interface than the socket uses
    for i in 0..<got {
      buf[i] = bytes[start + i]
    }
    Ok(got)
  }
}

///|
test "fill_exact assembles a read that arrives in pieces" {
  let payload = b"0123456789abcdefghijklmnopqrstuvwxyz"
  // 3 + 11 + 7 + … : every piece is shorter than the request, which
  // is exactly the case the first implementation got wrong by writing
  // each piece at offset 0 and keeping only the last one
  let source = scripted_source([3, 11, 7], payload)
  let assembled = match fill_exact(payload.length(), source) {
    Ok(bytes) => bytes
    Err(e) => abort("fill_exact: \{e}")
  }
  assert_eq(assembled, payload)
}

///|
test "fill_exact writes pieces after what it already has, in order" {
  let payload = b"ABCDEFGHIJ"
  // read the first five bytes, then the next five: the second read
  // starts where the first stopped
  let source = scripted_source([5], payload)
  let head = match fill_exact(5, source) {
    Ok(bytes) => bytes
    Err(e) => abort("fill_exact head: \{e}")
  }
  let tail = match fill_exact(5, source) {
    Ok(bytes) => bytes
    Err(e) => abort("fill_exact tail: \{e}")
  }
  assert_eq(head, b"ABCDE")
  assert_eq(tail, b"FGHIJ")
}

///|
test "fill_exact reports a short stream instead of a short read" {
  let payload = b"only-four"
  let source = scripted_source([2], payload)
  assert_eq(
    fill_exact(20, source),
    Err("connection closed after 9 of 20 bytes"),
  )
}

///|
test "fill_exact refuses a source that claims to have read too much" {
  let source = fn(_buf, _want) { Ok(99) }
  assert_eq(
    fill_exact(4, source),
    Err("transport returned 99 bytes for a 4-byte read"),
  )
}

///|
test "a zero-length read is empty, not an error" {
  let source = scripted_source([4], b"abcd")
  assert_eq(fill_exact(0, source), Ok(b""))
}
