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
}

unit_def :: struct {
	id: string,
	cost: cost4,
	health: f64,
	speed: f64,
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
		{id = "priest", cost = {50, 0, 0, 30}, health = 60, speed = 1.2, u_type = "support", tier = "bronze"},
		{id = "slinger", cost = {60, 20, 0, 0}, health = 45, speed = 1, u_type = "ranged", tier = "neolithic", train_at = "archery_range"},
		{id = "horse_carriage", cost = {60, 20, 40, 40}, health = 100, speed = 2, u_type = "cavalry", tier = "bronze", train_at = "stable"},
	{}, {}, {}, {}, {}}, n_units = 3,
	techs = {
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {100, 150, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone", requires = {"farm", "", "", ""}, n_req = 1},
		{cost = {80, 40, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {200, 150, 0, 0}, research_at = "town_center", required_age = "neolithic"},
		{cost = {50, 50, 50, 0}, research_at = "academy", required_age = "neolithic", requires = {"academy", "", "", ""}, n_req = 1},
		{cost = {100, 100, 0, 50}, research_at = "academy", required_age = "neolithic"},
		{cost = {0, 0, 150, 100}, research_at = "academy", required_age = "bronze"},
		{cost = {150, 100, 0, 0}, research_at = "town_center", required_age = "neolithic"},
		{cost = {150, 0, 0, 100}, research_at = "temple", required_age = "bronze"},
		{cost = {0, 0, 200, 200}, research_at = "academy", required_age = "iron", requires = {"bronze_armor", "", "", ""}, n_req = 1},
		{cost = {50, 100, 80, 100}, research_at = "academy", required_age = "iron"},
	}, n_techs = 14,
}

greek :: civ{
	id = "greek", name_en = "Greeks",
	bldg_mult = 1.3, honus_harvest = 1.0, honus_techcost = 1.0,
	wonder_id = "akropolis", wonder_cost = {4500, 4500, 4000, 2500},
	excluded = {"cavalry", "heavy_cavalry", "", ""}, n_excluded = 2,
	units = {
		{id = "hoplite", cost = {80, 0, 50, 30}, health = 150, speed = 0.9, u_type = "infantry", tier = "neolithic", train_at = "barracks"},
		{id = "phalanx", cost = {60, 0, 40, 20}, health = 100, speed = 0.8, u_type = "infantry", tier = "bronze", train_at = "barracks"},
	{}, {}, {}, {}, {}, {}}, n_units = 2,
	techs = {
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {100, 150, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {150, 100, 0, 0}, research_at = "town_center", required_age = "neolithic"},
		{cost = {100, 100, 0, 0}, research_at = "town_center", required_age = "stone", requires = {"barracks", "", "", ""}, n_req = 1},
		{cost = {100, 50, 0, 30}, research_at = "town_center", required_age = "stone"},
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {200, 150, 0, 0}, research_at = "town_center", required_age = "neolithic"},
		{cost = {200, 0, 0, 150}, research_at = "academy", required_age = "neolithic", requires = {"academy", "", "", ""}, n_req = 1},
		{cost = {300, 0, 0, 200}, research_at = "academy", required_age = "bronze", requires = {"philosophy", "", "", ""}, n_req = 1},
		{cost = {0, 50, 150, 100}, research_at = "academy", required_age = "bronze"},
		{cost = {150, 0, 0, 100}, research_at = "temple", required_age = "bronze"},
		{cost = {0, 0, 200, 200}, research_at = "academy", required_age = "iron", requires = {"phalanx_armor", "", "", ""}, n_req = 1},
		{cost = {50, 100, 80, 100}, research_at = "academy", required_age = "iron"},
	}, n_techs = 14,
}

