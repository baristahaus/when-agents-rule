package main

// §14.3's open question, measured instead of assumed: may the compiler turn `a*b + c` into a
// fused multiply-add? A fused op rounds once where the reference rounds twice, so a contraction
// in the movement math is a silent, seed-independent divergence — exactly the failure a port
// never sees coming, because the numbers stay plausible.
//
// The reference is IEEE-754 double throughout (JavaScript's `number`) and separates multiply
// from add at sites like the steering normalization, so this file does exactly one multiply and
// one add. The operands come from the *lengths of the command line*, which the compiler cannot
// know: a probe whose operands are literals can be constant-folded into an exact answer, and
// then it proves nothing about the instruction sequence. gate.sh counts FMA mnemonics in the
// object file. Zero means the compiler can be trusted with the determinism contract; nonzero
// means the flag that stops it must be recorded here, and if no flag does, spec §14.3 says the
// language decision reopens — in writing, not by drift.

import "core:fmt"
import "core:os"

// Not inline-able into a constant: the values arrive from the process environment.
probe :: proc(a, b, c: f64) -> f64 {
	return a * b + c
}

main :: proc() {
	n := len(os.args)
	a := f64(n) + 0.1                      // runtime, and not a round number
	b := f64(len(os.args[0])) * 3.0        // runtime
	c := f64(len(os.args[len(os.args)-1])) * 1.0e-9  // runtime
	got := probe(a, b, c)
	two_roundings := (a * b) + c           // spelled out: multiply, round, add, round

	// In the default rounding mode these agree for doubles even under fusion, which is exactly
	// why this test must read the *object file* and not the printed value: agreement here is not
	// the property, the instruction is. The values are printed so the file is also a runnable
	// spot-check, not so they can be trusted as the gate.
	fmt.println("probe:", got, "two roundings:", two_roundings, "agree:", got == two_roundings)
}
