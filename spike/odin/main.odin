package main

// The spike's only job: prove an Odin core can reproduce the reference's numbers exactly.
// It transcribes js/simulation/rng.js — the twelve load-bearing lines of it — and prints the two
// draws the golden pins (golden/MANIFEST.json, golden/keyed-vectors.md). Nothing here is a design
// idea. It is a transcription, and a transcription either matches or it does not.
//
// Why these two numbers and not a whole match: `draw(state, key)` is
//
//     stream(hashSeed(seed + "|" + key + "|" + n), 42)()
//
// so a single draw exercises the string hash, the integer mixing, and the one place a compiled
// language could quietly disagree with JavaScript: `Math.imul` and `>>>` are *exact 32-bit
// modular* operations, whereas `a*b|0` in JS is float arithmetic that loses low bits above 2^53.
// That distinction is the porting hazard — a port that used modular multiplication where the
// reference used float rounding would differ in low bits and nobody would find out why. rng.js
// uses `Math.imul` for every multiply, so modular arithmetic is honest here. gate.sh checks it.
//
// Four things this file also records, because they were each a wrong guess first, and the next
// agent to arrive will guess the same wrong things (see skills/odin-core-port/reference/build.md):
//   - casts are `cast(u32)(x)`, not `cast[u32](x)`; `u32(x)` also works
//   - `*`, `+`, `-` on u32 wrap — there is no `wrapping_mul`, and no `+#`/`+^` operator either
//   - `strings.Builder` has no `builder_free` in this compiler, so the buffer below is on the
//     stack: no allocator, no leak, nothing to free, which is the nicer lesson anyway
//   - bitwise XOR is `~`; `^` is pointer dereference only, and a JS transcription full of `^`
//     fails to parse in the most confusing possible place

import "core:fmt"

// The map generator's own hash, kept exactly (rng.js's words), so an existing map seed still
// produces its map. JS: h = 1779033703 ^ len; h = imul(h ^ ch, 3432918353); h = (h<<13)|(h>>>19).
hash_seed :: proc(text: string) -> u32 {
	h: u32 = 1779033703 ~ (cast(u32)(len(text)))
	for b in text {
		h = (h ~ (cast(u32)(b))) * 3432918353
		h = (h << 13) | (h >> 19)
	}
	return h
}

// One step of mulberry32, in the reference's exact shape. `a` is the state; the result is the
// u32 the reference divides by 2^32 to get a draw in [0, 1). The state is a `^u32` and is read
// with a *trailing* caret (`a^`, never `*a`), because this compiler has no parameter modes:
// `inout` and `ref` in a signature are syntax errors, so a pointer is the only way to take one.
mulberry_next :: proc(a: ^u32) -> u32 {
	a^ = a^ + 0x6D2B79F5
	t := (a^ ~ (a^ >> 15)) * (a^ | 1)
	// JS: t = (t + imul(t ^ (t >>> 7), 61 | t)) ^ t — the trailing ^t is the OLD t, since the
	// assignment happens after the right-hand side is evaluated. Easy to port wrong.
	t = (t + (t ~ (t >> 7)) * (t | 61)) ~ t
	return t ~ (t >> 14)
}

// The reference's key text, `seed + "|" + key + "|" + n`, built on the stack.
join_key :: proc(seed: string, key: string, n: u32, buf: ^[128]u8) -> string {
	i := 0
	copy(buf[0:len(seed)], seed)
	i += len(seed)
	buf[i] = '|'
	i += 1
	copy(buf[i:len(key)+i], key)
	i += len(key)
	buf[i] = '|'
	i += 1
	if n == 0 {
		buf[i] = '0'
		i += 1
	} else {
		digits: [10]u8
		dn := 0
		m := n
		for m > 0 {
			digits[dn] = cast(byte)('0' + m %% 10)
			m /= 10
			dn += 1
		}
		j := dn - 1
		for ; j >= 0; j -= 1 {
			buf[i] = digits[j]
			i += 1
		}
	}
	return string(buf[0:i])
}

// A keyed draw as the exact u32 the reference turns into a double.
keyed_draw :: proc(seed: string, key: string, n: u32) -> u32 {
	buf: [128]u8
	text := join_key(seed, key, n, &buf)

	// stream(seed, fallback): a zero seed becomes 42, as the map generator's own copy had it.
	a := hash_seed(text)
	if a == 0 {
		a = 42
	}
	return mulberry_next(&a)
}

main :: proc() {
	// The vectors, from golden/MANIFEST.json — recorded from the reference, never from a port.
	// Printed as the u32, because that integer is the byte-exact fact and a decimal rendering
	// invites the reader to trust a rounding.
	want := [2]u32{0xa9b8bccd, 0x9fd153da}
	got := [2]u32{
		keyed_draw("golden", "s0:start-workers", 0),
		keyed_draw("golden", "s0:start-workers", 1),
	}

	ok := true
	for i in 0 ..< 2 {
		mark := "ok"
		if got[i] != want[i] {
			mark = "MISMATCH"
			ok = false
		}
		// fmt.println does NOT interpolate: it prints its arguments space-separated, braces
		// included, which makes a passing gate look like a broken one. The templated form is
		// printfln; tprintfln exists too but returns results you must handle.
		fmt.printfln("draw {}: #{:08x} -> {:.17f}  expected #{:08x}  {}",
			i, got[i], cast(f64)(got[i]) / 4294967296.0, want[i], mark)
	}

	// The property the reference cares about more than the values: a draw on one key must not
	// move another key's next value. Here it is structural (the key is in the hash input and
	// nothing else is stateful), which is worth *checking* rather than admiring — the day the
	// port grows a cache or a shared counter, this is the line that goes red.
	a := keyed_draw("golden", "s0:start-workers", 0)
	_ = keyed_draw("golden", "s3:scout-target", 0)
	_ = keyed_draw("golden", "s3:scout-target", 1)
	if a != want[0] || keyed_draw("golden", "s0:start-workers", 1) != want[1] {
		fmt.println("invariance across keys is broken: another key's draws moved this key")
		ok = false
	}

	if ok {
		fmt.println("SPIKE GREEN: Odin reproduces the reference's keyed vectors")
		return
	}
	panic("SPIKE RED: the transcription does not match the reference")
}
