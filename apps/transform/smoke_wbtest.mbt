// apps/transform: mbel-backed dynamic rule execution for records
// (P1). The engine is seeded by mbel's builtin function library.
// Imports live in moon.pkg.

///|
test "mbel compiles once and evaluates per record (smoke)" {
  let engine = @mengine.new()
  engine.set_limits(10000, 100, 100000)
  engine.set_engine(@mengine.Vm)
  let expr = engine.compile("upper(value) + \"!\"")
  let ctx = @ast.ObjectVal([
    ("value", @ast.StrVal("hello")),
    ("key", @ast.StrVal("")),
  ])
  let out = expr.eval(ctx)
  assert_true(out is @ast.StrVal("HELLO!"))
  // second eval reuses the cached compiled program
  let ctx2 = @ast.ObjectVal([
    ("value", @ast.StrVal("again")),
    ("key", @ast.StrVal("")),
  ])
  assert_true(expr.eval(ctx2) is @ast.StrVal("AGAIN!"))
}
