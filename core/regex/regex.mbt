// SPDX-License-Identifier: Apache-2.0
// core/regex: a small regular-expression engine (P30/T111). Pure
// computation: zero IO, zero clock, no third-party dependency; compiles
// for every backend (kernel red lines, AGENTS §5).
//
// WHY THOMPSON AND NOT BACKTRACKING: matching simulates a *set* of NFA
// states instead of exploring alternatives depth-first. The work is
// therefore linear in the input, and a hostile record cannot make a
// pattern blow up — `(a*)*b` costs the same whether or not it matches.
// This engine also serves the `regex` spec filter, so a pattern that
// cannot be honoured must never become a per-record surprise: compile()
// refuses what it does not support, by name.
//
// SEMANTICS, STATED SO THEY CANNOT BE ASSUMED:
//   * byte/ASCII oriented — records are byte strings. `.` matches any
//     byte except '\n'; \d \w \s are the ASCII classes.
//   * `^` and `$` are STRING anchors (offset 0 / end of input). There is
//     no multiline flag and no line-anchor mode.
//
// SUPPORTED: literals, `.`, `*` `+` `?`, `{n}` `{n,}` `{n,m}`, classes
// `[...]` / `[^...]` with ranges, `^` `$`, groups, alternation `|`, the
// escapes \d \D \w \W \s \S \n \t \r \f \v, and escaped metacharacters.
//
// REFUSED BY NAME: \b \B, backreferences (\1), lookaround / named groups /
// inline flags (`(?…`), lazy or possessive quantifiers (`*?` `+?` `??`
// `*+`), Unicode classes (\p{…} \P{…}), negated shorthand inside a class
// (\D \W \S in `[...]`), and ranges whose endpoints are not single
// characters.

///|
/// The parsed pattern.
priv enum Node {
  Empty
  Lit(UInt16)
  Any
  Class(Array[(UInt16, UInt16)], Bool)
  Start
  End
  Cat(Array[Node])
  Alt(Array[Node])
  /// min, max; max < 0 means unbounded
  Rep(Node, Int, Int)
}

///|
/// One NFA instruction. Every instruction carries its successor index;
/// `Split` has two, and alternation is just `Split`.
///
/// This type is public only because `Regex` holds an array of it: it is
/// the compiled program, not an author-facing API, and its constructors
/// stay private to this package.
pub enum Inst {
  Byte(UInt16, Int)
  AnyByte(Int)
  ClassByte(Array[(UInt16, UInt16)], Bool, Int)
  Split(Int, Int)
  Jmp(Int)
  AnchorStart(Int)
  AnchorEnd(Int)
  Match
}

///|
/// A compiled program. The fields are private: callers match with it, they
/// do not reach into it.
pub struct Regex {
  insts : Array[Inst]
  start : Int
}

///|
/// The parser's cursor over the pattern source.
priv struct Parser {
  src : String
  mut pos : Int
}

///|
/// Compiles a pattern, or explains why it will not.
pub fn compile(pattern : String) -> Result[Regex, String] {
  let p = Parser::{ src: pattern, pos: 0, }
  let node = match parse_alt(p) {
    Ok(node) => node
    Err(e) => return Err(e)
  }
  if p.pos != pattern.length() {
    return Err("unmatched ) at \{p.pos}")
  }
  let insts : Array[Inst] = [Match]
  let start = emit(insts, node, 0)
  Ok(Regex::{ insts, start, })
}

///|
/// True when the pattern matches anywhere in `text` (unanchored search).
pub fn is_match(re : Regex, text : String) -> Bool {
  let insts = re.insts
  let len = text.length()
  let mark : Array[Int] = []
  for _ in 0..<insts.length() {
    mark.push(0)
  }
  let mut gen = 1
  let mut pos = 0
  let mut clist : Array[Int] = []
  add_state(insts, re.start, 0, len, clist, mark, gen)
  while true {
    let mut hit = false
    for pc in clist {
      if insts[pc] is Match {
        hit = true
      }
    }
    if hit {
      return true
    }
    if pos >= len {
      return false
    }
    let b = text[pos]
    gen = gen + 1
    let nlist : Array[Int] = []
    for pc in clist {
      match insts[pc] {
        Byte(c, nx) =>
          if c == b {
            add_state(insts, nx, pos + 1, len, nlist, mark, gen)
          }
        AnyByte(nx) =>
          if b != 10 {
            add_state(insts, nx, pos + 1, len, nlist, mark, gen)
          }
        ClassByte(rs, neg, nx) =>
          if class_has(rs, neg, b) {
            add_state(insts, nx, pos + 1, len, nlist, mark, gen)
          }
        _ => ()
      }
    }
    // the unanchored search trick: the program may also start here
    add_state(insts, re.start, pos + 1, len, nlist, mark, gen)
    clist = nlist
    pos = pos + 1
  }
  false
}

