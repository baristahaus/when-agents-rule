# Where an agent's defaults mislead it, in Odin

Not a style guide — the compiler enforces style. This is about the handful of places where what
you would write in Rust or TypeScript is *wrong* here, with the failure mode named.

- **Bitwise XOR is `~`. `^` is pointer dereference only.** Every `^` you copy out of the
  reference's `hashSeed` and `mulberry32` must become `~`, and `^u32` in a signature means
  `*u32` in Rust. The failure mode is the worst kind: a *syntax* error whose message points at an
  unrelated token (`Expected ')', got 'identifier'` at the operand, because the parser reads `^`
  as a prefix operator), so you spend twenty minutes suspecting the cast or the precedence.
  Measured spellings: `a ~ b`, `(a ~ b) ~ a` and `(a + (a ~ b)) ~ a` all parse; `a ^ b` does not.
- **No implicit conversions, and no operator overloading.** `u32 + int` is an error, `f64(u32)`
  is a conversion call, and `a == b` between distinct numeric types does not compile. The cost is
  two hundred small errors; the benefit is that the cost/age/roster tables cannot promote
  themselves, which for a sim whose whole claim is a reproducible answer is the point.
- **Slices and arrays are not the same thing, and arrays are values.** `[:]u8` is a pointer plus a
  length; `[N]u8` is the bytes. Passing an array to a procedure copies it. The reference's
  serialization is a stream of JSON strings, so the natural Odin form is `[N]u8` for fixed shapes
  and `[]u8` for the wire — mixing them compiles and then corrupts nothing, which is why the
  mistake is quiet: it just gets slower and copies where you meant to alias.
- **Reverse iteration is not `for x in reverse 0 ..< n`.** That is a syntax error here. Either
  iterate a collection with `for j, x in reverse collection`, or write the C form
  (`for j := dn - 1; j >= 0; j -= 1`), which is what the spike does for its decimal digits.
- **`or_return`, `?:`, and `defect` are not Rust's `?`.** A `!T` result must be handled at the
  call site or the procedure's own signature says `!`. Silence is not allowed, which is the same
  value the rules put on "visible, not absorbed" — but it will account for most of an agent's
  first-day errors.
- **Allocations go through the context.** `context.allocator` is implicit in every proc, and
  changing it changes everything downstream. For a match that runs for half an hour, one arena per
  match is the shape, and the memory tracker (see `reference/build.md` for its real name in this
  version) is what proves it drained.
- **No methods, no traits, no operator overloading.** `draw(state, key)` rather than
  `state.draw(key)`. This reads as primitive and is exactly right for a deterministic port: the
  order of operations is written where it happens, with no implicit receiver and no dispatch.
- **The package clause must match the directory**, and the executable's package is `main`.
  `spike/odin/` therefore cannot be `package spike`; both spike packages are `package main`.