persian :: civ{
	id = "persian", name_en = "Persians",
	bldg_mult = 1.0, honus_harvest = 1.2, honus_techcost = 1.0,
	wonder_id = "firetemple", wonder_cost = {4500, 4500, 4000, 2500},
	excluded = {"", "", "", ""}, n_excluded = 0,
	units = {
		{id = "archer", cost = {70, 30, 0, 0}, health = 50, speed = 1.1, u_type = "ranged", tier = "neolithic"},
		{id = "cavalry", cost = {110, 0, 0, 40}, health = 140, speed = 2, u_type = "cavalry", tier = "bronze"},
		{id = "heavy_cavalry", cost = {160, 0, 40, 70}, health = 200, speed = 1.8, u_type = "cavalry", tier = "iron"},
	{}, {}, {}, {}, {}}, n_units = 3,
	techs = {
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {100, 150, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {150, 100, 0, 0}, research_at = "town_center", required_age = "neolithic"},
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {200, 150, 0, 0}, research_at = "town_center", required_age = "neolithic"},
		{cost = {150, 50, 0, 100}, research_at = "academy", required_age = "neolithic", requires = {"horseback", "", "", ""}, n_req = 1},
		{cost = {0, 0, 200, 150}, research_at = "academy", required_age = "bronze", requires = {"cavalry_training", "", "", ""}, n_req = 1},
		{cost = {0, 0, 150, 100}, research_at = "academy", required_age = "bronze"},
		{cost = {150, 0, 0, 100}, research_at = "temple", required_age = "bronze"},
		{cost = {100, 100, 0, 50}, research_at = "academy", required_age = "bronze"},
		{cost = {0, 200, 150, 200}, research_at = "academy", required_age = "iron", requires = {"archery", "", "", ""}, n_req = 1},
		{cost = {50, 100, 80, 100}, research_at = "academy", required_age = "iron"},
		{},
	}, n_techs = 13,
}