// ---------------------------------------------------------------------
// Simulation

///|
/// Epsilon-closure: adds `pc` (and everything reachable without consuming
/// input) to `list`, honouring the anchors against the current position.
/// `mark`/`gen` deduplicate without clearing arrays between positions.
fn add_state(
  insts : Array[Inst],
  pc : Int,
  pos : Int,
  len : Int,
  list : Array[Int],
  mark : Array[Int],
  gen : Int,
) -> Unit {
  if mark[pc] == gen {
    return
  }
  mark[pc] = gen
  match insts[pc] {
    Split(a, b) => {
      add_state(insts, a, pos, len, list, mark, gen)
      add_state(insts, b, pos, len, list, mark, gen)
    }
    Jmp(a) => add_state(insts, a, pos, len, list, mark, gen)
    AnchorStart(a) =>
      if pos == 0 {
        add_state(insts, a, pos, len, list, mark, gen)
      }
    AnchorEnd(a) =>
      if pos == len {
        add_state(insts, a, pos, len, list, mark, gen)
      }
    _ => list.push(pc)
  }
}

///|
/// Membership in a class: any range contains the byte, XOR negation.
fn class_has(ranges : Array[(UInt16, UInt16)], neg : Bool, b : UInt16) -> Bool {
  let mut inside = false
  for r in ranges {
    if b >= r.0 && b <= r.1 {
      inside = true
    }
  }
  inside != neg
}

// ---------------------------------------------------------------------
// Compilation (emitted backwards, so concatenation is a fold)

///|
/// Emits `node` so that it continues at `next`, returning its entry index.
/// Backwards emission is what makes `Cat` a plain right-to-left fold.
fn emit(prog : Array[Inst], node : Node, next : Int) -> Int {
  match node {
    Empty => next
    Lit(c) => {
      prog.push(Byte(c, next))
      prog.length() - 1
    }
    Any => {
      prog.push(AnyByte(next))
      prog.length() - 1
    }
    Class(rs, neg) => {
      prog.push(ClassByte(rs, neg, next))
      prog.length() - 1
    }
    Start => {
      prog.push(AnchorStart(next))
      prog.length() - 1
    }
    End => {
      prog.push(AnchorEnd(next))
      prog.length() - 1
    }
    Cat(xs) => {
      let mut acc = next
      let mut i = xs.length()
      while i > 0 {
        i = i - 1
        acc = emit(prog, xs[i], acc)
      }
      acc
    }
    Alt(xs) => {
      if xs.length() == 0 {
        return next
      }
      let mut acc = emit(prog, xs[xs.length() - 1], next)
      let mut i = xs.length() - 1
      while i > 0 {
        i = i - 1
        let other = emit(prog, xs[i], next)
        prog.push(Split(other, acc))
        acc = prog.length() - 1
      }
      acc
    }
    Rep(x, lo, hi) =>
      if hi == 1 {
        // `x?`
        let body = emit(prog, x, next)
        prog.push(Split(body, next))
        prog.length() - 1
      } else if lo == 0 {
        // `x*`: reserve the split, emit the body back into it, patch
        let loop_idx = prog.length()
        prog.push(Jmp(-1))
        let body = emit(prog, x, loop_idx)
        prog[loop_idx] = Split(body, next)
        loop_idx
      } else {
        // `x+`: the same loop, entered through the body so it runs once
        let loop_idx = prog.length()
        prog.push(Jmp(-1))
        let body = emit(prog, x, loop_idx)
        prog[loop_idx] = Split(body, next)
        body
      }
  }
}

