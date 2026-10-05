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

import "core:fmt" "core:math" "core:os"

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
bits64 :: proc(x: f64) -> u64 {
	return cast(u64)(x)
}
high32 :: proc(x: f64) -> i32 {
	return cast(i32)(bits64(x) >> 32)
}
low32 :: proc(x: f64) -> u32 {
	return cast(u32)(bits64(x))
}
with_high :: proc(hi: i32, lo: u32) -> f64 {
	return cast(f64)(cast(u64)(cast(u32)(hi))<<32 | u64(lo))
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
m_hypot :: proc(a: f64, b: f64) -> f64 {
	x := m_abs(a)
	y := m_abs(b)
	if x != x || y != y {
		return math.inf if x == math.inf or y == math.inf else math.nan
	}
	max := x if x > y else y
	if max == math.inf {
		return math.inf
	}
	if max == 0 {
		return 0
	}
	n := x / max
	m := y / max
	return math.sqrt(n*n + m*m) * max
}

// --- fdlibm kernels on [-pi/4, pi/4]; y is the tail of the reduced argument. ---
S1c :: f64 = -1.66666666666666324348e-01
S2c :: f64 = 8.33333333332248946124e-03
S3c :: f64 = -1.98412698298579493134e-04
S4c :: f64 = 2.75573137070700676789e-06
S5c :: f64 = -2.50507602534068634195e-08
S6c :: f64 = 1.58969099521155010221e-10
C1c :: f64 = 4.16666666666666019037e-02
C2c :: f64 = -1.38888888888741095749e-03
C3c :: f64 = 2.48015872894767294178e-05
C4c :: f64 = -2.75573143513906633035e-07
C5c :: f64 = 2.08757232129817482790e-09
C6c :: f64 = -1.13596475577881948265e-11

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
	qx := 0.28125 if ix > cast(i32)(0x3fe90000) else with_high(ix - cast(i32)(0x00200000), 0)
	hz := 0.5 * z - qx
	a := 1 - qx
	return a - (hz - (z*r - x*y))
}

// x - n*pi/2 as a head and tail, for |x| up to 2^20 * pi/2 (fdlibm's medium
// range). Beyond it the argument is first brought down with %, which is exact.
invpio2c :: f64 = 6.36619772367581382433e-01
pio2_1c :: f64 = 1.57079632673412561417e+00
pio2_1tc :: f64 = 6.07710050650619224932e-11
pio2_2c :: f64 = 6.07710050630396597660e-11
pio2_2tc :: f64 = 2.02226624879595063154e-21
pio2_3c :: f64 = 2.02226624871116645580e-21
pio2_3tc :: f64 = 8.47842766036889956997e-32

npio2_hw :: [32]i32 = [
	0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
	0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
	0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
	0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
	0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
	0x404858EB, 0x404921FB,
]

rem_pio2 :: proc(x: f64, y0: ^f64, y1: ^f64) -> i32 {
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
		x = x % 6.283185307179586
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
	var y0, y1 f64
	switch rem_pio2(x, &y0, &y1) & 3 {
	case 0:
		return k_sin(y0, y1, 1)
	case 1:
		return k_cos(y0, y1)
	case 2:
		return -k_sin(y0, y1, 1)
	default:
		return -k_cos(y0, y1)
	}
}

m_cos :: proc(x: f64) -> f64 {
	ix := high32(x) & cast(i32)(0x7fffffff)
	if ix <= cast(i32)(0x3fe921fb) {
		return k_cos(x, 0)
	}
	if ix >= cast(i32)(0x7ff00000) {
		return x - x
	}
	var y0, y1 f64
	switch rem_pio2(x, &y0, &y1) & 3 {
	case 0:
		return k_cos(y0, y1)
	case 1:
		return -k_sin(y0, y1, 1)
	case 2:
		return -k_cos(y0, y1)
	default:
		return k_sin(y0, y1, 1)
	}
}

// --- fdlibm atan and atan2. ---
atanhi :: [4]f64 = [
	4.63647609000806093515e-01,
	7.85398163397448278999e-01,
	9.82793723247329054082e-01,
	1.57079632679489655800e+00,
]
atanlo :: [4]f64 = [
	2.26987774529616870924e-17,
	3.06161699786838301793e-17,
	1.39033110312309984516e-17,
	6.12323399573676603587e-17,
]
aT :: [11]f64 = [
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
]

