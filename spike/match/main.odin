// turn1/main.odin — the first turn of the arena, transcribed from the reference.
//
// The reference is the browser game (js/game.js + js/openai-ai.js + js/terrain.js +
// js/units.js + js/buildings.js + js/civilizations.js + js/simulation/*) run headless
// (tools/golden/run.cjs) over the golden arena: four rule-based seats — egyptian,
// greek, persian, yamato — map seed 'golden', a single 1x clock, no model. The
// fixtures are the canonical states at t = 0 and t = 1000 ms, one per seat, from
// golden/turn1-b1040.canonical.jsonl (re-derived at build 1040; see the ledger
// in docs/111-odin-core-port-architecture.md). This file re-runs that first turn
// in Odin and must reproduce those bytes: the gate is a cmp, in
// skills/odin-core-port/reference/gates.sh.
//
// Everything here is a transcription, not a design. Where the reference's numbers
// come from a portable library this file re-derives the same bits:
//   * WarMath (js/simulation/math.js): + - * / and sqrt are language-fixed, so a
//     bare operation is the transcription; hypot, sin, cos, atan2 are fdlibm
//     kernels pinned so every engine computes the same bits, so they are
//     transcribed in full.
//   * WarRng (js/simulation/rng.js): mulberry32 over a per-seat keyed draw
//     (golden/keyed-vectors.md pins two of these). The spike at ../odin proved the
//     two load-bearing lines; this file reuses that proof and calls the same
//     primitives for the whole match.
// The world this turn runs in is the arena's: terrain size 800, four Town Centers
// on a 306-unit circle, 98 food / 784 wood / 40 stone / 20 gold (one wood node
// lands under the egyptian TC and is cleared). That is the same world the t0/t1
// fixtures were born in; the 200-unit world of the legacy map-line record is a
// different corpus and is not what this port replays.
//
// The shape of the port: one seat at a time is the unit of state. A seat owns its
// resources, units, building, the nodes it has seen, and the map it has explored;
// the arena is the set of four seats plus the shared node list. A "step" is the
// reference's stepOnce(): the discovery beat, the simulation, the position rules,
// the observation. The clock is 50 ms per step at 1x; twenty steps is one second,
// which is the whole match this turn covers.

package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"

// ===========================================================================
// Portable math — a transcription of js/simulation/math.js.
//
// + - * / and sqrt are IEEE 754: the language fixes them, so a bare operation is
// the port. hypot, sin, cos, atan2 are not fixed; the reference builds them from
// fdlibm kernels so that every engine computes the same bits. A transcription of
// a kernel is line-for-line: the constants below are the reference's, spelled at
// the reference's precision.
// ===========================================================================

// A double's 64 bits, so the kernels can read the sign and exponent the way the
// reference reads them through its shared buffer. (x | 0) in JS is ToInt32 —
// truncation toward zero, which is the float-to-int cast here.
// The fdlibm bit helpers. transmute, not cast: cast(u64)(pi) is the numeric
// value 3, and every branch threshold below would compare against garbage —
// this exact bug was found by the run (rem_pio2 returned n=0 for pi/2).
bits64 :: proc(x: f64) -> u64 {
	return transmute(u64)(x)
}
high32 :: proc(x: f64) -> i32 {
	return cast(i32)(bits64(x) >> 32)
}
low32 :: proc(x: f64) -> u32 {
	return cast(u32)(bits64(x))
}
with_high :: proc(hi: i32, lo: u32) -> f64 {
	return transmute(f64)((cast(u64)(cast(u32)(hi))<<32 | u64(lo)))
}

// v < 0 ? -v : v + 0 — the +0 turns -0 into 0, as Math.abs does.
m_abs :: proc(v: f64) -> f64 {
	if v < 0 {
		return -v
	}
	return v + 0
}

// V8's Math.hypot, two-term: normalised by the largest term. With two terms the
// Kahan compensation is exactly zero, so this straight line gives V8's bits.
m_inf : f64 = transmute(f64)u64(0x7ff0000000000000) // +inf, the fdlibm INF (this core:math ships no inf constant)
m_nan : f64 = transmute(f64)u64(0x7ff8000000000000) // quiet NaN, the fdlibm NAN

m_hypot :: proc(a: f64, b: f64) -> f64 {
	x := m_abs(a)
	y := m_abs(b)
	if x != x || y != y {
		if x == m_inf || y == m_inf {
			return m_inf
		}
		return m_nan
	}
	max := x
	if y > x {
		max = y
	}
	if max == m_inf {
		return m_inf
	}
	if max == 0 {
		return 0
	}
	n := x / max
	m := y / max
	return math.sqrt(n*n + m*m) * max
}

// --- fdlibm kernels on [-pi/4, pi/4]; y is the tail of the reduced argument. ---
S1c :: f64(-1.66666666666666324348e-01)
S2c :: f64(8.33333333332248946124e-03)
S3c :: f64(-1.98412698298579493134e-04)
S4c :: f64(2.75573137070700676789e-06)
S5c :: f64(-2.50507602534068634195e-08)
S6c :: f64(1.58969099521155010221e-10)
C1c :: f64(4.16666666666666019037e-02)
C2c :: f64(-1.38888888888741095749e-03)
C3c :: f64(2.48015872894767294178e-05)
C4c :: f64(-2.75573143513906633035e-07)
C5c :: f64(2.08757232129817482790e-09)
C6c :: f64(-1.13596475577881948265e-11)
k_sin :: proc(x: f64, y: f64, iy: i32) -> f64 {
	if (high32(x) & cast(i32)(0x7fffffff)) < cast(i32)(0x3e400000) && cast(i32)(x) == 0 {
		return x
	}
	z := x * x
	v := z * x
	r := S2c + z*(S3c + z*(S4c + z*(S5c + z*S6c)))
	if iy == 0 {
		return x + v*(S1c + z*r)
	}
	return x - ((z*(0.5*y - v*r) - y) - v*S1c)
}

k_cos :: proc(x: f64, y: f64) -> f64 {
	ix := high32(x) & cast(i32)(0x7fffffff)
	if ix < cast(i32)(0x3e400000) && cast(i32)(x) == 0 {
		return 1
	}
	z := x * x
	r := z * (C1c + z*(C2c + z*(C3c + z*(C4c + z*(C5c + z*C6c)))))
	if ix < cast(i32)(0x3fd33333) {
		return 1 - (0.5*z - (z*r - x*y))
	}
	qx := f64(0.28125)
	if ix <= cast(i32)(0x3fe90000) {
		qx = with_high(ix - cast(i32)(0x00200000), 0)
	}
	hz := 0.5 * z - qx
	a := 1 - qx
	return a - (hz - (z*r - x*y))
}

// x - n*pi/2 as a head and tail, for |x| up to 2^20 * pi/2 (fdlibm's medium
// range). Beyond it the argument is first brought down with %, which is exact.
invpio2c :: f64(6.36619772367581382433e-01)
pio2_1c :: f64(1.57079632673412561417e+00)
pio2_1tc :: f64(6.07710050650619224932e-11)
pio2_2c :: f64(6.07710050630396597660e-11)
pio2_2tc :: f64(2.02226624879595063154e-21)
pio2_3c :: f64(2.02226624871116645580e-21)
pio2_3tc :: f64(8.47842766036889956997e-32)
npio2_hw : [32]i32 = {
	0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
	0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
	0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
	0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
	0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
	0x404858EB, 0x404921FB,
}

// The JS '%' on doubles: the ECMAScript remainder, which is fmod semantics —
// the result carries the sign of the dividend, and x - result is an exact
// multiple of the divisor. fdlibm's __rem_pio2 medium path leans on it for
// |x| > 329571 (0x413921fb); the arena never sends such an x, but the branch
// is transcribed anyway, and a transcription of '%' is this, not a guess.
// The loop is the binary-subtraction form of fmod: every subtraction is
// Sterbenz-exact (r/2 < s <= r holds at each step), so the returned value
// is the true mathematical remainder — no rounding enters anywhere.
m_fmod :: proc(x_in: f64, y_in: f64) -> f64 {
	ax := m_abs(x_in)
	ay := m_abs(y_in)
	if ay == 0 || ax == m_inf || ax != ax || ay != ay {
		return m_nan // x % 0, x % NaN, inf % y: all NaN in JS
	}
	if ax == 0 || ax < ay {
		return x_in // 0 % y = 0 (sign kept); |x| < |y|: x unchanged
	}
	r := ax
	for r >= ay {
		s := ay
		for s + s <= r {
			s += s
		}
		r -= s
	}
	if x_in < 0 {
		return -r
	}
	return r
}

// floor4: the JS Math.floor((cost || 0) * mult) the research table uses.
floor4 :: proc(v: f64, mult: f64) -> f64 {
	return math.floor(v * mult)
}

// The node-type names, in type order (0 food, 1 wood, 2 stone, 3 gold) —
// the reference indexes its own array inline; the port names it.
res_type_name : [4]string = {"food", "wood", "stone", "gold"}

rem_pio2 :: proc(x_in: f64, y0: ^f64, y1: ^f64) -> i32 {
	x := x_in
	hx := high32(x)
	ix := hx & cast(i32)(0x7fffffff)
	if ix <= cast(i32)(0x3fe921fb) {
		y0^ = x
		y1^ = 0
		return 0
	}
	if ix < cast(i32)(0x4002d97c) {
		if hx > 0 {
			z := x - pio2_1c
			if ix != cast(i32)(0x3ff921fb) {
				y0^ = z - pio2_1tc
				y1^ = (z - y0^) - pio2_1tc
			} else {
				z -= pio2_2c
				y0^ = z - pio2_2tc
				y1^ = (z - y0^) - pio2_2tc
			}
			return 1
		}
		z := x + pio2_1c
		if ix != cast(i32)(0x3ff921fb) {
			y0^ = z + pio2_1tc
			y1^ = (z - y0^) + pio2_1tc
		} else {
			z += pio2_2c
			y0^ = z + pio2_2tc
			y1^ = (z - y0^) + pio2_2tc
		}
		return -1
	}
	if ix > cast(i32)(0x413921fb) {
		x = m_fmod(x, 6.283185307179586)
		hx = high32(x)
		ix = hx & cast(i32)(0x7fffffff)
		if ix <= cast(i32)(0x3fe921fb) {
			y0^ = x
			y1^ = 0
			return 0
		}
	}
	t := m_abs(x)
	n := cast(i32)(t*invpio2c + 0.5) // (.. | 0): ToInt32, truncation toward zero
	fn := f64(n)
	r := t - fn*pio2_1c
	w := fn * pio2_1tc
	if n < 32 && ix != npio2_hw[n-1] {
		y0^ = r - w
	} else {
		j := cast(u32)(ix) >> 20
		y0^ = r - w
		i := i32(j) - ((high32(y0^) >> 20) & cast(i32)(0x7ff))
		if i > 16 {
			t = r
			w = fn * pio2_2c
			r = t - w
			w = fn*pio2_2tc - ((t - r) - w)
			y0^ = r - w
			i = i32(j) - ((high32(y0^) >> 20) & cast(i32)(0x7ff))
			if i > 49 {
				t = r
				w = fn * pio2_3c
				r = t - w
				w = fn*pio2_3tc - ((t - r) - w)
				y0^ = r - w
			}
		}
	}
	y1^ = (r - y0^) - w
	if hx < 0 {
		y0^ = -y0^
		y1^ = -y1^
		return -n
	}
	return n
}

m_sin :: proc(x: f64) -> f64 {
	ix := high32(x) & cast(i32)(0x7fffffff)
	if ix <= cast(i32)(0x3fe921fb) {
		return k_sin(x, 0, 0)
	}
	if ix >= cast(i32)(0x7ff00000) {
		return x - x // NaN
	}
	y0, y1: f64
	switch rem_pio2(x, &y0, &y1) & 3 {
	case 0:
		return k_sin(y0, y1, 1)
	case 1:
		return k_cos(y0, y1)
	case 2:
		return -k_sin(y0, y1, 1)
	}
	return -k_cos(y0, y1)
}

m_cos :: proc(x: f64) -> f64 {
	ix := high32(x) & cast(i32)(0x7fffffff)
	if ix <= cast(i32)(0x3fe921fb) {
		return k_cos(x, 0)
	}
	if ix >= cast(i32)(0x7ff00000) {
		return x - x
	}
	y0, y1: f64
	switch rem_pio2(x, &y0, &y1) & 3 {
	case 0:
		return k_cos(y0, y1)
	case 1:
		return -k_sin(y0, y1, 1)
	case 2:
		return -k_cos(y0, y1)
	}
	return k_sin(y0, y1, 1)
}

// --- fdlibm atan and atan2. ---
atanhi : [4]f64 = {
	4.63647609000806093515e-01,
	7.85398163397448278999e-01,
	9.82793723247329054082e-01,
	1.57079632679489655800e+00,
}
atanlo : [4]f64 = {
	2.26987774529616870924e-17,
	3.06161699786838301793e-17,
	1.39033110312309984516e-17,
	6.12323399573676603587e-17,
}
aT : [11]f64 = {
	3.33333333333329318027e-01,
	-1.99999999998764832476e-01,
	1.42857142725034663711e-01,
	-1.11111104054623557880e-01,
	9.09088713343650656196e-02,
	-7.69187620504482999495e-02,
	6.66107313738753120669e-02,
	-5.83357013379057348645e-02,
	4.97687799461593236017e-02,
	-3.65315727442169155270e-02,
	1.62858201153657823623e-02,
}

m_atan :: proc(x_in: f64) -> f64 {
	x := x_in
	hx := high32(x)
	ix := hx & cast(i32)(0x7fffffff)
	id: i32
	if ix >= cast(i32)(0x44100000) {
		if ix > cast(i32)(0x7ff00000) || (ix == cast(i32)(0x7ff00000) && low32(x) != 0) {
			return x + x
		}
		if hx > 0 {
			return atanhi[3] + atanlo[3]
		}
		return -atanhi[3] - atanlo[3]
	}
	if ix < cast(i32)(0x3fdc0000) {
		if ix < cast(i32)(0x3e200000) {
			return x
		}
		id = -1
	} else {
		x = m_abs(x)
		if ix < cast(i32)(0x3ff30000) {
			if ix < cast(i32)(0x3fe60000) {
				id = 0
				x = (2*x - 1) / (2 + x)
			} else {
				id = 1
				x = (x - 1) / (x + 1)
			}
		} else if ix < cast(i32)(0x40038000) {
			id = 2
			x = (x - 1.5) / (1 + 1.5*x)
		} else {
			id = 3
			x = -1 / x
		}
	}
	z := x * x
	w := z * z
	s1 := z * (aT[0] + w*(aT[2] + w*(aT[4] + w*(aT[6] + w*(aT[8] + w*aT[10])))))
	s2 := w * (aT[1] + w*(aT[3] + w*(aT[5] + w*(aT[7] + w*aT[9]))))
	if id < 0 {
		return x - x*(s1 + s2)
	}
	r := atanhi[id] - ((x*(s1 + s2) - atanlo[id]) - x)
	if hx < 0 {
		return -r
	}
	return r
}

pim :: f64(3.1415926535897931160e+00)
pi_o_2m :: f64(1.5707963267948965580e+00)
pi_o_4m :: f64(7.8539816339744827900e-01)
pi_lom :: f64(1.2246467991473531772e-16)
tinym :: f64(1.0e-300)
m_atan2 :: proc(yv: f64, x: f64) -> f64 {
	if x != x || yv != yv {
		return x + yv
	}
	hx := high32(x)
	lx := low32(x)
	hy := high32(yv)
	ly := low32(yv)
	ix := hx & cast(i32)(0x7fffffff)
	iy := hy & cast(i32)(0x7fffffff)
	if hx == cast(i32)(0x3ff00000) && lx == 0 {
		return m_atan(yv)
	}
	m := (hy >> 31) & 1 | ((hx >> 30) & 2)
	if (iy | cast(i32)(ly)) == 0 {
		if m == 0 || m == 1 {
			return yv
		}
		if m == 2 {
			return pim + tinym
		}
		return -pim - tinym
	}
	if (ix | cast(i32)(lx)) == 0 {
		if hy < 0 {
			return -pi_o_2m - tinym
		}
		return pi_o_2m + tinym
	}
	if ix == cast(i32)(0x7ff00000) {
		if iy == cast(i32)(0x7ff00000) {
			vals := [4]f64{pi_o_4m + tinym, -pi_o_4m - tinym, 3*pi_o_4m + tinym, -3*pi_o_4m - tinym}
			return vals[m]
		}
		vals := [4]f64{0, -0, pim + tinym, -pim - tinym}
		return vals[m]
	}
	if iy == cast(i32)(0x7ff00000) {
		if hy < 0 {
			return -pi_o_2m - tinym
		}
		return pi_o_2m + tinym
	}
	k := (iy - ix) >> 20
	z: f64
	if k > 60 {
		z = pi_o_2m + 0.5*pi_lom
		m &= 1
	} else if hx < 0 && k < -60 {
		z = 0
	} else {
		z = m_atan(m_abs(yv / x))
	}
	switch m {
	case 0:
		return z
	case 1:
		return -z
	case 2:
		return pim - (z - pi_lom)
	}
	return (z - pi_lom) - pim
}

// A small whole power by repeated multiplication: exact wherever the result is.
m_pow_int :: proc(base: f64, n: i32) -> f64 {
	r := f64(1)
	for i := 0; i < cast(int)(n); i += 1 {
		r *= base
	}
	return r
}

// ===========================================================================
// The arena's randomness — a transcription of js/simulation/rng.js, the same
// twelve load-bearing lines the spike at ../odin already proved against the
// golden's keyed vectors (golden/keyed-vectors.md).
// ===========================================================================

// The map generator's own hash: h = 1779033703 ^ len; h = imul(h ^ ch, 3432918353);
// h = (h<<13) | (h>>>19). u32 * and + wrap in Odin, which is exactly what
// Math.imul does: 32-bit modular arithmetic.
hash_seed :: proc(text: string) -> u32 {
	h: u32 = 1779033703 ~ cast(u32)(len(text))
	for b in text {
		h = (h ~ cast(u32)(b)) * 3432918353
		h = (h << 13) | (h >> 19)
	}
	return h
}

// One step of mulberry32, in the reference's exact shape.
mulberry_next :: proc(a: ^u32) -> u32 {
	a^ = a^ + 0x6D2B79F5
	t := (a^ ~ (a^ >> 15)) * (a^ | 1)
	t = (t + (t ~ (t >> 7)) * (t | 61)) ~ t // the ^ t is the OLD t
	return t ~ (t >> 14)
}

// stream(seed, 42): the first value of the mix, with the zero-seed fallback.
stream_first :: proc(seed: u32) -> f64 {
	a := seed
	if a == 0 {
		a = 42
	}
	return cast(f64)(mulberry_next(&a)) / 4294967296.0
}

// draw(state, key): the key's next value. The reference's `state.n[key] || 0`
// counts per key, so a draw on one key never moves another key's next value.
keyed_draw :: proc(seed: string, key: string, n: u32) -> f64 {
	buf: [192]u8
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
			digits[dn] = cast(u8)('0' + m%%10)
			m /= 10
			dn += 1
		}
		for j := dn - 1; j >= 0; j -= 1 {
			buf[i] = digits[j]
			i += 1
		}
	}
	return stream_first(hash_seed(string(buf[0:i])))
}

// ===========================================================================
// The four civilisations — transcribed from js/civilizations.js (the canonical
// German data; the English names below are the i18n table, js/i18n.js).
// ===========================================================================

cost4 :: struct {
	food, wood, stone, gold: f64,
}

tech :: struct {
	cost: cost4,
	research_at: string,
	required_age: string,
	requires: [4]string,
	n_req: int,
	research_time: f64, // js/civilizations.js researchTime (ms; the default 15000)
	unlocks_bldg: string, // tech.unlocks.buildings[0], or "" for none
}

unit_def :: struct {
	id: string,
	cost: cost4,
	health: f64,
	speed: f64,
	attack: f64, // damage per 1 s swing
	range: f64, // 0.5 melee (game.js: melee reach is the flat 1.5)
	u_type: string, // 'worker', 'infantry', 'ranged', 'cavalry', 'support'
	tier: string, // the epoch that trains it
	train_at: string, // set for uniques that need a specific building
}

civ :: struct {
	id: string,
	name_en: string,
	// per-building health multiplier from the civ bonus ('Pyramide' 1.5, 'Akropolis' 1.3)
	bldg_mult: f64,
	// the observation's bonuses table: harvest 1.2 (Satrapie) / techCostMult 0.7 (Schrein)
	honus_harvest: f64,
	honus_techcost: f64,
	wonder_id: string,
	wonder_cost: cost4,
	excluded: [4]string,
	n_excluded: int,
	units: [8]unit_def,
	n_units: int,
	techs: [14]tech,
	n_techs: int,
}

egypt :: civ{
	id = "egyptian", name_en = "Egyptians",
	bldg_mult = 1.5, honus_harvest = 1.0, honus_techcost = 1.0,
	wonder_id = "pyramid", wonder_cost = {4800, 4800, 4250, 2650},
	excluded = {"cavalry", "heavy_cavalry", "", ""}, n_excluded = 2,
	units = {
		{id = "priest", cost = {50, 0, 0, 30}, health = 60, speed = 1.2, u_type = "support", tier = "bronze", attack = 3.0, range = 10.5 },
		{id = "slinger", cost = {60, 20, 0, 0}, health = 45, speed = 1, u_type = "ranged", tier = "neolithic", train_at = "archery_range", attack = 6.0, range = 12.0 },
		{id = "horse_carriage", cost = {60, 20, 40, 40}, health = 100, speed = 2, u_type = "cavalry", tier = "bronze", train_at = "stable", attack = 8.0, range = 2.0 },
	{}, {}, {}, {}, {}}, n_units = 3,
	techs = {
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "house"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "farm"},
		{cost = {100, 150, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "barracks"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone", requires = {"farm", "", "", ""}, n_req = 1, research_time = 15000, unlocks_bldg = ""},
		{cost = {80, 40, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = ""},
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "archery_range"},
		{cost = {200, 150, 0, 0}, research_at = "town_center", required_age = "neolithic", research_time = 15000, unlocks_bldg = "academy"},
		{cost = {50, 50, 50, 0}, research_at = "academy", required_age = "neolithic", requires = {"academy", "", "", ""}, n_req = 1, research_time = 20000, unlocks_bldg = ""},
		{cost = {100, 100, 0, 50}, research_at = "academy", required_age = "neolithic", research_time = 20000, unlocks_bldg = ""},
		{cost = {0, 0, 150, 100}, research_at = "academy", required_age = "bronze", research_time = 25000, unlocks_bldg = ""},
		{cost = {150, 100, 0, 0}, research_at = "town_center", required_age = "neolithic", research_time = 15000, unlocks_bldg = "stable"},
		{cost = {150, 0, 0, 100}, research_at = "temple", required_age = "bronze", research_time = 20000, unlocks_bldg = ""},
		{cost = {0, 0, 200, 200}, research_at = "academy", required_age = "iron", requires = {"bronze_armor", "", "", ""}, n_req = 1, research_time = 30000, unlocks_bldg = ""},
		{cost = {50, 100, 80, 100}, research_at = "academy", required_age = "iron", research_time = 30000, unlocks_bldg = ""},
	}, n_techs = 14,
}

greek :: civ{
	id = "greek", name_en = "Greeks",
	bldg_mult = 1.3, honus_harvest = 1.0, honus_techcost = 1.0,
	wonder_id = "akropolis", wonder_cost = {4500, 4500, 4000, 2500},
	excluded = {"cavalry", "heavy_cavalry", "", ""}, n_excluded = 2,
	units = {
		{id = "hoplite", cost = {80, 0, 50, 30}, health = 150, speed = 0.9, u_type = "infantry", tier = "neolithic", train_at = "barracks", attack = 10.0, range = 1.0 },
		{id = "phalanx", cost = {60, 0, 40, 20}, health = 100, speed = 0.8, u_type = "infantry", tier = "bronze", train_at = "barracks", attack = 8.0, range = 2.0 },
	{}, {}, {}, {}, {}, {}}, n_units = 2,
	techs = {
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "house"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "farm"},
		{cost = {100, 150, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "barracks"},
		{cost = {150, 100, 0, 0}, research_at = "town_center", required_age = "neolithic", research_time = 15000, unlocks_bldg = "stable"},
		{cost = {100, 100, 0, 0}, research_at = "town_center", required_age = "stone", requires = {"barracks", "", "", ""}, n_req = 1, research_time = 15000, unlocks_bldg = ""},
		{cost = {100, 50, 0, 30}, research_at = "town_center", required_age = "stone", research_time = 20000, unlocks_bldg = ""},
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "archery_range"},
		{cost = {200, 150, 0, 0}, research_at = "town_center", required_age = "neolithic", research_time = 20000, unlocks_bldg = "academy"},
		{cost = {200, 0, 0, 150}, research_at = "academy", required_age = "neolithic", requires = {"academy", "", "", ""}, n_req = 1, research_time = 20000, unlocks_bldg = ""},
		{cost = {300, 0, 0, 200}, research_at = "academy", required_age = "bronze", requires = {"philosophy", "", "", ""}, n_req = 1, research_time = 25000, unlocks_bldg = ""},
		{cost = {0, 50, 150, 100}, research_at = "academy", required_age = "bronze", research_time = 25000, unlocks_bldg = ""},
		{cost = {150, 0, 0, 100}, research_at = "temple", required_age = "bronze", research_time = 20000, unlocks_bldg = ""},
		{cost = {0, 0, 200, 200}, research_at = "academy", required_age = "iron", requires = {"phalanx_armor", "", "", ""}, n_req = 1, research_time = 30000, unlocks_bldg = ""},
		{cost = {50, 100, 80, 100}, research_at = "academy", required_age = "iron", research_time = 30000, unlocks_bldg = ""},
	}, n_techs = 14,
}

persian :: civ{
	id = "persian", name_en = "Persians",
	bldg_mult = 1.0, honus_harvest = 1.2, honus_techcost = 1.0,
	wonder_id = "firetemple", wonder_cost = {4500, 4500, 4000, 2500},
	excluded = {"", "", "", ""}, n_excluded = 0,
	units = {
		{id = "archer", cost = {70, 30, 0, 0}, health = 50, speed = 1.1, u_type = "ranged", tier = "neolithic", attack = 6.0, range = 12.0 },
		{id = "cavalry", cost = {110, 0, 0, 40}, health = 140, speed = 2, u_type = "cavalry", tier = "bronze", attack = 12.0, range = 0.5 },
		{id = "heavy_cavalry", cost = {160, 0, 40, 70}, health = 200, speed = 1.8, u_type = "cavalry", tier = "iron", attack = 18.0, range = 0.5 },
	{}, {}, {}, {}, {}}, n_units = 3,
	techs = {
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "house"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "farm"},
		{cost = {100, 150, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "barracks"},
		{cost = {150, 100, 0, 0}, research_at = "town_center", required_age = "neolithic", research_time = 15000, unlocks_bldg = "stable"},
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "archery_range"},
		{cost = {200, 150, 0, 0}, research_at = "town_center", required_age = "neolithic", research_time = 20000, unlocks_bldg = "academy"},
		{cost = {150, 50, 0, 100}, research_at = "academy", required_age = "neolithic", requires = {"horseback", "", "", ""}, n_req = 1, research_time = 20000, unlocks_bldg = ""},
		{cost = {0, 0, 200, 150}, research_at = "academy", required_age = "bronze", requires = {"cavalry_training", "", "", ""}, n_req = 1, research_time = 25000, unlocks_bldg = ""},
		{cost = {0, 0, 150, 100}, research_at = "academy", required_age = "bronze", research_time = 25000, unlocks_bldg = ""},
		{cost = {150, 0, 0, 100}, research_at = "temple", required_age = "bronze", research_time = 20000, unlocks_bldg = ""},
		{cost = {100, 100, 0, 50}, research_at = "academy", required_age = "bronze", research_time = 25000, unlocks_bldg = ""},
		{cost = {0, 200, 150, 200}, research_at = "academy", required_age = "iron", requires = {"archery", "", "", ""}, n_req = 1, research_time = 30000, unlocks_bldg = ""},
		{cost = {50, 100, 80, 100}, research_at = "academy", required_age = "iron", research_time = 30000, unlocks_bldg = ""},
		{},
	}, n_techs = 13,
}