///|
/// Deep copy, so `{n,m}` expansion cannot share (or alias) subtrees.
fn clone_node(n : Node) -> Node {
  match n {
    Empty => Empty
    Lit(c) => Lit(c)
    Any => Any
    Class(rs, neg) => {
      let out : Array[(UInt16, UInt16)] = []
      for r in rs {
        out.push(r)
      }
      Class(out, neg)
    }
    Start => Start
    End => End
    Cat(xs) => {
      let out : Array[Node] = []
      for x in xs {
        out.push(clone_node(x))
      }
      Cat(out)
    }
    Alt(xs) => {
      let out : Array[Node] = []
      for x in xs {
        out.push(clone_node(x))
      }
      Alt(out)
    }
    Rep(x, lo, hi) => Rep(clone_node(x), lo, hi)
  }
}

// ---------------------------------------------------------------------
// Parsing

///|
/// The current byte as an Int (-1 at end of pattern).
fn peek(p : Parser) -> Int {
  if p.pos >= p.src.length() {
    -1
  } else {
    p.src[p.pos].to_int()
  }
}

///|
/// alternation := concat ('|' concat)*
fn parse_alt(p : Parser) -> Result[Node, String] {
  let branches : Array[Node] = []
  match parse_concat(p) {
    Ok(n) => branches.push(n)
    Err(e) => return Err(e)
  }
  while peek(p) == 124 {
    p.pos = p.pos + 1
    match parse_concat(p) {
      Ok(n) => branches.push(n)
      Err(e) => return Err(e)
    }
  }
  if branches.length() == 1 {
    Ok(branches[0])
  } else {
    Ok(Alt(branches))
  }
}

///|
/// concat := repeat*
fn parse_concat(p : Parser) -> Result[Node, String] {
  let items : Array[Node] = []
  while true {
    let c = peek(p)
    if c < 0 || c == 124 || c == 41 {
      break
    }
    match parse_repeat(p) {
      Ok(n) => items.push(n)
      Err(e) => return Err(e)
    }
  }
  if items.length() == 0 {
    Ok(Empty)
  } else if items.length() == 1 {
    Ok(items[0])
  } else {
    Ok(Cat(items))
  }
}

///|
/// repeat := atom quantifier?
fn parse_repeat(p : Parser) -> Result[Node, String] {
  let atom = match parse_atom(p) {
    Ok(n) => n
    Err(e) => return Err(e)
  }
  match peek(p) {
    42 => {
      p.pos = p.pos + 1
      match no_lazy(p) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      Ok(Rep(atom, 0, -1))
    }
    43 => {
      p.pos = p.pos + 1
      match no_lazy(p) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      Ok(Rep(atom, 1, -1))
    }
    63 => {
      p.pos = p.pos + 1
      match no_lazy(p) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      Ok(Rep(atom, 0, 1))
    }
    123 => {
      p.pos = p.pos + 1
      expand_braces(p, atom)
    }
    _ => Ok(atom)
  }
}

///|
/// `*?` `+?` `??` `*+` … are refused: a lazy quantifier would change which
/// match a *search* reports, and silently treating it as greedy is exactly
/// the kind of quiet mis-match this engine refuses to do.
fn no_lazy(p : Parser) -> Result[Unit, String] {
  let c = peek(p)
  if c == 63 || c == 43 {
    Err("unsupported construct: lazy or possessive quantifier")
  } else {
    Ok(())
  }
}