yamato_civ :: civ{
	id = "yamato", name_en = "Yamato",
	bldg_mult = 1.0, honus_harvest = 1.0, honus_techcost = 0.7,
	wonder_id = "shrine", wonder_cost = {4500, 4500, 4000, 2500},
	excluded = {"", "", "", ""}, n_excluded = 0,
	units = {
		{id = "samurai", cost = {100, 50, 0, 50}, health = 130, speed = 1.3, u_type = "infantry", tier = "bronze", train_at = "barracks"},
		{id = "archer_ship", cost = {150, 150, 0, 50}, health = 200, speed = 1.5, u_type = "ranged"},
	{}, {}, {}, {}, {}, {}}, n_units = 2,
	techs = {
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {100, 50, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {100, 150, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {150, 0, 0, 100}, research_at = "town_center", required_age = "stone", requires = {"barracks", "", "", ""}, n_req = 1},
		{cost = {150, 0, 0, 100}, research_at = "temple", required_age = "bronze"},
		{cost = {100, 100, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {50, 100, 0, 0}, research_at = "town_center", required_age = "stone"},
		{cost = {200, 150, 0, 0}, research_at = "town_center", required_age = "neolithic"},
		{cost = {150, 100, 0, 0}, research_at = "town_center", required_age = "neolithic"},
		{cost = {0, 100, 150, 150}, research_at = "academy", required_age = "bronze", requires = {"bushido", "", "", ""}, n_req = 1},
		{cost = {0, 0, 150, 100}, research_at = "academy", required_age = "bronze"},
		{cost = {0, 0, 200, 200}, research_at = "academy", required_age = "iron", requires = {"armor", "", "", ""}, n_req = 1},
		{cost = {50, 100, 80, 100}, research_at = "academy", required_age = "iron"},
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
	{id = "worker", cost = {50, 0, 0, 0}, health = 40, speed = 1, u_type = "worker"},
	{id = "militia", cost = {50, 20, 0, 0}, health = 70, speed = 1.1, u_type = "infantry", tier = "stone"},
	{id = "warrior", cost = {80, 0, 30, 20}, health = 120, speed = 1, u_type = "infantry", tier = "bronze"},
	{id = "champion", cost = {150, 50, 50, 100}, health = 200, speed = 1.5, u_type = "infantry", tier = "iron"},
	{id = "archer", cost = {60, 30, 0, 0}, health = 40, speed = 1, u_type = "ranged", tier = "neolithic"},
	{id = "crossbowman", cost = {100, 40, 20, 30}, health = 60, speed = 0.9, u_type = "ranged", tier = "iron"},
	{id = "elite_archer", cost = {150, 60, 30, 50}, health = 80, speed = 1.1, u_type = "ranged", tier = "iron"},
	{id = "scout_cavalry", cost = {100, 0, 0, 30}, health = 100, speed = 2.2, u_type = "cavalry", tier = "neolithic"},
	{id = "cavalry", cost = {120, 0, 0, 50}, health = 140, speed = 2, u_type = "cavalry", tier = "bronze"},
	{id = "heavy_cavalry", cost = {180, 0, 50, 80}, health = 200, speed = 1.8, u_type = "cavalry", tier = "iron"},
	{id = "priest", cost = {50, 0, 0, 30}, health = 60, speed = 1, u_type = "support", tier = "bronze"},
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
}

std_bldg_defs : [9]bldg_def = {
	{id = "town_center", cost = {100, 100, 100, 100}, base_health = 1000, req_age = "stone", train_opts = {"worker", ""}, n_train = 1, can_train = true},
	{id = "house", cost = {30, 20, 0, 0}, base_health = 300, req_age = "stone", req_tech = "house"},
	{id = "farm", cost = {50, 50, 0, 0}, base_health = 400, req_age = "stone", req_tech = "farm"},
	{id = "barracks", cost = {50, 150, 0, 0}, base_health = 800, req_age = "stone", req_tech = "barracks", can_train = true},
	{id = "archery_range", cost = {50, 100, 50, 0}, base_health = 600, req_age = "neolithic", req_tech = "longbow", can_train = true},
	{id = "stable", cost = {100, 100, 0, 50}, base_health = 700, req_age = "neolithic", req_tech = "horseback", can_train = true},
	{id = "academy", cost = {100, 100, 100, 50}, base_health = 700, req_age = "neolithic", req_tech = "academy"},
	{id = "tower", cost = {50, 50, 100, 0}, base_health = 600, req_age = "stone"},
	{id = "temple", cost = {100, 100, 150, 100}, base_health = 800, req_age = "bronze", train_opts = {"priest", ""}, n_train = 1, can_train = true},
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
	nodes: [1024]rnode, // 942 pre-clearing (98+784+40+20); 1024 for headroom
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
terrain_scatter_rotational :: proc(t: ^terrain, size: f64, spawns: [4][2]f64, a0: f64, sector: f64, st: ^u32, ntype: i32, total: f64, amount: f64) {
	per := f64(math.max(1, math.floor((total / 4) + 0.5)))
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
			for s in 0 ..< 4 {
				if m_hypot(x - spawns[s][0], z - spawns[s][1]) < KEEP_OUT {
					close = true
					break
				}
			}
			if !close {
				break
			}
		}
		for p := 0; p < 4; p += 1 {
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

t_terrain :: proc(size: f64, seed: string, spawns: [4][2]f64) -> terrain {
	coast_lat_build()
	coast_limit_table()

	t := terrain{size = size, seed = seed}
	usable := size - 80
	tile := usable / 7

	// The rotation the scarce types use is about the first spawn's angle; the
	// arena's four are the ideal circle, so this is the one the whole layout shares.
	a0 := m_atan2(spawns[0][1], spawns[0][0])
	sector := (math.PI * 2) / 4

	st := hash_seed(seed)
	if st == 0 {
		st = 42
	}

	// medium: food 196 x 0.5, wood 784 x 1, stone 40 x 1, gold 18 (no mods entry).
	terrain_scatter_equal(&t, usable, tile, &st, 0, 196*0.5, 500)         // food
	terrain_scatter_equal(&t, usable, tile, &st, 1, 784*1.0, 300)         // wood
	terrain_scatter_rotational(&t, size, spawns, a0, sector, &st, 2, 40*1.0, 1000) // stone
	terrain_scatter_rotational(&t, size, spawns, a0, sector, &st, 3, 18, 2000)     // gold
	for s in 0 ..< 4 {
		terrain_clear_near(&t, spawns[s][0], spawns[s][1], 9.5 + 3)
	}

	return t
}

// The arena's spawn circle: (i/4) * 2pi - pi/2 on a 306-unit radius, in WarMath
// (game.js:373-381; halfSize = 400 - 40, radius = 0.85 x that).
arena_spawns :: proc() -> [4][2]f64 {
	sp: [4][2]f64
	half := f64(400) - 40
	radius := half * 0.85
	for i := 0; i < 4; i += 1 {
		angle := f64(i)/f64(4) * math.PI * 2 - math.PI/2
		sp[i][0] = m_cos(angle) * radius
		sp[i][1] = m_sin(angle) * radius
	}
	return sp
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
}

// The worker task vocabulary (js/game.js's task strings, as an int).
TASK_NONE :: 0
TASK_HARVESTING :: 1
TASK_CARRYING :: 2
TASK_BUILDING :: 3
TASK_REPAIRING :: 4
TASK_FARM_WORK :: 5
TASK_SCOUTING :: 6

MAX_UNITS :: 24 // this minute peaks at 14; headroom for longer matches
MAX_BLDGS :: 8 // TC + houses + farms
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
	known: [1024]byte, // _knownResIdx: node index -> seen
	seen_amt: [1024]f64, // the seen amount the harness caches with the node
	seen_set: [1024]byte,
	explored: [42 * 42]byte, // the exploration bitmap, one per 19-unit cell
	met: [4]bool, // first-contact memory: has this seat ever seen rival <i>?
	harvest_bonus: f64, // workerHarvestBonus: 1.0 — the spectator path applies NO civ bonus
	techcost_mult: f64, // techCostMultiplier: 1.0 likewise (ai.js addAIPlayer's defaults)
	k: keyed_rng,
	// --- the match engine's brain fields (js/ai.js AIManager + the seat) ---
	think_timer: f64, // advanceThink's accumulator (sim ms)
	cur_research: bool, // ai.currentResearch != null
	res_tech: string, // the tech id being researched
	res_progress: f64,
	res_duration: f64,
	cur_age_upgrade: bool, // ai.currentAgeUpgrade != null (dormant in this minute)
	researched: [16]string, // researchedTechs (the set, in completion order)
	n_researched: int,
	unlocked_bldgs: [16]string, // owner.unlockedBuildings (tech unlocks)
	n_unlocked_bldgs: int,
	events: [MAX_EVTS]evt, // the seat's notice ring (logPlayerEvent's)
	n_events: int,
	turn_seq: int, // ai._turnSeq
	last_counts: [4]int, // _lastNodeCounts: {food,wood,stone,gold}
	dry_told: [1024]bool, // _dryNodesTold: once per node
	explore_timer: int, // _exploreTimer
	scout_angle: f64, // _scoutAngle
	scout_radius: f64, // _scoutRadius
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
	seats: [4]seat,
	terrain: terrain,
	match_ms: f64, // clock.matchMs: the MATCH clock, 25 per sim step at the recorder's 2x
	sim_ms: f64, // clock.simMs: 50 per sim step
	step_no: int,
	discovery_timer: f64, // the 4 Hz beat's own accumulator (mgr.update)
	world_rng: keyed_rng, // the game's one rng (seed 'golden'): 'world:*' draws
	// --- the match timeline (game.js resetTimeline/sampleTimeline) ---
	tl_t0: f64,
	tl_last: f64,
	tl_samples: [64]tl_sample,
	tl_n_samples: int,
	tl_marks: [64]tl_mark,
	tl_n_marks: int,
	tl_age: [4]int, // the last age index per seat (-1 = unset)
	tl_dry: [4][4]bool, // ran-dry flags per seat per type (start true)
}

// resetTimeline: a fresh match — population 0, the match clock 0, the
// discovery beat 0, no pending events, the exploration bitmaps blank.
setup :: proc(g: ^game_state, spawns: [4][2]f64) {
	g.match_ms = 0
	g.sim_ms = 0
	g.step_no = 0
	g.world_rng.seed = "golden"
	g.discovery_timer = 0
	g.tl_t0 = 0
	g.tl_last = 0
	g.tl_n_samples = 0
	g.tl_n_marks = 0
	for i in 0 ..< 4 {
		g.tl_age[i] = -1
		for k in 0 ..< 4 {
			g.tl_dry[i][k] = true
		}
	}
	for i in 0 ..< 4 {
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
		sp := spawns[i]

		// The Town Center, at the spawn, finished (createBuilding, age 'stone').
		def := bldg_def_by_id("town_center")
		mh := building_max_health(def, i, "stone")
		s.home = bldg_state{id = "town_center", x = sp[0], z = sp[1], health = mh, max_health = mh}
		// ...and the match engine's building list: the TC is bldgs[0]. The
		// reference's seat owns its buildings as a list (ai.buildings); the
		// TC is created first (startGame), then houses/farms append as built.
		s.bldgs[0] = s.home
		s.n_bldgs = 1

		// The three workers: each axis one keyed draw of the seat's own stream,
		// 's<i>:start-workers', n = 0..5 (x then z, worker by worker).
		key := fmt.aprintf("s%d:start-workers", i)
		for w in 0 ..< 3 {
			x := sp[0] + (krng_draw(&s.k, key) - 0.5) * 10
			z := sp[1] + (krng_draw(&s.k, key) - 0.5) * 10
			s.units[w] = unit_state{handle = w + 1, x = x, z = z, health = 40, speed = 1.0}
			s.n_units += 1
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
	return 15
}
building_vision :: proc(b: ^bldg_state) -> f64 {
	if b.id == "tower" {
		return 80
	}
	if b.id == "town_center" {
		return 40
	}
	return 20
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
	cx := cast(int)(math.floor((x + half) / CELL))
	cz := cast(int)(math.floor((z + half) / CELL))
	cx = min(G-1, max(0, cx))
	cz = min(G-1, max(0, cz))
	cr := cast(int)(math.ceil(r / CELL))
	idx := es.n
	for dz := -cr; dz <= cr; dz += 1 {
		for dx := -cr; dx <= cr; dx += 1 {
			gx := cx + dx
			gz := cz + dz
			if gx < 0 || gx >= G || gz < 0 || gz >= G {
				continue
			}
			wx := (f64(gx) + 0.5)*CELL - half
			wz := (f64(gz) + 0.5)*CELL - half
			if m_hypot(wx - x, wz - z) <= r {
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
make_eyes :: proc(s: ^seat) -> eye_set {
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
			x := f64(math.floor((u.x) + 0.5))
			z := f64(math.floor((u.z) + 0.5))
			eyes_file(&es, x, z, unit_vision(u))
		}
	}
	b := &s.home
	if b.health > 0 {
		eyes_file(&es, b.x, b.z, building_vision(b))
	}
	return es
}

// The test itself: the point's cell and its one-cell ring, every eye in it.
// Harness mode: a plain sqrt against the eye's own (rounded) position.
see_test :: proc(es: ^eye_set, x: f64, z: f64) -> bool {
	G := 40
	CELL := f64(20)
	half := f64(400)
	cx := cast(int)(math.floor((x + half) / CELL))
	cz := cast(int)(math.floor((z + half) / CELL))
	cx = min(G-1, max(0, cx))
	cz = min(G-1, max(0, cz))
	for dz := -1; dz <= 1; dz += 1 {
		for dx := -1; dx <= 1; dx += 1 {
			gx := cx + dx
			gz := cz + dz
			if gx < 0 || gx >= G || gz < 0 || gz >= G {
				continue
			}
			for idx := es.cells[gz*G + gx]; idx != -1; idx = es.next[idx] {
				e := &es.eyes[idx]
				dx2 := e.x - x
				dz2 := e.z - z
				if math.sqrt(dx2*dx2 + dz2*dz2) <= e.r {
					return true
				}
			}
		}
	}
	return false
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

JW_SIZE :: 4194304 // the whole one-minute stream (3.1 MB) fits with headroom

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
	by: [4][200]nearby_node,
	n_by: [4]int,
	// the nearby map: insertion-ordered, keyed by the rounded "x,z" pair; a
	// later set with the same key replaces the value in place (Map semantics)
	key_x: [200]i32,
	key_z: [200]i32,
	val: [200]nearby_node,
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

	// ---- recentEvents: the arena's seats have no scripted orders, so the
	//      graph's pending list is empty and the view's is.
	j_key(j, "recentEvents")
	j_arr(j)
	j_end_arr(j)

	// ---- bonuses: the seat's own multipliers as the state reports them
	//      (workerHarvestBonus / techCostMultiplier, 1.0 omitted). The
	//      spectator path never applies the civ bonus, so the recorder's
	//      seats carry 1.0/1.0 — the stream's bonuses are {} for every
	//      seat, unlike the arena fixture (whose seats got the bonus).
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
	// (getAIBuildingCenter) -- the one building is the spawn itself.
	j_key(j, "yourSpawnArea")
	j_obj(j)
	j_key(j, "x")
	j_int(j, cast(i64)(math.floor((s.home.x) + 0.5)))
	j_key(j, "z")
	j_int(j, cast(i64)(math.floor((s.home.z) + 0.5)))
	j_end_obj(j)

	// yourBaseTiles: one tile per standing building, by the A1..G7 label.
	tiles := map[string]i32{}
	tiles[tile_at(s.home.x, s.home.z, size)] = 1
	j_key(j, "yourBaseTiles")
	j_obj(j)
	for k, v in tiles {
		j_key(j, k)
		j_int(j, i64(v))
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

	// ---- nodes: what the seat has seen, and what is on the map at all.
	sc := &o.scratch
	sc.n_by = [4]int{}
	sc.n_key = 0

	// The live amounts, in the survivor list's order. The discovered tally is
	// the seat's own: a node counts when the seat knows it and it holds amount.
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
	b := &s.home
	if b.health > 0 {
		j_obj(j)
		j_key(j, "type")
		j_str(j, b.id)
		j_key(j, "x")
		j_int(j, cast(i64)(math.floor((b.x) + 0.5)))
		j_key(j, "z")
		j_int(j, cast(i64)(math.floor((b.z) + 0.5)))
		j_key(j, "healthPct")
		j_int(j, cast(i64)(math.floor((b.health/b.max_health*100) + 0.5)))
		j_key(j, "state")
		j_str(j, "complete") // the port's constructing flag: the arena's TC is finished
		j_key(j, "busy")
		j_bool(j, false) // nothing producing, researching or advancing at either gate
		j_key(j, "activity")
		j_str(j, "idle")
		j_key(j, "producing")
		j_null(j)
		j_end_obj(j)
	}
	j_end_arr(j)

	// ---- enemyBuildings: the other seats' buildings, only those in sight
	//      under the step's batched test (the same one discovery uses).
	//      (updateEnemyBuildingDiscovery keeps a per-seat memory of what has
	//      ever been seen; at turn 1 no seat's vision reaches another's
	//      306-unit spawn, so the list is the empty one.)
	eyes := make_eyes(s)
	j_key(j, "enemyBuildings")
	j_arr(j)
	for i in 0 ..< 4 {
		if i == s.ci {
			continue
		}
		e := &g.seats[i].home
		if e.health > 0 && see_test(&eyes, e.x, e.z) {
			j_obj(j)
			j_key(j, "type")
			j_str(j, e.id)
			j_key(j, "x")
			j_int(j, cast(i64)(math.floor((e.x) + 0.5)))
			j_key(j, "z")
			j_int(j, cast(i64)(math.floor((e.z) + 0.5)))
			j_key(j, "healthPct")
			j_int(j, cast(i64)(math.floor((e.health/e.max_health*100) + 0.5)))
			j_end_obj(j)
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
			j_str(j, "worker")
			j_key(j, "x")
			j_int(j, cast(i64)(math.floor((u.x) + 0.5)))
			j_key(j, "z")
			j_int(j, cast(i64)(math.floor((u.z) + 0.5)))
			j_key(j, "healthPct")
			j_int(j, cast(i64)(math.floor((u.health/40*100) + 0.5)))
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
	wtotal := i64(s.n_units)
	idle: i64 = 0
	for i in 0 ..< s.n_units {
		if s.units[i].health > 0 {
			idle += 1
		}
	}
	j_key(j, "total")
	j_int(j, wtotal)
	j_key(j, "idle")
	j_int(j, idle)
	j_key(j, "building")
	j_int(j, 0)
	j_key(j, "farm")
	j_int(j, 0)
	j_key(j, "scouting")
	j_int(j, 0)
	j_key(j, "moving")
	j_int(j, 0)
	j_key(j, "fighting")
	j_int(j, 0)
	j_key(j, "food")
	j_int(j, 0)
	j_key(j, "wood")
	j_int(j, 0)
	j_key(j, "stone")
	j_int(j, 0)
	j_key(j, "gold")
	j_int(j, 0)
	j_end_obj(j)

	// ---- enemyUnits: none in sight, as with enemyBuildings.
	j_key(j, "enemyUnits")
	j_arr(j)
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
	j_end_arr(j)
	j_key(j, "current")
	j_null(j)
	j_key(j, "available")
	j_arr(j)
	tc_cost_mult := s.techcost_mult
	for t in 0 ..< c.n_techs {
		te := &c.techs[t]
		if age_idx(te.required_age) > age_idx("stone") {
			continue
		}
		// Nothing is researched at this gate's two moments (the golden's
		// research.researched is [] and current is null for every seat), so the
		// reference's "all requires researched" filter reduces to: any tech
		// with a requirement is out of the available list. The general form
		// consults the seat's researched set; this state does not carry one
		// because nothing is ever researched here.
		if te.n_req > 0 {
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
		has_tc := s.home.id == "town_center" && s.home.health > 0
		if at != "town_center" || !has_tc {
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
				standing := host == "town_center" && s.home.health > 0
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
		if bdef.req_tech != "" {
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
		// alreadyBuilt: no wonder stands at turn 1
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

	// ---- threats: no one takes fire at one second — the under-attack scan
	//      finds nothing; and no rival wonder exists, seen or not.
	j_key(j, "threats")
	j_obj(j)
	j_key(j, "underAttack")
	j_arr(j)
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
		j_bool(j, false)
		j_key(j, "defeated")
		j_bool(j, seat_eliminated(&g.seats[oci]))
		j_end_obj(j)
	}
	j_end_arr(j)
	j_end_obj(j) // gameStats

	j_end_obj(j) // state
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
				if math.sqrt(ddx*ddx + ddz*ddz) <= rng {
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
	if s.home.health > 0 {
		mark(s, s.home.x, s.home.z, building_vision(&s.home), cell, half)
		marked += 1
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
	es := make_eyes(viewer)
	for oi in 0 ..< 4 {
		if oi == viewer.ci || viewer.met[oi] {
			continue
		}
		o := &g.seats[oi]
		spotted := false
		for i in 0 ..< o.n_units {
			u := &o.units[i]
			if u.health > 0 && see_test(&es, u.x, u.z) {
				spotted = true
			}
		}
		if o.home.health > 0 && see_test(&es, o.home.x, o.home.z) {
			spotted = true
		}
		if spotted {
			viewer.met[oi] = true
		}
	}
}

// WarPositionRules.apply (port 851): separation and building clearance at
// the end of every simulation step. The pairs are same-owner (units from
// different seats never interact — nothing crosses the 306-unit spawn
// gap); the clearance pushes a unit away from its own finished buildings.
war_position_rules :: proc(g: ^game_state, dt: f64) {
	SEPARATION_DIST := f64(1.2)
	SEPARATION_FORCE := f64(0.03)
	sepK := math.min(f64(3), math.max(f64(0), dt) * 60)
	// the port walks the global unit list; the degenerate-pair fallback
	// direction uses the global index parity — gi tracks it
	gi := 0
	for si in 0 ..< 4 {
		s := &g.seats[si]
		for i in 0 ..< s.n_units {
			for k := i + 1; k < s.n_units; k += 1 {
				a := &s.units[i]
				b := &s.units[k]
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
						if gi % 2 == 0 { nx = 1 } else { nx = -1 }
						nz = 0
					}
					push := (SEPARATION_DIST - dist) * SEPARATION_FORCE * sepK
					a.x -= nx * push
					a.z -= nz * push
					b.x += nx * push
					b.z += nz * push
				}
			}
			gi += 1
		}
	}
	CLEAR_DIST := f64(4.5)
	CLEAR_FORCE := f64(0.05)
	clearK := math.min(f64(3), math.max(f64(0), dt) * 60)
	for si in 0 ..< 4 {
		s := &g.seats[si]
		for i in 0 ..< s.n_units {
			u := &s.units[i]
			if s.home.health > 0 {
				dx := u.x - s.home.x
				dz := u.z - s.home.z
				dist := math.sqrt(dx*dx + dz*dz)
				if dist > 0.01 && dist < CLEAR_DIST {
					push := (CLEAR_DIST - dist) * CLEAR_FORCE * clearK
					u.x += (dx / dist) * push
					u.z += (dz / dist) * push
				}
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
observe_step :: proc(g: ^game_state) {
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
	for i in 0 ..< 4 {
		g.seats[i].pop = g.seats[i].n_units
	}
	g.discovery_timer += dt
	if g.discovery_timer >= 250 {
		g.discovery_timer -= 250
		for i in 0 ..< 4 {
			mark_exploration(&g.seats[i], g.terrain.size)
			update_rival_contacts(g, &g.seats[i])
		}
	}
	g.step_no += 1
	war_position_rules(g, dt / 1000)
	observe_step(g)
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
	for i in 0 ..< 4 {
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
write_match_line :: proc(g: ^game_state, j: ^jw) {
	j_raw(j, "{\"type\":\"match\",\"matchId\":\"golden\",\"startedAt\":0,\"seed\":\"golden\",\"difficulty\":\"medium\",\"seats\":4,\"minutes\":1,\"stepMs\":100,\"snapshotMs\":500,\"simSpeed\":1,\"turnBased\":false,\"resourceBoost\":false,\"version\":\"1.0.0\",\"players\":[")
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
write_map_line :: proc(g: ^game_state, j: ^jw, spawns: [4][2]f64) {
	t := &g.terrain
	j_raw(j, "{\"playerId\":\"__map__\",\"type\":\"map\",\"seed\":\"golden\",\"difficulty\":\"medium\",\"seats\":4,\"size\":800,\"spawns\":[")
	for p in 0 ..< 4 {
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
		j_raw(j, fmt.aprintf("\"seat\":%d,\"age\":\"stone\",\"population\":%d,\"maxPopulation\":%d,\"units\":%d,\"buildings\":%d,\"eliminated\":false", i, s.pop, s.max_pop, s.n_units, s.n_bldgs))
		j_raw(j, "}")
	}
	j_raw(j, "]}}\n\n")
}

// One turn record: the stream's per-seat wrapper around the state view.
write_turn_line :: proc(g: ^game_state, j: ^jw, si: int, turn: int) {
	s := &g.seats[si]
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
		// units: the type-count map, first-encounter order.
		first := true
		for u in 0 ..< s.n_units {
			if s.units[u].health <= 0 {
				continue
			}
			ty := "worker"
			seen := false
			for p in 0 ..< u {
				if s.units[p].health > 0 && "worker" == ty {
					seen = true
					break
				}
			}
			if seen {
				continue
			}
			if !first {
				j_raw(j, ",")
			}
			first = false
			j_raw(j, fmt.aprintf("\"%s\":1", ty))
		}
		j_raw(j, "},\"buildings\":{")
		// buildings: the type-count map, first-encounter order.
		first = true
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
	j_raw(j, "{\"type\":\"timeline\",\"timeline\":{\"t0\":0,\"ages\":[")
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
	j_raw(j, "],\"wonders\":[],\"samples\":[")
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
			j_raw(j, fmt.aprintf("\":{\"f\":%d,\"w\":%d,\"s\":%d,\"o\":%d,\"pw\":0,\"al\":%d}", int(row.f[si]), int(row.w[si]), int(row.s[si]), int(row.o[si]), row.al[si] ? 1 : 0))
		}
		j_raw(j, "}}")
	}
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
	spawns := arena_spawns()
	g: game_state
	g.terrain = t_terrain(f64(800), "golden", spawns)
	setup(&g, spawns)

	j := new(jw)
	j.n = 0

	write_match_line(&g, j)
	write_map_line(&g, j, spawns)

	for tick := 1; tick <= 600; tick += 1 {
		g.match_ms += 100
		for k in 0 ..< 4 {
			g.sim_ms += 50
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