m_atan :: proc(x: f64) -> f64 {
	hx := high32(x)
	ix := hx & cast(i32)(0x7fffffff)
	var id i32
	if ix >= cast(i32)(0x44100000) {
		if ix > cast(i32)(0x7ff00000) || (ix == cast(i32)(0x7ff00000) && low32(x) != 0) {
			return x + x
		}
		return hx > 0 ? atanhi[3] + atanlo[3] : -atanhi[3] - atanlo[3]
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
	return hx < 0 ? -r : r
}

pim :: f64 = 3.1415926535897931160e+00
pi_o_2m :: f64 = 1.5707963267948965580e+00
pi_o_4m :: f64 = 7.8539816339744827900e-01
pi_lom :: f64 = 1.2246467991473531772e-16
tinym :: f64 = 1.0e-300

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
		return m == 2 ? pim + tinym : -pim - tinym
	}
	if (ix | cast(i32)(lx)) == 0 {
		return hy < 0 ? -pi_o_2m - tinym : pi_o_2m + tinym
	}
	if ix == cast(i32)(0x7ff00000) {
		if iy == cast(i32)(0x7ff00000) {
			return [pi_o_4m + tinym, -pi_o_4m - tinym, 3*pi_o_4m + tinym, -3*pi_o_4m - tinym][m]
		}
		return [0, -0, pim + tinym, -pim - tinym][m]
	}
	if iy == cast(i32)(0x7ff00000) {
		return hy < 0 ? -pi_o_2m - tinym : pi_o_2m + tinym
	}
	k := (iy - ix) >> 20
	var z f64
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
	default:
		return (z - pi_lom) - pim
	}
}