///|
/// `{n}` / `{n,}` / `{n,m}`, expanded into the three primitive repeats.
fn expand_braces(p : Parser, atom : Node) -> Result[Node, String] {
  let lo = match parse_number(p) {
    Ok(n) => n
    Err(e) => return Err(e)
  }
  let mut hi = lo
  let mut unbounded = false
  if peek(p) == 44 {
    p.pos = p.pos + 1
    if peek(p) == 125 {
      unbounded = true
    } else {
      hi = match parse_number(p) {
        Ok(n) => n
        Err(e) => return Err(e)
      }
    }
  }
  if peek(p) != 125 {
    return Err("invalid repetition range (expected })")
  }
  p.pos = p.pos + 1
  match no_lazy(p) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if !unbounded && hi < lo {
    return Err("invalid repetition range (max < min)")
  }
  if lo > 1000 || hi > 1000 {
    return Err("repetition count too large (max 1000)")
  }
  let parts : Array[Node] = []
  if unbounded {
    if lo == 0 {
      parts.push(Rep(clone_node(atom), 0, -1))
    } else {
      for _ in 0..<lo {
        parts.push(clone_node(atom))
      }
      parts.push(Rep(clone_node(atom), 0, -1))
    }
  } else {
    for _ in 0..<lo {
      parts.push(clone_node(atom))
    }
    for _ in 0..<(hi - lo) {
      parts.push(Rep(clone_node(atom), 0, 1))
    }
  }
  if parts.length() == 0 {
    Ok(Empty)
  } else if parts.length() == 1 {
    Ok(parts[0])
  } else {
    Ok(Cat(parts))
  }
}

///|
/// A decimal count inside `{…}`; bounded so a hostile pattern cannot ask
/// for a million instructions.
fn parse_number(p : Parser) -> Result[Int, String] {
  let mut n = 0
  let mut digits = 0
  while true {
    let c = peek(p)
    if c >= 48 && c <= 57 {
      n = n * 10 + (c - 48)
      digits = digits + 1
      if digits > 4 {
        return Err("repetition count too large (max 1000)")
      }
      p.pos = p.pos + 1
    } else {
      break
    }
  }
  if digits == 0 {
    Err("invalid repetition range (expected a number)")
  } else {
    Ok(n)
  }
}

///|
/// atom := '(' alt ')' | class | '.' | '^' | '$' | escape | literal
fn parse_atom(p : Parser) -> Result[Node, String] {
  let c = peek(p)
  if c < 0 {
    return Err("unexpected end of pattern")
  }
  match c {
    40 => {
      p.pos = p.pos + 1
      if peek(p) == 63 {
        return Err(
          "unsupported construct: (?…) group flags, lookaround or named group",
        )
      }
      let inner = match parse_alt(p) {
        Ok(n) => n
        Err(e) => return Err(e)
      }
      if peek(p) != 41 {
        return Err("unclosed group (expected ))")
      }
      p.pos = p.pos + 1
      Ok(inner)
    }
    91 => {
      p.pos = p.pos + 1
      parse_class(p)
    }
    46 => {
      p.pos = p.pos + 1
      Ok(Any)
    }
    94 => {
      p.pos = p.pos + 1
      Ok(Start)
    }
    36 => {
      p.pos = p.pos + 1
      Ok(End)
    }
    92 => {
      p.pos = p.pos + 1
      parse_escape(p)
    }
    42 | 43 | 63 => Err("nothing to repeat")
    41 => Err("unmatched )")
    123 => Err("invalid repetition range (nothing to repeat)")
    _ => {
      p.pos = p.pos + 1
      Ok(Lit(p.src[p.pos - 1]))
    }
  }
}

///|
/// class := '[' '^'? item+ ']', where an item is a character, an escape, or
/// a `a-z` range, and a `]` first up is a literal.
fn parse_class(p : Parser) -> Result[Node, String] {
  let mut neg = false
  if peek(p) == 94 {
    neg = true
    p.pos = p.pos + 1
  }
  let ranges : Array[(UInt16, UInt16)] = []
  let mut first = true
  while true {
    let c = peek(p)
    if c < 0 {
      return Err("unclosed character class")
    }
    if c == 93 && !first {
      p.pos = p.pos + 1
      return Ok(Class(ranges, neg))
    }
    first = false
    let (item, single) = match parse_class_item(p) {
      Ok(pair) => pair
      Err(e) => return Err(e)
    }
    if peek(p) == 45 && single {
      // a '-' that is not the last member is a range separator
      let save = p.pos
      p.pos = p.pos + 1
      if peek(p) == 93 {
        // trailing '-' is a literal
        p.pos = save
        for r in item {
          ranges.push(r)
        }
      } else {
        let (hi_item, hi_single) = match parse_class_item(p) {
          Ok(pair) => pair
          Err(e) => return Err(e)
        }
        if !hi_single {
          return Err(
            "character ranges need single-character endpoints (shorthand classes are sets)",
          )
        }
        let lo = item[0].0
        let hi = hi_item[0].0
        if hi < lo {
          return Err("invalid character range (end before start)")
        }
        ranges.push((lo, hi))
      }
    } else {
      if peek(p) == 45 && !single {
        return Err(
          "character ranges need single-character endpoints (shorthand classes are sets)",
        )
      }
      for r in item {
        ranges.push(r)
      }
    }
  } nobreak {
    Err(
      // unreachable: every exit above is a `return`, but the loop still has
      // to type-check as an expression
      "unclosed character class",
    )
  }
}

