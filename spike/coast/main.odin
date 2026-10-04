package main

// Gate 2c: the coastline. `js/terrain.js` decides where land ends by bisecting against a noise
// field owned by the texture generator, so this file ports exactly four symbols out of a 925-line
// texgen — rng, the noise lattice, the sampler, the wobble — plus the table terrain.js builds from
// them. It matters because node placement is clipped to the shore: the counts gate proved nothing
// was *dropped*, and this is the machinery that could have dropped it.
//
// The chain, from the sources named at each step:
//
//   TexGen.rng(seed)        = WarRng.stream(seed, 1)                      texgen.js:11
//   noiseSampler(24, rand)  = Float32Array(576) of rand(), bilinear with  texgen.js:22
//                             smoothstep blending and wrapped indices
//   coastSampler(seed)(u,v) = (n(u,v) - 0.5) * COAST_WOBBLE  (26)         texgen.js:700
//   coastLimitTable()       = 1025 bisections of dist(r) = r + wobble(r), texgen.js:39
//                             18 rounds, COAST_WALK_DIST = 413, a
//                             Float32Array — so the table is f32, and
//                             texgen.js's TERRAIN_SEED 12345 / WORLD 1000
//
// The f32 in that last line is a decision, not an optimization: the lattice is stored as 32-bit
// and every later value is read back out of it, so a port that keeps f64 all the way gets a
// different coastline in the last few decimal places and then wonders why 300 nodes moved. This
// file asserts the table's f32 bit patterns, not its decimal values, because a decimal compare at
// 6 digits is exactly the slop that would let that bug live.

import "core:fmt"
import "core:mem"
import "core:math"

COAST_CELLS      :: 24
COAST_WOBBLE     :: 26.0
TERRAIN_SEED     :: 12345
TERRAIN_WORLD    :: 1000.0
COAST_WALK_DIST  :: 413.0
COAST_LIMIT_N    :: 1024

// The f32 bit pattern, by copy rather than by reinterpret-cast spellings, because that is the one
// form that does not depend on remembering which of Odin's three ways to bit-cast this version
// accepts.
// Hex by hand. Odin's `fmt` in this compiler substitutes `{}` only — `{\:x}` and `{\:.6}` are not
// verbs and come back as literal text — so a gate that needs to print a bit pattern builds the
// digits itself. Ugly, and better than discovering the mismatch at the wrong precision.
hex_bits :: proc(bits_in: u32, buf: ^[8]u8) -> string {
	v := bits_in
	digits := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}
	i := 7
	for ; i >= 0; i -= 1 {
		buf[i] = digits[v & 15]
		v = v >> 4
	}
	return string(buf[:])
}

f32_bits :: proc(x: f32) -> u32 {
	v := x
	u: u32
	mem.copy(&u, &v, size_of(f32))
	return u
}

// mulberry32 as the reference's `stream(seed, fallback)` returns it: a fresh state, one step, and
// the u32 divided by 2^32 as a double. `* 4294967296.0` style reciprocals are not equivalent; the
// reference divides, so this divides.
Rand :: struct { a: u32 }

stream_step :: proc(r: ^Rand) -> f64 {
	r.a = r.a + 0x6D2B79F5
	t := (r.a ~ (r.a >> 15)) * (r.a | 1)
	t = (t + (t ~ (t >> 7)) * (t | 61)) ~ t
	v := t ~ (t >> 14)
	return cast(f64)(v) / 4294967296.0
}

Noise :: struct { lat: [COAST_CELLS * COAST_CELLS]f32 }

init_noise :: proc(r: ^Rand) -> Noise {
	out: Noise
	for i in 0 ..< len(out.lat) {
		out.lat[i] = cast(f32)(stream_step(r))
	}
	return out
}

wrap1 :: proc(x: f64) -> f64 {
	return math.mod(math.mod(x, 1.0) + 1.0, 1.0)
}

sample_noise :: proc(n: ^Noise, u, v: f64) -> f64 {
	gx := wrap1(u) * COAST_CELLS
	gy := wrap1(v) * COAST_CELLS
	x0 := int(math.floor(gx))
	y0 := int(math.floor(gy))
	fx := gx - cast(f64)(x0)
	fy := gy - cast(f64)(y0)
	sx := fx * fx * (3.0 - 2.0 * fx)
	sy := fy * fy * (3.0 - 2.0 * fy)
	// Not a nested proc: Odin's procs are not closures, so the lattice is indexed inline. The four
	// lookups are the wrapped indices the reference uses, kept in the same order so a diff reads as
	// the same shape.
	idx :: proc(ix, iy: int) -> int { return (iy %% COAST_CELLS) * COAST_CELLS + (ix %% COAST_CELLS) }
	i00 := cast(f64)(n.lat[idx(x0, y0)])
	i10 := cast(f64)(n.lat[idx(x0 + 1, y0)])
	i01 := cast(f64)(n.lat[idx(x0, y0 + 1)])
	i11 := cast(f64)(n.lat[idx(x0 + 1, y0 + 1)])
	return (i00 * (1.0 - sx) + i10 * sx) * (1.0 - sy) + (i01 * (1.0 - sx) + i11 * sx) * sy
}