// A small whole power by repeated multiplication: exact wherever the result is.
m_pow_int :: proc(base: f64, n: i32) -> f64 {
	r := f64(1)
	for i := 0; i < n; i += 1 {
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

type cost4 struct {
	food, wood, stone, gold f64
}

type tech struct {
	cost         cost4
	research_at  string
	required_age string
	requires     [4]string
	n_req        int
}

type unit_def struct {
	id       string
	cost     cost4
	health   f64
	speed    f64
	u_type   string // 'worker', 'infantry', 'ranged', 'cavalry', 'support'
	tier     string // the epoch that trains it
	train_at string // set for uniques that need a specific building
}

type civ struct {
	id          string
	name_en     string
	// per-building health multiplier from the civ bonus ('Pyramide' 1.5, 'Akropolis' 1.3)
	bldg_mult      f64
	// the observation's bonuses table: harvest 1.2 (Satrapie) / techCostMult 0.7 (Schrein)
	honus_harvest  f64
	honus_techcost f64
	wonder_id   string
	wonder_cost cost4
	excluded    [4]string
	n_excluded  int
	units       [8]unit_def
	n_units     int
	techs       [14]tech
	n_techs     int
}

egypt :: civ = {
	id: "egyptian", name_en: "Egyptians",
	bldg_mult: 1.5, honus_harvest: 1.0, honus_techcost: 1.0,
	wonder_id: "pyramid", wonder_cost: {4800, 4800, 4250, 2650},
	excluded: ["cavalry", "heavy_cavalry"], n_excluded: 2,
	units: [
		{id: "priest", cost: {50, 0, 0, 30}, health: 60, speed: 1.2, u_type: "support", tier: "bronze"},
		{id: "slinger", cost: {60, 20, 0, 0}, health: 45, speed: 1, u_type: "ranged", tier: "neolithic", train_at: "archery_range"},
		{id: "horse_carriage", cost: {60, 20, 40, 40}, health: 100, speed: 2, u_type: "cavalry", tier: "bronze", train_at: "stable"},
	], n_units: 3,
	techs: [
		{cost: {50, 100, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {100, 50, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {100, 150, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {100, 50, 0, 0}, research_at: "town_center", required_age: "stone", requires: ["farm"], n_req: 1},
		{cost: {80, 40, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {50, 100, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {200, 150, 0, 0}, research_at: "town_center", required_age: "neolithic"},
		{cost: {50, 50, 50, 0}, research_at: "academy", required_age: "neolithic", requires: ["academy"], n_req: 1},
		{cost: {100, 100, 0, 50}, research_at: "academy", required_age: "neolithic"},
		{cost: {0, 0, 150, 100}, research_at: "academy", required_age: "bronze"},
		{cost: {150, 100, 0, 0}, research_at: "town_center", required_age: "neolithic"},
		{cost: {150, 0, 0, 100}, research_at: "temple", required_age: "bronze"},
		{cost: {0, 0, 200, 200}, research_at: "academy", required_age: "iron", requires: ["bronze_armor"], n_req: 1},
		{cost: {50, 100, 80, 100}, research_at: "academy", required_age: "iron"},
	], n_techs: 14,
}

greek :: civ = {
	id: "greek", name_en: "Greeks",
	bldg_mult: 1.3, honus_harvest: 1.0, honus_techcost: 1.0,
	wonder_id: "akropolis", wonder_cost: {4500, 4500, 4000, 2500},
	excluded: ["cavalry", "heavy_cavalry"], n_excluded: 2,
	units: [
		{id: "hoplite", cost: {80, 0, 50, 30}, health: 150, speed: 0.9, u_type: "infantry", tier: "neolithic", train_at: "barracks"},
		{id: "phalanx", cost: {60, 0, 40, 20}, health: 100, speed: 0.8, u_type: "infantry", tier: "bronze", train_at: "barracks"},
	], n_units: 2,
	techs: [
		{cost: {50, 100, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {100, 50, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {100, 150, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {150, 100, 0, 0}, research_at: "town_center", required_age: "neolithic"},
		{cost: {100, 100, 0, 0}, research_at: "town_center", required_age: "stone", requires: ["barracks"], n_req: 1},
		{cost: {100, 50, 0, 30}, research_at: "town_center", required_age: "stone"},
		{cost: {50, 100, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {200, 150, 0, 0}, research_at: "town_center", required_age: "neolithic"},
		{cost: {200, 0, 0, 150}, research_at: "academy", required_age: "neolithic", requires: ["academy"], n_req: 1},
		{cost: {300, 0, 0, 200}, research_at: "academy", required_age: "bronze", requires: ["philosophy"], n_req: 1},
		{cost: {0, 50, 150, 100}, research_at: "academy", required_age: "bronze"},
		{cost: {150, 0, 0, 100}, research_at: "temple", required_age: "bronze"},
		{cost: {0, 0, 200, 200}, research_at: "academy", required_age: "iron", requires: ["phalanx_armor"], n_req: 1},
		{cost: {50, 100, 80, 100}, research_at: "academy", required_age: "iron"},
	], n_techs: 14,
}

persian :: civ = {
	id: "persian", name_en: "Persians",
	bldg_mult: 1.0, honus_harvest: 1.2, honus_techcost: 1.0,
	wonder_id: "firetemple", wonder_cost: {4500, 4500, 4000, 2500},
	excluded: ["", "", "", ""], n_excluded: 0,
	units: [
		{id: "archer", cost: {70, 30, 0, 0}, health: 50, speed: 1.1, u_type: "ranged", tier: "neolithic"},
		{id: "cavalry", cost: {110, 0, 0, 40}, health: 140, speed: 2, u_type: "cavalry", tier: "bronze"},
		{id: "heavy_cavalry", cost: {160, 0, 40, 70}, health: 200, speed: 1.8, u_type: "cavalry", tier: "iron"},
	], n_units: 3,
	techs: [
		{cost: {50, 100, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {100, 50, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {100, 150, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {150, 100, 0, 0}, research_at: "town_center", required_age: "neolithic"},
		{cost: {50, 100, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {200, 150, 0, 0}, research_at: "town_center", required_age: "neolithic"},
		{cost: {150, 50, 0, 100}, research_at: "academy", required_age: "neolithic", requires: ["horseback"], n_req: 1},
		{cost: {0, 0, 200, 150}, research_at: "academy", required_age: "bronze", requires: ["cavalry_training"], n_req: 1},
		{cost: {0, 0, 150, 100}, research_at: "academy", required_age: "bronze"},
		{cost: {150, 0, 0, 100}, research_at: "temple", required_age: "bronze"},
		{cost: {100, 100, 0, 50}, research_at: "academy", required_age: "bronze"},
		{cost: {0, 200, 150, 200}, research_at: "academy", required_age: "iron", requires: ["archery"], n_req: 1},
		{cost: {50, 100, 80, 100}, research_at: "academy", required_age: "iron"},
	], n_techs: 13,
}

yamato_civ :: civ = {
	id: "yamato", name_en: "Yamato",
	bldg_mult: 1.0, honus_harvest: 1.0, honus_techcost: 0.7,
	wonder_id: "shrine", wonder_cost: {4500, 4500, 4000, 2500},
	excluded: ["", "", "", ""], n_excluded: 0,
	units: [
		{id: "samurai", cost: {100, 50, 0, 50}, health: 130, speed: 1.3, u_type: "infantry", tier: "bronze", train_at: "barracks"},
		{id: "archer_ship", cost: {150, 150, 0, 50}, health: 200, speed: 1.5, u_type: "ranged"},
	], n_units: 2,
	techs: [
		{cost: {50, 100, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {100, 50, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {100, 150, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {150, 0, 0, 100}, research_at: "town_center", required_age: "stone", requires: ["barracks"], n_req: 1},
		{cost: {150, 0, 0, 100}, research_at: "temple", required_age: "bronze"},
		{cost: {100, 100, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {50, 100, 0, 0}, research_at: "town_center", required_age: "stone"},
		{cost: {200, 150, 0, 0}, research_at: "town_center", required_age: "neolithic"},
		{cost: {150, 100, 0, 0}, research_at: "town_center", required_age: "neolithic"},
		{cost: {0, 100, 150, 150}, research_at: "academy", required_age: "bronze", requires: ["bushido"], n_req: 1},
		{cost: {0, 0, 150, 100}, research_at: "academy", required_age: "bronze"},
		{cost: {0, 0, 200, 200}, research_at: "academy", required_age: "iron", requires: ["armor"], n_req: 1},
		{cost: {50, 100, 80, 100}, research_at: "academy", required_age: "iron"},
	], n_techs: 13,
}

civs :: [4]civ = [egypt, greek, persian, yamato_civ]

// Tech tree ids in tree order (the observation walks this order), parallel to
// civs[ci].techs[i].
tech_ids :: [4][14]string = [
	["house", "farm", "barracks", "agriculture", "pottery", "longbow", "academy", "mining", "archery", "bronze_armor", "horseback", "healing", "iron_working", "fire_arrows"],
	["house", "farm", "barracks", "horseback", "falx", "farsight", "longbow", "academy", "philosophy", "democracy", "phalanx_armor", "healing", "iron_working", "fire_arrows"],
	["house", "farm", "barracks", "horseback", "longbow", "academy", "cavalry_training", "cavalry_armor", "immortals", "healing", "archery", "siege", "fire_arrows"],
	["house", "farm", "barracks", "bushido", "healing", "speed", "longbow", "academy", "horseback", "armor", "lamellar_armor", "iron_working", "fire_arrows"],
]

// ===========================================================================
// Standard unit and building definitions — js/units.js and js/buildings.js.
// Only the fields the first turn reads are kept; costs are the whole of the
// economy at this scale.
// ===========================================================================

std_unit_defs :: [11]unit_def = [
	{id: "worker", cost: {50, 0, 0, 0}, health: 40, speed: 1, u_type: "worker"},
	{id: "militia", cost: {50, 20, 0, 0}, health: 70, speed: 1.1, u_type: "infantry", tier: "stone"},
	{id: "warrior", cost: {80, 0, 30, 20}, health: 120, speed: 1, u_type: "infantry", tier: "bronze"},
	{id: "champion", cost: {150, 50, 50, 100}, health: 200, speed: 1.5, u_type: "infantry", tier: "iron"},
	{id: "archer", cost: {60, 30, 0, 0}, health: 40, speed: 1, u_type: "ranged", tier: "neolithic"},
	{id: "crossbowman", cost: {100, 40, 20, 30}, health: 60, speed: 0.9, u_type: "ranged", tier: "iron"},
	{id: "elite_archer", cost: {150, 60, 30, 50}, health: 80, speed: 1.1, u_type: "ranged", tier: "iron"},
	{id: "scout_cavalry", cost: {100, 0, 0, 30}, health: 100, speed: 2.2, u_type: "cavalry", tier: "neolithic"},
	{id: "cavalry", cost: {120, 0, 0, 50}, health: 140, speed: 2, u_type: "cavalry", tier: "bronze"},
	{id: "heavy_cavalry", cost: {180, 0, 50, 80}, health: 200, speed: 1.8, u_type: "cavalry", tier: "iron"},
	{id: "priest", cost: {50, 0, 0, 30}, health: 60, speed: 1, u_type: "support", tier: "bronze"},
]

type bldg_def struct {
	id          string
	cost        cost4
	base_health f64
	req_age     string
	req_tech    string
	train_opts  [2]string
	n_train     int
	can_train   bool
}

std_bldg_defs :: [9]bldg_def = [
	{id: "town_center", cost: {100, 100, 100, 100}, base_health: 1000, req_age: "stone", train_opts: ["worker"], n_train: 1, can_train: true},
	{id: "house", cost: {30, 20, 0, 0}, base_health: 300, req_age: "stone", req_tech: "house"},
	{id: "farm", cost: {50, 50, 0, 0}, base_health: 400, req_age: "stone", req_tech: "farm"},
	{id: "barracks", cost: {50, 150, 0, 0}, base_health: 800, req_age: "stone", req_tech: "barracks", can_train: true},
	{id: "archery_range", cost: {50, 100, 50, 0}, base_health: 600, req_age: "neolithic", req_tech: "longbow", can_train: true},
	{id: "stable", cost: {100, 100, 0, 50}, base_health: 700, req_age: "neolithic", req_tech: "horseback", can_train: true},
	{id: "academy", cost: {100, 100, 100, 50}, base_health: 700, req_age: "neolithic", req_tech: "academy"},
	{id: "tower", cost: {50, 50, 100, 0}, base_health: 600, req_age: "stone"},
	{id: "temple", cost: {100, 100, 150, 100}, base_health: 800, req_age: "bronze", train_opts: ["priest"], n_train: 1, can_train: true},
]

bldg_def_by_id :: proc(id: string) -> ^bldg_def {
	for i, d in std_bldg_defs {
		if d.id == id {
			return &d
		}
	}
	return nil
}

std_unit_by_id :: proc(id: string) -> ^unit_def {
	for i, d in std_unit_defs {
		if d.id == id {
			return &d
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
	var idx i32 = 0
	for i, a in agess {
		if a == age {
			idx = cast(i32)(i)
			break
		}
	}
	h := d.base_health * m_pow_int(1.5, idx) * civs[ci].bldg_mult
	return math.max(50, f64(math.round(h/50)) * 50)
}

// ===========================================================================
// The map — a transcription of js/terrain.js for the arena's 800-unit world,
// medium difficulty (the golden's): 98 food, 784 wood, 40 stone, 20 gold, one
// wood node landing under the first Town Center. The stream is the seed's own
// (WarRng.stream(WarRng.hashSeed(seed), 42)): stateful, one step per draw.
// ===========================================================================

type rnode struct {
	n_type i32 // 0 food, 1 wood, 2 stone, 3 gold
	x, z   f64
	amount f64
}

type terrain struct {
	seed    string
	size    f64
	nodes   [900]rnode
	n_nodes int
}

// --- The coast: js/engine/texgen.js's sampler and js/terrain.js's table. ---
// The shoreline is a wobbled square: 413 ± 26 along each of 1024 directions,
// solved by the bisection the surf ribbon uses. The table is Float32: the
// entries are stored in 32-bit floats and read back as doubles.
const COAST_CELLS   = 24
const COAST_WOBBLE  = f64(26)
const TERRAIN_SEED  = 12345
const TERRAIN_WORLD = f64(1000)
const COAST_WALK    = f64(413)
const COAST_LIMIT_N = 1024

coast_lat :: [COAST_CELLS * COAST_CELLS]f32

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
	ux := ((u % 1) + 1) % 1
	vx := ((v % 1) + 1) % 1
	gx := ux * cells
	gy := vx * cells
	x0 := cast(int)(math.floor(gx))
	y0 := cast(int)(math.floor(gy))
	fx := gx - f64(x0)
	sy := gy - f64(y0)
	sx := fx * fx * (3 - 2 * fx)
	sy = sy * sy * (3 - 2 * sy)
	x0m := x0 %% cells
	y0m := y0 %% cells
	i00 := f64(coast_lat[y0m*COAST_CELLS + x0m])
	i10 := f64(coast_lat[y0m*COAST_CELLS + ((x0 + 1) %% cells)])
	i01 := f64(coast_lat[(y0 + 1) %% cells * COAST_CELLS + x0m])
	i11 := f64(coast_lat[(y0 + 1) %% cells * COAST_CELLS + ((x0 + 1) %% cells)])
	return (i00*(1 - sx) + i10*sx) * (1 - sy) + (i01*(1 - sx) + i11*sx) * sy
}

coast_wob :: proc(u: f64, v: f64) -> f64 {
	return (coast_sample(u, v) - 0.5) * COAST_WOBBLE
}

coast_limit :: [COAST_LIMIT_N + 1]f32

coast_limit_table :: proc() {
	for i := 0; i <= COAST_LIMIT_N; i += 1 {
		t := f64(i)/f64(COAST_LIMIT_N) * 4
		side := min(3, cast(int)(math.floor(t)))
		s := t - f64(side)
		var px f64 = 0
		var pz f64 = 0
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
	var t f64
	if ax >= az {
		pz := z / ax
		t = if x > 0 { (pz + 1) / 2 } else { 2 + (1 - pz) / 2 }
	} else {
		px := x / az
		t = if z > 0 { 1 + (1 - px) / 2 } else { 3 + (px + 1) / 2 }
	}
	f := math.min(f64(COAST_LIMIT_N), math.max(0, t/4*f64(COAST_LIMIT_N)))
	i0 := cast(int)(math.floor(f))
	i1 := min(COAST_LIMIT_N, i0 + 1)
	a := f - f64(i0)
	return f64(coast_limit[i0])*(1 - a) + f64(coast_limit[i1])*a
}

t_terrain :: proc(size: f64, seed: string, spawns: [4][2]f64) -> terrain {
	coast_lat_build()
	coast_limit_table()

	t := terrain{size: size, seed: seed}
	usable := size - 80
	tile := usable / 7

	// The rotation the scarce types use is about the first spawn's angle; the
	// arena's four are the ideal circle, so this is the one the whole layout shares.
	a0 := m_atan2(spawns[0][1], spawns[0][0])
	sector := (math.pi * 2) / 4

	st := hash_seed(seed)
	if st == 0 {
		st = 42
	}
	draw := func() f64 {
		a := st
		v := mulberry_next(&a) // the state is a + K; the mix never touches it
		st = a
		return cast(f64)(v) / 4294967296.0
	}

	// scatterEqual(type, total, amount): the 7x7 grid, equal per tile.
	scatter_equal :: proc(ntype: i32, total: f64, amount: f64) {
		per := f64(math.max(1, math.round(total / 49)))
		for tx := 0; tx < 7; tx += 1 {
			for tz := 0; tz < 7; tz += 1 {
				x0 := -usable/2 + f64(tx)*tile
				z0 := -usable/2 + f64(tz)*tile
				inset := f64(6)
				for i := 0; i < cast(int)(per); i += 1 {
					x := x0 + inset + draw()*(tile - inset*2)
					z := z0 + inset + draw()*(tile - inset*2)
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
	scatter_rotational :: proc(ntype: i32, total: f64, amount: f64) {
		per := f64(math.max(1, math.round(total / 4)))
		R := size/2 - 40    // same usable radius the grid's box spans
		rMin := f64(60)      // nothing on the map's navel
		KEEP_OUT := f64(95)  // no stone/gold this close to ANY Town Center
		for i := 0; i < cast(int)(per); i += 1 {
			var r f64 = rMin
			var ang f64 = a0
			for tries := 0; tries < 60; tries += 1 {
				u := draw()
				r = math.sqrt(rMin*rMin + u*(R*R - rMin*rMin))
				ang = a0 + (draw() - 0.5)*sector
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

	// medium: food 196 x 0.5, wood 784 x 1, stone 40 x 1, gold 18 (no mods entry).
	t.scatter_equal(0, 196*0.5, 500)        // food
	t.scatter_equal(1, 784*1.0, 300)        // wood
	t.scatter_rotational(2, 40*1.0, 1000)  // stone
	t.scatter_rotational(3, 18, 2000)       // gold

	// The four Town Centers clear whatever node sits within clearance + 3 of
	// their spawn, in seat order (resourceClearance('town_center') = 5 + 4.5);
	// the survivor list is the node space every later read (and the fixtures) uses.
	clear_near :: proc(x: f64, z: f64, radius: f64) {
		j := 0
		for i := 0; i < t.n_nodes; i += 1 {
			n := &t.nodes[i]
			if m_hypot(n.x - x, n.z - z) < radius {
				continue
			}
			t.nodes[j] = *n
			j += 1
		}
		t.n_nodes = j
	}
	for s in 0 ..< 4 {
		clear_near(spawns[s][0], spawns[s][1], 9.5 + 3)
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
		angle := f64(i)/f64(4) * math.pi * 2 - math.pi/2
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

type res_state struct {
	food, wood, stone, gold f64
}

type unit_state struct {
	handle int
	x, z   f64
	health f64
}

type bldg_state struct {
	id         string
	x, z       f64
	health     f64
	max_health f64
}

// WarRng.keyed(seed): {seed, n: {}}, and draw: the key's n-th value, counted
// per key so one key's draws never move another's.
type keyed_rng struct {
	seed string
	n    map[string]u32
}

krng_draw :: proc(k: ^keyed_rng, key: string) -> f64 {
	n := k.n[key] // 0 on first use, as `state.n[key] || 0`
	k.n[key] = n + 1
	return keyed_draw(k.seed, key, n)
}

type seat struct {
	ci       int
	id       string // 'ai_egyptian_golden' and friends
	units    [3]unit_state
	n_units  int
	home     bldg_state
	res      res_state
	pop      int // resources.updatePopulation(units.length) each step
	max_pop  int // the ResourceManager's starting cap: 10, the TC's contribution
	known    [900]byte // _knownResIdx: node index -> seen
	seen_amt [900]f64 // the seen amount the harness caches with the node
	seen_set [900]byte
	explored [42 * 42]byte // the exploration bitmap, one per 19-unit cell
	k        keyed_rng
}

type game_state struct {
	seats    [4]seat
	terrain  terrain
	match_ms f64 // clock.matchMs: 50 per step at the arena's 1x pace
	step_no  int
}

// resetTimeline: a fresh match — population 0, the match clock 0, the
// discovery beat 0, no pending events, the exploration bitmaps blank.
setup :: proc(g: ^game_state, spawns: [4][2]f64) {
	g.match_ms = 0
	g.step_no = 0
	for i in 0 ..< 4 {
		s := &g.seats[i]
		c := &civs[i]
		s.ci = i
		s.id = "ai_" + c.id + "_golden"
		s.k.seed = "golden"
		sp := spawns[i]

		// The Town Center, at the spawn, finished (createBuilding, age 'stone').
		def := bldg_def_by_id("town_center")
		mh := building_max_health(def, i, "stone")
		s.home = bldg_state{id: "town_center", x: sp[0], z: sp[1], health: mh, max_health: mh}

		// The three workers: each axis one keyed draw of the seat's own stream,
		// 's<i>:start-workers', n = 0..5 (x then z, worker by worker).
		key := "s" + fmt.i32(i32(i)) + ":start-workers"
		for w in 0 ..< 3 {
			x := sp[0] + (krng_draw(&s.k, key) - 0.5) * 10
			z := sp[1] + (krng_draw(&s.k, key) - 0.5) * 10
			s.units[w] = unit_state{handle: w + 1, x: x, z: z, health: 40}
			s.n_units += 1
		}

		// The ResourceManager's opening balances (resources.js's constructor).
		s.res = res_state{food: 200, wood: 200, stone: 100, gold: 50}
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
	if !b.id == "" {
		range := building_vision(b)
		dx := b.x - x
		dz := b.z - z
		if math.sqrt(dx*dx + dz*dz) <= range {
			return true
		}
	}
	return false
}

type eye struct {
	x, z, r f64
	cell     i32
}

type eye_set struct {
	cells  [1600]i32 // cell -> first eye index, -1 for none
	next   [64]i32   // next in the cell's chain
	eyes   [64]eye
	n      int
}

// buildVisionTest (harness mode): the eye grid is rebuilt each step, because
// the eyes move. Eyes are filed where their RANGE reaches, not where they
// stand: an eye in a cell sees up to one ring of cells around it.
make_eyes :: proc(s: ^seat) -> eye_set {
	var es eye_set
	for c in 0 ..< 1600 {
		es.cells[c] = -1
	}
	es.n = 0
	G := 40
	CELL := f64(20)
	half := f64(400)

	file :: proc(x: f64, z: f64, r: f64) {
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
					es.cells[c] = idx
				}
			}
		}
		es.eyes[idx] = eye{x: x, z: z, r: r}
		es.n += 1
	}

	for i in 0 ..< s.n_units {
		u := &s.units[i]
		if u.health > 0 {
			x := f64(math.round(u.x))
			z := f64(math.round(u.z))
			file(x, z, unit_vision(u))
		}
	}
	b := &s.home
	if b.health > 0 {
		file(b.x, b.z, building_vision(b))
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
	return string(rune('A' + cast(int32)(col))) + fmt.i32(i32(row + 1))
}

exploration_summary :: proc(s: ^seat) -> [7][7]i32 {
	var out [7][7]i32
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

const JW_SIZE = 262144

type jw struct {
	buf [JW_SIZE]byte
	n   int
	sep bool // a comma goes before the next element
}

j_val :: proc(j: ^jw) {
	if j.sep {
		j.buf[j.n] = ','
		j.n += 1
	}
	j.sep = true
}

j_str :: proc(j: ^jw, s string) {
	j_val(j)
	j.buf[j.n] = '"'
	j.n += 1
	copy(j.buf[j.n:len(s)+j.n], s)
	j.n += len(s)
	j.buf[j.n] = '"'
	j.n += 1
}

j_int :: proc(j: ^jw, v i64) {
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

j_bool :: proc(j: ^jw, b bool) {
	j_val(j)
	if b {
		copy(j.buf[j.n:j.n+4], "true")
	} else {
		copy(j.buf[j.n:j.n+5], "false")
	}
	j.n += 4 if b else 5
}

j_null :: proc(j: ^jw) {
	j_val(j)
	copy(j.buf[j.n:j.n+4], "null")
	j.n += 4
}

// The one float the state view carries: the bonus multipliers (1.2, 0.7).
// fmt.f64 is the shortest decimal that round-trips, the same rule the
// engine's Number.prototype.toString obeys.
j_f64 :: proc(j: ^jw, v f64) {
	j_val(j)
	s := fmt.f64(v)
	copy(j.buf[j.n:len(s)+j.n], s)
	j.n += len(s)
}

// A key: a comma if it is not the first in its object, then "name":, and the
// value that follows owes the object nothing until it is written.
j_key :: proc(j: ^jw, k string) {
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

AGES_ORDER :: [4]string = ["stone", "neolithic", "bronze", "iron"]

age_idx :: proc(a: string) -> i32 {
	for i, x in AGES_ORDER {
		if x == a {
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

type nearby_node struct {
	ntype  i32
	x, z   i32
	amount f64
}

type obs_scratch struct {
	by    [4][200]nearby_node
	n_by  [4]int
	// the nearby map: insertion-ordered, keyed by the rounded "x,z" pair; a
	// later set with the same key replaces the value in place (Map semantics)
	key_x [200]i32
	key_z [200]i32
	val   [200]nearby_node
	n_key int
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
		return math.nan, true // floor of the missing cache entry: NaN, as upstream
	}
	return 0, false
}

type unit_entry struct {
	id       string
	cost     cost4
	age      string
	at       string
	blocked  [8]string
	n_block  int
}

type bldg_entry struct {
	btype    string
	req_age  string
	req_tech string
	cost     cost4
	is_wonder bool
	built_as string
	blocked  [8]string
	n_block  int
}

type obs struct {
	g       ^game_state
	j       ^jw
	s       ^seat
	scratch obs_scratch
	t_ms    i64
}

// One fixture line: {"seat":i,"playerId":"seat<i>","t":T,"state":{...}}.
observe_line :: proc(o: ^obs) {
	g := o.g
	s := o.s
	j := o.j
	size := g.terrain.size

	j_obj(j)

	// ---- the seat's own coordinates in the document.
	j_key(j, "seat")
	j_int(j, i64(s.ci))
	j_key(j, "playerId")
	j_str(j, "seat" + fmt.i32(i32(s.ci)))
	j_key(j, "t")
	j_int(j, o.t_ms)
	j_key(j, "state")
	j_obj(j)

	// ---- player.
	c := &civs[s.ci]
	j_key(j, "player")
	j_obj(j)
	j_key(j, "id")
	j_str(j, "seat" + fmt.i32(i32(s.ci)))
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
	j_int(j, cast(i64)(math.round(g.match_ms / 1000)))
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

	// ---- bonuses: the civ effects the seat carries (the reference's
	//      workerHarvestBonus / techCostMultiplier, 1.0 omitted).
	j_key(j, "bonuses")
	j_obj(j)
	if c.honus_harvest != 1.0 {
		j_key(j, "harvest")
		j_f64(j, c.honus_harvest)
	}
	if c.honus_techcost != 1.0 {
		j_key(j, "techCostMult")
		j_f64(j, c.honus_techcost)
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
	j_int(j, cast(i64)(math.round(s.home.x)))
	j_key(j, "z")
	j_int(j, cast(i64)(math.round(s.home.z)))
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
	var disc [4]i64 = [4]i64{}
	var total [4]i64 = [4]i64{}
	for i in 0 ..< g.terrain.n_nodes {
		n := &g.terrain.nodes[i]
		if n.amount > 0 {
			total[n.n_type] += 1
		}
		amt, _ := known_amount(s, i, n.x, n.z, n.amount, true)
		if amt > 0 {
			disc[n.n_type] += 1
			bucket := &sc.by[n.n_type]
			bucket[sc.n_by[n.n_type]] = nearby_node{ntype: n.n_type,
				x: cast(i32)(math.round(n.x)), z: cast(i32)(math.round(n.z)), amount: amt}
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
				sc.val[i] = *e
				return
			}
		}
		sc.key_x[sc.n_key] = e.x
		sc.key_z[sc.n_key] = e.z
		sc.val[sc.n_key] = *e
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

	ax := math.round(s.home.x)
	az := math.round(s.home.z)
	var cand [200]nearby_node
	var cd   [200]f64
	for it in 0 ..< sc.n_by[0] { // food
		e := &sc.by[0][it]
		cd[it] = m_hypot(f64(e.x) - ax, f64(e.z) - az)
		cand[it] = *e
	}
	// stable: later items pass only while strictly nearer
	for i in 1 ..< sc.n_by[0] {
		e := cand[i]
		d := cd[i]
		for k := i - 1; k >= 0 && cd[k] > d; k -= 1 {
			cand[k+1] = cand[k]
			cd[k+1] = cd[k]
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
		cand[it] = *e
	}
	for i in 1 ..< sc.n_by[1] {
		e := cand[i]
		d := cd[i]
		for k := i - 1; k >= 0 && cd[k] > d; k -= 1 {
			cand[k+1] = cand[k]
			cd[k+1] = cd[k]
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
		j_int(j, cast(i64)(math.round(e.amount)))
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
		j_int(j, cast(i64)(math.round(b.x)))
		j_key(j, "z")
		j_int(j, cast(i64)(math.round(b.z)))
		j_key(j, "healthPct")
		j_int(j, cast(i64)(math.round(b.health/b.max_health*100)))
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
			j_int(j, cast(i64)(math.round(e.x)))
			j_key(j, "z")
			j_int(j, cast(i64)(math.round(e.z)))
			j_key(j, "healthPct")
			j_int(j, cast(i64)(math.round(e.health/e.max_health*100)))
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
			j_int(j, cast(i64)(math.round(u.x)))
			j_key(j, "z")
			j_int(j, cast(i64)(math.round(u.z)))
			j_key(j, "healthPct")
			j_int(j, cast(i64)(math.round(u.health/40*100)))
			j_end_obj(j)
		}
	}
	j_end_arr(j)

	// ---- workers: the seat's units by job. An idle worker is one with no
	//      task, attack, or harvest in flight -- at turn 1 all of them.
	j_key(j, "workers")
	j_obj(j)
	var idle i64 = 0
	for i in 0 ..< s.n_units {
		if s.units[i].health > 0 {
			idle += 1
		}
	}
	j_key(j, "idle")
	j_int(j, idle)
	j_key(j, "gatherFood")
	j_int(j, 0)
	j_key(j, "gatherWood")
	j_int(j, 0)
	j_key(j, "gatherStone")
	j_int(j, 0)
	j_key(j, "gatherGold")
	j_int(j, 0)
	j_key(j, "attack")
	j_int(j, 0)
	j_key(j, "attackMove")
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
	tc_cost_mult := c.honus_techcost
	for t in 0 ..< c.n_techs {
		te := &c.techs[t]
		if age_idx(te.req_age) > age_idx("stone") {
			continue
		}
		cc := cost4{floor4(te.cost.food, tc_cost_mult), floor4(te.cost.wood, tc_cost_mult),
			floor4(te.cost.stone, tc_cost_mult), floor4(te.cost.gold, tc_cost_mult)}
		at := "town_center"
		if te.research_at != "" {
			at = te.research_at
		}
		var bl [8]string
		var nbl int
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
		j_str(j, te.id)
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
		if nbl > 0 {
			j_key(j, "blockedBy")
			j_arr(j)
			for k in 0 ..< nbl {
				j_str(j, bl[k])
			}
			j_end_arr(j)
		}
		j_end_obj(j)
	}
	j_end_arr(j)
	j_end_obj(j)

	// ---- unlockedContent: which unit of which age each building could train
	//      right now, and which ages' buildings could be raised. Every gate is
	//      `age reached` here (the seats are stone), so the shape is the
	//      whole tree with only the stone rows set.
	j_key(j, "unlockedContent")
	j_obj(j)
	j_key(j, "training")
	j_obj(j)
	for h in 0 ..< 5 {
		if c.unit_hosts[h] == "" {
			continue
		}
		j_key(j, c.unit_hosts[h])
		j_obj(j)
		for a in 0 ..< 4 {
			if !age_reached("stone", AGES_ORDER[a]) {
				continue
			}
			j_key(j, AGES_ORDER[a])
			j_obj(j)
			for u in 0 ..< c.n_units {
				udef := &c.units[u]
				if udef.at == c.unit_hosts[h] && udef.tier == AGES_ORDER[a] {
					j_key(j, udef.id)
					j_bool(j, age_reached("stone", udef.tier))
				}
		}
			j_end_obj(j)
		}
		j_end_obj(j)
	}
	j_end_obj(j) // training
	j_key(j, "building")
	j_obj(j)
	j_key(j, "stone")
	j_bool(j, true) // the tier-stone buildings exist for every civ
	j_end_obj(j)
	j_end_obj(j) // unlockedContent