///|
/// One class member: a set of ranges, plus whether it is a single byte
/// (only single bytes may anchor a range).
fn parse_class_item(
  p : Parser,
) -> Result[(Array[(UInt16, UInt16)], Bool), String] {
  let c = peek(p)
  if c < 0 {
    return Err("unclosed character class")
  }
  if c == 92 {
    p.pos = p.pos + 1
    let e = peek(p)
    if e < 0 {
      return Err("dangling backslash in character class")
    }
    p.pos = p.pos + 1
    match e {
      100 => Ok((digit_ranges(), false))
      119 => Ok((word_ranges(), false))
      115 => Ok((space_ranges(), false))
      68 | 87 | 83 =>
        Err(
          "unsupported construct: negated shorthand inside a class (negate the class instead)",
        )
      98 | 66 => Err("unsupported construct: word boundary (\\b)")
      112 | 80 => Err("unsupported construct: Unicode class (\\p)")
      110 => Ok(([(10, 10)], true))
      116 => Ok(([(9, 9)], true))
      114 => Ok(([(13, 13)], true))
      102 => Ok(([(12, 12)], true))
      118 => Ok(([(11, 11)], true))
      _ =>
        match escaped_literal(e) {
          Some(b) => Ok(([(b, b)], true))
          None => Err("unknown escape in character class")
        }
    }
  } else {
    p.pos = p.pos + 1
    let b = p.src[p.pos - 1]
    Ok(([(b, b)], true))
  }
}

///|
/// An escape outside a class: a shorthand class, or a literal byte.
fn parse_escape(p : Parser) -> Result[Node, String] {
  let e = peek(p)
  if e < 0 {
    return Err("dangling backslash")
  }
  p.pos = p.pos + 1
  match e {
    100 => Ok(Class(digit_ranges(), false))
    68 => Ok(Class(digit_ranges(), true))
    119 => Ok(Class(word_ranges(), false))
    87 => Ok(Class(word_ranges(), true))
    115 => Ok(Class(space_ranges(), false))
    83 => Ok(Class(space_ranges(), true))
    98 | 66 => Err("unsupported construct: word boundary (\\b)")
    112 | 80 => Err("unsupported construct: Unicode class (\\p)")
    49 | 50 | 51 | 52 | 53 | 54 | 55 | 56 | 57 =>
      Err("unsupported construct: backreference")
    110 => Ok(Lit(10))
    116 => Ok(Lit(9))
    114 => Ok(Lit(13))
    102 => Ok(Lit(12))
    118 => Ok(Lit(11))
    _ =>
      match escaped_literal(e) {
        Some(b) => Ok(Lit(b))
        None => Err("unknown escape (byte \{e})")
      }
  }
}

///|
/// The bytes a backslash may quote into a literal.
fn escaped_literal(e : Int) -> UInt16? {
  if e == 46 ||
    e == 42 ||
    e == 43 ||
    e == 63 ||
    e == 40 ||
    e == 41 ||
    e == 91 ||
    e == 93 ||
    e == 123 ||
    e == 125 ||
    e == 124 ||
    e == 94 ||
    e == 36 ||
    e == 92 ||
    e == 47 ||
    e == 45 {
    Some(e.to_uint16())
  } else {
    None
  }
}

///|
fn digit_ranges() -> Array[(UInt16, UInt16)] {
  [(48, 57)]
}

///|
fn word_ranges() -> Array[(UInt16, UInt16)] {
  [(48, 57), (65, 90), (95, 95), (97, 122)]
}

///|
fn space_ranges() -> Array[(UInt16, UInt16)] {
  [(9, 13), (32, 32)]
}