coast_wobble :: proc(n: ^Noise, u, v: f64) -> f64 {
	return (sample_noise(n, u, v) - 0.5) * COAST_WOBBLE
}

// The table, in the Float32Array's shape: computed in double, stored as f32.
coast_limit_table :: proc(n: ^Noise) -> [COAST_LIMIT_N + 1]f32 {
	lim: [COAST_LIMIT_N + 1]f32
	for i in 0 ..< COAST_LIMIT_N + 1 {
		t := cast(f64)(i) / cast(f64)(COAST_LIMIT_N) * 4.0
		side := int(math.floor(t))
		if side > 3 { side = 3 }
		s := t - cast(f64)(side)
		px, pz: f64 = 1.0, s * 2.0 - 1.0
		if side == 1 {
			px, pz = 1.0 - s * 2.0, 1.0
		} else if side == 2 {
			px, pz = -1.0, 1.0 - s * 2.0
		} else if side == 3 {
			px, pz = s * 2.0 - 1.0, -1.0
		}
		lo, hi := COAST_WALK_DIST - COAST_WOBBLE, COAST_WALK_DIST + COAST_WOBBLE
		for _ in 0 ..< 18 {
			mid := (lo + hi) / 2.0
			d := mid + coast_wobble(n, (mid * px) / TERRAIN_WORLD + 0.5, (mid * pz) / TERRAIN_WORLD + 0.5)
			if d < COAST_WALK_DIST {
				lo = mid
			} else {
				hi = mid
			}
		}
		lim[i] = cast(f32)((lo + hi) / 2.0)
	}
	return lim
}

Expect :: struct { idx: int, bits: u32, shown: f64 }

main :: proc() {
	r := Rand{TERRAIN_SEED}
	// TexGen.rng passes fallback 1; the seed is 12345, so the zero-seed branch is not taken here.
	if r.a == 0 { r.a = 1 }

	n := init_noise(&r)
	lim := coast_limit_table(&n)

	// From the reference implementation, run today: `node` with the real WarRng and a real
	// Float32Array. Hex bit patterns, because they are the fact.
	want := []Expect{
		{0,    0x43d11b3a, 418.212708},
		{128,  0x43cbc3ca, 407.529602},
		{256,  0x43cb5cdb, 406.725433},
		{512,  0x43cb92ea, 407.147766},
		{768,  0x43d190f0, 419.132324},
		{1024, 0x43d11b3a, 418.212708},
	}
	// The lattice too: the wobble's whole shape comes from these, so if a draw order is wrong, this
	// is where it shows first, and it shows as a bit pattern rather than as a mystery.
	lattice_ok := true
	idx  := [3]int{0, 1, 575}
	want_lat := [3]u32{0x3f7acf79, 0x3e9d0ea2, 0x3e5f2f04}
	for i in 0 ..< 3 {
		got_bits := f32_bits(n.lat[idx[i]])
		if got_bits != want_lat[i] {
			h1, h2, h3: [8]u8
		fmt.printfln("lattice[{}] mismatch: #{} vs #{}", idx[i],
			hex_bits(got_bits, &h1), hex_bits(want_lat[i], &h2), hex_bits(0, &h3))
			lattice_ok = false
		}
	}
	if lattice_ok {
		fmt.println("lattice[0,1,575] match the reference's Float32Array")
	}

	ok := lattice_ok
	mn, mx := f64(1e9), f64(-1e9)
	for v in lim {
		d := cast(f64)(v)
		if d < mn { mn = d }
		if d > mx { mx = d }
	}
	for w in want {
		got_bits := f32_bits(lim[w.idx])
		mark := "ok"
		if got_bits != w.bits {
			mark, ok = "MISMATCH", false
		}
		g, e: [8]u8
		fmt.printfln("lim[{}] bits #{} (want #{})  {}", w.idx,
			hex_bits(got_bits, &g), hex_bits(w.bits, &e), mark)
	}
	// The range the texgen comments quote: the shore must never fall below 400, which is the whole
	// reason TERRAIN_LAND moved to 417.
	fmt.printfln("table range {} .. {}  (expected 400.90740966796875 .. 425.1048889160156)", mn, mx)
	if mn < 400.0 || mn > 400.91 || mx < 425.10 {
		ok = false
		fmt.println("table range wrong")
	}

	if ok {
		fmt.println("COAST GREEN: the walkable-shore table matches the reference bit for bit")
		return
	}
	panic("the coastline does not match, and every node position downstream of it is wrong")
}