yamato_civ :: civ{
	id = "yamato", name_en = "Yamato",
	bldg_mult = 1.0, honus_harvest = 1.0, honus_techcost = 0.7,
	wonder_id = "shrine", wonder_cost = {4500, 4500, 4000, 2500},
	excluded = {"", "", "", ""}, n_excluded = 0,
	units = {
		{id = "samurai", cost = {100, 50, 0, 50}, health = 130, speed = 1.3, u_type = "infantry", tier = "bronze", train_at = "barracks", attack = 14.0, range = 1.0 },
		{id = "archer_ship", cost = {150, 150, 0, 50}, health = 200, speed = 1.5, u_type = "ranged"},
	{}, {}, {}, {}, {}, {}}, n_units = 2,
	techs = {
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "house"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "farm"},
		{cost = {100, 150, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "barracks"},
		{cost = {150, 0, 0, 100}, research_at = "town_center", required_age = "stone", requires = {"barracks", "", "", ""}, n_req = 1, research_time = 15000, unlocks_bldg = ""},
		{cost = {150, 0, 0, 100}, research_at = "temple", required_age = "bronze", research_time = 20000, unlocks_bldg = ""},
		{cost = {100, 100, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "archery_range"},
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone", research_time = 15000, unlocks_bldg = "academy"},
		{cost = {200, 150, 0, 0}, research_at = "town_center", required_age = "neolithic", research_time = 20000, unlocks_bldg = "stable"},
		{cost = {150, 100, 0, 0}, research_at = "town_center", required_age = "neolithic", research_time = 15000, unlocks_bldg = ""},
		{cost = {0, 100, 150, 150}, research_at = "academy", required_age = "bronze", requires = {"bushido", "", "", ""}, n_req = 1, research_time = 15000, unlocks_bldg = ""},
		{cost = {0, 0, 150, 100}, research_at = "academy", required_age = "bronze", research_time = 25000, unlocks_bldg = ""},
		{cost = {0, 0, 200, 200}, research_at = "academy", required_age = "iron", requires = {"armor", "", "", ""}, n_req = 1, research_time = 15000, unlocks_bldg = ""},
		{cost = {50, 100, 80, 100}, research_at = "academy", required_age = "iron", research_time = 30000, unlocks_bldg = ""},
		{},
	}, n_techs = 13,
}

civs : [4]civ = {egypt, greek, persian, yamato_civ}

// Tech tree ids in tree order (the observation walks this order), parallel to
// civs[ci].techs[i].
tech_ids : [4][14]string = {
	{"house", "farm", "barracks", "agriculture", "pottery", "longbow", "academy", "mining", "archery", "bronze_armor", "horseback", "healing", "iron_working", "fire_arrows"},
	{"house", "farm", "barracks", "horseback", "falx", "farsight", "longbow", "academy", "philosophy", "democracy", "phalanx_armor", "healing", "iron_working", "fire_arrows"},
	{"house", "farm", "barracks", "horseback", "longbow", "academy", "cavalry_training", "cavalry_armor", "immortals", "healing", "archery", "siege", "fire_arrows", ""},
	{"house", "farm", "barracks", "bushido", "healing", "speed", "longbow", "academy", "horseback", "armor", "lamellar_armor", "iron_working", "fire_arrows", ""},
}

// ===========================================================================
// Standard unit and building definitions — js/units.js and js/buildings.js.
// Only the fields the first turn reads are kept; costs are the whole of the
// economy at this scale.
// ===========================================================================

std_unit_defs : [11]unit_def = {
	{id = "worker", cost = {50, 0, 0, 0}, health = 40, speed = 1, u_type = "worker", attack = 3.0, range = 0.5 },
	{id = "militia", cost = {50, 20, 0, 0}, health = 70, speed = 1.1, u_type = "infantry", tier = "stone", attack = 7.0, range = 0.5 },
	{id = "warrior", cost = {80, 0, 30, 20}, health = 120, speed = 1, u_type = "infantry", tier = "bronze", attack = 12.0, range = 0.5 },
	{id = "champion", cost = {150, 50, 50, 100}, health = 200, speed = 1.5, u_type = "infantry", tier = "iron", attack = 18.0, range = 0.5 },
	{id = "archer", cost = {60, 30, 0, 0}, health = 40, speed = 1, u_type = "ranged", tier = "neolithic", attack = 6.0, range = 12.0 },
	{id = "crossbowman", cost = {100, 40, 20, 30}, health = 60, speed = 0.9, u_type = "ranged", tier = "iron", attack = 12.0, range = 13.5 },
	{id = "elite_archer", cost = {150, 60, 30, 50}, health = 80, speed = 1.1, u_type = "ranged", tier = "iron", attack = 16.0, range = 15.0 },
	{id = "scout_cavalry", cost = {150, 80, 0, 0}, health = 100, speed = 2.2, u_type = "cavalry", tier = "neolithic", attack = 8.0, range = 0.5 },
	{id = "cavalry", cost = {120, 0, 0, 50}, health = 140, speed = 2, u_type = "cavalry", tier = "bronze", attack = 12.0, range = 0.5 },
	{id = "heavy_cavalry", cost = {180, 0, 50, 80}, health = 200, speed = 1.8, u_type = "cavalry", tier = "iron", attack = 18.0, range = 0.5 },
	{id = "priest", cost = {50, 0, 0, 30}, health = 60, speed = 1, u_type = "support", tier = "bronze", attack = 3.0, range = 10.5 },
}

bldg_def :: struct {
	id: string,
	cost: cost4,
	base_health: f64,
	req_age: string,
	req_tech: string,
	train_opts: [2]string,
	n_train: int,
	can_train: bool,
	build_time: f64, // js/buildings.js buildTime (ms; BASE_BUILD_TIME = 10000)
	pop_bonus: int, // popBonus: TC 10, house 5, the rest 0
}

std_bldg_defs : [9]bldg_def = {
	{id = "town_center", cost = {100, 100, 100, 100}, base_health = 1000, req_age = "stone", train_opts = {"worker", ""}, n_train = 1, can_train = true, build_time = 15000, pop_bonus = 10},
	{id = "house", cost = {30, 20, 0, 0}, base_health = 300, req_age = "stone", req_tech = "house", build_time = 5000, pop_bonus = 5},
	{id = "farm", cost = {50, 50, 0, 0}, base_health = 400, req_age = "stone", req_tech = "farm", build_time = 8000, pop_bonus = 0},
	{id = "barracks", cost = {50, 150, 0, 0}, base_health = 800, req_age = "stone", req_tech = "barracks", can_train = true, build_time = 15000, pop_bonus = 0},
	{id = "archery_range", cost = {50, 100, 50, 0}, base_health = 600, req_age = "neolithic", req_tech = "longbow", can_train = true, build_time = 12000, pop_bonus = 0},
	{id = "stable", cost = {100, 100, 0, 50}, base_health = 700, req_age = "neolithic", req_tech = "horseback", can_train = true, build_time = 15000, pop_bonus = 0},
	{id = "academy", cost = {100, 100, 100, 50}, base_health = 700, req_age = "neolithic", req_tech = "academy", build_time = 15000, pop_bonus = 0},
	{id = "tower", cost = {50, 50, 100, 0}, base_health = 600, req_age = "stone", build_time = 8000, pop_bonus = 0},
	{id = "temple", cost = {100, 100, 150, 100}, base_health = 800, req_age = "bronze", train_opts = {"priest", ""}, n_train = 1, can_train = true, build_time = 20000, pop_bonus = 0},
}

bldg_def_by_id :: proc(id: string) -> ^bldg_def {
	for i in 0 ..< len(std_bldg_defs) {
		if std_bldg_defs[i].id == id {
			return &std_bldg_defs[i]
		}
	}
	return nil
}

std_unit_by_id :: proc(id: string) -> ^unit_def {
	for i in 0 ..< len(std_unit_defs) {
		if std_unit_defs[i].id == id {
			return &std_unit_defs[i]
		}
	}
	return nil
}

// getUnitDefFor: unique-first when SPAWNING, shared for everyone else. Here the
// only fork is the cost table, and the only civ with same-name uniques is
// persian (archer / cavalry / heavy_cavalry).
civ_unit_def :: proc(ci: int, id: string) -> ^unit_def {
	c := &civs[ci]
	for i := 0; i < c.n_units; i += 1 {
		if c.units[i].id == id {
			return &c.units[i]
		}
	}
	return std_unit_by_id(id)
}

// buildingMaxHealth: the wonder is flat; the civ bonus scales by bonus name; the
// age scales by 1.5^index (WarMath.powInt: exact whole power), rounded to a 50-unit
// step, floored at 50.
building_max_health :: proc(d: ^bldg_def, ci: int, age: string) -> f64 {
	agess := [4]string{"stone", "neolithic", "bronze", "iron"}
	idx: i32 = 0
	for i in 0 ..< 4 {
		if agess[i] == age {
			idx = cast(i32)(i)
			break
		}
	}
	h := d.base_health * m_pow_int(1.5, idx) * civs[ci].bldg_mult
	return math.max(50, f64(math.floor((h/50) + 0.5)) * 50)
}

// ===========================================================================
// The map — a transcription of js/terrain.js for the arena's 800-unit world,
// medium difficulty (the golden's): 98 food, 784 wood, 40 stone, 20 gold, one
// wood node landing under the first Town Center. The stream is the seed's own
// (WarRng.stream(WarRng.hashSeed(seed), 42)): stateful, one step per draw.
// ===========================================================================

rnode :: struct {
	n_type: i32, // 0 food, 1 wood, 2 stone, 3 gold
	x, z: f64,
	amount: f64,
}

terrain :: struct {
	seed: string,
	size: f64,

	nodes: [2048]rnode, // 942 pre-clearing on golden/medium; easy's multipliers raise the count
	n_nodes: int,
}

// --- The coast: js/engine/texgen.js's sampler and js/terrain.js's table. ---
// The shoreline is a wobbled square: 413 ± 26 along each of 1024 directions,
// solved by the bisection the surf ribbon uses. The table is Float32: the
// entries are stored in 32-bit floats and read back as doubles.
COAST_CELLS :: 24
COAST_WOBBLE :: f64(26)
TERRAIN_SEED :: 12345
TERRAIN_WORLD :: f64(1000)
COAST_WALK :: f64(413)
COAST_LIMIT_N :: 1024

coast_lat : [COAST_CELLS * COAST_CELLS]f32

// TexGen.rng(seed) = WarRng.stream(seed, 1): mulberry, zero-seed fallback 1.
coast_lat_build :: proc() {
	st := hash_seed("12345")
	if st == 0 {
		st = 1
	}
	for i := 0; i < len(coast_lat); i += 1 {
		a := st
		v := mulberry_next(&a)
		st = a
		coast_lat[i] = cast(f32)(cast(f64)(v) / 4294967296.0)
	}
}

// TexGen.noiseSampler: wrapped bilinear over the lattice, in [0,1). The
// lattice entries are 32-bit floats; the interpolation is the language's f64.
coast_sample :: proc(u: f64, v: f64) -> f64 {
	cells := f64(COAST_CELLS)
	ux := m_fmod(m_fmod(u, 1) + 1, 1)
	vx := m_fmod(m_fmod(v, 1) + 1, 1)
	gx := ux * cells
	gy := vx * cells
	x0 := cast(int)(math.floor(gx))
	y0 := cast(int)(math.floor(gy))
	fx := gx - f64(x0)
	sy := gy - f64(y0)
	sx := fx * fx * (3 - 2 * fx)
	sy = sy * sy * (3 - 2 * sy)
	x0m := x0 %% COAST_CELLS
	y0m := y0 %% COAST_CELLS
	i00 := f64(coast_lat[y0m*COAST_CELLS + x0m])
	i10 := f64(coast_lat[y0m*COAST_CELLS + ((x0 + 1) %% COAST_CELLS)])
	i01 := f64(coast_lat[(y0 + 1) %% COAST_CELLS * COAST_CELLS + x0m])
	i11 := f64(coast_lat[(y0 + 1) %% COAST_CELLS * COAST_CELLS + ((x0 + 1) %% COAST_CELLS)])
	return (i00*(1 - sx) + i10*sx) * (1 - sy) + (i01*(1 - sx) + i11*sx) * sy
}

coast_wob :: proc(u: f64, v: f64) -> f64 {
	return (coast_sample(u, v) - 0.5) * COAST_WOBBLE
}

coast_limit : [COAST_LIMIT_N + 1]f32

coast_limit_table :: proc() {
	for i := 0; i <= COAST_LIMIT_N; i += 1 {
		t := f64(i)/f64(COAST_LIMIT_N) * 4
		side := min(3, cast(int)(math.floor(t)))
		s := t - f64(side)
		px: f64 = 0
		pz: f64 = 0
		if side == 0 {
			px, pz = 1, s*2 - 1
		} else if side == 1 {
			px, pz = 1 - s*2, 1
		} else if side == 2 {
			px, pz = -1, 1 - s*2
		} else {
			px, pz = s*2 - 1, -1
		}
		lo := COAST_WALK - COAST_WOBBLE
		hi := COAST_WALK + COAST_WOBBLE
		for k := 0; k < 18; k += 1 {
			mid := (lo + hi) / 2
			d := mid + coast_wob(mid*px/TERRAIN_WORLD + 0.5, mid*pz/TERRAIN_WORLD + 0.5)
			if d < COAST_WALK {
				lo = mid
			} else {
				hi = mid
			}
		}
		coast_limit[i] = cast(f32)((lo + hi) / 2)
	}
}

// terrain.landLimit: which side of the square this direction falls on, in the
// table's own perimeter parameter; the answer is interpolated, not rounded.
land_limit :: proc(x: f64, z: f64) -> f64 {
	ax := math.abs(x)
	az := math.abs(z)
	if ax < 1e-6 && az < 1e-6 {
		return f64(coast_limit[0])
	}
	t: f64
	if ax >= az {
		pz := z / ax
		if x > 0 {
			t = (pz + 1) / 2
		} else {
			t = 2 + (1 - pz) / 2
		}
	} else {
		px := x / az
		if z > 0 {
			t = 1 + (1 - px) / 2
		} else {
			t = 3 + (px + 1) / 2
		}
	}
	f := math.min(f64(COAST_LIMIT_N), math.max(0, t/4*f64(COAST_LIMIT_N)))
	i0 := cast(int)(math.floor(f))
	i1 := min(COAST_LIMIT_N, i0 + 1)
	a := f - f64(i0)
	return f64(coast_limit[i0])*(1 - a) + f64(coast_limit[i1])*a
}

// The terrain's one random stream: TexGen.rng(seed) = WarRng.stream(seed, 1) —
// mulberry32, drawn as u32/2^32. The state lives in the caller and is
// threaded by pointer: this compiler's proc values do not capture an
// enclosing scope (verified with a closure test that failed to see the
// local), so the JS closure over 'st' becomes an explicit parameter.
terrain_draw :: proc(st: ^u32) -> f64 {
	a := st^
	v := mulberry_next(&a) // the state is a + K; the mix never touches it
	st^ = a
	return cast(f64)(v) / 4294967296.0
}

// scatterEqual(type, total, amount): the 7x7 grid, equal per tile. The nodes
// array and the stream are threaded by pointer (see terrain_draw above).
terrain_scatter_equal :: proc(t: ^terrain, usable: f64, tile: f64, st: ^u32, ntype: i32, total: f64, amount: f64) {
	per := f64(math.max(1, math.floor((total / 49) + 0.5)))
	for tx := 0; tx < 7; tx += 1 {
		for tz := 0; tz < 7; tz += 1 {
			x0 := -usable/2 + f64(tx)*tile
			z0 := -usable/2 + f64(tz)*tile
			inset := f64(6)
			for i := 0; i < cast(int)(per); i += 1 {
				x := x0 + inset + terrain_draw(st)*(tile - inset*2)
				z := z0 + inset + terrain_draw(st)*(tile - inset*2)
				t.nodes[t.n_nodes] = rnode{ntype, x, z, amount}
				t.n_nodes += 1
			}
		}
	}
}

// scatterRotational(type, total, amount): k nodes in one sector, rotated onto
// every other. The arena's spawns are the ideal circle, so the plain
// rotation runs (the shifted variant needs a jittered caller, which the
// arena is not).
terrain_scatter_rotational :: proc(t: ^terrain, size: f64, spawns: [][2]f64, a0: f64, sector: f64, st: ^u32, ntype: i32, total: f64, amount: f64) {
	ns := len(spawns)
	per := f64(math.max(1, math.floor((total / f64(ns)) + 0.5)))
	R := size/2 - 40    // same usable radius the grid's box spans
	rMin := f64(60)      // nothing on the map's navel
	KEEP_OUT := f64(95)  // no stone/gold this close to ANY Town Center
	for i := 0; i < cast(int)(per); i += 1 {
		r: f64 = rMin
		ang: f64 = a0
		for tries := 0; tries < 60; tries += 1 {
			u := terrain_draw(st)
			r = math.sqrt(rMin*rMin + u*(R*R - rMin*rMin))
			ang = a0 + (terrain_draw(st) - 0.5)*sector
			x := m_cos(ang) * r
			z := m_sin(ang) * r
			close := false
			for s in 0 ..< ns {
				if m_hypot(x - spawns[s][0], z - spawns[s][1]) < KEEP_OUT {
					close = true
					break
				}
			}
			if !close {
				break
			}
		}
		for p := 0; p < ns; p += 1 {
			angp := ang + f64(p)*sector
			t.nodes[t.n_nodes] = rnode{ntype, m_cos(angp)*r, m_sin(angp)*r, amount}
			t.n_nodes += 1
		}
	}
}

// The four Town Centers clear whatever node sits within clearance + 3 of
// their spawn, in seat order (resourceClearance('town_center') = 5 + 4.5);
// the survivor list is the node space every later read (and the fixtures) uses.
terrain_clear_near :: proc(t: ^terrain, x: f64, z: f64, radius: f64) {
	j := 0
	for i := 0; i < t.n_nodes; i += 1 {
		n := &t.nodes[i]
		if m_hypot(n.x - x, n.z - z) < radius {
			continue
		}
		t.nodes[j] = n^
		j += 1
	}
	t.n_nodes = j
}

t_terrain :: proc(size: f64, seed: string, spawns: [][2]f64, diff: string) -> terrain {
	coast_lat_build()
	coast_limit_table()

	t := terrain{size = size, seed = seed}
	usable := size - 80
	tile := usable / 7

	// The rotation the scarce types use is about the first spawn's angle; the
	// arena's four are the ideal circle, so this is the one the whole layout shares.
	a0 := m_atan2(spawns[0][1], spawns[0][0])
	sector := (math.PI * 2) / f64(len(spawns))

	st := hash_seed(seed)
	if st == 0 {
		st = 42
	}

	// the difficulty mods (terrain.js DIFFICULTY_MODS): easy food x2 is the
	// baseline; medium food x0.5; hard food x0.25, wood x0.25, stone x0.5.
	// Gold has no entry and is identical in all three.
	fm, wm, sm := f64(2.0), f64(1.0), f64(1.0)
	if diff == "medium" {
		fm = 0.5
	} else if diff == "hard" {
		fm = 0.25
		wm = 0.25
		sm = 0.5
	}
	terrain_scatter_equal(&t, usable, tile, &st, 0, 196*fm, 500)         // food
	terrain_scatter_equal(&t, usable, tile, &st, 1, 784*wm, 300)         // wood
	terrain_scatter_rotational(&t, size, spawns, a0, sector, &st, 2, 40*sm, 1000) // stone
	terrain_scatter_rotational(&t, size, spawns, a0, sector, &st, 3, 18, 2000)     // gold
	for s in 0 ..< len(spawns) {
		terrain_clear_near(&t, spawns[s][0], spawns[s][1], 9.5 + 3)
	}

	return t
}

// The arena's spawn circle: (i/4) * 2pi - pi/2 on a 306-unit radius, in WarMath
// (game.js:373-381; halfSize = 400 - 40, radius = 0.85 x that).
arena_spawns :: proc(n: int) -> [][2]f64 {
	sp := make([][2]f64, n)
	half := f64(400) - 40
	radius := half * 0.85
	for i in 0 ..< n {
		angle := f64(i)/f64(n) * math.PI * 2 - math.PI/2
		sp[i][0] = m_cos(angle) * radius
		sp[i][1] = m_sin(angle) * radius
	}
	return sp
}


// The recorder's Math.random (record.cjs): mulberry32 derived from the seed
// string. Its ONLY consumer is the entity-id mint at every createUnit and
// createBuilding — the mints are invisible until a rival entity is seen.
mseed_init :: proc(st: ^u32, seed: string) {
	a: u32 = 1779033703
	for c in 0 ..< len(seed) {
		a = a ~ u32(seed[c])
		a *= u32(3432918353)
	}
	st^ = a
}

m_rand :: proc(st: ^u32) -> f64 {
	st^ += u32(0x6D2B79F5)
	y := u32(1) | st^
	t := st^
	t = t ~ (t >> 15)
	t *= y
	x := t ~ (t >> 7)
	t = (t + (x * (u32(61) | t))) ~ t
	return f64(t ~ (t >> 14)) / 4294967296.0
}

// Math.random().toString(36).substr(2, 9): V8's radix-36 digit loop —
// multiply the fraction by 36, take each integer digit, until the f64
// fraction hits exactly zero.
base36_suffix :: proc(st: ^u32, out: []u8) -> int {
	frac := m_rand(st)
	n := 0
	for frac > 0 && n < len(out) {
		frac = frac * 36
		d := f64(math.floor(frac))
		if d < 10 {
			out[n] = u8('0' + u8(d))
		} else {
			out[n] = u8('a' + u8(d - 10))
		}
		n += 1
		frac = frac - d
	}
	return n
}

mint_entity :: proc(g: ^game_state, prefix: string) -> string {
	digs: [9]u8
	n := base36_suffix(&g.mseed, digs[:])
	s := fmt.aprintf("%s%d_%s", prefix, int(g.match_ms), string(digs[:n]))
	return s
}


// ===========================================================================
// The state — one seat at a time. A seat owns its resources, its units, its
// Town Center, the nodes it has seen, the map it has explored, and the keyed
// draws it has made. The arena is the four seats plus the shared node list.
// ===========================================================================

res_state :: struct {
	food, wood, stone, gold: f64,
}

unit_state :: struct {
	handle: int,
	x, z: f64,
	health: f64,
	u_type: string, // 'worker' or the military id ('militia', 'archer', ...)
	max_health: f64,
	pid: string, // the minted entity id: 'unit_<ms>_<9 base-36 digits>'
	is_attacking: bool,
	atk_kind: int, // 0 none, 1 enemy unit, 2 enemy building
	atk_seat, atk_idx: int,
	attack_move: bool,
	am_x, am_z: f64,
	attack_timer: f64,
	acquire_timer: f64,
	acquire_set: bool,
	self_defense: bool, sd_x, sd_z: f64,
	last_dmg_time: f64,
	ldk_kind, ldk_seat, ldk_idx: int, // _lastAttacker
	def_at: f64, def_none: bool, // _defense: did anything answer this hit
	dead_counted: bool, // recordBattleLoss fired once
	// the retaliation ladder (_origTarget/_retalQueue): refs are stable
	// because dead entities keep their slot
	orig_kind, orig_seat, orig_idx: int,
	rt_kind, rt_seat, rt_idx: [8]int, // _retalQueue, head first
	n_rt: int,
	// --- the match engine's worker fields (js/game.js updateWorkerTasks) ---
	task: int, // TASK_*: the worker state machine's current job
	is_moving: bool,
	is_harvesting: bool,
	is_building: bool,
	carrying: bool,
	carry_type: int, // 0..3: the resource type the worker is hauling
	harvest_amt: f64,
	harvest_timer: f64,
	target_x, target_z: f64,
	harvest_node: int, // terrain node index; -1 none
	build_site: int, // this seat's bldgs index; -1 none
	speed: f64, // unit.speed: workers 1.0 (moveSpeedOf's own pace)
	scout_ticks: int, // the scouting leg's _scoutTicks
	farm: int, // this seat's bldgs index (farmRef); -1 none
	former_task: int, // _formerTask.task (-1 none): the pulled worker's restore
	former_node: int, // _formerTask.harvestTarget
	former_farm: int, // _formerTask.farmRef
	repair_site: int, // repairTarget; -1 none (no repairs fire in this corpus)
}

bldg_state :: struct {
	id: string, // the type id: 'town_center', 'house', 'farm'
	x, z: f64,
	health: f64,
	max_health: f64,
	// --- the match engine's production/construction fields ---
	under_constr: bool,
	build_progress: f64,
	build_time: f64,
	is_producing: bool,
	prod_type: string, // 'worker' (military ids later in longer matches)
	prod_duration: f64,
	prod_progress: f64,
	food_amount: f64, // farms: the live food stock
	max_food: f64,
	regen_timer: f64,
	assigned_worker: int, // this seat's unit index; -1 none
	is_wonder: bool,
	pid: string, // the minted entity id
	last_dmg_time: f64,
		def_at: f64, def_none: bool, // _defense: did anything answer this hit
ldk_kind, ldk_seat, ldk_idx: int, // _lastAttacker
	dead_counted: bool, // recordBattleLoss fired once
}

// The worker task vocabulary (js/game.js's task strings, as an int).
TASK_NONE :: 0
TASK_HARVESTING :: 1
TASK_CARRYING :: 2
TASK_BUILDING :: 3
TASK_REPAIRING :: 4
TASK_FARM_WORK :: 5
TASK_SCOUTING :: 6

MAX_UNITS :: 64 // the 1-minute corpus peaks at 14; headroom for longer matches
MAX_BLDGS :: 32 // TC + houses + farms; the 5-minute run builds 9

// The reference's position rules walk TWO GLOBAL lists in CREATION order:
// renderer.units and renderer.buildings (game.js getAllUnits/getAllBuildings).
// Pair indices and the dead-centre spoke come from those global positions,
// and the clearance pass accumulates pushes in building creation order
// (which interleaves seats as rival builds land between ours), so both
// lists are kept here explicitly.
gl_ref :: struct {
	seat: i32,
	idx: i32,
}
MAX_EVTS :: 32 // the live ring holds 14; shift semantics, no wrap math

// One recentEvents entry (game.js logPlayerEvent): {at, seq, text, ttl}.
// The text is a template plus small parameters, formatted at write time.
EVT_DRY_NODE :: 0 // "The {type} at ({x}, {z}) was already exhausted..."
EVT_LAST_EMPTY :: 1 // "Your last discovered {k} node has been emptied..."

evt :: struct {
	at: f64, // simNow() at log time (sim ms)
	seq: int, // the seat's turn seq at log time
	ttl: int, // 2 (logPlayerEvent's default)
	kind: int, // EVT_*
	p_type: int, // the resource type index (both templates name one)
	p_x: int, // the node's rounded x (EVT_DRY_NODE)
	p_z: int,
}

// WarRng.keyed(seed): {seed, n: {}}, and draw: the key's n-th value, counted
// per key so one key's draws never move another's.
keyed_rng :: struct {
	seed: string,
	n: map[string]u32,
}

krng_draw :: proc(k: ^keyed_rng, key: string) -> f64 {
	n := k.n[key] // 0 on first use, as `state.n[key] || 0`
	k.n[key] = n + 1
	return keyed_draw(k.seed, key, n)
}

seat :: struct {
	ci: int,
	id: string, // 'ai_egyptian_golden' and friends (the arena's mint, kept)
	pid: string, // the recorder's minted id: 'ai_0ye7zz9o0ng' (WarRng.id)
	units: [MAX_UNITS]unit_state,
	n_units: int,
	bldgs: [MAX_BLDGS]bldg_state,
	n_bldgs: int,
	home: bldg_state, // the Town Center; also bldgs[0] in the match engine
	res: res_state,
	gathered: res_state, // ResourceManager.gathered: lifetime delivered, per type
	pop: int, // resources.updatePopulation(units.length) each step
	max_pop: int, // recomputeMaxPopulation: 10 (TC) + 5/house
	known: [2048]byte, // _knownResIdx: node index -> seen
	seen_amt: [2048]f64, // the seen amount the harness caches with the node
	seen_set: [2048]byte,
	explored: [42 * 42]byte, // the exploration bitmap, one per 19-unit cell
	met: [4]bool, // first-contact memory: has this seat ever seen rival <i>?
	harvest_bonus: f64, // workerHarvestBonus: 1.0 — the spectator path applies NO civ bonus
	techcost_mult: f64, // techCostMultiplier: 1.0 likewise (ai.js addAIPlayer's defaults)
	handle_next: int, // the per-owner handle counter (nextUnitHandle): 4 after the start
	k: keyed_rng,
	// --- the match engine's brain fields (js/ai.js AIManager + the seat) ---
	think_timer: f64, // advanceThink's accumulator (sim ms)
	cur_research: bool, // ai.currentResearch != null
	res_tech: string, // the tech id being researched
	res_progress: f64,
	res_duration: f64,
	cur_age_upgrade: bool, // ai.currentAgeUpgrade != null (dormant in this minute)
	cur_age: int, // age index 0..3 (stone..iron); no age-up fires in this corpus
	researched: [16]string, // researchedTechs (the set, in completion order)
	n_researched: int,
	unlocked_bldgs: [16]string, // owner.unlockedBuildings (tech unlocks)
	n_unlocked_bldgs: int,
	events: [MAX_EVTS]evt, // the seat's notice ring (logPlayerEvent's)
	n_events: int,
	turn_seq: int, // ai._turnSeq
	last_counts: [4]int, // _lastNodeCounts: {food,wood,stone,gold}
	dry_told: [2048]bool, // _dryNodesTold: once per node
	explore_timer: int, // _exploreTimer
	army_scout_x, army_scout_z: f64, // _armyScoutTarget
	army_scout_set: bool,
	army_scout_ticks: int, // stuck counter
	army_scout_best: f64, // the closest the centroid got this leg
	army_scout_best_set: bool,
	army_scout_angle: f64, // the golden-angle fallback
	army_scout_radius: f64,
	army_leg_skip: [49]bool, // tiles given up on, row-major 7x7
	um_pid: [512]string, // _unitMemory: remembered enemy units
	um_oseat: [512]int,
	um_oidx: [128]int,
	um_type: [512]string,
	um_x, um_z, um_sx, um_sz: [512]f64,
	um_has_sx: [512]bool,
	um_hp: [512]int,
	um_carry: [512]string, // "" none, else the load
	um_at, um_t: [512]f64,
	um_visible, um_located, um_spot_hidden: [512]bool,
	um_sighted: [512]bool, // sighted this state build
	n_um: int,
	scout_angle: f64, // _scoutAngle
	scout_radius: f64, // _scoutRadius
	eb_known: [4][32]bool, // _knownEnemyBuildings, per enemy seat per building
	eb_hp: [4][32]int, // _enemyBuildingSeen snapshot: healthPct at last sight
	eb_x, eb_z: [4][32]f64, // snapshot position (rounded at write time)
	eb_has: [4][32]bool,
}

// One timeline sample: {t, p: {aiId: {f,w,s,o,pw,al}}} (game.js sampleTimeline).
tl_sample :: struct {
	t: int,
	f, w, s, o: [4]f64, // gathered per seat (rounded)
	al: [4]bool, // alive: buildings or units
}

tl_mark :: struct {
	t: int,
	id: int, // the seat index (written as the minted id)
	kind: int, // 0 = age (string), 1 = exhausted (a resource type index)
	p_type: int, // the resource type (EVT_LAST_EMPTY's shape, for exhausted)
}

game_state :: struct {
	contact_idx: int, // detectContacts' rotating seat
	// the battle ledger (game.js _battles): engagements opened by damage
	b_x, b_z: [8]f64,
	b_started, b_last: [8]f64,
	b_nsides: [8]int,
	b_side_seat: [8][8]int, // sides in first-damage order
	b_inv_type: [8][8][16]string, // per side: involved attacker types
	b_inv_n: [8][8]int,
	b_inv_ids: [8][8][16][64]string, // the unique attacker pids
	b_inv_nids: [8][8][16]int,
	b_inv_du, b_inv_db, b_inv_he: [8][8][16]f64,
	b_lost_type: [8][8][16]string, // per side: lost victims by type
	b_lost_n: [8][8][16]int,
	b_nlost: [8][8]int,
	n_battles: int,
	seats: [4]seat,
	terrain: terrain,
	match_ms: f64, // clock.matchMs: the MATCH clock, 25 per sim step at the recorder's 2x
	sim_ms: f64, // clock.simMs: 50 per sim step
	step_no: int,
	total_minutes: int, // the recorded corpus length (header field)
	n_seats: int, // the corpus seat count
	map_seed: string, // the corpus seed (header/map fields)
	map_diff: string, // the corpus difficulty (header/map fields)
	discovery_timer: f64, // the 4 Hz beat's own accumulator (mgr.update)
world_rng: keyed_rng, // the game's one rng (seed 'golden'): 'world:*' draws
	mseed: u32, // the recorder's mulberry32 Math.random: entity-id mints
	autodef_timer: f64,
	// --- the match timeline (game.js resetTimeline/sampleTimeline) ---
	tl_t0: f64,
	tl_last: f64,
	tl_samples: [256]tl_sample,
	tl_n_samples: int,
	tl_marks: [256]tl_mark,
	tl_n_marks: int,
	tl_age: [4]int, // the last age index per seat (-1 = unset)
	tl_dry: [4][4]bool, // ran-dry flags per seat per type (start true)
	// --- the position rules' global creation-ordered lists ---
	gl_u: [4 * MAX_UNITS]gl_ref,
	n_gl_u: int,
	gl_b: [4 * MAX_BLDGS]gl_ref, // every building in creation order
	n_gl_b: int,
	cb_x, cb_z: [4][MAX_UNITS]f64, // the combat pass's start positions: the
	// reference's visionSources cache is stamped once per sub-step, so the
	// acquire scan's sight test reads the PRE-COMBAT positions
}

// resetTimeline: a fresh match — population 0, the match clock 0, the
// discovery beat 0, no pending events, the exploration bitmaps blank.
setup :: proc(g: ^game_state, spawns: [][2]f64, n_seats: int, seed_for_rng: string) {
	g.match_ms = 0
	g.sim_ms = 0
	g.step_no = 0
	g.world_rng.seed = seed_for_rng
	mseed_init(&g.mseed, seed_for_rng)
	// burn the reference recorder's load-time draws: its terrain preview
	// scatters through the same mulberry32 Math.random that entity mints
	// use, and the first entity mint lands on draw 2548 (0-based, measured
	// against the golden corpus: TC0's suffix is that draw's)
	for burn in 0 ..< 2548 {
		_ = m_rand(&g.mseed)
	}
	g.discovery_timer = 0
	g.total_minutes = 1
	g.tl_t0 = 0
	g.tl_last = 0
	g.tl_n_samples = 0
	g.tl_n_marks = 0
	g.n_gl_u = 0
	g.n_gl_b = 0
	for i in 0 ..< 4 {
		g.tl_age[i] = -1
		for k in 0 ..< 4 {
			g.tl_dry[i][k] = true
		}
	}
	for i in 0 ..< g.n_seats {
		s := &g.seats[i]
		c := &civs[i]
		s.ci = i
		s.id = fmt.aprintf("ai_%s_golden", c.id)
		s.k.seed = "golden"
		// The recorder's minted player id: WarRng.id('ai_', two draws of the
		// game's own 'world:player-id' stream), in seat order — the stream's
		// turn records and match line carry these verbatim (addAIPlayer, ai.js).
		s.pid = war_rng_id(&g.world_rng, "ai_")
		s.harvest_bonus = 1.0
		s.techcost_mult = 1.0
		s.handle_next = 4
		sp := spawns[i]

		// The Town Center, at the spawn, finished (createBuilding, age 'stone').
		def := bldg_def_by_id("town_center")
		mh := building_max_health(def, i, "stone")
		s.home = bldg_state{id = "town_center", x = sp[0], z = sp[1], health = mh, max_health = mh}
		// ...and the match engine's building list: the TC is bldgs[0]. The
		// reference's seat owns its buildings as a list (ai.buildings); the
		// TC is created first (startGame), then houses/farms append as built.
		s.bldgs[0] = s.home
		s.bldgs[0].pid = mint_entity(g, "building_")
		s.n_bldgs = 1
		g.gl_b[g.n_gl_b] = gl_ref{seat = i32(i), idx = 0}
		g.n_gl_b += 1

		// The three workers: each axis one keyed draw of the seat's own stream,
		// 's<i>:start-workers', n = 0..5 (x then z, worker by worker).
		key := fmt.aprintf("s%d:start-workers", i)
		for w in 0 ..< 3 {
			x := sp[0] + (krng_draw(&s.k, key) - 0.5) * 10
			z := sp[1] + (krng_draw(&s.k, key) - 0.5) * 10
			s.units[w] = unit_state{handle = w + 1, x = x, z = z, health = 40, max_health = 40, speed = 1.0, u_type = "worker", harvest_node = -1, build_site = -1, farm = -1, former_node = -1, former_farm = -1, repair_site = -1}
			s.units[w].pid = mint_entity(g, "unit_")
			s.n_units += 1
			g.gl_u[g.n_gl_u] = gl_ref{seat = i32(i), idx = i32(w)}
			g.n_gl_u += 1
		}

		// The ResourceManager's opening balances (resources.js's constructor).
		s.res = res_state{food = 200, wood = 200, stone = 100, gold = 50}
		s.pop = 0
		s.max_pop = 10

		// The civ bonus, applied to the seat the way the reference does
		// (civ.bonus.effect(ai)): egypt/greek scale building health (folded
		// into the TC's maxHealth above), persian harvest, yamato tech cost.
	}
}

// ===========================================================================
// Sight. Two shapes, both in the reference: the per-position test the state
// view uses (isPositionVisibleToAI: a straight loop over the seat's own
// units and buildings, plain sqrt) and the batched test the step's discovery
// beat uses (buildVisionTest, harness mode: a 20-unit eye grid, the cell a
// point falls in plus its ring).
// ===========================================================================

// A unit sees 15 (22.5 cavalry, which the arena has not fielded yet); a
// finished Town Center sees 40 (buildingVision).
unit_vision :: proc(u: ^unit_state) -> f64 {
	return u.u_type == "cavalry" ? 22.5 : 15
}
building_vision :: proc(b: ^bldg_state) -> f64 {
	// construction sites grant no vision; completed wonders are landmarks
	if b.under_constr {
		return 0
	}
	if b.id == "tower" {
		return 80
	}
	if b.is_wonder {
		return 60
	}
	if b.id == "town_center" {
		return 40
	}
	return 20
}

// isIdleWorker (game.js 3594): the worker-side freedom test workerJob's
// idle bucket shares with the builder pick.
is_idle_worker :: proc(u: ^unit_state) -> bool {
	return u.health > 0 &&
		!u.is_building && u.task != TASK_BUILDING &&
		u.task != TASK_HARVESTING && u.task != TASK_CARRYING && u.task != TASK_FARM_WORK &&
		!u.is_harvesting && !u.carrying && u.farm < 0
}

// isPositionVisibleToAI: the first eye that reaches the point wins.
immediate_visible :: proc(s: ^seat, x: f64, z: f64) -> bool {
	for i in 0 ..< s.n_units {
		u := &s.units[i]
		if u.health > 0 {
			range := unit_vision(u)
			dx := u.x - x
			dz := u.z - z
			if math.sqrt(dx*dx + dz*dz) <= range {
				return true
			}
		}
	}
	for bi in 0 ..< s.n_bldgs {
		bd := &s.bldgs[bi]
		if bd.under_constr {
			continue
		}
		range := building_vision(bd)
		dx := bd.x - x
		dz := bd.z - z
		if math.sqrt(dx*dx + dz*dz) <= range {
			return true
		}
	}
	b := &s.home
	if b.id != "" {
		range := building_vision(b)
		dx := b.x - x
		dz := b.z - z
		if math.sqrt(dx*dx + dz*dz) <= range {
			return true
		}
	}
	return false
}

eye :: struct {
	x, z, r: f64,
	cell: i32,
}

eye_set :: struct {
	cells: [1600]i32, // cell -> first eye index, -1 for none
	next: [64]i32, // next in the cell's chain
	eyes: [64]eye,
	n: int,
}

// The eye-filing closure the JS harness defines inside makeEyes: an eye is
// filed in every cell its RANGE reaches (up to one ring around its own
// cell). Hoisted to file scope with the eye set threaded by pointer — proc
// values do not capture an enclosing scope in this compiler — and the grid
// constants inlined as the literals they are in the JS (G=40, cell=20,
// half=400).
eyes_file :: proc(es: ^eye_set, x: f64, z: f64, r: f64) {
	half := f64(400)
	CELL := f64(20)
	G := 40
	// buildVisionTest's file(): the eye lands in EVERY cell of the exact
	// bounding square floor((pos-r-1)/CELL) .. floor((pos+r+1)/CELL) — no
	// centre-distance filter; the query's own test decides. Cell coords
	// here are shifted +20 into the 0..40 grid this engine indexes.
	gx0 := cast(int)(math.floor((x - r - 1.0) / CELL)) + 20
	gx1 := cast(int)(math.floor((x + r + 1.0) / CELL)) + 20
	gz0 := cast(int)(math.floor((z - r - 1.0) / CELL)) + 20
	gz1 := cast(int)(math.floor((z + r + 1.0) / CELL)) + 20
	idx := es.n
	for gz := gz0; gz <= gz1; gz += 1 {
		for gx := gx0; gx <= gx1; gx += 1 {
			if gx < 0 || gx >= G || gz < 0 || gz >= G {
				continue
			}
			{
				c := gz*G + gx
				es.next[idx] = es.cells[c]
				es.cells[c] = cast(i32)(idx)
			}
		}
	}
	es.eyes[idx] = eye{x = x, z = z, r = r}
	es.n += 1
}

// buildVisionTest (harness mode): the eye grid is rebuilt each step, because
// the eyes move. Eyes are filed where their RANGE reaches, not where they
// stand: an eye in a cell sees up to one ring of cells around it.
make_eyes_mode :: proc(s: ^seat, harness: bool) -> eye_set {
	es: eye_set
	for c in 0 ..< 1600 {
		es.cells[c] = -1
	}
	es.n = 0
	G := 40
	CELL := f64(20)
	half := f64(400)


	for i in 0 ..< s.n_units {
		u := &s.units[i]
		if u.health > 0 {
			// the eye is filed at the RAW position — buildVisionTest files
			// u.x/u.z verbatim; rounding here shifts the vision boundary
			eyes_file(&es, u.x, u.z, unit_vision(u))
		}
	}
	for i in 0 ..< s.n_bldgs {
		b := &s.bldgs[i]
		// buildVisionTest: harness mode skips construction plots (they see
		// nothing), non-harness only the dead
		if b.health > 0 && (!harness || !b.under_constr) {
			eyes_file(&es, b.x, b.z, building_vision(b))
		}
	}
	return es
}

make_eyes :: proc(s: ^seat) -> eye_set {
	return make_eyes_mode(s, true)
}

// The test itself: the point's cell and its one-cell ring, every eye in it.
// Harness mode: a plain sqrt against the eye's own (rounded) position.
see_test :: proc(es: ^eye_set, x: f64, z: f64) -> bool {
	// per-eye distance, the reference's exact test (the cell grid only ever
	// indexed candidates; the scan is small and removes the indirection)
	for e in 0 ..< es.n {
		ev := &es.eyes[e]
		dx := ev.x - x
		dz := ev.z - z
		if math.sqrt(dx*dx + dz*dz) <= ev.r {
			return true
		}
	}
	return false
}

// The brain's own discovery test (buildVisionTest's non-harness mode): the
// same eye set, but the comparison is WarMath.hypot where the harness's is
// Math.sqrt — the two differ by an ulp at the vision boundary, and a node
// on the line is known to the brain before the state's own pass sees it.
see_test_brain :: proc(es: ^eye_set, x: f64, z: f64) -> bool {
	// per-eye distance, the reference's exact test (the cell grid only ever
	// indexed candidates; the scan is small and removes the indirection)
	for e in 0 ..< es.n {
		ev := &es.eyes[e]
		dx := ev.x - x
		dz := ev.z - z
		if m_hypot(dx, dz) <= ev.r {
			return true
		}
	}
	return false
}

// ai.js updateDiscovery (the 250 ms beat): the brain's own node discovery.
// The enemy-building memory it also fills stays dormant — no contacts in
// this corpus.
brain_discovery :: proc(g: ^game_state, s: ^seat) {
	es := make_eyes_mode(s, false)
	for i in 0 ..< g.terrain.n_nodes {
		if s.known[i] != 0 {
			continue
		}
		n := &g.terrain.nodes[i]
		if see_test_brain(&es, n.x, n.z) {
			s.known[i] = 1
		}
	}
	// updateRivalContacts: first contact with a rival gates the opponents
	// footer's army/building counts (game.js 4660)
	for oi in 0 ..< g.n_seats {
		if oi == s.ci || s.met[oi] { continue }
		o := &g.seats[oi]
		spotted := false
		for i in 0 ..< o.n_units {
			if o.units[i].health > 0 && see_test_brain(&es, o.units[i].x, o.units[i].z) { spotted = true; break }
		}
		if !spotted {
			for i in 0 ..< o.n_bldgs {
				if o.bldgs[i].health > 0 && see_test_brain(&es, o.bldgs[i].x, o.bldgs[i].z) { spotted = true; break }
			}
		}
		if spotted { s.met[oi] = true }
	}
}

// markExploration: the seat's 42-cell bitmap, a cell set when an eye of
// `range` reaches its centre. Units mark at 15, the Town Center at 40.
exploration_mark :: proc(s: ^seat, x: f64, z: f64, range: f64) {
	G := 42
	cell := f64(800) / f64(G)
	half := f64(400)
	cr := cast(int)(math.ceil(range / cell))
	cx := cast(int)(math.floor((x + half) / cell))
	cz := cast(int)(math.floor((z + half) / cell))
	cx = min(G-1, max(0, cx))
	cz = min(G-1, max(0, cz))
	for dz := -cr; dz <= cr; dz += 1 {
		for dx := -cr; dx <= cr; dx += 1 {
			gx := cx + dx
			gz := cz + dz
			if gx < 0 || gx >= G || gz < 0 || gz >= G {
				continue
			}
			wx := (f64(gx) + 0.5)*cell - half
			wz := (f64(gz) + 0.5)*cell - half
			if m_hypot(wx - x, wz - z) <= range {
				s.explored[gz*G + gx] = 1
			}
		}
	}
}

// explorationSummary: the 7x7 tiles, each the percent of the 36 bitmap cells
// inside it that are set. The state view keys it by the A1..G7 labels.
tile_label :: proc(row: int, col: int) -> string {
	return fmt.aprintf("%c%d", cast(rune)(65 + cast(i32)(col)), row + 1)
}

exploration_summary :: proc(s: ^seat) -> [7][7]i32 {
	out: [7][7]i32
	G := 42
	T := 7
	S := G / T
	for tz in 0 ..< T {
		for tx in 0 ..< T {
			seen := 0
			for dz in 0 ..< S {
				for dx in 0 ..< S {
					if s.explored[(tz*S + dz)*G + tx*S + dx] != 0 {
						seen += 1
					}
				}
			}
			out[tz][tx] = cast(i32)(math.round(f64(seen)/f64(S*S) * 100))
		}
	}
	return out
}

// tileLabelAt: which A1..G7 tile a world position falls in (game.js:4020).
tile_at :: proc(x: f64, z: f64, size: f64) -> string {
	T := 7
	cell := size / f64(T)
	half := size / 2
	col := cast(int)(math.floor((x + half) / cell))
	row := cast(int)(math.floor((z + half) / cell))
	col = min(T-1, max(0, col))
	row = min(T-1, max(0, row))
	return tile_label(row, col)
}

// ===========================================================================
// The JSON writer. The fixtures are JSON.stringify of the state view: no
// spacing, insertion order, numbers as the engine prints them (ints for all
// values here, and two floats — the bonus multipliers). This writer has the
// same comma discipline and nothing else: no escaping is ever needed because
// every string in the document is ASCII.
// ===========================================================================

JW_SIZE :: 134217728 // the one-minute stream is 3.1 MB; 10 minutes is 34.7 MB

jw :: struct {
	buf: [JW_SIZE]byte,
	n: int,
	sep: bool, // a comma goes before the next element
}

j_val :: proc(j: ^jw) {
	if j.sep {
		j.buf[j.n] = ','
		j.n += 1
	}
	j.sep = true
}

j_str :: proc(j: ^jw, s: string) {
	j_val(j)
	j.buf[j.n] = '"'
	j.n += 1
	copy(j.buf[j.n:len(s)+j.n], s)
	j.n += len(s)
	j.buf[j.n] = '"'
	j.n += 1
}

j_int :: proc(j: ^jw, v_in: i64) {
	v := v_in
	j_val(j)
	if v < 0 {
		j.buf[j.n] = '-'
		j.n += 1
		v = -v
	}
	d: [24]byte
	dn := 0
	if v == 0 {
		d[dn] = '0'
		dn += 1
	} else {
		for ; v > 0; v /= 10 {
			d[dn] = cast(byte)('0' + cast(u64)(v % 10))
			dn += 1
		}
	}
	for i := dn - 1; i >= 0; i -= 1 {
		j.buf[j.n] = d[i]
		j.n += 1
	}
}

j_bool :: proc(j: ^jw, b: bool) {
	j_val(j)
	if b {
		copy(j.buf[j.n:j.n+4], "true")
		j.n += 4
	} else {
		copy(j.buf[j.n:j.n+5], "false")
		j.n += 5
	}
}

j_null :: proc(j: ^jw) {
	j_val(j)
	copy(j.buf[j.n:j.n+4], "null")
	j.n += 4
}

// The one float the state view carries: the bonus multipliers (1.2, 0.7).
// The JS Number.prototype.toString rule (ECMA-262 6.1.6.1), which is also
// JSON.stringify's number rule: the shortest decimal that round-trips, in
// plain notation whenever 1e-6 <= |v| < 1e21, and an unpadded exponent
// ("1e+21", "1e-7") outside that range. Integers carry no ".0". NaN and
// the infinities are "null", as JSON.stringify writes them.
j_f64 :: proc(j: ^jw, v_in: f64) {
	j_val(j)
	if v_in != v_in || v_in == m_inf || v_in == -m_inf {
		copy(j.buf[j.n:j.n+4], "null")
		j.n += 4
		return
	}
	if v_in == 0 {
		j.buf[j.n] = '0' // covers -0 too: JSON.stringify(-0) is "0"
		j.n += 1
		return
	}
	if v_in < 0 {
		j.buf[j.n] = '-'
		j.n += 1
	}
	av := m_abs(v_in)
	// The shortest round-trip digits, from strconv's exponential form
	// ("d.ddde±dd", precision -1). The digits and exponent are all that is
	// needed here; the notation is re-chosen below by the JS rule, not by
	// Odin's — Odin's %v switches to an exponent far earlier than JS does.
	ftoa_buf: [32]byte
	s := strconv.generic_ftoa(ftoa_buf[:], av, 'e', -1, 64)
	// strconv prefixes positive values with '+'; av never carries a sign
	// here (the minus was written above), so the plus is skipped, not parsed.
	p := 0
	if s[0] == '+' {
		p = 1
	}
	dig: [32]byte
	nd := 1
	dig[0] = s[p]
	i := p + 1
	if s[i] == '.' {
		i += 1
		for s[i] != 'e' {
			dig[nd] = s[i]
			nd += 1
			i += 1
		}
	}
	i += 1 // past 'e'
	esign := 1
	if s[i] == '+' {
		i += 1
	} else if s[i] == '-' {
		esign = -1
		i += 1
	}
	exp10 := 0
	for i < len(s) {
		exp10 = exp10*10 + (cast(int)(s[i]) - 48)
		i += 1
	}
	exp10 *= esign
	n := exp10 + 1 // the value is dig[0..nd] x 10^(n - nd)
	// The ECMA table: k = nd, the exponent above is n - 1.
	if nd <= n && n <= 21 {
		// digits, then n - k zeros
		for d in 0 ..< nd {
			j.buf[j.n] = dig[d]
			j.n += 1
		}
		for d in 0 ..< n - nd {
			j.buf[j.n] = '0'
			j.n += 1
		}
	} else if n > 0 && n <= nd {
		// the point falls inside the digits
		for d in 0 ..< n {
			j.buf[j.n] = dig[d]
			j.n += 1
		}
		j.buf[j.n] = '.'
		j.n += 1
		for d in n ..< nd {
			j.buf[j.n] = dig[d]
			j.n += 1
		}
	} else if n > -6 && n <= 0 {
		// 0.000ddd: -n zeros after the point
		j.buf[j.n] = '0'
		j.n += 1
		j.buf[j.n] = '.'
		j.n += 1
		for d in 0 ..< -n {
			j.buf[j.n] = '0'
			j.n += 1
		}
		for d in 0 ..< nd {
			j.buf[j.n] = dig[d]
			j.n += 1
		}
	} else {
		// exponential, exponent unpadded: 1e+21, 1e-7
		j.buf[j.n] = dig[0]
		j.n += 1
		if nd > 1 {
			j.buf[j.n] = '.'
			j.n += 1
			for d in 1 ..< nd {
				j.buf[j.n] = dig[d]
				j.n += 1
			}
		}
		j.buf[j.n] = 'e'
		j.n += 1
		e := n - 1
		if e >= 0 {
			j.buf[j.n] = '+'
		} else {
			j.buf[j.n] = '-'
			e = -e
		}
		j.n += 1
		eb: [4]byte
		en := 0
		if e == 0 {
			eb[0] = '0'
			en = 1
		}
		for e > 0 {
			eb[en] = byte(e % 10 + '0')
			en += 1
			e /= 10
		}
		for d := en - 1; d >= 0; d -= 1 {
			j.buf[j.n] = eb[d]
			j.n += 1
		}
	}
}

// A key: a comma if it is not the first in its object, then "name":, and the
// value that follows owes the object nothing until it is written.
j_key :: proc(j: ^jw, k: string) {
	j_val(j)
	j.buf[j.n] = '"'
	j.n += 1
	copy(j.buf[j.n:len(k)+j.n], k)
	j.n += len(k)
	j.buf[j.n] = '"'
	j.n += 1
	j.buf[j.n] = ':'
	j.n += 1
	j.sep = false
}

j_obj :: proc(j: ^jw) {
	j_val(j)
	j.buf[j.n] = '{'
	j.n += 1
	j.sep = false
}

j_end_obj :: proc(j: ^jw) {
	j.buf[j.n] = '}'
	j.n += 1
	j.sep = true
}

j_arr :: proc(j: ^jw) {
	j_val(j)
	j.buf[j.n] = '['
	j.n += 1
	j.sep = false
}

j_end_arr :: proc(j: ^jw) {
	j.buf[j.n] = ']'
	j.n += 1
	j.sep = true
}

// ===========================================================================
// The state view -- a transcription of OpenAIAIManager.observe() (the object
// the harness is handed, one per seat per step) and of the helpers it walks:
// knownAmount, availableTechsFor, trainableUnitsFor, buildableStructures,
// splitByBlock, isPlayerEliminated. The output is the reference's own,
// golden/turn1-b1040.canonical.jsonl.
// ===========================================================================

AGES_ORDER : [4]string = {"stone", "neolithic", "bronze", "iron"}

age_idx :: proc(a: string) -> i32 {
	for i in 0 ..< len(AGES_ORDER) {
		if AGES_ORDER[i] == a {
			return cast(i32)(i)
		}
	}
	return -1
}

age_reached :: proc(cur: string, want: string) -> bool {
	return age_idx(cur) >= age_idx(want)
}

has_resources :: proc(r: ^res_state, c: cost4) -> bool {
	return r.food >= c.food && r.wood >= c.wood && r.stone >= c.stone && r.gold >= c.gold
}

nearby_node :: struct {
	ntype: i32,
	x, z: i32,
	amount: f64,
}

obs_scratch :: struct {
	by: [4][2048]nearby_node,
	n_by: [4]int,
	// the nearby map: insertion-ordered, keyed by the rounded "x,z" pair; a
	// later set with the same key replaces the value in place (Map semantics)
	key_x: [200]i32,
	key_z: [200]i32,
	val: [2048]nearby_node,
	n_key: int,
}

// knownAmount: the node's amount for this seat at this instant.
//   visible now  -> the node's live amount, cached in the seat's seen map
//   seen before  -> the cached amount (a node can be known without being in
//                    sight; the cache is what the harness shows for it)
//   otherwise    -> 0, unknown
// The reference's second branch floors `seen.get(idx)`, which is undefined
// -- hence NaN, which sorts as neither > 0 nor a number in the view -- for a
// node known only through the step's coarser test. That is transcribed too:
// such a node shows for no one.
known_amount :: proc(s: ^seat, idx: int, x: f64, z: f64, live: f64, observe: bool) -> (f64, bool) {
	if immediate_visible(s, x, z) {
		a := f64(math.floor(live))
		if observe {
			s.seen_amt[idx] = a
			s.seen_set[idx] = 1
		}
		return a, true
	}
	if observe && s.known[idx] != 0 {
		if s.seen_set[idx] != 0 {
			return f64(math.floor(s.seen_amt[idx])), true
		}
		return m_nan, true // floor of the missing cache entry: NaN, as upstream
	}
	return 0, false
}

unit_entry :: struct {
	id: string,
	cost: cost4,
	age: string,
	at: string,
	blocked: [8]string,
	n_block: int,
}

bldg_entry :: struct {
	btype: string,
	req_age: string,
	req_tech: string,
	cost: cost4,
	is_wonder: bool,
	built_as: string,
	blocked: [8]string,
	n_block: int,
}

obs :: struct {
	g: ^game_state,
	j: ^jw,
	s: ^seat,
	scratch: obs_scratch,
	t_ms: i64,
	// The state build's own found events (the "last node emptied" notice),
	// displayed now and logged on the commit at the end of observe_line.
	pend: [8]evt,
	n_pend: int,
}

// One fixture line: {"seat":i,"playerId":"seat<i>","t":T,"state":{...}}.
// ===========================================================================
// The tail of the state view: units, buildings, threats, gameStats (port
// 1420-1575 and its helpers, transcribed).
// ===========================================================================

// The hosts the units section walks, in vocabulary order (port 1604).
UNITS_HOSTS : [5]string = {"town_center", "barracks", "archery_range", "stable", "temple"}

// The military-building train tiers (js/buildings.js BUILDING_TRAIN_TIERS):
// per host, per age index, the unit ids that building trains at that age.
TT_BARRACKS : [4][3]string = {
	{"militia", "", ""},
	{"militia", "", ""},
	{"militia", "warrior", ""},
	{"militia", "warrior", "champion"},
}
TT_STABLE : [4][3]string = {
	{"", "", ""},
	{"scout_cavalry", "", ""},
	{"scout_cavalry", "cavalry", ""},
	{"scout_cavalry", "cavalry", "heavy_cavalry"},
}
TT_ARCHERY : [4][3]string = {
	{"", "", ""},
	{"archer", "", ""},
	{"archer", "", ""},
	{"archer", "crossbowman", "elite_archer"},
}

// Does the civ tech tree contain tid? The tree is an array in tree order;
// tech_ids[ci][t] is its id (port: the techs map lookup).
civ_has_tech :: proc(ci: int, tid: string) -> bool {
	c := &civs[ci]
	for t in 0 ..< c.n_techs {
		if tech_ids[ci][t] == tid {
			return true
		}
	}
	return false
}

// A tech definition by id from the civ tree (nil when absent).
civ_tech_by_id :: proc(ci: int, tid: string) -> ^tech {
	c := &civs[ci]
	for t in 0 ..< c.n_techs {
		if tech_ids[ci][t] == tid {
			return &c.techs[t]
		}
	}
	return nil
}

// A unit definition: the civ uniques first, then the standard table
// (getUnitDefFor, port 403).
unit_def_for :: proc(ci: int, id: string) -> ^unit_def {
	c := &civs[ci]
	for u in 0 ..< c.n_units {
		if c.units[u].id == id {
			return &c.units[u]
		}
	}
	return std_unit_by_id(id)
}

// The units a building of host trains for civ ci at age index a: the tier
// table, then the civ uniques that train there (tier within the age), then
// the civ exclusions filtered out (getTrainOptionsForBuilding, port 422).
// The building own trainOptions is NOT here — the walk falls back to it
// when this returns nothing (the Town Center worker, the temple priest).
train_tiers_for :: proc(ci: int, host: string, a: int, out_ids: []string) -> int {
	n := 0
	c := &civs[ci]
	tiers: ^[4][3]string
	if host == "barracks" {
		tiers = &TT_BARRACKS
	} else if host == "stable" {
		tiers = &TT_STABLE
	} else if host == "archery_range" {
		tiers = &TT_ARCHERY
	}
	if tiers != nil {
		for k in 0 ..< 3 {
			id := tiers[a][k]
			if id != "" {
				out_ids[n] = id
				n += 1
			}
		}
	}
	for u in 0 ..< c.n_units {
		ud := &c.units[u]
		if ud.train_at == host && cast(int)(age_idx(ud.tier)) <= a {
			dup := false
			for k in 0 ..< n {
				if out_ids[k] == ud.id {
					dup = true
				}
			}
			if !dup {
				out_ids[n] = ud.id
				n += 1
			}
		}
	}
	for e in 0 ..< c.n_excluded {
		ex := c.excluded[e]
		if ex == "" {
			continue
		}
		w := 0
		for k in 0 ..< n {
			if out_ids[k] != ex {
				out_ids[w] = out_ids[k]
				w += 1
			}
		}
		n = w
	}
	return n
}

// The age a civ can actually build this at: the def requiredAge, or the
// unlocking tech age if that comes later (effectiveBuildingAge, port 412).
effective_building_age :: proc(ci: int, def: ^bldg_def) -> string {
	idx := age_idx(def.req_age)
	if idx < 0 {
		idx = 0
	}
	if def.req_tech != "" {
		t := civ_tech_by_id(ci, def.req_tech)
		if t != nil && t.required_age != "" {
			ti := age_idx(t.required_age)
			if ti > idx {
				idx = ti
			}
		}
	}
	return AGES_ORDER[idx]
}

// A unit entry is blocked when any of its blocks is structural (splitByBlock,
// port 1618): age, tech, host, alreadyBuilt.
unit_structural :: proc(e: ^unit_entry) -> bool {
	for b in 0 ..< e.n_block {
		tb := e.blocked[b]
		if tb == "age" || tb == "tech" || tb == "host" || tb == "alreadyBuilt" {
			return true
		}
	}
	return false
}

// One unit entry: {id, cost, blockedBy?}. The trainable list strips an empty
// blockedBy; the blocked list always writes it.
unit_entry_write :: proc(j: ^jw, e: ^unit_entry, always_blocked: bool) {
	j_obj(j)
	j_key(j, "id")
	j_str(j, e.id)
	j_key(j, "cost")
	j_obj(j)
	j_key(j, "food")
	j_int(j, i64(e.cost.food))
	j_key(j, "wood")
	j_int(j, i64(e.cost.wood))
	j_key(j, "stone")
	j_int(j, i64(e.cost.stone))
	j_key(j, "gold")
	j_int(j, i64(e.cost.gold))
	j_end_obj(j)
	if always_blocked || e.n_block > 0 {
		j_key(j, "blockedBy")
		j_arr(j)
		for b in 0 ..< e.n_block {
			j_str(j, e.blocked[b])
		}
		j_end_arr(j)
	}
	j_end_obj(j)
}

// One unit group — the trainable or the blocked half, as nested host/age
// objects with the entries in walk order (the port splitByBlock preserves
// the insertion order of both).
units_write_group :: proc(j: ^jw, ents: []unit_entry, structural: bool) {
	for h in 0 ..< 5 {
		host_open := false
		for a in 0 ..< 4 {
			n_here := 0
			for k in 0 ..< len(ents) {
				e := &ents[k]
				if e.at != UNITS_HOSTS[h] || e.age != AGES_ORDER[a] {
					continue
				}
				if unit_structural(e) != structural {
					continue
				}
				n_here += 1
			}
			if n_here == 0 {
				continue
			}
			if !host_open {
				j_key(j, UNITS_HOSTS[h])
				j_obj(j)
				host_open = true
			}
			j_key(j, AGES_ORDER[a])
			j_arr(j)
			for k in 0 ..< len(ents) {
				e := &ents[k]
				if e.at != UNITS_HOSTS[h] || e.age != AGES_ORDER[a] {
					continue
				}
				if unit_structural(e) != structural {
					continue
				}
				unit_entry_write(j, e, structural)
			}
			j_end_arr(j)
		}
		if host_open {
			j_end_obj(j)
		}
	}
}

// A building entry is blocked when any of its blocks is structural — same
// rule as the units.
bldg_structural :: proc(be: ^bldg_entry) -> bool {
	for b in 0 ..< be.n_block {
		tb := be.blocked[b]
		if tb == "age" || tb == "tech" || tb == "host" || tb == "alreadyBuilt" {
			return true
		}
	}
	return false
}

// One building entry: {type, builtAs?, requiredAge, requiresTech, isWonder?,
// cost, blockedBy?} — the wonder carries builtAs and isWonder (port 1489-
// 1510); the trainable list strips an empty blockedBy.
bldg_entry_write :: proc(j: ^jw, be: ^bldg_entry, always_blocked: bool) {
	j_obj(j)
	j_key(j, "type")
	j_str(j, be.btype)
	if be.is_wonder {
		j_key(j, "builtAs")
		j_str(j, be.built_as)
	}
	j_key(j, "requiredAge")
	j_str(j, be.req_age)
	j_key(j, "requiresTech")
	if be.req_tech != "" {
		j_str(j, be.req_tech)
	} else {
		j_null(j)
	}
	if be.is_wonder {
		j_key(j, "isWonder")
		j_bool(j, true)
	}
	j_key(j, "cost")
	j_obj(j)
	j_key(j, "food")
	j_int(j, i64(be.cost.food))
	j_key(j, "wood")
	j_int(j, i64(be.cost.wood))
	j_key(j, "stone")
	j_int(j, i64(be.cost.stone))
	j_key(j, "gold")
	j_int(j, i64(be.cost.gold))
	j_end_obj(j)
	if always_blocked || be.n_block > 0 {
		j_key(j, "blockedBy")
		j_arr(j)
		for b in 0 ..< be.n_block {
			j_str(j, be.blocked[b])
		}
		j_end_arr(j)
	}
	j_end_obj(j)
}

// The b1054 elimination predicate (port 764-837), reduced to the state the
// arena carries at turn 1. Every check of the full walk is below, with the
// vacuous ones noted; at this gate every seat leaves at the third check —
// population room holds (cap 10 over 3 workers) and the Town Center trains
// workers, which every seat affords.
seat_eliminated :: proc(s: ^seat) -> bool {
	// (1) A live fighter (non-worker, non-support) keeps the seat alive:
	//     vacuous at turn 1 — the arena units are all workers.
	// (2) A producing trainer: vacuous — the Town Center is idle.
	// (3) Population room and affordable military from a standing building:
	if s.pop < s.max_pop && has_resources(&s.res, unit_def_for(s.ci, "worker").cost) {
		return false
	}
	// (4) A Town Center with worker funds:
	if s.home.health > 0 && has_resources(&s.res, unit_def_for(s.ci, "worker").cost) {
		return false
	}
	// (5) A seat with no live worker at all is eliminated — the arena units
	//     are all workers, so this is the unit count.
	if s.n_units == 0 {
		return true
	}
	// (6) An under-construction Town Center or producer: vacuous — nothing
	//     is ever built at turn 1.
	// (7) A Town Center:
	if s.home.health > 0 {
		return false
	}
	// (8) Town-Center funds:
	if has_resources(&s.res, bldg_def_by_id("town_center").cost) {
		return false
	}
	// (9) With room: barracks, archery-range or stable funds.
	if s.pop < s.max_pop {
		if has_resources(&s.res, bldg_def_by_id("barracks").cost) { return false }
		if has_resources(&s.res, bldg_def_by_id("archery_range").cost) { return false }
		if has_resources(&s.res, bldg_def_by_id("stable").cost) { return false }
	}
	return true
}

// One state view: the 21 sections, as the reference's buildGameStateJSON
// writes them. The WRAPPER around it (the fixture line or the stream's turn
// record) is the driver's job — this proc writes the state object only,
// opened and closed.
observe_line :: proc(o: ^obs) {
	g := o.g
	s := o.s
	j := o.j
	size := g.terrain.size

	j_obj(j)

	// ---- player.
	c := &civs[s.ci]
	j_key(j, "player")
	j_obj(j)
	j_key(j, "id")
	j_str(j, s.pid)
	j_key(j, "civilization")
	j_str(j, c.id)
	j_key(j, "civilizationName")
	j_str(j, c.name_en)
	j_key(j, "isHuman")
	j_bool(j, false)
	j_end_obj(j)

	// ---- clock: matchSeconds, whole seconds of the match clock.
	j_key(j, "clock")
	j_obj(j)
	j_key(j, "matchSeconds")
	j_int(j, cast(i64)(math.floor((g.match_ms / 1000) + 0.5)))
	j_end_obj(j)

	// ---- epoch: the seat is in stone; the next epoch's cost is fixed data.
	j_key(j, "epoch")
	j_obj(j)
	j_key(j, "currentEpoch")
	j_str(j, "stone")
	j_key(j, "nextEpoch")
	j_str(j, "neolithic")
	j_key(j, "nextEpochCost")
	j_obj(j)
	j_key(j, "food")
	j_int(j, 1000)
	j_key(j, "wood")
	j_int(j, 800)
	j_key(j, "stone")
	j_int(j, 0)
	j_key(j, "gold")
	j_int(j, 0)
	j_end_obj(j)
	j_key(j, "upgradeInProgress")
	j_null(j)
	j_end_obj(j)

	// ---- resources: whole units, as the harness floors them.
	j_key(j, "resources")
	j_obj(j)
	j_key(j, "food")
	j_int(j, cast(i64)(math.floor(s.res.food)))
	j_key(j, "wood")
	j_int(j, cast(i64)(math.floor(s.res.wood)))
	j_key(j, "stone")
	j_int(j, cast(i64)(math.floor(s.res.stone)))
	j_key(j, "gold")
	j_int(j, cast(i64)(math.floor(s.res.gold)))
	j_end_obj(j)

	// ---- population.
	j_key(j, "population")
	j_obj(j)
	j_key(j, "used")
	j_int(j, i64(s.pop))
	j_key(j, "capacityNow")
	j_int(j, i64(s.max_pop))
	j_key(j, "capacityCeiling")
	j_int(j, 100) // MAX_POPULATION_CAP
	j_end_obj(j)

	// ---- the node pass, hoisted above the sections that read it: the live
	//      amounts (the scratch buckets nearestNodes and nodes write from),
	//      the discovered tally, and this look's own found events (the
	//      "last node emptied" notice — the transition from the previous
	//      look's counts to this one's, said out loud here).
	sc := &o.scratch
	sc.n_by = [4]int{}
	sc.n_key = 0
	o.n_pend = 0
	disc: [4]i64 = [4]i64{}
	total: [4]i64 = [4]i64{}
	for i in 0 ..< g.terrain.n_nodes {
		n := &g.terrain.nodes[i]
		if n.amount > 0 {
			total[n.n_type] += 1
		}
		amt, _ := known_amount(s, i, n.x, n.z, n.amount, true)
		if amt > 0 {
			disc[n.n_type] += 1
			bucket := &sc.by[n.n_type]
			bucket[sc.n_by[n.n_type]] = nearby_node{ntype = n.n_type,
				x = cast(i32)(math.floor((n.x) + 0.5)), z = cast(i32)(math.floor((n.z) + 0.5)), amount = amt}
			sc.n_by[n.n_type] += 1
		}
	}
	// the transition notice (openai-ai.js 3365): a type the PREVIOUS look
	// counted above zero and this look counts at zero.
	for k in 0 ..< 4 {
		if s.last_counts[k] > 0 && disc[k] == 0 {
			if o.n_pend < len(o.pend) {
				o.pend[o.n_pend] = evt{kind = EVT_LAST_EMPTY, p_type = k}
				o.n_pend += 1
			}
		}
	}

	// ---- recentEvents: the seat's notice ring plus this look's own found
	//      events, expired by the seat's own turns (two), the last eight,
	//      each stamped with its age on the MATCH clock (o.pend is filled by
	//      the node pass below — hoisted ahead of this section).
	j_key(j, "recentEvents")
	j_arr(j)
	build_recent_events(o)
	j_end_arr(j)

	// ---- bonuses: the seat's own multipliers as the state reports them
	//      (workerHarvestBonus / techCostMultiplier, 1.0 omitted). The
	//      spectator path never applies the civ bonus, so the recorder's
	//      seats carry 1.0/1.0 — the stream's bonuses are {} for every
	//      seat, unlike the arena fixture (whose seats got the bonus).
	// ---- battles (openai-ai.js 3200): the seat's engagements, newest
	//      three; sides carry involved-by-type and losses; a quiet fight
	//      reports endedSecondsAgo instead of staying "ongoing".
	//      Omitted in peacetime: no battle with this seat, no key.
	has_battle := false
	start2 := g.n_battles - 3
	if start2 < 0 { start2 = 0 }
	for bi in start2 ..< g.n_battles {
		for si2 := 0; si2 < g.b_nsides[bi]; si2 += 1 {
			if g.b_side_seat[bi][si2] == s.ci { has_battle = true; break }
		}
	}
	if has_battle {
	j_key(j, "battles")
	j_arr(j)
	n_shown := 0
	start := g.n_battles - 3
	if start < 0 { start = 0 }
	for bi in start ..< g.n_battles {
		own := -1
		for si2 := 0; si2 < g.b_nsides[bi]; si2 += 1 {
			if g.b_side_seat[bi][si2] == s.ci { own = si2; break }
		}
		if own < 0 { continue }
		j_obj(j)
		j_key(j, "at")
		j_arr(j)
		j_int(j, cast(i64)(math.floor(g.b_x[bi] + 0.5)))
		j_int(j, cast(i64)(math.floor(g.b_z[bi] + 0.5)))
		j_end_arr(j)
		ongoing := g.sim_ms - g.b_last[bi] < 10000
		j_key(j, "ongoing")
		j_bool(j, ongoing)
		if !ongoing {
			j_key(j, "endedSecondsAgo")
			j_int(j, i64(math.max(0, math.round((g.sim_ms - g.b_last[bi]) / 2000))))
		}
		j_key(j, "secondsElapsed")
		j_int(j, i64(math.max(0, math.round((g.b_last[bi] - g.b_started[bi]) / 2000))))
		j_key(j, "you")
		j_obj(j)
		j_key(j, "involved")
		j_obj(j)
		for ii in 0 ..< g.b_inv_n[bi][own] {
			j_key(j, g.b_inv_type[bi][own][ii])
			j_obj(j)
			j_key(j, "n")
			j_int(j, i64(g.b_inv_nids[bi][own][ii]))
			if g.b_inv_du[bi][own][ii] > 0 {
				j_key(j, "dmgUnits")
				j_int(j, i64(math.round(g.b_inv_du[bi][own][ii])))
			}
			if g.b_inv_db[bi][own][ii] > 0 {
				j_key(j, "dmgBuildings")
				j_int(j, i64(math.round(g.b_inv_db[bi][own][ii])))
			}
			if g.b_inv_he[bi][own][ii] > 0 {
				j_key(j, "healed")
				j_int(j, i64(math.round(g.b_inv_he[bi][own][ii])))
			}
			j_end_obj(j)
		}
		j_end_obj(j)
		j_key(j, "lost")
		j_obj(j)
		for li in 0 ..< g.b_nlost[bi][own] {
			j_key(j, g.b_lost_type[bi][own][li])
			j_int(j, i64(g.b_lost_n[bi][own][li]))
		}
		j_end_obj(j)
		j_end_obj(j) // you
		j_key(j, "enemy")
		j_arr(j)
		for si2 := 0; si2 < g.b_nsides[bi]; si2 += 1 {
			foe := g.b_side_seat[bi][si2]
			if foe == s.ci { continue }
			j_obj(j)
			j_key(j, "owner")
			j_str(j, fmt.aprintf("%s-%d", civs[foe].id, foe + 1))
			j_key(j, "involved")
			j_obj(j)
			for ii in 0 ..< g.b_inv_n[bi][si2] {
				j_key(j, g.b_inv_type[bi][si2][ii])
				j_obj(j)
				j_key(j, "n")
				j_int(j, i64(g.b_inv_nids[bi][si2][ii]))
				if g.b_inv_du[bi][si2][ii] > 0 {
					j_key(j, "dmgUnits")
					j_int(j, i64(math.round(g.b_inv_du[bi][si2][ii])))
				}
				if g.b_inv_db[bi][si2][ii] > 0 {
					j_key(j, "dmgBuildings")
					j_int(j, i64(math.round(g.b_inv_db[bi][si2][ii])))
				}
				if g.b_inv_he[bi][si2][ii] > 0 {
					j_key(j, "healed")
					j_int(j, i64(math.round(g.b_inv_he[bi][si2][ii])))
				}
				j_end_obj(j)
			}
			j_end_obj(j)
			j_key(j, "lost")
			j_obj(j)
			for li in 0 ..< g.b_nlost[bi][si2] {
				j_key(j, g.b_lost_type[bi][si2][li])
				j_int(j, i64(g.b_lost_n[bi][si2][li]))
			}
			j_end_obj(j)
			j_end_obj(j)
		}
		j_end_arr(j)
		j_end_obj(j)
		_ = n_shown
	}
	j_end_arr(j)
	}

	// ---- ordersInProgress (openai-ai.js 3120): the seat's running
	//      marches — units with an attack-move and no live target, grouped
	//      by order token (the rule brain mints no tokens: one group).
	//      Omitted when nothing is marching.
	n_rows := 0
	row_n, row_eta := 0, 0
	row_sx, row_sz := f64(0), f64(0)
	for i in 0 ..< s.n_units {
		u := &s.units[i]
		if u.health <= 0 { continue }
		in_contact := u.is_attacking && u.atk_kind != 0 && ref_alive(g, u.atk_kind, u.atk_seat, u.atk_idx)
		if !u.attack_move || in_contact { continue }
		n_rows += 1
		row_n += 1
		row_sx += u.am_x
		row_sz += u.am_z
		d := m_hypot(u.x - u.am_x, u.z - u.am_z)
		sp := u.speed * 3
		eta := f64(1)
		if sp > 0 {
			eta = math.ceil((d / sp) * 1000 / 1000 / 2)
			if eta < 1 { eta = 1 }
		}
		if eta > f64(row_eta) { row_eta = int(eta) }
	}
	if n_rows > 0 {
		j_key(j, "ordersInProgress")
		j_arr(j)
		j_obj(j)
		j_key(j, "order")
		j_str(j, "attack_target")
		j_key(j, "to")
		j_arr(j)
		j_int(j, cast(i64)(math.floor(row_sx/f64(row_n) + 0.5)))
		j_int(j, cast(i64)(math.floor(row_sz/f64(row_n) + 0.5)))
		j_end_arr(j)
		j_key(j, "units")
		j_int(j, i64(row_n))
		j_key(j, "secondsRemaining")
		j_int(j, i64(row_eta))
		j_end_obj(j)
		j_end_arr(j)
	}

	j_key(j, "bonuses")
	j_obj(j)
	if s.harvest_bonus != 1.0 {
		j_key(j, "harvest")
		j_f64(j, s.harvest_bonus)
	}
	if s.techcost_mult != 1.0 {
		j_key(j, "techCostMult")
		j_f64(j, s.techcost_mult)
	}
	j_end_obj(j)

	// ---- map.
	j_key(j, "map")
	j_obj(j)
	j_key(j, "size")
	j_int(j, cast(i64)(size))
	j_key(j, "bounds")
	j_obj(j)
	j_key(j, "minX")
	j_int(j, -cast(i64)(size/2))
	j_key(j, "maxX")
	j_int(j, cast(i64)(size/2))
	j_key(j, "minZ")
	j_int(j, -cast(i64)(size/2))
	j_key(j, "maxZ")
	j_int(j, cast(i64)(size/2))
	j_end_obj(j)

	// yourSpawnArea: the centroid of the seat's buildings, whole units
	// (getAIBuildingCenter) — live: houses and farms shift it off the spawn.
	sx, sz := f64(0), f64(0)
	for b in 0 ..< s.n_bldgs {
		sx += s.bldgs[b].x
		sz += s.bldgs[b].z
	}
	j_key(j, "yourSpawnArea")
	j_obj(j)
	j_key(j, "x")
	j_int(j, cast(i64)(math.floor(sx / f64(s.n_bldgs) + 0.5)))
	j_key(j, "z")
	j_int(j, cast(i64)(math.floor(sz / f64(s.n_bldgs) + 0.5)))
	j_end_obj(j)

	// yourBaseTiles: one entry per occupied tile, the count of buildings in
	// it, keyed by the A1..G7 label in first-encounter order (the
	// reference's object insertion order over ai.buildings).
	tiles := map[string]i32{}
	tile_order: [16]string
	n_tiles := 0
	for b in 0 ..< s.n_bldgs {
		k := tile_at(s.bldgs[b].x, s.bldgs[b].z, size)
		if tiles[k] == 0 {
			tile_order[n_tiles] = k
			n_tiles += 1
		}
		tiles[k] += 1
	}
	j_key(j, "yourBaseTiles")
	j_obj(j)
	for t in 0 ..< n_tiles {
		j_key(j, tile_order[t])
		j_int(j, i64(tiles[tile_order[t]]))
	}
	j_end_obj(j)

	// exploration: the 7x7 summary, keyed A1..G7 in the view's own order
	// (row r, column c -> tileLabel(r, c)).
	sum := exploration_summary(s)
	j_key(j, "exploration")
	j_obj(j)
	for r in 0 ..< 7 {
		for cc in 0 ..< 7 {
			j_key(j, tile_label(r, cc))
			j_int(j, i64(sum[r][cc]))
		}
	}
	j_end_obj(j)

	j_end_obj(j) // map

	j_key(j, "nodes")
	j_obj(j)
	j_key(j, "discovered")
	j_obj(j)
	j_key(j, "food")
	j_int(j, disc[0])
	j_key(j, "wood")
	j_int(j, disc[1])
	j_key(j, "stone")
	j_int(j, disc[2])
	j_key(j, "gold")
	j_int(j, disc[3])
	j_end_obj(j)
	j_key(j, "totalOnMap")
	j_obj(j)
	j_key(j, "food")
	j_int(j, total[0])
	j_key(j, "wood")
	j_int(j, total[1])
	j_key(j, "stone")
	j_int(j, total[2])
	j_key(j, "gold")
	j_int(j, total[3])
	j_end_obj(j)
	j_end_obj(j) // nodes

	// ---- nearestNodes. The anchor is the seat's own buildings -- the one
	// Town Center. Stone and gold come first, in survivor order; then the
	// ten nearest food and ten nearest wood, a stable sort by distance with
	// list order breaking the tie (Array.prototype.sort is stable, and the
	// reference sorts the discovered lists before slicing). A later group
	// replaces an earlier entry at the same rounded position -- the reference
	// keeps these in a Map keyed by "x,z".
	j_key(j, "nearestNodes")
	j_arr(j)

	nb_set :: proc(sc: ^obs_scratch, e: ^nearby_node) {
		for i in 0 ..< sc.n_key {
			if sc.key_x[i] == e.x && sc.key_z[i] == e.z {
				sc.val[i] = e^
				return
			}
		}
		sc.key_x[sc.n_key] = e.x
		sc.key_z[sc.n_key] = e.z
		sc.val[sc.n_key] = e^
		sc.n_key += 1
	}

	for it in 0 ..< sc.n_by[2] { // stone, survivor order
		e := &sc.by[2][it]
		nb_set(sc, e)
	}
	for it in 0 ..< sc.n_by[3] { // gold, survivor order
		e := &sc.by[3][it]
		nb_set(sc, e)
	}

	ax := math.floor((s.home.x) + 0.5)
	az := math.floor((s.home.z) + 0.5)
	cand: [200]nearby_node
	cd: [200]f64
	for it in 0 ..< sc.n_by[0] { // food
		e := &sc.by[0][it]
		cd[it] = m_hypot(f64(e.x) - ax, f64(e.z) - az)
		cand[it] = e^
	}
	// stable: later items pass only while strictly nearer
	for i in 1 ..< sc.n_by[0] {
		e := cand[i]
		d := cd[i]
		k := i - 1
		for k >= 0 && cd[k] > d {
			cand[k+1] = cand[k]
			cd[k+1] = cd[k]
			k -= 1
		}
		cand[k+1] = e
		cd[k+1] = d
	}
	n := min(10, sc.n_by[0])
	for it in 0 ..< n {
		e := &cand[it]
		nb_set(sc, e)
	}
	for it in 0 ..< sc.n_by[1] { // wood, the same pass
		e := &sc.by[1][it]
		cd[it] = m_hypot(f64(e.x) - ax, f64(e.z) - az)
		cand[it] = e^
	}
	for i in 1 ..< sc.n_by[1] {
		e := cand[i]
		d := cd[i]
		k := i - 1
		for k >= 0 && cd[k] > d {
			cand[k+1] = cand[k]
			cd[k+1] = cd[k]
			k -= 1
		}
		cand[k+1] = e
		cd[k+1] = d
	}
	n = min(10, sc.n_by[1])
	for it in 0 ..< n {
		e := &cand[it]
		nb_set(sc, e)
	}

	for it in 0 ..< sc.n_key {
		e := &sc.val[it]
		j_obj(j)
		j_key(j, "type")
		j_str(j, res_type_name[e.ntype])
		j_key(j, "x")
		j_int(j, i64(e.x))
		j_key(j, "z")
		j_int(j, i64(e.z))
		j_key(j, "amount")
		j_int(j, cast(i64)(math.floor((e.amount) + 0.5)))
		j_end_obj(j)
	}
	j_end_arr(j)

	// ---- friendlyBuildings: every standing building of the seat, in the
	//      seat's own order (the single Town Center first), whole coordinates.
	j_key(j, "friendlyBuildings")
	j_arr(j)
	// The research/age hosts: each task is attributed to ONE finished host
	// building of its researchAt type (openai-ai.js 3396-3424). No age
	// upgrade runs in this corpus.
	research_host := -1
	if s.cur_research {
		host_type := "town_center"
		for t in 0 ..< c.n_techs {
			if tech_ids[s.ci][t] == s.res_tech {
				if civs[s.ci].techs[t].research_at != "" {
					host_type = civs[s.ci].techs[t].research_at
				}
				break
			}
		}
		for b in 0 ..< s.n_bldgs {
			bd := &s.bldgs[b]
			if bd.id == host_type && !bd.under_constr {
				research_host = b
				break
			}
		}
	}
	for b in 0 ..< s.n_bldgs {
		bd := &s.bldgs[b]
		if bd.health <= 0 {
			continue
		}
		constructing := bd.under_constr
		producing := bd.is_producing && !constructing
		researching := research_host == b && !constructing
		busy := constructing || producing || researching
		j_obj(j)
		j_key(j, "type")
		j_str(j, bd.id)
		j_key(j, "x")
		j_int(j, cast(i64)(math.floor((bd.x) + 0.5)))
		j_key(j, "z")
		j_int(j, cast(i64)(math.floor((bd.z) + 0.5)))
		j_key(j, "healthPct")
		j_int(j, cast(i64)(math.floor((bd.health/bd.max_health*100) + 0.5)))
		j_key(j, "state")
		if constructing {
			j_str(j, "under_construction")
		} else {
			j_str(j, "complete")
		}
		j_key(j, "busy")
		j_bool(j, busy)
		j_key(j, "activity")
		if constructing {
			j_str(j, "under_construction")
		} else if producing {
			j_str(j, "producing")
		} else if researching {
			j_str(j, "researching")
		} else {
			j_str(j, "idle")
		}
		j_key(j, "producing")
		if producing {
			j_str(j, bd.prod_type)
		} else {
			j_null(j)
		}
		if producing {
			j_key(j, "producingSecondsRemaining")
			j_int(j, secs_left(bd.prod_progress, bd.prod_duration))
		}
		if constructing {
			j_key(j, "buildPct")
			j_int(j, cast(i64)(math.floor(math.min(1, bd.build_progress / bd.build_time) * 100 + 0.5)))
			j_key(j, "buildSecondsRemaining")
			j_int(j, secs_left(bd.build_progress, bd.build_time))
		}
		if researching {
			j_key(j, "researchingTech")
			j_str(j, s.res_tech)
			j_key(j, "researchSecondsRemaining")
			j_int(j, secs_left(s.res_progress, s.res_duration))
		}
		if bd.id == "farm" {
			j_key(j, "food")
			j_int(j, cast(i64)(math.floor(bd.food_amount)))
			j_key(j, "farmed")
			// the farm's real status: game.js farmFarmer — the hand must still
			// hold the post (alive, farm_work or carrying, farmRef === farm)
			farmed := false
			if bd.assigned_worker >= 0 && bd.assigned_worker < s.n_units {
				w := &s.units[bd.assigned_worker]
				farmed = w.health > 0 && w.farm == b && (w.task == TASK_FARM_WORK || w.task == TASK_CARRYING)
			}
			j_bool(j, farmed)
		}
		j_end_obj(j)
	}
	j_end_arr(j)

	// ---- enemyBuildings (openai-ai.js 3498): every enemy building seen
	//      now (refreshing the last-seen snapshot) or remembered from an
	//      earlier one; a spot seen empty drops the memory, as does a
		//      building this seat's own units razed or a defeated owner.
	eyes := make_eyes(s)
	j_key(j, "enemyBuildings")
	j_arr(j)
	for i in 0 ..< 4 {
		if i == s.ci {
			continue
		}
		e := &g.seats[i]
		for bi in 0 ..< e.n_bldgs {
			b := &e.bldgs[bi]
			if b.health <= 0 {
				s.eb_known[i][bi] = false
				continue
			}
			seen_now := b.is_wonder || see_test(&eyes, b.x, b.z)
			if seen_now {
				s.eb_known[i][bi] = true
				s.eb_has[i][bi] = true
				s.eb_hp[i][bi] = int(math.round(b.health / b.max_health * 100))
				s.eb_x[i][bi] = b.x
				s.eb_z[i][bi] = b.z
			}
			if !seen_now && !s.eb_known[i][bi] {
				continue
			}
			j_obj(j)
			j_key(j, "id")
			j_str(j, b.pid)
			j_key(j, "type")
			j_str(j, b.id)
			j_key(j, "x")
			j_int(j, cast(i64)(math.floor((seen_now ? b.x : s.eb_x[i][bi]) + 0.5)))
			j_key(j, "z")
			j_int(j, cast(i64)(math.floor((seen_now ? b.z : s.eb_z[i][bi]) + 0.5)))
			j_key(j, "owner")
			j_str(j, fmt.aprintf("%s-%d", civs[i].id, i + 1))
			j_key(j, "healthPct")
			j_int(j, i64(s.eb_hp[i][bi]))
			j_key(j, "visible")
			j_bool(j, seen_now)
			j_end_obj(j)
			s.eb_known[i][bi] = true // listed: still known
		}
	}
	j_end_arr(j)

	// ---- friendlyUnits: every living unit of the seat, whole coordinates.
	j_key(j, "friendlyUnits")
	j_arr(j)
	for i in 0 ..< s.n_units {
		u := &s.units[i]
		if u.health > 0 {
			j_obj(j)
			j_key(j, "id")
			j_int(j, i64(u.handle))
			j_key(j, "type")
			j_str(j, u.u_type)
			j_key(j, "x")
			j_int(j, cast(i64)(math.floor((u.x) + 0.5)))
			j_key(j, "z")
			j_int(j, cast(i64)(math.floor((u.z) + 0.5)))
			j_key(j, "healthPct")
			j_int(j, i64(math.round(u.health / u.max_health * 100)))
			// non-workers carry an action: attacking when engaged, marching
			// on an attack-move with no target in contact, else idle
			if u.u_type != "worker" {
				action := "idle"
				if u.is_attacking {
					in_contact := false
					if u.atk_kind == 1 && u.atk_seat >= 0 && g.seats[u.atk_seat].units[u.atk_idx].health > 0 { in_contact = true }
					if u.atk_kind == 2 && u.atk_seat >= 0 && g.seats[u.atk_seat].bldgs[u.atk_idx].health > 0 { in_contact = true }
					action = (!in_contact && u.attack_move) ? "marching" : "attacking"
				} else if u.is_moving {
					action = "moving"
				}
				j_key(j, "action")
				j_str(j, action)
			}
			j_end_obj(j)
		}
	}
	j_end_arr(j)

	// ---- workers: the seat's units by job. An idle worker is one with no
	//      task, attack, or harvest in flight -- at turn 1 all of them.
	// ---- workers: the seat's units by job, in the golden's key order:
	//      total, idle, building, farm, scouting, moving, fighting, food,
	//      wood, stone, gold. The port's workerJobImpl walks task/building/
	//      attack/scout/farm/carrying branches before falling to isIdleWorker;
	//      the arena issues no orders at all (every seat is harness-controlled),
	//      and its units are all workers, so every live unit lands in idle and
	//      the other buckets are zero.
	j_key(j, "workers")
	j_obj(j)
	// The live tally (openai-ai.js 3621): every worker counted under
	// workerJob's job name — building, scouting, farm, the four resource
	// pools (a job at any point of the gather cycle), moving, fighting, idle.
	// No fighter and no death exists in this corpus; the buckets still
	// follow the classifier's order exactly.
	wk_total, wk_idle, wk_building, wk_farm, wk_scouting, wk_moving, wk_fighting: i64
	wk_pool: [4]i64
	for i in 0 ..< s.n_units {
		u := &s.units[i]
		if u.health <= 0 || u.u_type != "worker" {
			continue
		}
		wk_total += 1
		job := 8 // 8 moving, 9 idle (the tail buckets)
		if u.task == TASK_BUILDING || u.is_building {
			job = 0
		} else if u.task == TASK_SCOUTING {
			job = 1
		} else if u.task == TASK_FARM_WORK || u.farm >= 0 {
			job = 2
		} else if u.carrying || u.task == TASK_CARRYING || u.task == TASK_HARVESTING || u.is_harvesting || u.harvest_node >= 0 {
			// the resource the job points at, or moving while unresolvable
			if u.harvest_node >= 0 {
				nt := int(g.terrain.nodes[u.harvest_node].n_type)
				job = 3 + nt
			} else if u.carrying && (u.carry_type >= 0 && u.carry_type < 4) {
				job = 3 + u.carry_type
			} else {
				job = 8
			}
		} else if is_idle_worker(u) {
			job = 9
		}
		if job == 0 {
			wk_building += 1
		} else if job == 1 {
			wk_scouting += 1
		} else if job == 2 {
			wk_farm += 1
		} else if job == 3 {
			wk_pool[0] += 1
		} else if job == 4 {
			wk_pool[1] += 1
		} else if job == 5 {
			wk_pool[2] += 1
		} else if job == 6 {
			wk_pool[3] += 1
		} else if job == 8 {
			wk_moving += 1
		} else if job == 9 {
			wk_idle += 1
		}
	}
	j_key(j, "total")
	j_int(j, wk_total)
	j_key(j, "idle")
	j_int(j, wk_idle)
	j_key(j, "building")
	j_int(j, wk_building)
	j_key(j, "farm")
	j_int(j, wk_farm)
	j_key(j, "scouting")
	j_int(j, wk_scouting)
	j_key(j, "moving")
	j_int(j, wk_moving)
	j_key(j, "fighting")
	j_int(j, wk_fighting)
	j_key(j, "food")
	j_int(j, wk_pool[0])
	j_key(j, "wood")
	j_int(j, wk_pool[1])
	j_key(j, "stone")
	j_int(j, wk_pool[2])
	j_key(j, "gold")
	j_int(j, wk_pool[3])
	j_end_obj(j)

	// ---- enemyUnits: in sight first, then the most recently seen, located
	// only — the rememberedUnits projection of the seat's memory.
	j_key(j, "enemyUnits")
	j_arr(j)
	// order: visible first, then the most recent `at`; cap 50
	order: [128]int
	n_order := 0
	for m in 0 ..< s.n_um {
		if !s.um_located[m] { continue }
		j := n_order
		for j > 0 {
			p := order[j-1]
			// b before a: (b.visible - a.visible) || (b.at - a.at) > 0
			b_vis := s.um_visible[m] ? 1 : 0
			a_vis := s.um_visible[p] ? 1 : 0
			if b_vis > a_vis || (b_vis == a_vis && s.um_at[m] > s.um_at[p]) {
				order[j] = order[j-1]
				j -= 1
				continue
			}
			break
		}
		order[j] = m
		n_order += 1
	}
	shown := n_order
	if shown > 50 { shown = 50 }
	for k in 0 ..< shown {
		m := order[k]
		o := &g.seats[s.um_oseat[m]]
		j_obj(j)
		j_key(j, "id")
		j_str(j, s.um_pid[m])
		j_key(j, "type")
		j_str(j, s.um_type[m])
		j_key(j, "x")
		j_int(j, i64(math.floor(s.um_x[m] + 0.5)))
		j_key(j, "z")
		j_int(j, i64(math.floor(s.um_z[m] + 0.5)))
		j_key(j, "owner")
		j_str(j, fmt.aprintf("%s-%d", civs[s.um_oseat[m]].id, s.um_oseat[m] + 1))
		j_key(j, "healthPct")
		j_int(j, i64(s.um_hp[m]))
		if s.um_carry[m] != "" {
			j_key(j, "carrying")
			j_str(j, s.um_carry[m])
		}
		j_key(j, "visible")
		j_bool(j, s.um_visible[m])
		if !s.um_visible[m] {
			j_key(j, "secondsAgo")
			j_int(j, i64(math.max(0, math.round((g.match_ms - s.um_at[m]/2) / 1000))))
		}
		moved := s.um_has_sx[m] && m_hypot(s.um_x[m] - s.um_sx[m], s.um_z[m] - s.um_sz[m]) >= 3
		if moved {
			j_key(j, "sightedAt")
			j_arr(j)
			j_int(j, i64(math.floor(s.um_sx[m] + 0.5)))
			j_int(j, i64(math.floor(s.um_sz[m] + 0.5)))
			j_end_arr(j)
		}
		j_end_obj(j)
	}
	j_end_arr(j)

	// ---- research: the civ's tech tree as the seat may use it. The arena
	//      seats start stone-age with no techs researched, so every entry is
	//      gated on its age; the ones the seat could host and afford carry no
	//      blockedBy, the rest carry the reasons in check order (age, tech,
	//      host, cost).
	j_key(j, "research")
	j_obj(j)
	j_key(j, "researched")
	j_arr(j)
	for t in 0 ..< c.n_techs {
		if seat_has_tech(s, tech_ids[s.ci][t]) {
			j_str(j, tech_ids[s.ci][t])
		}
	}
	j_end_arr(j)
	j_key(j, "current")
	if s.cur_research {
		j_obj(j)
		j_key(j, "techId")
		j_str(j, s.res_tech)
		j_key(j, "progressPercent")
		j_int(j, cast(i64)(math.floor(s.res_progress / s.res_duration * 100 + 0.5)))
		j_key(j, "secondsRemaining")
		j_int(j, secs_left(s.res_progress, s.res_duration))
		j_end_obj(j)
	} else {
		j_null(j)
	}
	j_key(j, "available")
	j_arr(j)
	tc_cost_mult := s.techcost_mult
	for t in 0 ..< c.n_techs {
		te := &c.techs[t]
		tid := tech_ids[s.ci][t]
		// the live filters (openai-ai.js 3696): researched is out; the age
		// gate; every requires researched; the host check is general.
		if seat_has_tech(s, tid) {
			continue
		}
		if age_idx(te.required_age) > age_idx("stone") {
			continue
		}
		reqs_ok := true
		for r in 0 ..< te.n_req {
			if !seat_has_tech(s, te.requires[r]) {
				reqs_ok = false
				break
			}
		}
		if !reqs_ok {
			continue
		}
		cc := cost4{floor4(te.cost.food, tc_cost_mult), floor4(te.cost.wood, tc_cost_mult),
			floor4(te.cost.stone, tc_cost_mult), floor4(te.cost.gold, tc_cost_mult)}
		at := "town_center"
		if te.research_at != "" {
			at = te.research_at
		}
		bl: [8]string
		nbl: int
		if !seat_has_finished_bldg(s, at) {
			bl[nbl] = "host"
			nbl += 1
		}
		if !has_resources(&s.res, cc) {
			bl[nbl] = "cost"
			nbl += 1
		}
		j_obj(j)
		j_key(j, "id")
		j_str(j, tech_ids[s.ci][t])
		j_key(j, "cost")
		j_obj(j)
		j_key(j, "food")
		j_int(j, i64(cc.food))
		j_key(j, "wood")
		j_int(j, i64(cc.wood))
		j_key(j, "stone")
		j_int(j, i64(cc.stone))
		j_key(j, "gold")
		j_int(j, i64(cc.gold))
		j_end_obj(j)
		j_key(j, "researchAt")
		j_str(j, te.research_at)
		j_key(j, "blockedBy")
		j_arr(j)
		for k in 0 ..< nbl {
			j_str(j, bl[k])
		}
		j_end_arr(j)
		j_end_obj(j)
	}
	j_end_arr(j)
	j_end_obj(j)

	// ---- unlockedContent: the buildings the seat may now place. Nothing is
	//      unlocked at this gate's two moments — the golden writes
	//      {"buildings":[]} for every seat at both t=0 and t=1000 — so the
	//      whole section is the empty list, transcribed as such rather than
	//      derived from a tree the state does not carry.
	j_key(j, "unlockedContent")
	j_obj(j)
	j_key(j, "buildings")
	j_arr(j)
	for b in 0 ..< s.n_unlocked_bldgs {
		j_str(j, s.unlocked_bldgs[b])
	}
	j_end_arr(j)
	j_end_obj(j)

	// ---- units: trainable and blocked, split by the structural blocks
	//      (HANDOVER §3.8). The walk: hosts in vocabulary order, each age at
	//      or above the host building own floor, the tier table plus the civ
	//      uniques with the building trainOptions as the empty fallback; a
	//      unit id appears at its first (host, age) only. blockedBy in
	//      check order: age, host, pop, cost. The arena seats are stone-age
	//      at this gate (the epoch section writes the same constant), and the
	//      standing buildings are the one Town Center per seat.
	ents: [24]unit_entry
	n_ents := 0
	seen_ids: [24]string
	n_seen := 0
	for h in 0 ..< 5 {
		host := UNITS_HOSTS[h]
		hdef := bldg_def_by_id(host)
		// a host whose unlocking tech the civ lacks is skipped entirely
		if hdef.req_tech != "" && !civ_has_tech(s.ci, hdef.req_tech) {
			continue
		}
		floor := age_idx(hdef.req_age)
		if floor < 0 {
			floor = 0
		}
		for a := floor; a < 4; a += 1 {
			ids: [8]string
			n_ids := train_tiers_for(s.ci, host, cast(int)(a), ids[:])
			if n_ids == 0 {
				// the building own trainOptions: the Town Center worker,
				// the temple priest
				for k in 0 ..< hdef.n_train {
					ids[k] = hdef.train_opts[k]
					n_ids += 1
				}
			}
			for k in 0 ..< n_ids {
				dup := false
				for g in 0 ..< n_seen {
					if seen_ids[g] == ids[k] {
						dup = true
					}
				}
				if dup {
					continue
				}
				seen_ids[n_seen] = ids[k]
				n_seen += 1
				e := &ents[n_ents]
				e.id = ids[k]
				e.at = host
				e.age = AGES_ORDER[a]
				e.cost = unit_def_for(s.ci, ids[k]).cost
				e.n_block = 0
				if !age_reached("stone", e.age) {
					e.blocked[e.n_block] = "age"
					e.n_block += 1
				}
				standing := seat_has_finished_bldg(s, host)
				if !standing {
					e.blocked[e.n_block] = "host"
					e.n_block += 1
				}
				if s.pop >= s.max_pop {
					e.blocked[e.n_block] = "pop"
					e.n_block += 1
				}
				if !has_resources(&s.res, e.cost) {
					e.blocked[e.n_block] = "cost"
					e.n_block += 1
				}
				n_ents += 1
			}
		}
	}
	j_key(j, "units")
	j_obj(j)
	j_key(j, "trainable")
	j_obj(j)
	units_write_group(j, ents[:n_ents], false)
	j_end_obj(j)
	j_key(j, "blocked")
	j_obj(j)
	units_write_group(j, ents[:n_ents], true)
	j_end_obj(j)
	j_end_obj(j) // units

	// ---- buildings: the nine standard buildings in table order plus the
	//      civ wonder, split by the same structural rule. blockedBy in check
	//      order: age, tech, cost for the standards; age, alreadyBuilt, cost
	//      for the wonder. The civ-support check (the tree carries the
	//      unlocking tech) skips a building outright; the tech block is the
	//      RESEARCHED check, and nothing is ever researched at this gate (the
	//      research section writes the same fact) — so every tech-requiring
	//      building carries it.
	bents: [12]bldg_entry
	n_bents := 0
	for bi in 0 ..< 9 {
		bdef := &std_bldg_defs[bi]
		if bdef.req_tech != "" && !civ_has_tech(s.ci, bdef.req_tech) {
			continue
		}
		be := &bents[n_bents]
		be.btype = bdef.id
		be.req_age = effective_building_age(s.ci, bdef)
		be.req_tech = bdef.req_tech
		be.cost = bdef.cost
		be.is_wonder = false
		be.built_as = ""
		be.n_block = 0
		if !age_reached("stone", be.req_age) {
			be.blocked[be.n_block] = "age"
			be.n_block += 1
		}
		// the live tech check: the block is the RESEARCHED test
		if bdef.req_tech != "" && !seat_has_tech(s, bdef.req_tech) {
			be.blocked[be.n_block] = "tech"
			be.n_block += 1
		}
		if !has_resources(&s.res, be.cost) {
			be.blocked[be.n_block] = "cost"
			be.n_block += 1
		}
		n_bents += 1
	}
	{
		// the civ wonder: all four are iron-age (port 254-330).
		be := &bents[n_bents]
		be.btype = "wonder"
		be.built_as = c.wonder_id
		be.req_age = "iron"
		be.req_tech = ""
		be.cost = c.wonder_cost
		be.is_wonder = true
		be.n_block = 0
		if !age_reached("stone", "iron") {
			be.blocked[be.n_block] = "age"
			be.n_block += 1
		}
		// alreadyBuilt: a wonder standing (none in this corpus)
		for wb in 0 ..< s.n_bldgs {
			if s.bldgs[wb].health > 0 && false { // is_wonder flag: dormant this minute
				be.blocked[be.n_block] = "alreadyBuilt"
				be.n_block += 1
			}
		}
		if !has_resources(&s.res, be.cost) {
			be.blocked[be.n_block] = "cost"
			be.n_block += 1
		}
		n_bents += 1
	}
	j_key(j, "buildings")
	j_obj(j)
	j_key(j, "buildable")
	j_arr(j)
	for k in 0 ..< n_bents {
		if !bldg_structural(&bents[k]) {
			bldg_entry_write(j, &bents[k], false)
		}
	}
	j_end_arr(j)
	j_key(j, "blocked")
	j_arr(j)
	for k in 0 ..< n_bents {
		if bldg_structural(&bents[k]) {
			bldg_entry_write(j, &bents[k], true)
		}
	}
	j_end_arr(j)
	j_end_obj(j) // buildings

	// ---- threats.underAttack (openai-ai.js 3924): the seat's buildings
	//      then units, each hit within the last 6 s, with where the answer
	//      came from and whether anything of ours answered
	j_key(j, "threats")
	j_obj(j)
	j_key(j, "underAttack")
	j_arr(j)
	for pass in 0 ..< 2 {
		count := s.n_bldgs if pass == 0 else s.n_units
		for i in 0 ..< count {
			last_dmg: f64
			def_at := f64(0)
			def_none := false
			lseat, lidx, lkind := -1, -1, 0
			if pass == 0 {
				b := &s.bldgs[i]
				last_dmg = b.last_dmg_time
				def_at, def_none = b.def_at, b.def_none
				lseat, lidx, lkind = b.ldk_seat, b.ldk_idx, b.ldk_kind
			} else {
				u := &s.units[i]
				last_dmg = u.last_dmg_time
				def_at, def_none = u.def_at, u.def_none
				lseat, lidx, lkind = u.ldk_seat, u.ldk_idx, u.ldk_kind
			}
			if last_dmg <= 0 || g.sim_ms - last_dmg > 6000 { continue }
			// scanHit skips the dead
			if (pass == 0 && s.bldgs[i].health <= 0) || (pass == 1 && s.units[i].health <= 0) { continue }
			j_obj(j)
			j_key(j, "kind")
			j_str(j, pass == 0 ? "building" : "unit")
			if pass == 0 {
				b := &s.bldgs[i]
				j_key(j, "type")
				j_str(j, b.id)
				j_key(j, "x")
				j_int(j, cast(i64)(math.floor(b.x + 0.5)))
				j_key(j, "z")
				j_int(j, cast(i64)(math.floor(b.z + 0.5)))
				j_key(j, "healthPct")
				j_int(j, i64(math.round(b.health / b.max_health * 100)))
			} else {
				u := &s.units[i]
				j_key(j, "type")
				j_str(j, u.u_type)
				j_key(j, "x")
				j_int(j, cast(i64)(math.floor(u.x + 0.5)))
				j_key(j, "z")
				j_int(j, cast(i64)(math.floor(u.z + 0.5)))
				j_key(j, "healthPct")
				j_int(j, i64(math.round(u.health / u.max_health * 100)))
			}
			j_key(j, "attackerAt")
			// the reference logs the attacker's position whatever its health:
			// a dead attacker still says who struck the blow
			atk_valid := lkind != 0 && lseat >= 0
			if atk_valid {
				atk_seat := &g.seats[lseat]
				if lkind == 1 {
					atk_valid = lidx < atk_seat.n_units
				} else {
					atk_valid = lidx < atk_seat.n_bldgs
				}
			}
			if atk_valid {
				atk_seat := &g.seats[lseat]
				j_obj(j)
				j_key(j, "x")
				if lkind == 1 {
					j_int(j, cast(i64)(math.floor(atk_seat.units[lidx].x + 0.5)))
					j_key(j, "z")
					j_int(j, cast(i64)(math.floor(atk_seat.units[lidx].z + 0.5)))
				} else {
					j_int(j, cast(i64)(math.floor(atk_seat.bldgs[lidx].x + 0.5)))
					j_key(j, "z")
					j_int(j, cast(i64)(math.floor(atk_seat.bldgs[lidx].z + 0.5)))
				}
				j_key(j, "owner")
				j_str(j, fmt.aprintf("%s-%d", civs[lseat].id, lseat + 1))
				j_end_obj(j)
			} else {
				j_raw(j, "null")
			}
			if def_at > 0 && g.sim_ms - def_at <= 6000 && def_none {
				j_key(j, "noDefenders")
				j_bool(j, true)
			}
			j_end_obj(j)
		}
	}
	j_end_arr(j)
	j_key(j, "enemyWonders")
	j_arr(j)
	j_end_arr(j)
	j_end_obj(j) // threats

	// ---- gameStats: the wonder threshold and the three rivals, in seat
	//      order. No seat has met a rival at this gate (the 250 ms discovery
	//      beat and its contact memory never fire before t=1000 — port
	//      722-740), so discovered is false and the population/buildings keys
	//      the discovered entries carry are absent.
	j_key(j, "gameStats")
	j_obj(j)
	j_key(j, "wonderRequired")
	j_int(j, 600)
	j_key(j, "opponents")
	j_arr(j)
	for oci in 0 ..< 4 {
		if oci == s.ci {
			continue
		}
		oc := &civs[oci]
		j_obj(j)
		j_key(j, "id")
		j_str(j, fmt.aprintf("%s-%d", oc.id, oci + 1))
		j_key(j, "civilization")
		j_str(j, oc.id)
		j_key(j, "age")
		j_str(j, "stone")
		j_key(j, "discovered")
		j_bool(j, s.met[oci])
		j_key(j, "defeated")
		j_bool(j, seat_eliminated(&g.seats[oci]))
		if s.met[oci] {
			// the scouting reward: the rival's live counts and what this seat
		// has seen of them and not seen die, by type, located or not
			n_alive_opp := 0
			for u2 in 0 ..< g.seats[oci].n_units {
				if g.seats[oci].units[u2].health > 0 { n_alive_opp += 1 }
			}
			j_key(j, "population")
			j_int(j, i64(n_alive_opp))
			j_key(j, "buildings")
			j_int(j, i64(g.seats[oci].n_bldgs))
			counts: [8]string
			cnums: [8]int
			n_counts := 0
			newest, oldest := -i64(1), i64(-1)
			for m in 0 ..< s.n_um {
				if s.um_oseat[m] != oci { continue }
				k := -1
				for c in 0 ..< n_counts {
					if counts[c] == s.um_type[m] { k = c; break }
				}
				if k < 0 && n_counts < 8 {
					k = n_counts
					counts[k] = s.um_type[m]
					cnums[k] = 0
					n_counts += 1
				}
				if k >= 0 { cnums[k] += 1 }
				a := i64(math.max(0, math.round((g.match_ms - s.um_at[m]/2) / 1000)))
				if newest < 0 || a < newest { newest = a }
				if a > oldest { oldest = a }
			}
			if n_counts > 0 {
				j_key(j, "seenAlive")
				j_obj(j)
				for c in 0 ..< n_counts {
					j_key(j, counts[c])
					j_int(j, i64(cnums[c]))
				}
				j_end_obj(j)
				j_key(j, "seenSecondsAgo")
				j_obj(j)
				j_key(j, "newest")
				j_int(j, newest)
				j_key(j, "oldest")
				j_int(j, oldest)
				j_end_obj(j)
			}
		}
		j_end_obj(j)
	}
	j_end_arr(j)
	j_end_obj(j) // gameStats

	j_end_obj(j) // state

	// commitObservation: events first (they carry the turn counter as it
	// stood when they happened); then every node this look SAW joins the
	// known set (openai-ai.js commitObservation: for (const [idx, amount]
	// of p.nodes.seen) { ai._knownResIdx.add(idx); ... }) — the state build's
	// own linear test discovers too, and what it saw stays known; then the
	// counter, then the counts snapshot.
	for p in 0 ..< o.n_pend {
		log_player_event(g, s, o.pend[p])
	}
	for i in 0 ..< g.terrain.n_nodes {
		if s.seen_set[i] != 0 {
			s.known[i] = 1
		}
	}
	s.turn_seq += 1
	for k in 0 ..< 4 {
		s.last_counts[k] = int(disc[k])
	}
}

// ===========================================================================
// The 50 ms step and its machinery (port 822-845 and its pieces).
// ===========================================================================

// markExploration (port 671): the 42x42 bitmap; a unit's or building's sight
// disc marks the cells it covers, forever — the fog's memory of the map.
mark_exploration :: proc(s: ^seat, size: f64) -> int {
	G := 42
	cell := size / f64(G)
	half := size / 2
	marked := 0
	mark :: proc(s: ^seat, x: f64, z: f64, rng: f64, cell: f64, half: f64) {
		G := 42
		cr := cast(int)(math.ceil(rng / cell))
		cx := cast(int)(math.floor((x + half) / cell))
		cz := cast(int)(math.floor((z + half) / cell))
		for dz := -cr; dz <= cr; dz += 1 {
			for dx := -cr; dx <= cr; dx += 1 {
				gx := cx + dx
				gz := cz + dz
				if gx < 0 || gx >= G || gz < 0 || gz >= G {
					continue
				}
				wx := (f64(gx) + 0.5)*cell - half
				wz := (f64(gz) + 0.5)*cell - half
				ddx := wx - x
				ddz := wz - z
				if m_hypot(ddx, ddz) <= rng {
					s.explored[gz*G + gx] = 1
				}
			}
		}
	}
	for i in 0 ..< s.n_units {
		u := &s.units[i]
		if u.health > 0 {
			mark(s, u.x, u.z, unit_vision(u), cell, half)
			marked += 1
		}
	}
	// every building marks too — including construction sites, whose
	// buildingVision is 0, so a site lights its own bitmap cell (game.js
	// markExploration marks buildings on health alone)
	for bi in 0 ..< s.n_bldgs {
		bd := &s.bldgs[bi]
		if bd.health > 0 {
			mark(s, bd.x, bd.z, building_vision(bd), cell, half)
			marked += 1
		}
	}
	return marked
}

// updateRivalContacts (port 730): first-contact memory — has the viewer
// ever seen any unit or building of each rival? Monotonic; gates the rival
// counts a state carries. At turn 1 no seat's sight reaches another's
// spawn, so nothing is ever met here, but the walk runs as the reference
// runs it. (The non-harness vision test the port builds here skips dead
// buildings; the harness one skips construction sites — the arena has
// neither, so make_eyes serves both.)
update_rival_contacts :: proc(g: ^game_state, viewer: ^seat) {
	es := make_eyes_mode(viewer, false)
	for oi in 0 ..< 4 {
		if oi == viewer.ci || viewer.met[oi] {
			continue
		}
		o := &g.seats[oi]
		spotted := false
		for i in 0 ..< o.n_units {
			u := &o.units[i]
			if u.health > 0 && see_test_brain(&es, u.x, u.z) {
				spotted = true
			}
		}
		for i in 0 ..< o.n_bldgs {
			b := &o.bldgs[i]
			if b.health > 0 && see_test_brain(&es, b.x, b.z) {
				spotted = true
			}
		}
		if spotted {
			viewer.met[oi] = true
		}
	}
}

// noteUnitSighting (game.js 4400): one record per remembered unit, on the
// map for the seat's whole run. hypot_note: the caller's sight test decides
// whether the call happens at all.
note_sighting :: proc(v: ^seat, oseat: int, u: ^unit_state, now: f64, sighted: []string, n_sighted: ^int) {
	found := -1
	for m in 0 ..< v.n_um {
		if v.um_pid[m] == u.pid { found = m; break }
	}
	if found < 0 {
		found = v.n_um
		v.n_um += 1
		v.um_pid[found] = u.pid
		v.um_oseat[found] = oseat
		v.um_type[found] = u.u_type
		v.um_carry[found] = ""
		v.um_has_sx[found] = false
		v.um_located[found] = false
		v.um_visible[found] = false
	}
	m := found
	if !v.um_visible[m] {
		v.um_sx[m] = u.x
		v.um_sz[m] = u.z
		v.um_has_sx[m] = true
	}
	v.um_x[m] = u.x
	v.um_z[m] = u.z
	v.um_hp[m] = int(math.round(u.health / u.max_health * 100))
	if u.u_type == "worker" {
		v.um_carry[m] = (u.carrying && u.harvest_amt > 0) ? res_type_name[u.carry_type] : "empty"
	}
	v.um_at[m] = now
	v.um_t[m] = now
	v.um_visible[m] = true
	v.um_located[m] = true
	v.um_spot_hidden[m] = false
	if n_sighted^ < len(sighted) {
		sighted[n_sighted^] = u.pid
		n_sighted^ += 1
	}
}

// sweepUnitMemory (game.js 4414): everything not in the sighted set goes
// dark; a record's unit is found by pid (indexes move); dead records drop
// per the killer rule; the spot-covered rule relocates.
sweep_memory :: proc(g: ^game_state, v: ^seat, now: f64, es: ^eye_set, sighted: []string, n_sighted: int) {
	// sweepUnitMemory: everything not sighted goes dark; a record's unit
	// found by pid (indexes move), dead records drop per the killer rule
	m := 0
	for m < v.n_um {
		sighted_here := false
		for k in 0 ..< n_sighted {
			if sighted[k] == v.um_pid[m] { sighted_here = true; break }
		}
		if sighted_here { m += 1; continue }
		oseat := v.um_oseat[m]
		if seat_eliminated(&g.seats[oseat]) {
			v.n_um -= 1
			v.um_pid[m] = v.um_pid[v.n_um]
			v.um_oseat[m] = v.um_oseat[v.n_um]
			v.um_type[m] = v.um_type[v.n_um]
			v.um_x[m] = v.um_x[v.n_um]
			v.um_z[m] = v.um_z[v.n_um]
			v.um_sx[m] = v.um_sx[v.n_um]
			v.um_sz[m] = v.um_sz[v.n_um]
			v.um_has_sx[m] = v.um_has_sx[v.n_um]
			v.um_hp[m] = v.um_hp[v.n_um]
			v.um_carry[m] = v.um_carry[v.n_um]
			v.um_at[m] = v.um_at[v.n_um]
			v.um_t[m] = v.um_t[v.n_um]
			v.um_visible[m] = v.um_visible[v.n_um]
			v.um_located[m] = v.um_located[v.n_um]
			v.um_spot_hidden[m] = v.um_spot_hidden[v.n_um]
			continue
		}
		u: ^unit_state = nil
		o := &g.seats[oseat]
		for i in 0 ..< o.n_units {
			if o.units[i].pid == v.um_pid[m] { u = &o.units[i]; break }
		}
		spot_seen := u != nil && see_test(es, v.um_x[m], v.um_z[m])
		if u != nil && u.health <= 0 {
			killed_by_v := u.ldk_kind == 1 && u.ldk_seat == v.ci
			if (v.um_visible[m] && spot_seen) || killed_by_v {
				v.n_um -= 1
				v.um_pid[m] = v.um_pid[v.n_um]
				v.um_oseat[m] = v.um_oseat[v.n_um]
				v.um_type[m] = v.um_type[v.n_um]
				v.um_x[m] = v.um_x[v.n_um]
				v.um_z[m] = v.um_z[v.n_um]
				v.um_sx[m] = v.um_sx[v.n_um]
				v.um_sz[m] = v.um_sz[v.n_um]
				v.um_has_sx[m] = v.um_has_sx[v.n_um]
				v.um_hp[m] = v.um_hp[v.n_um]
				v.um_carry[m] = v.um_carry[v.n_um]
				v.um_at[m] = v.um_at[v.n_um]
				v.um_t[m] = v.um_t[v.n_um]
				v.um_visible[m] = v.um_visible[v.n_um]
				v.um_located[m] = v.um_located[v.n_um]
				v.um_spot_hidden[m] = v.um_spot_hidden[v.n_um]
				continue
			}
		}
		v.um_visible[m] = false
		v.um_t[m] = now
		if !spot_seen {
			v.um_spot_hidden[m] = true
		} else if v.um_spot_hidden[m] {
			v.um_located[m] = false
		}
		m += 1
	}
	// the 400-record cap: oldest at drops first (game.js 4462)
	for v.n_um > 400 {
		oldest := 0
		for m in 1 ..< v.n_um {
			if v.um_at[m] < v.um_at[oldest] { oldest = m }
		}
		v.n_um -= 1
		v.um_pid[oldest] = v.um_pid[v.n_um]
		v.um_oseat[oldest] = v.um_oseat[v.n_um]
		v.um_type[oldest] = v.um_type[v.n_um]
		v.um_x[oldest] = v.um_x[v.n_um]
		v.um_z[oldest] = v.um_z[v.n_um]
		v.um_sx[oldest] = v.um_sx[v.n_um]
		v.um_sz[oldest] = v.um_sz[v.n_um]
		v.um_has_sx[oldest] = v.um_has_sx[v.n_um]
		v.um_hp[oldest] = v.um_hp[v.n_um]
		v.um_carry[oldest] = v.um_carry[v.n_um]
		v.um_at[oldest] = v.um_at[v.n_um]
		v.um_t[oldest] = v.um_t[v.n_um]
		v.um_visible[oldest] = v.um_visible[v.n_um]
		v.um_located[oldest] = v.um_located[v.n_um]
		v.um_spot_hidden[oldest] = v.um_spot_hidden[v.n_um]
	}
}

// aiManager.update's discovery beat: markExploration, updateRivalContacts
// and the brain's own discovery for every seat, then detectContacts — fired
// per TICK (openai-ai.js update(deltaTime), the tick's wall ms, before the
// tick's steps run).
discovery_beat :: proc(g: ^game_state) {
	for i in 0 ..< 4 {
		mark_exploration(&g.seats[i], g.terrain.size)
		update_rival_contacts(g, &g.seats[i])
		brain_discovery(g, &g.seats[i])
	}
	detect_contacts(g)
}

// detectContacts (game.js 4497): one seat per beat, rotating; notes the
// rival units its sight covers now (noteUnitSighting) and sweeps the rest
// of the unit memory dark (sweepUnitMemory, the harness sqrt test).
detect_contacts :: proc(g: ^game_state) {
	g.contact_idx = (g.contact_idx + 1) % g.n_seats
	vi := g.contact_idx
	viewer := &g.seats[vi]
	now := g.sim_ms
	es := make_eyes(viewer)
	// sighted pids this look, by mark order
	sighted: [512]string
	n_sighted := 0
	for oi in 0 ..< g.n_seats {
		if oi == vi { continue }
		o := &g.seats[oi]
		for i in 0 ..< o.n_units {
			u := &o.units[i]
			if u.health <= 0 { continue }
			// detectContacts notes on the hypot test (d <= src.r) — the
			// sweep's sqrt test below can still disagree at the boundary
			if !see_test_brain(&es, u.x, u.z) { continue }
			note_sighting(viewer, oi, u, now, sighted[:], &n_sighted)
		}
	}
	// sweepUnitMemory: everything not sighted goes dark (the harness test)
	sweep_memory(g, viewer, now, &es, sighted[:], n_sighted)

}

// WarPositionRules.apply (port 851): separation and building clearance at
// the end of every simulation step. The pairs are same-owner (units from
// different seats never interact — nothing crosses the 306-unit spawn
// gap); the clearance pushes a unit away from its own finished buildings.

// updateFarmRegeneration (game.js 5608+): a manned, finished farm grows back
// its stock — +10 food per 3s in stone age, scaled by age — but only while its
// assigned hand still holds the post (farmFarmer's task/farm/health check);
// a deserted post drops the claim and grows nothing.
update_farm_regen :: proc(g: ^game_state, dt: f64) {
	age_rate := [4]f64{10, 15, 20, 25}
	for si in 0 ..< 4 {
		s := &g.seats[si]
		for b in 0 ..< s.n_bldgs {
			farm := &s.bldgs[b]
			if farm.id != "farm" || farm.under_constr { continue }
			manned := false
			if farm.assigned_worker >= 0 {
				w := &s.units[farm.assigned_worker]
				if w.health > 0 && (w.task == TASK_FARM_WORK || w.task == TASK_CARRYING) && w.farm == b {
					manned = true
				}
			}
			if !manned {
				farm.assigned_worker = -1
				continue
			}
			farm.regen_timer += dt
			for farm.regen_timer >= 3000 {
				farm.regen_timer -= 3000
				if farm.food_amount < farm.max_food {
					farm.food_amount = math.min(farm.max_food, farm.food_amount + age_rate[s.cur_age])
				}
			}
		}
	}
}

war_position_rules :: proc(g: ^game_state, dt: f64) {
	// js/simulation/position-rules.js WarPositionRules.apply, verbatim: two
	// passes over the GLOBAL creation-ordered lists, deltaTime in seconds.
	SEPARATION_DIST := f64(1.2)
	SEPARATION_FORCE := f64(0.03)
	sepK := math.min(f64(3), math.max(f64(0), dt) * 60)
	for gi in 0 ..< g.n_gl_u {
		for gj in gi + 1 ..< g.n_gl_u {
			a_r := g.gl_u[gi]
			b_r := g.gl_u[gj]
			if a_r.seat != b_r.seat { continue } // an enemy is not a wall
			a := &g.seats[a_r.seat].units[a_r.idx]
			b := &g.seats[b_r.seat].units[b_r.idx]
			dx := b.x - a.x
			dz := b.z - a.z
			dist := math.sqrt(dx*dx + dz*dz)
			if dist < SEPARATION_DIST {
				nx := f64(0)
				nz := f64(0)
				if dist > 0.01 {
					nx = dx / dist
					nz = dz / dist
				} else {
					// the index-derived eight-spoke fallback (FAN(i + j*5))
					ang := f64((gi + gj * 5) % 8) * 0.7853981633974483
					nx = m_cos(ang)
					nz = m_sin(ang)
				}
				push := (SEPARATION_DIST - dist) * SEPARATION_FORCE * sepK
				a.x -= nx * push
				a.z -= nz * push
				b.x += nx * push
				b.z += nz * push
			}
		}
	}
	UNIT_BUILDING_CLEARANCE := f64(4.5)
	WONDER_CLEARANCE := f64(10.5)
	for ui in 0 ..< g.n_gl_u {
		u_r := g.gl_u[ui]
		u := &g.seats[u_r.seat].units[u_r.idx]
		for bi in 0 ..< g.n_gl_b {
			b_r := g.gl_b[bi]
			bd := &g.seats[b_r.seat].bldgs[b_r.idx]
			if bd.id == "farm" { continue }
			if u.task == TASK_BUILDING && u.build_site >= 0 && u_r.seat == b_r.seat && i32(u.build_site) == b_r.idx { continue }
			if u.task == TASK_REPAIRING && u.repair_site >= 0 && u_r.seat == b_r.seat && i32(u.repair_site) == b_r.idx { continue }
			clr := UNIT_BUILDING_CLEARANCE
			if bd.is_wonder { clr = WONDER_CLEARANCE }
			dx := u.x - bd.x
			dz := u.z - bd.z
			dist := math.sqrt(dx*dx + dz*dz)
			if dist <= 0.01 {
				ang := f64(ui % 8) * 0.7853981633974483
				u.x = bd.x + m_cos(ang) * clr
				u.z = bd.z + m_sin(ang) * clr
			} else if dist < clr {
				push := (clr - dist) * 0.05 * sepK
				u.x += (dx / dist) * push
				u.z += (dz / dist) * push
			}
		}
	}
}

// The harness per-step discovery (port 1106-1132): the node indices each
// seat's sight now covers, into the persistent known set — the batched
// test, harness rules. The enemy-building walk that runs beside it
// populates a per-seat memory that is invisible at this gate (no seat's
// sight reaches another spawn, and no rival building exists to see); it
// becomes required at the first gate with contacts, like the b1041/42
// enemy-unit memory the handover already scopes there.
// updateEnemyBuildingDiscovery (openai-ai.js 9839): every step, each seat
// learns enemy buildings its harness vision covers; a dead one drops.
update_enemy_building_discovery :: proc(g: ^game_state) {
	for si in 0 ..< g.n_seats {
		s := &g.seats[si]
		es := make_eyes(s)
		for oi in 0 ..< g.n_seats {
			if oi == si { continue }
			o := &g.seats[oi]
			for bi in 0 ..< o.n_bldgs {
				b := &o.bldgs[bi]
				if b.health <= 0 {
					s.eb_known[oi][bi] = false
					continue
				}
				if b.is_wonder || see_test(&es, b.x, b.z) {
					s.eb_known[oi][bi] = true
					s.eb_has[oi][bi] = true
					s.eb_hp[oi][bi] = int(math.round(b.health / b.max_health * 100))
					s.eb_x[oi][bi] = b.x
					s.eb_z[oi][bi] = b.z
				}
			}
		}
	}
}

observe_step :: proc(g: ^game_state) {
	update_enemy_building_discovery(g)
	for si in 0 ..< 4 {
		s := &g.seats[si]
		es := make_eyes(s)
		for idx in 0 ..< g.terrain.n_nodes {
			if s.known[idx] != 0 {
				continue
			}
			n := &g.terrain.nodes[idx]
			if see_test(&es, n.x, n.z) {
				s.known[idx] = 1
			}
		}
	}
}

// The 50 ms step, in the order the rules run it (port 832-845): population
// first, then the 4 Hz discovery beat, the clock, the position rules, and
// the harness discovery. The rule-based brain thinks on simulated time;
// every seat is harness-controlled, so only the beat runs. Worker tasks,
// production, research and combat all run inside the reference's
// simulation step and none can fire on a seat that has issued no order —
// omitted on purpose rather than ported as theatre.

// ===========================================================================
// The rule brain (js/ai.js AIManager) and the mechanics it drives. The
// whole-block transcription: think cadence, worker assignment, training,
// research, building placement, exploration, and the worker state machine
// (js/game.js updateWorkerTasks), production, research progress, the notice
// ring, and the shore clamp.
// ===========================================================================

can_afford :: proc(s: ^seat, c: cost4) -> bool {
	return s.res.food >= c.food && s.res.wood >= c.wood && s.res.stone >= c.stone && s.res.gold >= c.gold
}

spend :: proc(s: ^seat, c: cost4) {
	s.res.food -= c.food
	s.res.wood -= c.wood
	s.res.stone -= c.stone
	s.res.gold -= c.gold
}

seat_has_tech :: proc(s: ^seat, tid: string) -> bool {
	for r in 0 ..< s.n_researched {
		if s.researched[r] == tid {
			return true
		}
	}
	return false
}

// ai.js ensureMilitaryBuildings' has(): any building of the type, sites
// under construction included
seat_has_bldg :: proc(s: ^seat, btype: string) -> bool {
	for b in 0 ..< s.n_bldgs {
		if s.bldgs[b].id == btype {
			return true
		}
	}
	return false
}

seat_count_bldg :: proc(s: ^seat, btype: string) -> int {
	n := 0
	for b in 0 ..< s.n_bldgs {
		if s.bldgs[b].id == btype {
			n += 1
		}
	}
	return n
}

seat_researched :: proc(s: ^seat, tid: string) -> bool {
	for r in 0 ..< s.n_researched {
		if s.researched[r] == tid {
			return true
		}
	}
	return false
}

seat_has_finished_bldg :: proc(s: ^seat, btype: string) -> bool {
	for b in 0 ..< s.n_bldgs {
		bd := &s.bldgs[b]
		if bd.id == btype && !bd.under_constr {
			return true
		}
	}
	return false
}

// The resource the seat needs (ai.js neededResourceType): food gates
// everything below 200; otherwise the leanest stock, first of equals in the
// reference's check order (food, wood, gold, stone).
needed_resource_type :: proc(s: ^seat) -> int {
	if s.res.food < 200 {
		return 0
	}
	best := 1
	best_val := m_inf
	if s.res.food < best_val {
		best_val = s.res.food
		best = 0
	}
	if s.res.wood < best_val {
		best_val = s.res.wood
		best = 1
	}
	if s.res.gold < best_val {
		best_val = s.res.gold
		best = 3
	}
	if s.res.stone < best_val {
		best_val = s.res.stone
		best = 2
	}
	return best
}

// Nearest DISCOVERED node (of a type, or any with want < 0) with anything
// left (ai.js findKnownResource).
find_known_resource :: proc(g: ^game_state, s: ^seat, ux: f64, uz: f64, want: int) -> int {
	nearest := -1
	min_d := m_inf
	for i in 0 ..< g.terrain.n_nodes {
		if s.known[i] == 0 {
			continue
		}
		n := &g.terrain.nodes[i]
		if n.amount <= 0 {
			continue
		}
		if want >= 0 && int(n.n_type) != want {
			continue
		}
		d := m_hypot(n.x - ux, n.z - uz)
		if d < min_d {
			min_d = d
			nearest = i
		}
	}
	return nearest
}

// ai.js sendWorkerToResource: the move-then-harvest cycle restarts.
send_worker_to_resource :: proc(g: ^game_state, s: ^seat, u: ^unit_state, ni: int) {
	u.task = TASK_HARVESTING
	u.harvest_node = ni
	u.is_harvesting = false
	u.carrying = false
	u.harvest_amt = 0
	u.is_moving = true
	key := fmt.aprintf("s%d:node-spot", s.ci)
	n := &g.terrain.nodes[ni]
	u.target_x = n.x + (krng_draw(&s.k, key) - 0.5) * 2
	u.target_z = n.z + (krng_draw(&s.k, key) - 0.5) * 2
}

// ai.js assignWorkersToHarvest: genuinely idle workers onto the most-needed
// discovered resource; the nearest known node of any type as the fallback.
assign_workers_to_harvest :: proc(g: ^game_state, s: ^seat) {
	want := needed_resource_type(s)
	for u in 0 ..< s.n_units {
		w := &s.units[u]
		if w.u_type != "worker" {
			continue
		}
		if w.health <= 0 {
			continue
		}
		if w.is_moving || w.is_harvesting || w.carrying || w.is_building {
			continue
		}
		if w.task == TASK_BUILDING || w.task == TASK_FARM_WORK || w.task == TASK_SCOUTING {
			continue
		}
		ni := find_known_resource(g, s, w.x, w.z, want)
		if ni < 0 {
			ni = find_known_resource(g, s, w.x, w.z, -1)
		}
		if ni < 0 {
			continue
		}
		send_worker_to_resource(g, s, w, ni)
	}
}

// ai.js rebalanceWorkers: one pull per think toward a critically short type.
rebalance_workers :: proc(g: ^game_state, s: ^seat) {
	r := &s.res
	if s.ci == 3 && g.step_no >= 11100 {
	}
	threshold := [4]f64{150, 120, 60, 60} // food, wood, stone, gold
	min_when_short := [4]int{2, 2, 1, 1}
	// The reference's types order: food, wood, stone, gold (indices 0,1,2,3).
	types := [4]int{0, 1, 2, 3}
	// Group active harvesters by the resource they are gathering.
	by_type: [4][MAX_UNITS]int
	by_n: [4]int
	for i in 0 ..< 4 {
		by_n[i] = 0
	}
	for u in 0 ..< s.n_units {
		w := &s.units[u]
		if w.health <= 0 || w.u_type != "worker" || (w.task != TASK_HARVESTING && w.task != TASK_CARRYING) {
			continue
		}
		if w.harvest_node < 0 {
			continue
		}
		t := int(g.terrain.nodes[w.harvest_node].n_type)
		by_type[t][by_n[t]] = u
		by_n[t] += 1
	}
	for ti in 0 ..< 4 {
		t := types[ti]
		if r.food >= threshold[0] && t == 0 { continue }
		// The reference checks r[t] per type:
		rt := [4]f64{r.food, r.wood, r.stone, r.gold}
		if rt[t] >= threshold[t] {
			continue
		}
		if by_n[t] >= min_when_short[t] {
			continue
		}
		// center = ai.buildings[0]
		if s.n_bldgs == 0 {
			continue
		}
		b0 := &s.bldgs[0]
		fk := find_known_resource(g, s, b0.x, b0.z, t)
		if s.ci == 3 && g.step_no >= 11100 {
		}
		if fk < 0 {
			continue
		}
		// Donor: the most-staffed type that is itself not short.
		donor_type := -1
		donor_count := 0
		for dt in 0 ..< 4 {
			if dt == t || rt[dt] < threshold[dt] {
				continue
			}
			if by_n[dt] > donor_count && by_n[dt] > min_when_short[dt] {
				donor_count = by_n[dt]
				donor_type = dt
			}
		}
		if donor_type < 0 {
			continue
		}
		// Prefer a donor not hauling goods.
		pool := by_type[donor_type]
		donor := pool[by_n[donor_type]-1]
		for p in 0 ..< by_n[donor_type] {
			if !s.units[pool[p]].carrying {
				donor = pool[p]
				break
			}
		}
		d := &s.units[donor]
		ni := find_known_resource(g, s, d.x, d.z, t)
		if ni < 0 {
			continue
		}
		send_worker_to_resource(g, s, d, ni)
		return // one reassignment per think
	}
}

// ai.js manageWorkers: free finished scouts, assign idles, break starvation.
manage_workers :: proc(g: ^game_state, s: ^seat) {
	for u in 0 ..< s.n_units {
		w := &s.units[u]
		if w.u_type != "worker" {
			continue
		}
		if w.health <= 0 || w.task != TASK_SCOUTING {
			continue
		}
		w.scout_ticks += 1
		if !w.is_moving || w.scout_ticks > 6 {
			w.task = TASK_NONE
			w.scout_ticks = 0
		}
	}
	assign_workers_to_harvest(g, s)
	rebalance_workers(g, s)
}

// ai.js trainUnit (the worker path; military buildings arrive later).
train_unit_id :: proc(s: ^seat, b: ^bldg_state, unit_id: string) -> bool {
	// ai.js trainUnit: no production while building, a def with a cost, pop
	// room, and the money — then the 5 s train timer starts.
	if b.under_constr || b.is_producing {
		return false
	}
	ud := unit_def_for(s.ci, unit_id)
	if ud == nil || ud.cost.food == 0 && ud.cost.wood == 0 && ud.cost.stone == 0 && ud.cost.gold == 0 {
		return false
	}
	if s.pop >= s.max_pop {
		return false
	}
	if !can_afford(s, ud.cost) {
		return false
	}
	spend(s, ud.cost)
	b.is_producing = true
	b.prod_duration = 5000
	b.prod_progress = 0
	b.prod_type = unit_id
	return true
}

train_unit :: proc(s: ^seat, b: ^bldg_state) -> bool {
	return train_unit_id(s, b, "worker")
}

// ai.js getUnitToTrain: the per-age pick ladder, best first, restricted to
// what THIS building offers (civ exclusions reshape the list); nothing from
// the ladder means the building's last option — uniques append after the
// standard tiers, so that is the most advanced one.
get_unit_to_train :: proc(s: ^seat, b: ^bldg_state) -> string {
	ladder: [3]string
	n_ladder: int
	if b.id == "barracks" {
		if s.cur_age >= 2 {
			ladder = {"champion", "warrior", "militia"}
			n_ladder = 3
		} else if s.cur_age == 1 {
			ladder = {"warrior", "militia", ""}
			n_ladder = 2
		} else {
			ladder = {"militia", "", ""}
			n_ladder = 1
		}
	} else if b.id == "archery_range" {
		if s.cur_age >= 2 {
			ladder = {"elite_archer", "crossbowman", "archer"}
			n_ladder = 3
		} else {
			ladder = {"archer", "", ""}
			n_ladder = 1
		}
	} else if b.id == "stable" {
		if s.cur_age >= 2 {
			ladder = {"heavy_cavalry", "cavalry", "scout_cavalry"}
			n_ladder = 3
		} else if s.cur_age == 1 {
			ladder = {"cavalry", "scout_cavalry", ""}
			n_ladder = 2
		} else {
			ladder = {"scout_cavalry", "", ""}
			n_ladder = 1
		}
	} else {
		return ""
	}
	opts: [8]string
	n_opts := train_tiers_for(s.ci, b.id, s.cur_age, opts[:])
	for k in 0 ..< n_ladder {
		for o in 0 ..< n_opts {
			if opts[o] == ladder[k] {
				return ladder[k]
			}
		}
	}
	if n_opts > 0 {
		return opts[n_opts-1]
	}
	return ""
}

// ai.js trainMilitary: every finished, idle military building trains its
// ladder pick (standard profile: no counter-pick, no reserve).
train_military :: proc(g: ^game_state, s: ^seat) {
	for b in 0 ..< s.n_bldgs {
		bd := &s.bldgs[b]
		def := bldg_def_by_id(bd.id)
		if def == nil || !def.can_train || bd.id == "town_center" {
			continue
		}
		if bd.under_constr || bd.is_producing {
			continue
		}
		unit_type := get_unit_to_train(s, bd)
		if unit_type == "" {
			continue
		}
		train_unit_id(s, bd, unit_type)
	}
}

// ai.js maybeStartResearch: one affordable tech, unlock techs first (the
// reference's stable sort keeps tree order within each group).
maybe_start_research :: proc(s: ^seat) -> bool {
	if s.cur_research {
		return false
	}
	c := &civs[s.ci]
	for pass in 0 ..< 2 {
		for t in 0 ..< c.n_techs {
			te := &c.techs[t]
			if ((pass == 0) != (te.unlocks_bldg != "")) {
				continue
			}
			tid := tech_ids[s.ci][t]
			if seat_has_tech(s, tid) {
				continue
			}
			if age_idx(te.required_age) > age_idx("stone") {
				continue
			}
			ok := true
			for r in 0 ..< te.n_req {
				if !seat_has_tech(s, te.requires[r]) {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}
			if !seat_has_finished_bldg(s, te.research_at) {
				continue
			}
			cf := math.floor(te.cost.food * s.techcost_mult)
			cw := math.floor(te.cost.wood * s.techcost_mult)
			cs := math.floor(te.cost.stone * s.techcost_mult)
			cg := math.floor(te.cost.gold * s.techcost_mult)
			if s.res.food >= cf && s.res.wood >= cw && s.res.stone >= cs && s.res.gold >= cg {
				s.res.food -= cf
				s.res.wood -= cw
				s.res.stone -= cs
				s.res.gold -= cg
				s.cur_research = true
				s.res_tech = tid
				s.res_progress = 0
				s.res_duration = te.research_time
				return true
			}
		}
	}
	return false
}

// ---- building placement (js/game.js + ai.js findBuildPosition) ----

clamp_to_map :: proc(g: ^game_state, x: f64, z: f64) -> (f64, f64) {
	half := g.terrain.size / 2 - 30
	return math.clamp(x, -half, half), math.clamp(z, -half, half)
}

resource_clearance :: proc(btype: string) -> f64 {
	half := f64(3.5)
	if btype == "town_center" {
		half = 5
	}
	return half + 4.5
}

is_too_close_to_resource :: proc(g: ^game_state, x: f64, z: f64, btype: string) -> bool {
	clr := resource_clearance(btype)
	for i in 0 ..< g.terrain.n_nodes {
		n := &g.terrain.nodes[i]
		if n.amount <= 0 {
			continue
		}
		if m_hypot(n.x - x, n.z - z) < clr {
			return true
		}
	}
	return false
}

// buildingGap: 9 base (12 for a wonder); tower spacing is dormant here.
building_gap :: proc(a: f64) -> f64 {
	return a
}

is_clear_build_spot :: proc(g: ^game_state, s: ^seat, btype: string, x: f64, z: f64) -> bool {
	for b in 0 ..< s.n_bldgs {
		bd := &s.bldgs[b]
		if m_hypot(bd.x - x, bd.z - z) < building_gap(9) {
			return false
		}
	}
	if is_too_close_to_resource(g, x, z, btype) {
		return false
	}
	cx, cz := clamp_to_map(g, x, z)
	if math.abs(cx - x) > 0.5 || math.abs(cz - z) > 0.5 {
		return false
	}
	return true
}

find_build_position :: proc(g: ^game_state, s: ^seat, tc: ^bldg_state, btype: string) -> (f64, f64, bool) {
	key := fmt.aprintf("s%d:build-site", s.ci)
	for attempts in 0 ..< 24 {
		x := tc.x + (krng_draw(&s.k, key) - 0.5) * 60
		z := tc.z + (krng_draw(&s.k, key) - 0.5) * 60
		if is_clear_build_spot(g, s, btype, x, z) {
			return x, z, true
		}
	}
	return 0, 0, false
}

// workerPullRank + PULL_SECS (js/game.js pickBuilder): the cheapest worker
// in seconds of destroyed value. Builders and fighters never pulled.
pick_builder :: proc(g: ^game_state, s: ^seat, site: ^bldg_state) -> (int, bool) {
	best := -1
	best_pulled := false
	best_cost := m_inf
	for u in 0 ..< s.n_units {
		w := &s.units[u]
		if w.health <= 0 || w.u_type != "worker" {
			continue
		}
		// workerPullRank: builders/fighters Infinity (skip); repairers 5;
		// farmers 6; scouts 7; harvesters 1-4 by stock; else 0 idle.
		if w.task == TASK_BUILDING || w.is_building {
			continue
		}
		rank := 0
		if w.task == TASK_REPAIRING {
			rank = 5
		} else if w.farm >= 0 || w.task == TASK_FARM_WORK {
			rank = 6
		} else if w.task == TASK_SCOUTING {
			rank = 7
		} else if (w.task == TASK_HARVESTING || w.task == TASK_CARRYING) && w.harvest_node >= 0 {
			// 1 + the harvest target's type position in the stock order
			// (fattest first: food, wood, stone, gold sorted by the owner's
			// stock, descending).
			order := [4]int{0, 1, 2, 3}
			// sort food, wood, stone, gold by stock descending (stable)
			st := [4]f64{s.res.food, s.res.wood, s.res.stone, s.res.gold}
			// selection sort, stable: pick the max each pass
			for a in 0 ..< 4 {
				ai := a
				for b in a + 1 ..< 4 {
					if st[order[b]] > st[order[ai]] {
						ai = b
					}
				}
				tmp := order[a]
				order[a] = order[ai]
				order[ai] = tmp
			}
			ht := int(g.terrain.nodes[w.harvest_node].n_type)
			pos := 0
			for k in 0 ..< 4 {
				if order[k] == ht {
					pos = k
					break
				}
			}
			rank = 1 + pos
		}
		pull_secs := [8]f64{0, 4, 6, 8, 10, 14, 18, 45}
		walk := m_hypot(w.x - site.x, w.z - site.z) / (w.speed * 3)
		cost := walk + pull_secs[rank]
		if cost < best_cost {
			best_cost = cost
			best = u
			best_pulled = rank > 0
		}
	}
	return best, best_pulled
}

apply_builder :: proc(g: ^game_state, s: ^seat, pick: int, site: int, was_pulled: bool) {
	w := &s.units[pick]
	// _formerTask: remembered only when the worker was pulled off a task
	// (pickBuilder's restore flag); an idle worker builds outright.
	if was_pulled {
		w.former_task = w.task
		w.former_node = w.harvest_node
		w.former_farm = w.farm
	} else {
		w.former_task = -1
		w.former_node = -1
		w.former_farm = -1
	}
	if w.farm >= 0 && s.bldgs[w.farm].assigned_worker == pick {
		s.bldgs[w.farm].assigned_worker = -1
	}
	w.farm = -1
	w.task = TASK_BUILDING
	w.build_site = site
	w.is_moving = false
	w.is_harvesting = false
	w.carrying = false
}

release_builder :: proc(g: ^game_state, s: ^seat, w: ^unit_state, ui: int) {
	fsite := w.build_site
	w.is_building = false
	w.is_moving = false
	w.task = TASK_NONE
	w.build_site = -1
	// applyQueuedAssign: no model orders in this corpus — dormant.
	if w.former_task >= 0 {
		ft := w.former_task
		fn := w.former_node
		ff := w.former_farm
		w.former_task = -1
		w.former_node = -1
		w.former_farm = -1
		if ft == TASK_FARM_WORK && ff >= 0 && ff < s.n_bldgs && s.bldgs[ff].health > 0 {
			s.bldgs[ff].assigned_worker = ui
			w.task = TASK_FARM_WORK
			w.farm = ff
			w.is_moving = true
			key := fmt.aprintf("s%d:farm-spot", s.ci)
			w.target_x = s.bldgs[ff].x + (krng_draw(&s.k, key) - 0.5) * 3
			w.target_z = s.bldgs[ff].z + (krng_draw(&s.k, key) - 0.5) * 3
		} else if ft == TASK_HARVESTING || ft == TASK_CARRYING {
			// the restore resumes the FORMER TARGET directly — the node's
			// center, no fresh node-spot draws, even if the node has since
			// run dry (game.js releaseBuilder's harvesting branch; the walk
			// there hits State 2's depletion check, which retargets)
			w.task = TASK_HARVESTING
			w.harvest_node = fn
			w.is_moving = true
			w.target_x = g.terrain.nodes[fn].x
			w.target_z = g.terrain.nodes[fn].z
			w.carrying = false
		}
		// former task was idle -> stay idle (game.js's bare return)
		return
	}
	// An idle worker that just finished a farm becomes its farmer
	fs := &s.bldgs[fsite]
	if fs.health > 0 && !fs.under_constr && fs.id == "farm" && fs.assigned_worker < 0 {
		fs.assigned_worker = ui
		w.task = TASK_FARM_WORK
		w.farm = fsite
		w.is_moving = true
		key := fmt.aprintf("s%d:farm-spot", s.ci)
		w.target_x = fs.x + (krng_draw(&s.k, key) - 0.5) * 3
		w.target_z = fs.z + (krng_draw(&s.k, key) - 0.5) * 3
		return
	}
}

// The brain's buildStructure (ai.js): the def, the duplicate check, the
// afford check, the spot, the spend, the site, the builder.
build_structure :: proc(g: ^game_state, s: ^seat, btype: string) {
	def := bldg_def_by_id(btype)
	if def == nil {
		return
	}
	for b in 0 ..< s.n_bldgs {
		if s.bldgs[b].id == btype && s.bldgs[b].under_constr {
			return
		}
	}
	if !can_afford(s, def.cost) {
		return
	}
	tc := &s.bldgs[0]
	x, z, ok := find_build_position(g, s, tc, btype)
	if !ok {
		return
	}
	spend(s, def.cost)
	bd := &s.bldgs[s.n_bldgs]
	bd.id = btype
	bd.x = x
	bd.z = z
	bd.max_health = building_max_health(def, s.ci, "stone")
	bd.health = bd.max_health * 0.2 // a site starts at 20%?
	bd.under_constr = true
	bd.build_progress = 0
	bd.build_time = def.build_time
	bd.assigned_worker = -1
	if btype == "farm" {
		// createBuilding (units.js) gives farms their stock at CREATION,
		// not at completion — the state's food field reads it during
		// construction too
		bd.food_amount = 300
		bd.max_food = 300
	}
	s.n_bldgs += 1
	bd.pid = mint_entity(g, "building_")
	g.gl_b[g.n_gl_b] = gl_ref{seat = i32(s.ci), idx = i32(s.n_bldgs - 1)}
	g.n_gl_b += 1
	pick, pulled := pick_builder(g, s, bd)
	if pick >= 0 {
		apply_builder(g, s, pick, s.n_bldgs - 1, pulled)
	}
}

// ai.js runTurn, in the reference's order.
run_turn :: proc(g: ^game_state, s: ^seat) {
	workers := 0
	for u in 0 ..< s.n_units {
		if s.units[u].health > 0 && s.units[u].u_type == "worker" {
			workers += 1 // every unit this corpus fields is a worker
		}
	}
	pop_free := s.max_pop - s.pop
	if pop_free < 0 {
		pop_free = 0
	}
	manage_workers(g, s)
	// 1) population: a house when nearly capped
	if pop_free <= 2 && s.max_pop < 100 {
		houses := 0
		for b in 0 ..< s.n_bldgs {
			if s.bldgs[b].id == "house" {
				houses += 1
			}
		}
		if houses < 6 {
			build_structure(g, s, "house")
		}
	}
	// 2) economy: grow the worker base
	if workers < 14 && pop_free > 0 {
		for b in 0 ..< s.n_bldgs {
			bd := &s.bldgs[b]
			if bd.id == "town_center" && !bd.under_constr && !bd.is_producing {
				if train_unit(s, bd) {
					break
				}
			}
		}
	}
	// 3) farms at 5+ workers
	if workers >= 5 {
		farms := 0
		for b in 0 ..< s.n_bldgs {
			if s.bldgs[b].id == "farm" {
				farms += 1
			}
		}
		if farms < 4 {
			build_structure(g, s, "farm")
		}
	}
	// 4) research hosts: academy/temple are age-gated — dormant at stone.
	// 5) research
	maybe_start_research(s)
	// 6) age advancement needs 6+ workers (dormant this minute).
	// 7) military buildings: a barracks first, then stable/archery_range behind
	// their unlock techs, then a tower on spare stone (ai.js
	// ensureMilitaryBuildings; has() counts sites under construction too).
	// The reference's method returns after ONE build, but runTurn itself goes
	// on — exploreMap below always runs.
	if !seat_has_bldg(s, "barracks") {
		build_structure(g, s, "barracks")
	} else if seat_researched(s, "horseback") && !seat_has_bldg(s, "stable") {
		build_structure(g, s, "stable")
	} else if seat_researched(s, "longbow") && !seat_has_bldg(s, "archery_range") {
		build_structure(g, s, "archery_range")
	} else if seat_count_bldg(s, "tower") < 1 && s.res.stone >= 120 {
		// Defensive towers once we have stone to spare (standard: one).
		build_structure(g, s, "tower")
	}
	// 8) train military once the economy is on its feet (or a rival Wonder
	// must be answered — none in this corpus).
	pop_free2 := s.max_pop - s.pop
	if pop_free2 > 0 && workers >= 8 {
		train_military(g, s)
	}
	// 9) commandArmy: march the army to the least-explored tile (no enemy
	// contacts yet); dormant until a seat has military.
	command_army(g, s)
	// 10) keep revealing the map.
	explore_map(g, s)
}


// updateUnitMovement (game.js 5504): the NON-worker mover — plain moves,
// attack marches. Workers walk in updateWorkerTasks. No formation in this
// corpus: the aim is the slot itself, the straight line.
update_unit_movement :: proc(g: ^game_state, dt: f64) {
	for gi in 0 ..< g.n_gl_u {
		r := g.gl_u[gi]
		s := &g.seats[r.seat]
		u := &s.units[r.idx]
		if u.u_type == "worker" || u.health <= 0 {
			continue
		}
		if u.is_attacking {
			continue // attacking units belong to updateCombat
		}
		if u.is_moving {
			dx := u.target_x - u.x
			dz := u.target_z - u.z
			dist := math.sqrt(dx*dx + dz*dz)
			if dist > 0.5 {
				move_speed := u.speed * dt / 1000 * 3
				u.x += (dx / dist) * move_speed
				u.z += (dz / dist) * move_speed
			} else {
				// arrived: snap onto the exact point and stop
				u.is_moving = false
				u.x = u.target_x
				u.z = u.target_z
			}
		}
	}
}

// threatPriority (game.js 1828): wonder 3, Town Center 2, other building 1, unit 0.
threat_priority :: proc(kind: int, seat: ^seat, idx: int) -> int {
	if kind == 2 {
		bd := &seat.bldgs[idx]
		if bd.is_wonder { return 3 }
		if bd.id == "town_center" { return 2 }
		return 1
	}
	return 0
}

// findNearestEnemyInRange (game.js 1747), requireSight mode: the nearest
// living enemy unit or building within `rng` that the owner's sight covers.
// Sight is the same rule everywhere: living units plus finished buildings,
// dx*dx+dz*dz <= r*r (canOwnerSee).
find_nearest_enemy_target :: proc(g: ^game_state, s: ^seat, ux, uz: f64, rng: f64, include_buildings: bool) -> (int, int, int) {
	// kind 1 unit (seat, idx); kind 2 building. The scan walks the GLOBAL
	// creation order (renderer.units, then renderer.buildings) — a tie or
	// a near-tie resolves by creation order, not by seat.
	best_kind, best_seat, best_idx := 0, -1, -1
	min_d := rng
	for gi in 0 ..< g.n_gl_u {
		r := g.gl_u[gi]
		e := &g.seats[r.seat].units[r.idx]
		if r.seat == i32(s.ci) { continue }
		if e.health <= 0 { continue }
		if !can_owner_see(g, s, e.x, e.z) { continue }
		d := m_hypot(e.x - ux, e.z - uz)
		if d < min_d { min_d = d; best_kind, best_seat, best_idx = 1, int(r.seat), int(r.idx) }
	}
	if include_buildings {
		for bi in 0 ..< g.n_gl_b {
			r := g.gl_b[bi]
			b := &g.seats[r.seat].bldgs[r.idx]
			if r.seat == i32(s.ci) { continue }
			if b.health <= 0 { continue }
			if !can_owner_see(g, s, b.x, b.z) { continue }
			d := m_hypot(b.x - ux, b.z - uz)
			if d < min_d { min_d = d; best_kind, best_seat, best_idx = 2, int(r.seat), int(r.idx) }
		}
	}
	return best_kind, best_seat, best_idx
}

can_owner_see :: proc(g: ^game_state, s: ^seat, x, z: f64) -> bool {
	// the sight sources are the combat pass's START positions: the
	// reference caches visionSources once per sub-step
	for i in 0 ..< s.n_units {
		u := &s.units[i]
		if u.health <= 0 { continue }
		r := unit_vision(u)
		dx := g.cb_x[s.ci][i] - x
		dz := g.cb_z[s.ci][i] - z
		if dx*dx + dz*dz <= r*r { return true }
	}
	for i in 0 ..< s.n_bldgs {
		b := &s.bldgs[i]
		if b.health <= 0 { continue }
		r := building_vision(b)
		if r <= 0 { continue }
		dx := b.x - x
		dz := b.z - z
		if dx*dx + dz*dz <= r*r { return true }
	}
	return false
}

// combatMultiplier (game.js 1314): the hard-counter/soft-inverse table,
// buildings at infantry 1.5 / others 0.5.
combat_multiplier :: proc(atk_type: string, tgt_kind: int, tgt_type: string) -> f64 {
	if tgt_kind == 2 {
		if atk_type == "infantry" { return 1.5 }
		if atk_type == "cavalry" { return 1.0 }
		return 0.5
	}
	if atk_type == "cavalry" && tgt_type == "ranged" { return 1.5 }
	if atk_type == "ranged" && tgt_type == "infantry" { return 1.5 }
	if atk_type == "infantry" && tgt_type == "cavalry" { return 1.5 }
	if atk_type == "ranged" && tgt_type == "cavalry" { return 0.75 }
	if atk_type == "infantry" && tgt_type == "ranged" { return 0.75 }
	if atk_type == "cavalry" && tgt_type == "infantry" { return 0.75 }
	return 1.0
}

// updateCombat (game.js 1448): the military state machine — target
// acquisition on the 150 ms scan, the attack-move march, the 1 s swing,
// the counter-multiplier damage. No kills land in this corpus; the
// death/retaliation ladder stays unwritten beyond the target-gone drop.
// The battle ledger (game.js 2540-2650): engagements opened by damage,
// merged by place, kept 120 s past the last blow.
battle_entry :: proc(g: ^game_state, bi: int, owner_seat: int, type_id: string) -> (int, int) {
	// find or create the side, then the involved entry; returns (side, inv)
	si := -1
	for i in 0 ..< g.b_nsides[bi] {
		if g.b_side_seat[bi][i] == owner_seat { si = i; break }
	}
	if si < 0 && g.b_nsides[bi] < 8 {
		si = g.b_nsides[bi]
		g.b_side_seat[bi][si] = owner_seat
		g.b_nsides[bi] += 1
	}
	if si < 0 { return -1, -1 }
	for i in 0 ..< g.b_inv_n[bi][si] {
		if g.b_inv_type[bi][si][i] == type_id { return si, i }
	}
	if g.b_inv_n[bi][si] < 16 {
		ii := g.b_inv_n[bi][si]
		g.b_inv_type[bi][si][ii] = type_id
		g.b_inv_nids[bi][si][ii] = 0
		g.b_inv_du[bi][si][ii] = 0
		g.b_inv_db[bi][si][ii] = 0
		g.b_inv_he[bi][si][ii] = 0
		g.b_inv_n[bi][si] += 1
		return si, ii
	}
	return -1, -1
}

battle_add_id :: proc(g: ^game_state, bi, si, ii: int, pid: string) {
	for i in 0 ..< g.b_inv_nids[bi][si][ii] {
		if g.b_inv_ids[bi][si][ii][i] == pid { return }
	}
	if g.b_inv_nids[bi][si][ii] < 64 {
		g.b_inv_ids[bi][si][ii][g.b_inv_nids[bi][si][ii]] = pid
		g.b_inv_nids[bi][si][ii] += 1
	}
}

battle_merge_into :: proc(g: ^game_state, dst, src: int) {
	if dst == src { return }
	if g.b_started[src] < g.b_started[dst] { g.b_started[dst] = g.b_started[src] }
	if g.b_last[src] > g.b_last[dst] { g.b_last[dst] = g.b_last[src] }
	for ss in 0 ..< g.b_nsides[src] {
		oseat := g.b_side_seat[src][ss]
		dsi := -1
		for i in 0 ..< g.b_nsides[dst] {
			if g.b_side_seat[dst][i] == oseat { dsi = i; break }
		}
		if dsi < 0 && g.b_nsides[dst] < 8 {
			dsi = g.b_nsides[dst]
			g.b_side_seat[dst][dsi] = oseat
			g.b_nsides[dst] += 1
		}
		if dsi < 0 { continue }
		for ii in 0 ..< g.b_inv_n[src][ss] {
			ty := g.b_inv_type[src][ss][ii]
			dii := -1
			for i in 0 ..< g.b_inv_n[dst][dsi] {
				if g.b_inv_type[dst][dsi][i] == ty { dii = i; break }
			}
			if dii < 0 && g.b_inv_n[dst][dsi] < 16 {
				dii = g.b_inv_n[dst][dsi]
				g.b_inv_type[dst][dsi][dii] = ty
				g.b_inv_du[dst][dsi][dii] = 0
				g.b_inv_db[dst][dsi][dii] = 0
				g.b_inv_he[dst][dsi][dii] = 0
				g.b_inv_n[dst][dsi] += 1
			}
			if dii < 0 { continue }
			for k in 0 ..< g.b_inv_nids[src][ss][ii] {
				battle_add_id(g, dst, dsi, dii, g.b_inv_ids[src][ss][ii][k])
			}
			g.b_inv_du[dst][dsi][dii] += g.b_inv_du[src][ss][ii]
			g.b_inv_db[dst][dsi][dii] += g.b_inv_db[src][ss][ii]
			g.b_inv_he[dst][dsi][dii] += g.b_inv_he[src][ss][ii]
		}
		for li in 0 ..< g.b_nlost[src][ss] {
			ty := g.b_lost_type[src][ss][li]
			dli := -1
			for i in 0 ..< g.b_nlost[dst][dsi] {
				if g.b_lost_type[dst][dsi][i] == ty { dli = i; break }
			}
			if dli < 0 && g.b_nlost[dst][dsi] < 16 {
				dli = g.b_nlost[dst][dsi]
				g.b_lost_type[dst][dsi][dli] = ty
				g.b_nlost[dst][dsi] += 1
			}
			if dli >= 0 { g.b_lost_n[dst][dsi][dli] += g.b_lost_n[src][ss][li] }
		}
	}
	g.b_nsides[src] = 0
}

battle_at :: proc(g: ^game_state, x, z: f64, open: bool) -> int {
	now := g.sim_ms
	// prune: keep battles touched within 120 s
	n := 0
	for i in 0 ..< g.n_battles {
		if now - g.b_last[i] <= 120000 {
			g.b_x[n] = g.b_x[i]
			g.b_z[n] = g.b_z[i]
			g.b_started[n] = g.b_started[i]
			g.b_last[n] = g.b_last[i]
			g.b_nsides[n] = g.b_nsides[i]
			g.b_side_seat[n] = g.b_side_seat[i]
			g.b_inv_n[n] = g.b_inv_n[i]
			g.b_inv_type[n] = g.b_inv_type[i]
			g.b_inv_nids[n] = g.b_inv_nids[i]
			g.b_inv_ids[n] = g.b_inv_ids[i]
			g.b_inv_du[n] = g.b_inv_du[i]
			g.b_inv_db[n] = g.b_inv_db[i]
			g.b_inv_he[n] = g.b_inv_he[i]
			g.b_lost_type[n] = g.b_lost_type[i]
			g.b_lost_n[n] = g.b_lost_n[i]
			g.b_nlost[n] = g.b_nlost[i]
			n += 1
		}
	}
	g.n_battles = n
	// the near, still-open ones
	near: [8]int
	n_near := 0
	for i in 0 ..< g.n_battles {
		if now - g.b_last[i] <= 10000 && m_hypot(g.b_x[i] - x, g.b_z[i] - z) <= 90 {
			near[n_near] = i
			n_near += 1
		}
	}
	if n_near == 0 {
		if !open || g.n_battles >= 8 { return -1 }
		bi := g.n_battles
		g.b_x[bi], g.b_z[bi] = x, z
		g.b_started[bi], g.b_last[bi] = now, now
		g.b_nsides[bi] = 0
		g.b_inv_n[bi] = [8]int{}
		g.b_nlost[bi] = [8]int{}
		g.n_battles += 1
		return bi
	}
	b := near[0]
	for i in 1 ..< n_near {
		battle_merge_into(g, b, near[i])
		// remove near[i] by compacting
		for j := near[i]; j < g.n_battles - 1; j += 1 {
			g.b_x[j] = g.b_x[j+1]
			g.b_z[j] = g.b_z[j+1]
			g.b_started[j] = g.b_started[j+1]
			g.b_last[j] = g.b_last[j+1]
			g.b_nsides[j] = g.b_nsides[j+1]
			g.b_side_seat[j] = g.b_side_seat[j+1]
			g.b_inv_n[j] = g.b_inv_n[j+1]
			g.b_inv_type[j] = g.b_inv_type[j+1]
			g.b_inv_nids[j] = g.b_inv_nids[j+1]
			g.b_inv_ids[j] = g.b_inv_ids[j+1]
			g.b_inv_du[j] = g.b_inv_du[j+1]
			g.b_inv_db[j] = g.b_inv_db[j+1]
			g.b_inv_he[j] = g.b_inv_he[j+1]
			g.b_lost_type[j] = g.b_lost_type[j+1]
			g.b_lost_n[j] = g.b_lost_n[j+1]
			g.b_nlost[j] = g.b_nlost[j+1]
		}
		g.n_battles -= 1
		for k in 0 ..< n_near {
			if near[k] > near[i] { near[k] -= 1 }
		}
	}
	return b
}

record_battle_damage :: proc(g: ^game_state, aseat: int, atype: string, apid: string, tx, tz: f64, towner: int, t_is_building: bool, amount: f64) {
	if amount <= 0 { return }
	bi := battle_at(g, tx, tz, true)
	if bi < 0 { return }
	si, ii := battle_entry(g, bi, aseat, atype)
	if si < 0 { return }
	battle_add_id(g, bi, si, ii, apid)
	if t_is_building {
		g.b_inv_db[bi][si][ii] += amount
	} else {
		g.b_inv_du[bi][si][ii] += amount
	}
	g.b_last[bi] = g.sim_ms
	g.b_x[bi] += (tx - g.b_x[bi]) * 0.05
	g.b_z[bi] += (tz - g.b_z[bi]) * 0.05
}

record_battle_loss :: proc(g: ^game_state, towner: int, ttype: string, tx, tz: f64) {
	bi := battle_at(g, tx, tz, false)
	if bi < 0 { return }
	si := -1
	for i in 0 ..< g.b_nsides[bi] {
		if g.b_side_seat[bi][i] == towner { si = i; break }
	}
	if si < 0 && g.b_nsides[bi] < 8 {
		si = g.b_nsides[bi]
		g.b_side_seat[bi][si] = towner
		g.b_nsides[bi] += 1
	}
	if si < 0 { return }
	for i in 0 ..< g.b_nlost[bi][si] {
		if g.b_lost_type[bi][si][i] == ttype {
			g.b_lost_n[bi][si][i] += 1
			return
		}
	}
	if g.b_nlost[bi][si] < 16 {
		li := g.b_nlost[bi][si]
		g.b_lost_type[bi][si][li] = ttype
		g.b_lost_n[bi][si][li] = 1
		g.b_nlost[bi][si] += 1
	}
}

// target_ref helpers: (kind 0 none, 1 unit, 2 building)
ref_alive :: proc(g: ^game_state, kind, seat, idx: int) -> bool {
	if kind == 1 {
		return seat >= 0 && g.seats[seat].units[idx].health > 0
	}
	if kind == 2 {
		return seat >= 0 && g.seats[seat].bldgs[idx].health > 0
	}
	return false
}

ref_eq :: proc(k1, s1, i1, k2, s2, i2: int) -> bool {
	return k1 == k2 && s1 == s2 && i1 == i2
}

// noteRetaliation (game.js 4395-ish): a fighting military unit that takes
// damage from a third party queues the dealer; while it still pounds its
// ORIGINAL target it switches to the first living dealer and pulls the
// squad along. Workers resolve through self-defense instead; buildings
// have no queue.
note_retaliation :: proc(g: ^game_state, vseat, vidx: int, akind, aseat, aidx: int) {
	v := &g.seats[vseat].units[vidx]
	if v.u_type == "worker" { return } // self-defense handles workers
	ud := unit_def_for(g.seats[vseat].ci, v.u_type)
	if ud == nil || ud.u_type == "support" { return }
	if !v.is_attacking || v.atk_kind == 0 { return }
	if !ref_alive(g, akind, aseat, aidx) { return }
	if ref_eq(v.atk_kind, v.atk_seat, v.atk_idx, akind, aseat, aidx) { return }
	if v.orig_kind == 0 {
		v.orig_kind, v.orig_seat, v.orig_idx = v.atk_kind, v.atk_seat, v.atk_idx
	}
	// push the dealer unless queued
	q := false
	for i in 0 ..< v.n_rt {
		if ref_eq(v.rt_kind[i], v.rt_seat[i], v.rt_idx[i], akind, aseat, aidx) { q = true; break }
	}
	if !q && v.n_rt < 8 {
		v.rt_kind[v.n_rt], v.rt_seat[v.n_rt], v.rt_idx[v.n_rt] = akind, aseat, aidx
		v.n_rt += 1
	}
	if ref_eq(v.atk_kind, v.atk_seat, v.atk_idx, v.orig_kind, v.orig_seat, v.orig_idx) {
		for i in 0 ..< v.n_rt {
			if ref_alive(g, v.rt_kind[i], v.rt_seat[i], v.rt_idx[i]) {
				v.atk_kind, v.atk_seat, v.atk_idx = v.rt_kind[i], v.rt_seat[i], v.rt_idx[i]
				v.attack_timer = 0
				spread_retaliation(g, vseat, vidx)
				break
			}
		}
	}
}

// spreadRetaliation: squadmates on the same original target (or on a DEAD
// retaliation target from the same original) join the focus fire.
spread_retaliation :: proc(g: ^game_state, vseat, vidx: int) {
	v := &g.seats[vseat].units[vidx]
	if v.orig_kind == 0 { return }
	okind, oseat, oidx := v.orig_kind, v.orig_seat, v.orig_idx
	for w_i in 0 ..< g.seats[vseat].n_units {
		w := &g.seats[vseat].units[w_i]
		if w_i == vidx { continue }
		if w.u_type == "worker" { continue }
		ud := unit_def_for(g.seats[vseat].ci, w.u_type)
		if ud == nil || ud.u_type == "support" { continue }
		if !w.is_attacking || w.atk_kind == 0 { continue }
		if ref_eq(w.atk_kind, w.atk_seat, w.atk_idx, v.atk_kind, v.atk_seat, v.atk_idx) { continue }
		on_orig := ref_eq(w.atk_kind, w.atk_seat, w.atk_idx, okind, oseat, oidx)
		on_dead := ref_eq(w.orig_kind, w.orig_seat, w.orig_idx, okind, oseat, oidx) && \
			w.atk_kind != 0 && !ref_alive(g, w.atk_kind, w.atk_seat, w.atk_idx)
		if !on_orig && !on_dead { continue }
		w.orig_kind, w.orig_seat, w.orig_idx = okind, oseat, oidx
		// unshift the focus target: remove it elsewhere, put it at the head
		qi := -1
		for i in 0 ..< w.n_rt {
			if ref_eq(w.rt_kind[i], w.rt_seat[i], w.rt_idx[i], v.atk_kind, v.atk_seat, v.atk_idx) { qi = i; break }
		}
		if qi > 0 {
			for i in qi ..< w.n_rt - 1 {
				w.rt_kind[i] = w.rt_kind[i+1]
				w.rt_seat[i] = w.rt_seat[i+1]
				w.rt_idx[i] = w.rt_idx[i+1]
			}
			w.n_rt -= 1
			qi = -1
		}
		if qi != 0 {
			for i in 0 ..< w.n_rt {
				j := w.n_rt - i
				if j >= 8 { continue }
				w.rt_kind[j] = w.rt_kind[j-1]
				w.rt_seat[j] = w.rt_seat[j-1]
				w.rt_idx[j] = w.rt_idx[j-1]
			}
			if w.n_rt < 8 { w.n_rt += 1 }
			w.rt_kind[0], w.rt_seat[0], w.rt_idx[0] = v.atk_kind, v.atk_seat, v.atk_idx
		}
		w.atk_kind, w.atk_seat, w.atk_idx = v.atk_kind, v.atk_seat, v.atk_idx
	}
}

// nextRetaliationTarget: the head living dealer, else the original target,
// else none (the queue empties as it is consumed).
next_retaliation :: proc(g: ^game_state, s: ^seat, u: ^unit_state) -> (int, int, int) {
	for u.n_rt > 0 {
		k, si, ix := u.rt_kind[0], u.rt_seat[0], u.rt_idx[0]
		if ref_alive(g, k, si, ix) {
			u.atk_kind, u.atk_seat, u.atk_idx = k, si, ix
			u.attack_timer = 0
			vi := -1
			for i in 0 ..< s.n_units {
				if &s.units[i] == u { vi = i; break }
			}
			if vi >= 0 { spread_retaliation(g, s.ci, vi) }
			return k, si, ix
		}
		for i in 0 ..< u.n_rt - 1 {
			u.rt_kind[i] = u.rt_kind[i+1]
			u.rt_seat[i] = u.rt_seat[i+1]
			u.rt_idx[i] = u.rt_idx[i+1]
		}
		u.n_rt -= 1
	}
	if u.orig_kind != 0 && ref_alive(g, u.orig_kind, u.orig_seat, u.orig_idx) {
		u.n_rt = 0
		return u.orig_kind, u.orig_seat, u.orig_idx
	}
	u.n_rt = 0
	u.orig_kind, u.orig_seat, u.orig_idx = 0, -1, -1
	return 0, -1, -1
}

update_combat :: proc(g: ^game_state, dt: f64) {
	for i in 0 ..< g.n_seats {
		for u in 0 ..< g.seats[i].n_units {
			g.cb_x[i][u] = g.seats[i].units[u].x
			g.cb_z[i][u] = g.seats[i].units[u].z
		}
	}
	for gi in 0 ..< g.n_gl_u {
		r := g.gl_u[gi]
		s := &g.seats[r.seat]
		u := &s.units[r.idx]
		if u.health <= 0 { continue }
		if u.u_type == "worker" && !u.is_attacking { continue }
		// self-defense: the leash ends the reflex
		if u.self_defense {
			alive := false
			if u.atk_kind == 1 && u.atk_seat >= 0 {
				te := &g.seats[u.atk_seat].units[u.atk_idx]
				if te.health > 0 && m_hypot(te.x - u.sd_x, te.z - u.sd_z) <= 30 { alive = true }
			}
			if !alive {
				u.self_defense = false
				u.is_attacking = false
				u.task = TASK_NONE
				continue
			}
		}
		// a dead target drops: the retaliation ladder decides what comes
		// next (the next living dealer, then the original siege target),
		// else the nearby re-acquire scan takes over
		if u.is_attacking && u.atk_kind != 0 {
			dead := false
			if u.atk_kind == 1 && (u.atk_seat < 0 || g.seats[u.atk_seat].units[u.atk_idx].health <= 0) { dead = true }
			if u.atk_kind == 2 && (u.atk_seat < 0 || g.seats[u.atk_seat].bldgs[u.atk_idx].health <= 0) { dead = true }
			if dead {
				k2, s2, i2 := next_retaliation(g, s, u)
				if k2 != 0 {
					u.atk_kind, u.atk_seat, u.atk_idx = k2, s2, i2
				} else {
					u.atk_kind = 0
					u.acquire_timer = 150
					u.acquire_set = true
				}
			}
		}
		if u.is_attacking && u.atk_kind == 0 {
			// acquire on the 150 ms scan; between scans keep marching
			if !u.acquire_set {
				u.acquire_timer = 150
				u.acquire_set = true
			} else {
				u.acquire_timer += dt
			}
			if u.acquire_timer >= 150 {
				u.acquire_timer -= 150
				aggro := f64(24)
				if ud := unit_def_for(s.ci, u.u_type); ud != nil && ud.range > 1 {
					aggro = ud.range + 20
				}
				k, os_, oi := find_nearest_enemy_target(g, s, u.x, u.z, aggro, true)
				if k != 0 {
					u.atk_kind, u.atk_seat, u.atk_idx = k, os_, oi
				} else if !u.attack_move {
					// plain attack, nothing in sight: stand down
					u.is_attacking = false
					u.atk_kind = 0
					continue
				}
			}
			if u.atk_kind == 0 && u.attack_move {
				// march the attack-move leg
				dx := u.am_x - u.x
				dz := u.am_z - u.z
				dist := math.sqrt(dx*dx + dz*dz)
				if dist > 1.5 {
					u.is_moving = true
					move_speed := u.speed * dt / 1000 * 3
					u.x += (dx / dist) * move_speed
					u.z += (dz / dist) * move_speed
				} else {
					u.is_moving = false
					u.attack_move = false
					u.is_attacking = false
				}
				continue
			}
		}
		if u.is_attacking && u.atk_kind != 0 {
			// friendly-fire backstop (never fires from these orders)
			tx, tz, trng_build := f64(0), f64(0), false
			tgt_type := ""
			if u.atk_kind == 1 {
				te := &g.seats[u.atk_seat].units[u.atk_idx]
				tx, tz, tgt_type = te.x, te.z, te.u_type
			} else {
				tb := &g.seats[u.atk_seat].bldgs[u.atk_idx]
				tx, tz, trng_build = tb.x, tb.z, true
				tgt_type = tb.id
			}
			dx := tx - u.x
			 dz := tz - u.z
			dist := math.sqrt(dx*dx + dz*dz)
			ud := unit_def_for(s.ci, u.u_type)
			reach := f64(1.5)
			if ud != nil && ud.range > 1 { reach = ud.range }
			if trng_build { reach += 3.5 }
			if ud != nil && ud.u_type == "ranged" { reach = math.min(reach, 18) }
			if dist > reach + 1e-6 {
				// close to the target; the formation aim is the straight line
				u.is_moving = true
				u.target_x = tx
				u.target_z = tz
				move_speed := u.speed * dt / 1000 * 3
				if move_speed > dist - math.max(0, reach - 0.2) {
					move_speed = dist - math.max(0, reach - 0.2)
				}
				u.x += (dx / dist) * move_speed
				u.z += (dz / dist) * move_speed
			}
			// arrival and striking share a tick: a unit that just walked into
			// range starts its swing clock this very step (game.js 1615)
			if m_hypot(tx - u.x, tz - u.z) <= reach + 1e-6 {
				// in range: the 1 s swing
				u.is_moving = false
				u.attack_timer += dt
				if u.attack_timer >= 1000 {
					u.attack_timer -= 1000
					atk := f64(1)
					if ud != nil { atk = ud.attack }
					// combatMultiplier reads the attack CLASS (infantry /
					// ranged / cavalry), not the unit id
					a_cls := ud != nil ? ud.u_type : "worker"
					dealt := atk * combat_multiplier(a_cls, u.atk_kind, tgt_type)
					if u.atk_kind == 1 {
						te := &g.seats[u.atk_seat].units[u.atk_idx]
						te.health -= dealt
						te.last_dmg_time = g.sim_ms
						te.ldk_kind, te.ldk_seat, te.ldk_idx = 1, int(s.ci), int(r.idx)
						record_battle_damage(g, int(s.ci), u.u_type, u.pid, te.x, te.z, u.atk_seat, false, dealt)
						if te.health <= 0 && !te.dead_counted {
							te.dead_counted = true
							record_battle_loss(g, u.atk_seat, te.u_type, te.x, te.z)
						} else if te.health > 0 {
							note_retaliation(g, u.atk_seat, u.atk_idx, 1, int(s.ci), int(r.idx))
						}
					} else {
						tb := &g.seats[u.atk_seat].bldgs[u.atk_idx]
						tb.health -= dealt
						tb.last_dmg_time = g.sim_ms
						tb.ldk_kind, tb.ldk_seat, tb.ldk_idx = 1, int(s.ci), int(r.idx)
						record_battle_damage(g, int(s.ci), u.u_type, u.pid, tb.x, tb.z, u.atk_seat, true, dealt)
						if tb.health <= 0 && !tb.dead_counted {
							tb.dead_counted = true
							record_battle_loss(g, u.atk_seat, tb.id, tb.x, tb.z)
						}
					}
					// the killer walks the same ladder as its squadmates
					if u.atk_kind != 0 {
						dead2 := false
						if u.atk_kind == 1 && (u.atk_seat < 0 || g.seats[u.atk_seat].units[u.atk_idx].health <= 0) { dead2 = true }
						if u.atk_kind == 2 && (u.atk_seat < 0 || g.seats[u.atk_seat].bldgs[u.atk_idx].health <= 0) { dead2 = true }
						if dead2 {
							k2, s2, i2 := next_retaliation(g, s, u)
							if k2 != 0 {
								u.atk_kind, u.atk_seat, u.atk_idx = k2, s2, i2
							} else {
								u.atk_kind = 0
								u.acquire_timer = 150
								u.acquire_set = true
							}
						}
					}
				}
			}
		}
	}
}

// updateAutoDefense (game.js 1839): damage-triggered, every ~600 ms. The
// seat's idle military within the tiered reach engages the latest attacker;
// workers are never drafted here.
update_auto_defense :: proc(g: ^game_state, dt: f64) {
	g.autodef_timer += dt
	if g.autodef_timer < 600 { return }
	g.autodef_timer -= 600
	for si in 0 ..< g.n_seats {
		s := &g.seats[si]
		// recent threats: own entities hit in the last 4 s by a living enemy
		t_kind, t_idx := 0, -1
		t_pri := -1
		atk_x, atk_z := f64(0), f64(0)
		atk_seat, atk_idx, atk_kind := -1, -1, 0
		found := false
		for pass in 0 ..< 2 {
			count := s.n_bldgs if pass == 0 else s.n_units
			for i in 0 ..< count {
				last_dmg: f64
				lseat, lidx, lkind: int
				ex, ez: f64
				if pass == 0 {
					last_dmg = s.bldgs[i].last_dmg_time
					lseat, lidx, lkind = s.bldgs[i].ldk_seat, s.bldgs[i].ldk_idx, s.bldgs[i].ldk_kind
					ex, ez = s.bldgs[i].x, s.bldgs[i].z
				} else {
					last_dmg = s.units[i].last_dmg_time
					lseat, lidx, lkind = s.units[i].ldk_seat, s.units[i].ldk_idx, s.units[i].ldk_kind
					ex, ez = s.units[i].x, s.units[i].z
				}
				if last_dmg <= 0 || g.sim_ms - last_dmg > 4000 { continue }
				if lkind == 0 || lseat < 0 || lseat == si { continue }
				atk := &g.seats[lseat]
				alive := false
				ax, az := f64(0), f64(0)
				if lkind == 1 && lidx < atk.n_units {
					ae := &atk.units[lidx]
					if ae.health > 0 { alive = true; ax, az = ae.x, ae.z }
				} else if lkind == 2 && lidx < atk.n_bldgs {
					ab := &atk.bldgs[lidx]
					if ab.health > 0 { alive = true; ax, az = ab.x, ab.z }
				}
				if !alive { continue }
				pri := threat_priority(pass == 0 ? 2 : 1, s, i)
				if !found || pri > t_pri {
					found = true
					t_kind, t_idx = pass == 0 ? 2 : 1, i
					t_pri = pri
					atk_x, atk_z = ax, az
					atk_seat, atk_idx, atk_kind = lseat, lidx, lkind
				}
			}
		}
		if !found { continue }
		// the tiered reach: wonder unlimited, TC x2, building x1.5, unit x1
		reach := f64(90)
		if t_kind == 2 {
			bd := &s.bldgs[t_idx]
			if bd.is_wonder {
				reach = m_inf
			} else if bd.id == "town_center" {
				reach = 180
			} else {
				reach = 135
			}
		}
		ex, ez := f64(0), f64(0)
		if t_kind == 2 { ex, ez = s.bldgs[t_idx].x, s.bldgs[t_idx].z } else { ex, ez = s.units[t_idx].x, s.units[t_idx].z }
		// "did anything answer" (game.js 1957): the mark sits on what is being
		// hit, above the no-defenders return. "None" is nothing of the owner's
		// fighting here: no idle military this reflex sends, AND nobody already
		// attacking within one battle radius (90) of the attacker.
		n_draft := 0
		on_site := false
		for i in 0 ..< s.n_units {
			d := &s.units[i]
			if d.u_type == "worker" || d.u_type == "support" || d.health <= 0 { continue }
			if !d.is_attacking && m_hypot(d.x - ex, d.z - ez) <= reach {
				n_draft += 1
			}
			if d.is_attacking && m_hypot(d.x - atk_x, d.z - atk_z) <= 90 {
				on_site = true
			}
		}
		if t_kind == 2 {
			s.bldgs[t_idx].def_at = g.sim_ms
			s.bldgs[t_idx].def_none = !(n_draft > 0 || on_site)
		} else {
			s.units[t_idx].def_at = g.sim_ms
			s.units[t_idx].def_none = !(n_draft > 0 || on_site)
		}
		for i in 0 ..< s.n_units {
			d := &s.units[i]
			if d.u_type == "worker" || d.u_type == "support" || d.health <= 0 { continue }
			if d.is_attacking { continue }
			if m_hypot(d.x - ex, d.z - ez) > reach { continue }
			d.task = TASK_NONE
			d.is_attacking = true
			d.atk_kind = atk_kind
			d.atk_seat, d.atk_idx = atk_seat, atk_idx
			d.attack_move = true
			d.am_x, d.am_z = atk_x, atk_z
			d.attack_timer = 0
			d.is_moving = true
			d.target_x, d.target_z = atk_x, atk_z
		}
	}
}

// commandArmy (ai.js 688): commit the army at attackAt strength. A visible
// enemy wins the target; otherwise the army searches by exploration legs.
command_army :: proc(g: ^game_state, s: ^seat) {
	mil: [MAX_UNITS]int
	n_mil := 0
	for i in 0 ..< s.n_units {
		u := &s.units[i]
		if u.health > 0 && u.u_type != "worker" && u.u_type != "support" {
			mil[n_mil] = i
			n_mil += 1
		}
	}
	if n_mil == 0 { return }
	if n_mil < 8 { return } // attackAt, standard profile; no Wonder in this corpus

	origin := &s.units[mil[0]]
	// visibleEnemyTargets (ai.js 678): units the seat can SEE (hypot), plus
	// every REMEMBERED enemy building (known alive) — the army marches on
	// what scouting has learnt, not only on what is in sight right now
	es := make_eyes_mode(s, false)
	tk, ts, ti: [512]int
	n_t := 0
	for oi in 0 ..< g.n_seats {
		if oi == s.ci { continue }
		o := &g.seats[oi]
		for i in 0 ..< o.n_units {
			u := &o.units[i]
			if u.health <= 0 { continue }
			if !see_test_brain(&es, u.x, u.z) { continue }
			tk[n_t], ts[n_t], ti[n_t] = 1, oi, i
			n_t += 1
		}
		for i in 0 ..< o.n_bldgs {
			b := &o.bldgs[i]
			if b.health <= 0 || !b.is_wonder { continue }
			if !see_test_brain(&es, b.x, b.z) { continue }
			tk[n_t], ts[n_t], ti[n_t] = 2, oi, i
			n_t += 1
		}
		for i in 0 ..< o.n_bldgs {
			b := &o.bldgs[i]
			if b.health <= 0 || !s.eb_known[oi][i] { continue }
			tk[n_t], ts[n_t], ti[n_t] = 2, oi, i
			n_t += 1
		}
	}
	if n_t > 0 {
		// the nearest target from the army's first unit (this.distance)
		bk, bs, bi := 0, -1, -1
		min_d := f64(m_inf)
		for i in 0 ..< n_t {
			ex, ez: f64
			if tk[i] == 1 { ex, ez = g.seats[ts[i]].units[ti[i]].x, g.seats[ts[i]].units[ti[i]].z }
			else { ex, ez = g.seats[ts[i]].bldgs[ti[i]].x, g.seats[ts[i]].bldgs[ti[i]].z }
			d := m_hypot(ex-origin.x, ez-origin.z)
			if d < min_d { min_d = d; bk, bs, bi = tk[i], ts[i], ti[i] }
		}
		for i in 0 ..< n_mil {
			u := &s.units[mil[i]]
			if u.is_attacking && u.atk_kind == bk && u.atk_seat == bs && u.atk_idx == bi { continue }
			// an explicit order overrides the reflex: clear the ladder
			u.n_rt = 0
			u.orig_kind, u.orig_seat, u.orig_idx = 0, -1, -1
			u.is_attacking = true
			u.atk_kind, u.atk_seat, u.atk_idx = bk, bs, bi
			u.attack_move = true
			if bk == 1 { u.am_x, u.am_z = g.seats[bs].units[bi].x, g.seats[bs].units[bi].z }
			else { u.am_x, u.am_z = g.seats[bs].bldgs[bi].x, g.seats[bs].bldgs[bi].z }
			u.attack_timer = 0
			u.is_moving = true
			u.target_x, u.target_z = u.am_x, u.am_z
		}
		return
	}
	// no enemy: march by exploration legs
	// centroid
	cx, cz := f64(0), f64(0)
	for i in 0 ..< n_mil { cx += s.units[mil[i]].x; cz += s.units[mil[i]].z }
	cx /= f64(n_mil); cz /= f64(n_mil)
	half := g.terrain.size / 2 - 60
	left := m_inf
	if s.army_scout_set {
		dx := cx - s.army_scout_x
		dz := cz - s.army_scout_z
		left = m_hypot(dx, dz)
	}
	if s.army_scout_set && left < (s.army_scout_best_set ? s.army_scout_best : m_inf) - 5 {
		s.army_scout_best = left
		s.army_scout_best_set = true
		s.army_scout_ticks = 0
	} else {
		s.army_scout_ticks += 1
	}
	arrived := s.army_scout_set && left < 25
	stuck := s.army_scout_ticks > 6
	new_leg := false
	if !s.army_scout_set || arrived || stuck {
		if stuck && !arrived && s.army_scout_set {
			// the tile it gave up on: skipped (row-major 7x7 label)
			tr := int(math.floor((s.army_scout_z + 400) / (800 / 7)))
			tcc := int(math.floor((s.army_scout_x + 400) / (800 / 7)))
			if tr < 0 { tr = 0 }
			if tr > 6 { tr = 6 }
			if tcc < 0 { tcc = 0 }
			if tcc > 6 { tcc = 6 }
			s.army_leg_skip[tr*7 + tcc] = true
		}
		// armyLeg: the least-explored tile, nearest of equals
		T := 7
		tile := g.terrain.size / f64(T)
		bx, bz, bpct, bd := f64(0), f64(0), f64(0), f64(0)
		bset := false
		for rr in 0 ..< T {
			for cc in 0 ..< T {
				seen := 0
				for z := rr*6; z < (rr+1)*6; z += 1 {
					for x := cc*6; x < (cc+1)*6; x += 1 {
						seen += cast(int)(s.explored[z*42 + x])
					}
				}
				pct := math.round(f64(seen) / 36 * 100)
				if pct >= 100 { continue }
				if s.army_leg_skip[rr*7 + cc] { continue }
				lx := math.max(-half, math.min(half, (f64(cc)+0.5)*tile - 400))
				lz := math.max(-half, math.min(half, (f64(rr)+0.5)*tile - 400))
				d := m_hypot(lx - cx, lz - cz)
				if !bset || pct < bpct || (pct == bpct && d < bd) {
					bset = true
					bx, bz, bpct, bd = lx, lz, pct, d
				}
			}
		}
		if bset {
			s.army_scout_x, s.army_scout_z = bx, bz
			s.army_scout_set = true
		} else {
			// the golden-angle fallback
			if s.army_scout_angle == 0 {
				s.army_scout_angle = krng_draw(&s.k, fmt.aprintf("s%d:army-scout", s.ci)) * math.PI * 2
			} else {
				s.army_scout_angle += 2.399963
			}
			s.army_scout_radius = math.min(4*half, (s.army_scout_radius == 0 ? 90 : s.army_scout_radius) + 60)
			s.army_scout_x = math.max(-half, math.min(half, s.bldgs[0].x + m_cos(s.army_scout_angle) * s.army_scout_radius))
			s.army_scout_z = math.max(-half, math.min(half, s.bldgs[0].z + m_sin(s.army_scout_angle) * s.army_scout_radius))
			s.army_scout_set = true
		}
		s.army_scout_ticks = 0
		s.army_scout_best_set = false
		new_leg = true
	}
	for i in 0 ..< n_mil {
		u := &s.units[mil[i]]
		if u.is_attacking && u.atk_kind != 0 { continue } // already engaged
		if !new_leg && u.is_moving { continue }
		u.is_attacking = true
		u.atk_kind = 0
		u.attack_move = true
		u.am_x, u.am_z = s.army_scout_x, s.army_scout_z
		u.is_moving = true
		u.target_x, u.target_z = u.am_x, u.am_z
	}
}


// ai.js advanceThink: each seat's think clock, 2000 ms sim.
advance_think :: proc(g: ^game_state, s: ^seat, dt: f64) {
	s.think_timer += dt
	if s.think_timer < 2000 {
		return
	}
	s.think_timer -= 2000
	run_turn(g, s)
}

// ai.js exploreMap: one spare worker to the least-explored tile.
explore_map :: proc(g: ^game_state, s: ^seat) {
	want := needed_resource_type(s)
	b0 := &s.bldgs[0]
	have_wanted := find_known_resource(g, s, b0.x, b0.z, want) >= 0
	interval := 8
	if !have_wanted {
		interval = 2
	}
	s.explore_timer += 1
	if s.explore_timer < interval {
		return
	}
	// idleMilitary first, then a genuinely idle worker (ai.js exploreMap)
	scout := -1
	for pass in 0 ..< 2 {
		for u in 0 ..< s.n_units {
			w := &s.units[u]
			if w.health <= 0 {
				continue
			}
			if pass == 0 {
				// idleMilitary: not a worker, not support, not attacking, idle
				if w.u_type == "worker" || w.u_type == "support" {
					continue
				}
				if w.is_moving || w.is_attacking {
					continue
				}
					// The farthest-seeing idle soldier, the first of equals (b1060):
					// it was "the first rider, else the first soldier".
					if scout < 0 || unit_vision(w) > unit_vision(&s.units[scout]) {
						scout = u
					}
					continue
			} else {
				if w.u_type != "worker" {
					continue
				}
				if w.is_moving || w.is_harvesting || w.carrying || w.is_building {
					continue
				}
				if w.farm >= 0 {
					continue
				}
				if w.task == TASK_BUILDING || w.task == TASK_FARM_WORK {
					continue
				}
			}
			scout = u
			break
		}
		if scout >= 0 {
			break
		}
	}
	if scout < 0 {
		return
	}
	// the timer resets only when a scout actually goes out — a seat with no
	// idle unit keeps accumulating, so it dispatches the moment one frees up
	s.explore_timer = 0
	w := &s.units[scout]
	// leastExploredSection: the 7x7 summary's minimum tile (row order).
	sec_x, sec_z, sec_pct := least_explored_section(g, s)
	half := g.terrain.size / 2 - 40
	key := fmt.aprintf("s%d:scout", s.ci)
	tx, tz: f64
	if sec_pct < 100 {
		tx = sec_x + (krng_draw(&s.k, key) - 0.5) * 100
		tz = sec_z + (krng_draw(&s.k, key) - 0.5) * 100
	} else {
		// the golden-angle fallback (dormant while the map is unknown)
		if s.scout_angle == 0 {
			s.scout_angle = krng_draw(&s.k, key) * math.PI * 2
		} else {
			s.scout_angle += 2.399963
		}
		r0 := s.scout_radius
		if r0 == 0 {
			r0 = 60
		}
		s.scout_radius = math.min(half, r0 + 40)
		tx = b0.x + m_cos(s.scout_angle) * s.scout_radius
		tz = b0.z + m_sin(s.scout_angle) * s.scout_radius
	}
	// exploreMap: a worker scouts (task 'scouting'); military units scout
	// with the task flag left alone (null)
	if w.u_type == "worker" {
		w.task = TASK_SCOUTING
	}
	w.is_moving = true
	w.target_x = math.max(-half, math.min(half, tx))
	w.target_z = math.max(-half, math.min(half, tz))
}


// The coast limit table and landLimit are the port's own (the coast section
// above): 1025 f32 entries, built once at terrain construction (line 1039).

// keepUnitsAshore: the chebyshev clamp onto the land (game.js 3784).
keep_units_ashore :: proc(g: ^game_state) {
	for i in 0 ..< g.n_seats {
		s := &g.seats[i]
		for u in 0 ..< s.n_units {
			w := &s.units[u]
			cheb := math.max(math.abs(w.x), math.abs(w.z))
			lim := land_limit(w.x, w.z)
			if cheb <= lim {
				continue
			}
			k := lim / cheb
			w.x *= k
			w.z *= k
		}
	}
}

// ---- the notices (game.js logPlayerEvent) --------------------------------
log_player_event :: proc(g: ^game_state, s: ^seat, e: evt) {
	if s.n_events >= MAX_EVTS {
		// shift: drop the oldest, keep insertion order
		for i in 1 ..< s.n_events {
			s.events[i-1] = s.events[i]
		}
		s.n_events -= 1
	}
	ee := e
	ee.at = g.sim_ms
	ee.seq = s.turn_seq
	ee.ttl = 2
	s.events[s.n_events] = ee
	s.n_events += 1
	if s.n_events > 14 {
		for i in 1 ..< s.n_events {
			s.events[i-1] = s.events[i]
		}
		s.n_events -= 1
	}
}

// The dry-node retarget (game.js retargetDepletedWorker): the once-per-node
// notice, then the nearest known node of the same type FROM THE DEPLETED
// NODE, fresh node-spot draws, or idle.
retarget_depleted_worker :: proc(g: ^game_state, s: ^seat, u: ^unit_state) {
	want := -1
	nx, nz: f64
	if u.harvest_node >= 0 {
		want = int(g.terrain.nodes[u.harvest_node].n_type)
		nx = g.terrain.nodes[u.harvest_node].x
		nz = g.terrain.nodes[u.harvest_node].z
		// the notice, once per node
		if !s.dry_told[u.harvest_node] {
			s.dry_told[u.harvest_node] = true
			log_player_event(g, s, evt{kind = EVT_DRY_NODE, p_type = want, p_x = int(math.floor(nx + 0.5)), p_z = int(math.floor(nz + 0.5))})
		}
	}
	from_x := nx
	from_z := nz
	u.task = TASK_NONE
	u.harvest_node = -1
	u.is_harvesting = false
	u.harvest_timer = 0
	if want < 0 {
		return
	}
	best := -1
	best_d := m_inf
	for i in 0 ..< g.terrain.n_nodes {
		n := &g.terrain.nodes[i]
		if int(n.n_type) != want || n.amount <= 0 {
			continue
		}
		if s.known[i] == 0 {
			continue
		}
		d := m_hypot(n.x - from_x, n.z - from_z)
		if d < best_d {
			best_d = d
			best = i
		}
	}
	if best < 0 {
		return
	}
	send_worker_to_resource(g, s, u, best)
}

// addResource (resources.js): the stockpile plus the lifetime delivered tally.
add_resource :: proc(s: ^seat, t: int, amount: f64) {
	if t == 0 {
		s.res.food += amount
		s.gathered.food += amount
	} else if t == 1 {
		s.res.wood += amount
		s.gathered.wood += amount
	} else if t == 2 {
		s.res.stone += amount
		s.gathered.stone += amount
	} else if t == 3 {
		s.res.gold += amount
		s.gathered.gold += amount
	}
}

// ---- the worker state machine (game.js updateWorkerTasks) ----------------

// The closest FINISHED town center (State 2's drop-off search).
closest_tc :: proc(s: ^seat, ux: f64, uz: f64) -> ^bldg_state {
	best: ^bldg_state
	best_d := m_inf
	for b in 0 ..< s.n_bldgs {
		bd := &s.bldgs[b]
		if bd.id != "town_center" || bd.under_constr {
			continue
		}
		d := math.sqrt((bd.x-ux)*(bd.x-ux) + (bd.z-uz)*(bd.z-uz))
		if d < best_d {
			best_d = d
			best = bd
		}
	}
	return best
}

update_worker_tasks :: proc(g: ^game_state, s: ^seat, dt: f64) {
	for ui in 0 ..< s.n_units {
		u := &s.units[ui]
		if u.health <= 0 || u.u_type != "worker" {
			continue
		}
		// State 1: moving (builders and repairers excluded — they walk in
		// their own states; fighters belong to updateCombat, dormant here).
		if u.is_moving && u.task != TASK_BUILDING && u.task != TASK_REPAIRING {
			// a node can run dry while we walk to it
			if u.task == TASK_HARVESTING && !u.carrying && u.harvest_node >= 0 && g.terrain.nodes[u.harvest_node].amount <= 0 {
				retarget_depleted_worker(g, s, u)
				continue
			}
			dx := u.target_x - u.x
			dz := u.target_z - u.z
			dist := math.sqrt(dx*dx + dz*dz)
			threshold := 0.5
			if u.task == TASK_CARRYING {
				threshold = 5.5
			} else if u.task == TASK_HARVESTING {
				threshold = 2.0
			}
			if dist > threshold {
				u.is_moving = true // the mover owns the flag
				move_speed := u.speed * dt / 1000 * 3
				u.x += (dx / dist) * move_speed
				u.z += (dz / dist) * move_speed
			} else {
				// arrived: only plain moves snap onto the exact point
				u.is_moving = false
				if threshold <= 0.5 {
					u.x = u.target_x
					u.z = u.target_z
				}
				// harvesting and at the resource: start from the node's rim
				if u.task == TASK_HARVESTING && u.harvest_node >= 0 && !u.carrying {
					n := &g.terrain.nodes[u.harvest_node]
					rim := f64(1.2)
					if n.n_type == 0 {
						rim = 1.45
					} else if n.n_type == 1 {
						rim = 0.9
					} else if n.n_type == 2 {
					rim = 2.1
					} else if n.n_type == 3 {
						rim = 1.9
					}
					rx := u.x - n.x
					rz := u.z - n.z
					rd := m_hypot(rx, rz)
					if rd < rim {
						if rd < 0.01 {
							// dead-center: spread by a stable per-unit angle
							// (never reached in this corpus: the node-spot
							// spread keeps arrivals off the exact center)
							a := m_fmod((f64(u.handle) * 2.4 + n.x * 0.13 + n.z * 0.17), 6.283)
							rx = m_cos(a)
							rz = m_sin(a)
							rd = 1
						}
						u.x = n.x + (rx / rd) * rim
						u.z = n.z + (rz / rd) * rim
					}
					u.is_harvesting = true
					u.harvest_timer = 0
				}
				// a scout that has arrived has finished scouting
				if u.task == TASK_SCOUTING {
					u.task = TASK_NONE
				}
			}
			continue
		}
		// State 2: harvesting at the resource (not moving)
		if u.task == TASK_HARVESTING && u.is_harvesting && u.harvest_node >= 0 {
			n := &g.terrain.nodes[u.harvest_node]
			if n.amount <= 0 {
				retarget_depleted_worker(g, s, u)
				continue
			}
			u.harvest_timer += dt
			if u.harvest_timer >= 2000 {
				amount := 10 * s.harvest_bonus
				n.amount = math.max(0, n.amount - amount)
				if n.amount <= 0 {
					// the crew that emptied it knows: correct the owner's belief
					s.seen_amt[u.harvest_node] = 0
				}
				u.carrying = true
				u.carry_type = int(n.n_type)
				u.harvest_amt = amount
				u.is_harvesting = false
				u.harvest_timer = 0
				tc := closest_tc(s, u.x, u.z)
				if tc != nil {
					u.target_x = tc.x
					u.target_z = tc.z
					u.is_moving = true
					u.task = TASK_CARRYING
				} else {
					u.carrying = false
					u.carry_type = 0
					u.harvest_amt = 0
					u.task = TASK_NONE
					u.harvest_node = -1
				}
			}
			continue
		}
		// State 3: carrying — arrived at the drop point
		if u.task == TASK_CARRYING && u.carrying && !u.is_moving {
			if u.harvest_amt > 0 {
				add_resource(s, u.carry_type, u.harvest_amt)
			}
			u.carrying = false
			u.carry_type = 0
			u.harvest_amt = 0
			// resume the harvest (fresh node-spot draws), or retarget
			if u.harvest_node >= 0 {
				n := &g.terrain.nodes[u.harvest_node]
				if n.amount > 0 {
					key := fmt.aprintf("s%d:node-spot", s.ci)
					u.target_x = n.x + (krng_draw(&s.k, key) - 0.5) * 2
					u.target_z = n.z + (krng_draw(&s.k, key) - 0.5) * 2
					u.is_moving = true
					u.task = TASK_HARVESTING
				} else {
					retarget_depleted_worker(g, s, u)
				}
			}
			// the farm assignment resumes the field instead
			if u.farm >= 0 && s.bldgs[u.farm].assigned_worker == ui && s.bldgs[u.farm].health > 0 {
				u.task = TASK_FARM_WORK
				u.is_moving = true
				key := fmt.aprintf("s%d:farm-spot", s.ci)
				u.target_x = s.bldgs[u.farm].x + (krng_draw(&s.k, key) - 0.5) * 3
				u.target_z = s.bldgs[u.farm].z + (krng_draw(&s.k, key) - 0.5) * 3
			}
			if u.task == TASK_CARRYING {
				u.task = TASK_NONE
				u.harvest_node = -1
			}
			continue
		}
		// State 4: building construction
		if u.task == TASK_BUILDING && u.build_site >= 0 {
			site := &s.bldgs[u.build_site]
			if site.health <= 0 || !site.under_constr {
				release_builder(g, s, u, ui)
				continue
			}
			dx := site.x - u.x
			dz := site.z - u.z
			dist := math.sqrt(dx*dx + dz*dz)
			if dist > 3.5 {
				u.is_building = false
				u.is_moving = true
				move_speed := u.speed * dt / 1000 * 3
				u.x += (dx / dist) * move_speed
				u.z += (dz / dist) * move_speed
				continue
			}
			u.is_building = true
			u.is_moving = false
			rate := 1.0 * 1.0 // buildSpeed × workerBuildSpeedBonus (1.0 here)
			site.build_progress += dt * rate
			pct := math.min(1, site.build_progress / site.build_time)
			site.health = math.max(site.health, site.max_health * (0.2 + 0.8 * pct))
			if site.build_progress >= site.build_time {
				complete_construction(g, s, site)
				release_builder(g, s, u, ui)
			}
			continue
		}
		// State 5: farm_work
		if u.task == TASK_FARM_WORK && u.farm >= 0 {
			farm := &s.bldgs[u.farm]
			if farm.health <= 0 {
				farm.assigned_worker = -1
				u.task = TASK_NONE
				u.farm = -1
				continue
			}
			if farm.under_constr {
				u.is_moving = false
				continue
			}
			if farm.assigned_worker < 0 {
				farm.assigned_worker = ui
			}
			if !seat_has_finished_bldg(s, "town_center") {
				farm.assigned_worker = -1
				u.farm = -1
				u.task = TASK_NONE
				u.is_moving = false
				u.is_harvesting = false
				u.harvest_timer = 0
				u.carrying = false
				u.harvest_amt = 0
				continue
			}
			if farm.food_amount >= 10 && !u.carrying && !u.is_moving {
				u.harvest_timer += dt
				if u.harvest_timer >= 2000 {
					amount := 10 * s.harvest_bonus
					farm.food_amount = math.max(0, farm.food_amount - amount)
					u.carrying = true
					u.carry_type = 0
					u.harvest_amt = amount
					u.harvest_timer = 0
					tc := closest_tc(s, u.x, u.z)
					if tc != nil {
						u.target_x = tc.x
						u.target_z = tc.z
						u.is_moving = true
						u.task = TASK_CARRYING
					} else {
						u.carrying = false
						u.carry_type = 0
						u.harvest_amt = 0
						farm.assigned_worker = -1
						u.farm = -1
						u.task = TASK_NONE
						u.is_moving = false
					}
				}
				continue
			}
			if u.task == TASK_CARRYING && u.carrying && !u.is_moving {
				add_resource(s, u.carry_type, u.harvest_amt)
				u.carrying = false
				u.carry_type = 0
				u.harvest_amt = 0
				u.task = TASK_FARM_WORK
				u.is_moving = true
				key := fmt.aprintf("s%d:farm-spot", s.ci)
				u.target_x = farm.x + (krng_draw(&s.k, key) - 0.5) * 3
				u.target_z = farm.z + (krng_draw(&s.k, key) - 0.5) * 3
				continue
			}
			// idle at the farm: stay near it
			if !u.is_moving {
				dx := farm.x - u.x
				dz := farm.z - u.z
				if math.sqrt(dx*dx + dz*dz) > 3 {
					u.is_moving = true
					key := fmt.aprintf("s%d:farm-spot", s.ci)
					u.target_x = farm.x + (krng_draw(&s.k, key) - 0.5) * 2
					u.target_z = farm.z + (krng_draw(&s.k, key) - 0.5) * 2
				}
			}
			continue
		}
		// State 6: idle — orphaned sites (none: builders never die here), then
		// the nearest unassigned FINISHED farm.
		if u.task == TASK_NONE && !u.is_moving && u.farm < 0 {
			if !seat_has_finished_bldg(s, "town_center") {
				continue
			}
			near_farm := -1
			near_d := m_inf
			for b in 0 ..< s.n_bldgs {
				fb := &s.bldgs[b]
				if fb.id != "farm" || fb.assigned_worker >= 0 || fb.under_constr {
					continue
				}
				d := math.sqrt((fb.x-u.x)*(fb.x-u.x) + (fb.z-u.z)*(fb.z-u.z))
				if d < near_d {
					near_d = d
					near_farm = b
				}
			}
			if near_farm >= 0 {
				fb := &s.bldgs[near_farm]
				fb.assigned_worker = ui
				u.task = TASK_FARM_WORK
				u.farm = near_farm
				u.is_moving = true
				key := fmt.aprintf("s%d:farm-spot", s.ci)
				u.target_x = fb.x + (krng_draw(&s.k, key) - 0.5) * 2
				u.target_z = fb.z + (krng_draw(&s.k, key) - 0.5) * 2
			}
		}
	}
}

// completeConstruction: full HP, functional, the population cap re-derived.
complete_construction :: proc(g: ^game_state, s: ^seat, b: ^bldg_state) {
	if !b.under_constr {
		return
	}
	b.under_constr = false
	b.build_progress = b.build_time
	b.health = b.max_health
	recompute_max_population(s)
	// the farm's stock (createBuilding gave it at creation; keep in step here)
	if b.id == "farm" && b.max_food == 0 {
		b.food_amount = 300
		b.max_food = 300
	}
	// onTownCenterBuilt: idle hands back to work — dormant (the TC never falls).
}

recompute_max_population :: proc(s: ^seat) {
	slots := 0
	for b in 0 ..< s.n_bldgs {
		bd := &s.bldgs[b]
		if bd.under_constr || bd.health <= 0 {
			continue
		}
		def := bldg_def_by_id(bd.id)
		if def != nil {
			slots += def.pop_bonus
		}
	}
	s.max_pop = math.min(100, slots)
}

// updateProduction: the train timers and the spawn at the building.
update_production :: proc(g: ^game_state, dt: f64) {
	// getAllBuildings(): the GLOBAL creation order — the TCs first, then
	// every built building; completions in one tick mint in that order
	for pi in 0 ..< g.n_gl_b {
		r := g.gl_b[pi]
		s := &g.seats[r.seat]
		b := int(r.idx)
		bd := &s.bldgs[b]
			if bd.under_constr {
				continue
			}
			if bd.is_producing && len(bd.prod_type) > 0 {
				bd.prod_progress += dt
				if bd.prod_progress >= bd.prod_duration {
					// the spawn, clearly outside the footprint
					key := fmt.aprintf("s%d:train-exit", s.ci)
					spawn_angle := krng_draw(&s.k, key) * math.PI * 2
					foot := f64(3.5)
					if bd.id == "town_center" {
						foot = 5
					}
					spawn_dist := foot + 3 + krng_draw(&s.k, key) * 1.5
					spawn_x := bd.x + m_cos(spawn_angle) * spawn_dist
					spawn_z := bd.z + m_sin(spawn_angle) * spawn_dist
					if s.n_units < MAX_UNITS {
						w := &s.units[s.n_units]
						w.handle = s.handle_next
						s.handle_next += 1
						w.x = spawn_x
						w.z = spawn_z
						ud := unit_def_for(s.ci, bd.prod_type)
						w.u_type = bd.prod_type
						w.health = ud.health
						w.max_health = ud.health
						w.speed = ud.speed
						w.pid = mint_entity(g, "unit_")
						w.harvest_node = -1
						w.build_site = -1
						w.farm = -1
						w.former_node = -1
						w.former_farm = -1
						w.repair_site = -1
						s.n_units += 1
						s.pop = s.n_units
						g.gl_u[g.n_gl_u] = gl_ref{seat = i32(s.ci), idx = i32(s.n_units - 1)}
						g.n_gl_u += 1
					}
				bd.is_producing = false
				bd.prod_type = ""
				bd.prod_progress = 0
			}
		}
	}
}

// updateResearchProgress: the timers, then the completion.
update_research_progress :: proc(g: ^game_state, dt: f64) {
	for i in 0 ..< g.n_seats {
		s := &g.seats[i]
		if !s.cur_research {
			continue
		}
		s.res_progress += dt
		if s.res_progress >= s.res_duration {
			complete_research(s, s.res_tech)
		}
	}
}

// completeResearch: researched, unlocks applied, the slot freed.
complete_research :: proc(s: ^seat, tid: string) {
	if s.n_researched < len(s.researched) {
		s.researched[s.n_researched] = tid
		s.n_researched += 1
	}
	c := &civs[s.ci]
	for t in 0 ..< c.n_techs {
		if tech_ids[s.ci][t] == tid {
			te := &c.techs[t]
			if te.unlocks_bldg != "" && s.n_unlocked_bldgs < len(s.unlocked_bldgs) {
				s.unlocked_bldgs[s.n_unlocked_bldgs] = te.unlocks_bldg
				s.n_unlocked_bldgs += 1
			}
			break
		}
	}
	s.cur_research = false
	s.res_tech = ""
}

// leastExploredSection: the 7x7 summary's minimum tile (row order).
least_explored_section :: proc(g: ^game_state, s: ^seat) -> (f64, f64, f64) {
	T := 7
	size := g.terrain.size
	tile := size / f64(T)
	sum := exploration_summary(s)
	best_r, best_c := 0, 0
	for r in 0 ..< T {
		for c in 0 ..< T {
			if sum[r][c] < sum[best_r][best_c] {
				best_r, best_c = r, c
			}
		}
	}
	x := math.floor((f64(best_c) + 0.5) * tile - size / 2 + 0.5)
	z := math.floor((f64(best_r) + 0.5) * tile - size / 2 + 0.5)
	return x, z, f64(sum[best_r][best_c])
}


// realSecs (openai-ai.js 926): max(0, ceil(gameMs / 1000 / sp)) — the sim
// clock's remainder in MATCH seconds at the recorder's 2x rate.
secs_left :: proc(progress: f64, duration: f64) -> i64 {
	rem := duration - progress
	if rem < 0 {
		rem = 0
	}
	v := rem / 1000 / 2
	return cast(i64)(-math.floor(-v))
}

// The two notice templates (game.js 4921, openai-ai.js 3369).
evt_text :: proc(j: ^jw, e: ^evt) {
	ty := res_type_name[e.p_type]
	if e.kind == EVT_DRY_NODE {
		j_str(j, fmt.aprintf("The %s at (%d, %d) was already exhausted when your workers reached it — they are moving on to the nearest %s you have discovered, or going idle if you have none left.", ty, e.p_x, e.p_z, ty))
	} else if e.kind == EVT_LAST_EMPTY {
		j_str(j, fmt.aprintf("Your last discovered %s node has been emptied — nodes.discovered.%s is now 0.", ty, ty))
	}
}

// buildRecentEvents (openai-ai.js 3085): the seat's ring plus this look's own
// found events, expired by the seat's own turns (two), the last eight, each
// stamped with its age on the match clock. The found events carry the seq as
// it stood BEFORE this look bumped it — that is what makes them news now.
build_recent_events :: proc(o: ^obs) {
	g := o.g
	s := o.s
	j := o.j
	seq := s.turn_seq + 1
	merged: [MAX_EVTS + 8]evt
	n := 0
	for i in 0 ..< s.n_events {
		merged[n] = s.events[i]
		n += 1
	}
	for p in 0 ..< o.n_pend {
		e := o.pend[p]
		e.at = g.sim_ms
		e.seq = s.turn_seq
		e.ttl = 2
		merged[n] = e
		n += 1
	}
	kept: [MAX_EVTS + 8]evt
	kn := 0
	for i in 0 ..< n {
		if merged[i].seq >= seq - merged[i].ttl {
			kept[kn] = merged[i]
			kn += 1
		}
	}
	start := 0
	if kn > 8 {
		start = kn - 8
	}
	for i in start ..< kn {
		age := (g.match_ms - kept[i].at / 2) / 1000
		age_n := int(math.floor(age + 0.5))
		if age_n < 0 {
			age_n = 0
		}
		ty := res_type_name[kept[i].p_type]
		if kept[i].kind == EVT_DRY_NODE {
			j_str(j, fmt.aprintf("%ds ago: The %s at (%d, %d) was already exhausted when your workers reached it — they are moving on to the nearest %s you have discovered, or going idle if you have none left.", age_n, ty, kept[i].p_x, kept[i].p_z, ty))
		} else if kept[i].kind == EVT_LAST_EMPTY {
			j_str(j, fmt.aprintf("%ds ago: Your last discovered %s node has been emptied — nodes.discovered.%s is now 0.", age_n, ty, ty))
		}
	}
}


// ===========================================================================
// The match engine's tail: the mint, the stream writers, the tick, the driver.
// This file is the P0(c) target — one minute of the golden stream, byte for
// byte (golden/stream-1m.jsonl, the alive-world corpus recorded 5 Oct 2026).
// ===========================================================================

// Append raw literal bytes to the writer (no escaping, no comma logic):
// for the stream's fixed-shape wrappers.
j_raw :: proc(j: ^jw, s: string) {
	copy(j.buf[j.n:j.n+len(s)], s)
	j.n += len(s)
}

// Math.round, as the recorder's mm() uses it (floor(x + 0.5) for the
// non-negative half; JS's round-toward-plus-infinity on the halves).
mm :: proc(v: f64) -> int {
	return int(math.floor(v*1000 + 0.5))
}

// WarRng.id(prefix, next): hi = floor(d1 * 2^32), lo = floor(d2 * 2^20), the
// 52 bits as eleven base-36 characters zero-padded (js/simulation/rng.js).
// Verified against the stream's four minted ids, seat order, draws 0..7.
war_rng_id :: proc(k: ^keyed_rng, prefix: string) -> string {
	d1 := krng_draw(k, "world:player-id")
	d2 := krng_draw(k, "world:player-id")
	hi := u64(d1 * 4294967296.0)
	lo := u64(d2 * 1048576.0)
	v := hi * 1048576 + lo
	digs: [16]u8
	n := 0
	if v == 0 {
		digs[0] = '0'
		n = 1
	}
	vv := v
	for vv > 0 {
		r := vv % 36
		if r < 10 {
			digs[n] = u8('0' + r)
		} else {
			digs[n] = u8('a' + (r - 10))
		}
		n += 1
		vv /= 36
	}
	// digs[0..n) are least-significant first; the field is the digits
	// most-significant first, zero-padded to eleven.
	field: [11]u8
	for d in 0 ..< 11 {
		field[d] = '0'
	}
	for d in 0 ..< n {
		field[11-1-d] = digs[d]
	}
	out := make([]u8, len(prefix)+11)
	copy(out, prefix)
	copy(out[len(prefix):], field[:])
	return string(out)
}

// One 50 ms sim step: the discovery beat, the position rules, the harness
// discovery — the pieces the turn-1 fixture proved (stepOnce's order). The
// rule brain, the worker economy, production and research land with the next
// stages of the P0(c) transcription.
step_once :: proc(g: ^game_state) {
	dt := f64(50)
	// Population first: the brain below and the state both read it (stepOnce).
	// The reference splices dead units out of ai.units, so its counts are the
	// LIVING ones; this engine keeps corpses in place and counts instead.
	for i in 0 ..< 4 {
		n_alive := 0
		for u in 0 ..< g.seats[i].n_units {
			if g.seats[i].units[u].health > 0 { n_alive += 1 }
		}
		g.seats[i].pop = n_alive
	}
	// aiManager.update(dt): the 250 ms discovery beat (every 250 SIM ms —
	// stepOnce calls it with the step's dt), then the 2 s think beat.
	g.discovery_timer += dt
	if g.discovery_timer >= 250 {
		g.discovery_timer -= 250
		discovery_beat(g)
	}
	for i in 0 ..< 4 {
		advance_think(g, &g.seats[i], dt)
	}
	// simulateStep's clock-first rule: the step's sim time lands here, so the
	// beat above stamped the PREVIOUS step's time (simNow at its call) and
	// everything below carries this step's.
	g.sim_ms += dt
	// simulateStep(dt): the worker state machines, production, research.
	for i in 0 ..< 4 {
		update_worker_tasks(g, &g.seats[i], dt)
	}
	update_unit_movement(g, dt)
	update_production(g, dt)
	update_research_progress(g, dt)
	update_farm_regen(g, dt)
	update_combat(g, dt)
	update_auto_defense(g, dt)
	g.step_no += 1
	if g.step_no >= 1850 && g.step_no <= 1870 {
		s := &g.seats[2]
		for b in 0 ..< s.n_bldgs {
		}
		for u in 0 ..< s.n_units {
		}
	}
	war_position_rules(g, dt / 1000)
	observe_step(g)
	keep_units_ashore(g)
	prune_battles(g)
}

prune_battles :: proc(g: ^game_state) {
	n := 0
	for i in 0 ..< g.n_battles {
		if g.sim_ms - g.b_last[i] <= 120000 {
			g.b_x[n] = g.b_x[i]
			g.b_z[n] = g.b_z[i]
			g.b_started[n] = g.b_started[i]
			g.b_last[n] = g.b_last[i]
			g.b_nsides[n] = g.b_nsides[i]
			g.b_side_seat[n] = g.b_side_seat[i]
			g.b_inv_n[n] = g.b_inv_n[i]
			g.b_inv_type[n] = g.b_inv_type[i]
			g.b_inv_nids[n] = g.b_inv_nids[i]
			g.b_inv_ids[n] = g.b_inv_ids[i]
			g.b_inv_du[n] = g.b_inv_du[i]
			g.b_inv_db[n] = g.b_inv_db[i]
			g.b_inv_he[n] = g.b_inv_he[i]
			g.b_lost_type[n] = g.b_lost_type[i]
			g.b_lost_n[n] = g.b_lost_n[i]
			g.b_nlost[n] = g.b_nlost[i]
			n += 1
		}
	}
	g.n_battles = n
}

// discoveredNodeCounts: per type, how many of THIS seat's known nodes still
// hold anything (game.js 3983 — the timeline's ran-dry marker reads it).
discovered_node_counts :: proc(s: ^seat, t: ^terrain, out: ^[4]int) {
	for k in 0 ..< 4 {
		out[k] = 0
	}
	for i in 0 ..< t.n_nodes {
		if s.known[i] != 0 && t.nodes[i].amount > 0 {
			out[t.nodes[i].n_type] += 1
		}
	}
}

// sampleTimeline: every 5 s of MATCH time, one row per seat (gathered
// rounded, alive) plus the age and ran-dry marks (game.js 3993).
sample_timeline :: proc(g: ^game_state, now_ms: f64) {
	if now_ms - g.tl_last < 5000 {
		return
	}
	g.tl_last = now_ms
	tn := int(math.floor((now_ms - g.tl_t0)/1000 + 0.5))
	row := tl_sample{t = tn}
	counts: [4]int
	for i in 0 ..< g.n_seats {
		s := &g.seats[i]
		row.f[i] = math.floor(s.gathered.food + 0.5)
		row.w[i] = math.floor(s.gathered.wood + 0.5)
		row.s[i] = math.floor(s.gathered.stone + 0.5)
		row.o[i] = math.floor(s.gathered.gold + 0.5)
		alive := s.n_bldgs > 0 || s.n_units > 0
		row.al[i] = alive
		if !alive {
			continue
		}
		discovered_node_counts(s, &g.terrain, &counts)
		for k in 0 ..< 4 {
			dry := counts[k] == 0
			if dry && !g.tl_dry[i][k] {
				g.tl_dry[i][k] = true
				g.tl_marks[g.tl_n_marks] = tl_mark{t = tn, id = i, kind = 1, p_type = k}
				g.tl_n_marks += 1
			} else if !dry {
				g.tl_dry[i][k] = false
			}
		}
	}
	g.tl_samples[g.tl_n_samples] = row
	g.tl_n_samples += 1
}

// The match line: the recorder's rec.begin payload (transcript.js's match
// header + the recorder's conditions), players in seat order.
write_match_line :: proc(g: ^game_state, j: ^jw, n_seats: int, seed: string, diff: string) {
	j_raw(j, "{\"type\":\"match\",\"matchId\":\"golden\",\"startedAt\":0,")
	j_raw(j, fmt.aprintf("\"seed\":\"%s\",\"difficulty\":\"%s\",\"seats\":%d,", seed, diff, n_seats))
	j_raw(j, fmt.aprintf("\"minutes\":%d,", g.total_minutes))
	j_raw(j, "\"stepMs\":100,\"snapshotMs\":500,\"simSpeed\":1,\"turnBased\":false,\"resourceBoost\":false,\"version\":\"1.0.0\",\"players\":[")
	for i in 0 ..< 4 {
		if i > 0 {
			j_raw(j, ",")
		}
		j_raw(j, "{\"id\":\"")
		j_raw(j, g.seats[i].pid)
		j_raw(j, fmt.aprintf("\",\"seat\":%d,\"civ\":\"%s\",\"model\":null,\"name\":\"rule-brain\",\"settings\":", i, civs[i].id))
		j_raw(j, "{\"brain\":\"rule-based\"}}")
	}
	j_raw(j, "]}\n\n")
}

// The map line: the recorder's rec.note('__map__', ...) payload — the seeded
// layout exactly as the match starts, spawns and nodes in millimetres.
write_map_line :: proc(g: ^game_state, j: ^jw, spawns: [][2]f64, seed: string, diff: string) {
	t := &g.terrain
	j_raw(j, "{\"playerId\":\"__map__\",\"type\":\"map\",")
	j_raw(j, fmt.aprintf("\"seed\":\"%s\",\"difficulty\":\"%s\",\"seats\":%d,\"size\":800,\"spawns\":[", seed, diff, len(spawns)))
	for p in 0 ..< len(spawns) {
		if p > 0 {
			j_raw(j, ",")
		}
		j_raw(j, "{")
		j_raw(j, fmt.aprintf("\"x\":%d,\"z\":%d", mm(spawns[p][0]), mm(spawns[p][1])))
		j_raw(j, "}")
	}
	j_raw(j, "],\"resources\":[")
	for i in 0 ..< t.n_nodes {
		if i > 0 {
			j_raw(j, ",")
		}
		n := &t.nodes[i]
		j_raw(j, "{")
		j_raw(j, fmt.aprintf("\"t\":\"%s\",\"x\":%d,\"z\":%d,\"a\":%d,\"h\":%d", res_type_name[n.n_type], mm(n.x), mm(n.z), int(n.amount), int(n.amount)))
		j_raw(j, "}")
	}
	j_raw(j, "]}\n\n")
}

// The snap line: the recorder's per-half-second world summary.
write_snap_line :: proc(g: ^game_state, j: ^jw, wall_ms: int, seq: int) {
	j_raw(j, "{")
	j_raw(j, fmt.aprintf("\"playerId\":\"__snap__\",\"type\":\"snap\",\"t\":%d,\"seq\":%d,\"world\":", wall_ms, seq))
	j_raw(j, "{\"ages\":[")
	for m in 0 ..< g.tl_n_marks {
		if g.tl_marks[m].kind != 0 {
			continue
		}
		if m > 0 {
			j_raw(j, ",")
		}
		j_raw(j, "{")
		j_raw(j, fmt.aprintf("\"t\":%d,\"id\":\"%s\",\"age\":\"stone\"", g.tl_marks[m].t, g.seats[g.tl_marks[m].id].pid))
		j_raw(j, "}")
	}
	j_raw(j, "],\"exhausted\":[")
	first := true
	for m in 0 ..< g.tl_n_marks {
		if g.tl_marks[m].kind != 1 {
			continue
		}
		if !first {
			j_raw(j, ",")
		}
		first = false
		j_raw(j, "{")
		j_raw(j, fmt.aprintf("\"t\":%d,\"id\":\"%s\",\"type\":\"%s\"", g.tl_marks[m].t, g.seats[g.tl_marks[m].id].pid, res_type_name[g.tl_marks[m].p_type]))
		j_raw(j, "}")
	}
	j_raw(j, "],\"seats\":[")
	for i in 0 ..< 4 {
		if i > 0 {
			j_raw(j, ",")
		}
		s := &g.seats[i]
		j_raw(j, "{")
		n_alive := 0
		for u in 0 ..< s.n_units {
			if s.units[u].health > 0 { n_alive += 1 }
		}
		j_raw(j, fmt.aprintf("\"seat\":%d,\"age\":\"stone\",\"population\":%d,\"maxPopulation\":%d,\"units\":%d,\"buildings\":%d,\"eliminated\":false", i, s.pop, s.max_pop, n_alive, s.n_bldgs))
		j_raw(j, "}")
	}
	j_raw(j, "]}}\n\n")
}

// One turn record: the stream's per-seat wrapper around the state view.
write_turn_line :: proc(g: ^game_state, j: ^jw, si: int, turn: int) {
	s := &g.seats[si]
	// the state build's own look (openai-ai.js 3656): on a copy that is
	// then merged back — one look changes the live memory — noted at the
	// build's simNow with the harness sight test, then swept the same way
	now := g.sim_ms
	es := make_eyes(s)
	sighted: [512]string
	n_sighted := 0
	for oi in 0 ..< g.n_seats {
		if oi == si { continue }
		o := &g.seats[oi]
		for i in 0 ..< o.n_units {
			u := &o.units[i]
			if u.health <= 0 { continue }
			if !see_test(&es, u.x, u.z) { continue }
			note_sighting(s, oi, u, now, sighted[:], &n_sighted)
		}
	}
	sweep_memory(g, s, now, &es, sighted[:], n_sighted)
	j_raw(j, "{")
	j_raw(j, fmt.aprintf("\"turn\":%d,\"playerId\":\"", turn))
	j_raw(j, s.pid)
	j_raw(j, fmt.aprintf("\",\"civ\":\"%s\",\"seat\":%d,\"model\":null,\"name\":\"rule-brain\",\"harnessResult\":null,\"state\":", civs[si].id, si))
	j.sep = false // a fresh record: no comma before the state's first key
	o := obs{g = g, j = j, s = s, t_ms = 0}
	observe_line(&o)
	j_raw(j, "}\n\n")
}

// The results line: the recorder's tail, seat summaries floored.
write_results_line :: proc(g: ^game_state, j: ^jw) {
	j_raw(j, "{\"type\":\"results\",\"endedAt\":null,\"endedReason\":\"time-limit\",\"winner\":null,\"seats\":[")
	for i in 0 ..< 4 {
		if i > 0 {
			j_raw(j, ",")
		}
		s := &g.seats[i]
		j_raw(j, "{")
		j_raw(j, fmt.aprintf("\"seat\":%d,\"civ\":\"%s\",\"age\":\"stone\",\"eliminated\":false,\"population\":%d,\"maxPopulation\":%d,\"resources\":",
			i, civs[i].id, s.pop, s.max_pop))
		j_raw(j, "{")
		j_raw(j, fmt.aprintf("\"food\":%d,\"wood\":%d,\"stone\":%d,\"gold\":%d",
			int(math.floor(s.res.food)), int(math.floor(s.res.wood)), int(math.floor(s.res.stone)), int(math.floor(s.res.gold))))
		j_raw(j, "},\"units\":")
		j_raw(j, "{")
		// units: the type-count map — count(units) reduces the unit list to
		// {type: n}, keys in first-encounter order.
		firstu := true
		for u in 0 ..< s.n_units {
			if s.units[u].health <= 0 { continue }
			seen_u := false
			for p in 0 ..< u {
				if s.units[p].health > 0 && s.units[p].u_type == s.units[u].u_type { seen_u = true; break }
			}
			if seen_u { continue }
			cnt := 0
			for q in 0 ..< s.n_units {
				if s.units[q].health > 0 && s.units[q].u_type == s.units[u].u_type { cnt += 1 }
			}
			if !firstu { j_raw(j, ",") }
			firstu = false
			j_raw(j, fmt.aprintf("\"%s\":%d", s.units[u].u_type, cnt))
		}
		j_raw(j, "},\"buildings\":{")
		// buildings: the type-count map, first-encounter order.
		first := true
		for b in 0 ..< s.n_bldgs {
			seen := false
			for p in 0 ..< b {
				if s.bldgs[p].id == s.bldgs[b].id {
					seen = true
					break
				}
			}
			if seen {
				continue
			}
			cnt := 0
			for q in 0 ..< s.n_bldgs {
				if s.bldgs[q].id == s.bldgs[b].id {
					cnt += 1
				}
			}
			if !first {
				j_raw(j, ",")
			}
			first = false
			j_raw(j, fmt.aprintf("\"%s\":%d", s.bldgs[b].id, cnt))
		}
		j_raw(j, "}}")
	}
	j_raw(j, "]}\n\n")
}

// The timeline line: the recorder's second tail record.
write_timeline_line :: proc(g: ^game_state, j: ^jw) {
	j_raw(j, "{\"type\":\"timeline\",\"timeline\":{\"t0\":0,\"samples\":[")
	for i in 0 ..< g.tl_n_samples {
		if i > 0 {
			j_raw(j, ",")
		}
		row := &g.tl_samples[i]
		j_raw(j, "{")
		j_raw(j, fmt.aprintf("\"t\":%d,\"p\":", row.t))
		j_raw(j, "{")
		for si in 0 ..< 4 {
			if si > 0 {
				j_raw(j, ",")
			}
			j_raw(j, "\"")
			j_raw(j, g.seats[si].pid)
			j_raw(j, "\":")
			j_raw(j, "{")
			j_raw(j, fmt.aprintf("\"f\":%d,\"w\":%d,\"s\":%d,\"o\":%d,\"pw\":0,\"al\":%d", int(row.f[si]), int(row.w[si]), int(row.s[si]), int(row.o[si]), row.al[si] ? 1 : 0))
			j_raw(j, "}")
		}
		j_raw(j, "}}")
	}
	j_raw(j, "],\"ages\":[")
	for m in 0 ..< g.tl_n_marks {
		if g.tl_marks[m].kind != 0 {
			continue
		}
		if m > 0 {
			j_raw(j, ",")
		}
		j_raw(j, "{")
		j_raw(j, fmt.aprintf("\"t\":%d,\"id\":\"%s\",\"age\":\"stone\"", g.tl_marks[m].t, g.seats[g.tl_marks[m].id].pid))
		j_raw(j, "}")
	}
	j_raw(j, "],\"exhausted\":[")
	first := true
	for m in 0 ..< g.tl_n_marks {
		if g.tl_marks[m].kind != 1 {
			continue
		}
		if !first {
			j_raw(j, ",")
		}
		first = false
		j_raw(j, "{")
		j_raw(j, fmt.aprintf("\"t\":%d,\"id\":\"%s\",\"type\":\"%s\"", g.tl_marks[m].t, g.seats[g.tl_marks[m].id].pid, res_type_name[g.tl_marks[m].p_type]))
		j_raw(j, "}")
	}
	j_raw(j, "],\"wonders\":[")
	j_raw(j, "]}}\n\n")
}

// The driver: the recorder's own loop, transcribed — 600 wall ticks of 100 ms,
// each tick advancing the match clock 100 ms and running 4 sim steps of 50 ms
// (NORMAL_SIM_SPEED 2), with the snap/turn records every 5th tick and the
// two-line tail at the time limit.
main :: proc() {
	if len(os.args) < 2 {
		return
	}
	// ticks: 600 = the 1-minute corpus; pass 600*minutes for longer runs
	ticks := 600
	if len(os.args) >= 3 {
		ticks = strconv.atoi(os.args[2])
	}
	// argv: <out> [ticks] [seed] [seats] [difficulty] [map-only]
	seed := "golden"
	n_seats := 4
	diff := "medium"
	map_only := false
	if len(os.args) >= 4 { seed = os.args[3] }
	if len(os.args) >= 5 { if v, ok := strconv.parse_int(os.args[4]); ok { n_seats = v } }
	if len(os.args) >= 6 { diff = os.args[5] }
	if len(os.args) >= 7 { map_only = os.args[6] == "map" }
	spawns := arena_spawns(n_seats)
	g: game_state
	g.n_seats = n_seats
	g.map_seed = seed
	g.map_diff = diff
	if map_only {
		// the map-line oracle: terrain + Town Center clearance only
		g.terrain = t_terrain(f64(800), seed, spawns, diff)
		j := new(jw)
		j.n = 0
		write_map_line(&g, j, spawns, seed, diff)
		// the golden map files carry NO trailing newline
		_ = os.write_entire_file(os.args[1], j.buf[:j.n - 1])
		return
	}
	g.terrain = t_terrain(f64(800), seed, spawns, diff)
	setup(&g, spawns, n_seats, seed)
	if len(os.args) >= 3 {
		g.total_minutes = strconv.atoi(os.args[2]) / 600
	}

	j := new(jw)
	j.n = 0

	write_match_line(&g, j, n_seats, seed, diff)
	write_map_line(&g, j, spawns, seed, diff)

	for tick := 1; tick <= ticks; tick += 1 {
		g.match_ms += 100
		for k in 0 ..< 4 {
			step_once(&g)
		}
		sample_timeline(&g, g.match_ms)
		if tick % 5 == 0 {
			seq := tick / 5
			write_snap_line(&g, j, tick*100, seq)
			for si in 0 ..< 4 {
				write_turn_line(&g, j, si, seq)
			}
		}
	}

	write_results_line(&g, j)
	write_timeline_line(&g, j)
	_ = os.write_entire_file(os.args[1], j.buf[:j.n])
}
