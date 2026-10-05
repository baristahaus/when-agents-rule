package main

// Gate 2e: the map line itself. This file is a transcription, not a design: it reimplements
// js/terrain.js's placement and tools/golden/record.cjs's serialisation, and the gate is `cmp`
// against golden/map-line-b1040.json — 47,098 bytes, no tolerance. The gates before this one
// (vectors, counts, coastline) were each a cheaper way of failing early; this is the thing they
// were preparing for.
//
// The chain, with the source of each fact:
//
//   rand            = WarRng.stream(hashSeed("golden"), 42)     terrain.js _initRand, seed is the
//                                                                 map-seed STRING (game.js:392),
//                                                                 not a derived number
//   one stream      for every scatter, in this order: food, wood, stone, gold — the order
//                 is the call order in generateTerrain, and it is why a port that parallelises
//                 the four scatters cannot work
//   scatterEqual    7x7 tiles over the usable box, per tile = max(1, round(total/49)),
//                 inset 6, two draws per node                                  terrain.js:130
//   scatterRotational  per seat = max(1, round(total/seats)), one sector apart, r drawn
//                    area-uniformly, 60 tries against the Town-Center keep-out   terrain.js:178
//   serialise       {playerId,type,seed,difficulty,seats,size,spawns,resources}, nodes as
//                 {t,x,z,a,h} with x,z = Math.round(units*1000)                record.cjs:316,335
//
// What is NOT here yet, and is therefore taken as input rather than derived: the four spawns.
// They are placed by game.js, which this port has not reached, so they arrive as the golden's
// own values (±306 units on the axes). That is a real dependency, not a cheat — stone and gold
// positions are rotations about the spawn circle's centre and are tested against every Town
// Center — and the port owes the spawn placement as its next piece.

import "core:fmt"
import "core:math"
import "core:os"

SIZE        :: 800.0
GRID        :: 7
MARGIN      :: 40.0
INSET       :: 6.0
R_MIN       :: 60.0
KEEP_OUT    :: 95.0
TRIES       :: 60
MM_PER_UNIT :: 1000.0

MAX_SEATS :: 4

// Conditions come from the command line, defaulting to the golden's own. A port that only ever
// reproduces one configuration is a port that only ever tests one branch of every table it
// transcribes, and the four fixtures in golden/ disagree in exactly the places that matter: the
// difficulty multipliers, and the rotational rounding at two and three seats (alpha/hard/3 has 21
// stone, which is round(20/3)=7 per seat, and beta/medium/4 has the same 942 as golden with a
// different stream in it).
seed_str   := "golden"
difficulty := "medium"
seats      := 4

Rand :: struct { a: u32 }

hash_seed :: proc(text: string) -> u32 {
	h: u32 = 1779033703 ~ (cast(u32)(len(text)))
	for b in text {
		h = (h ~ (cast(u32)(b))) * 3432918353
		h = (h << 13) | (h >> 19)
	}
	return h
}

stream_new :: proc(seed: string) -> Rand {
	a := hash_seed(seed)
	if a == 0 { a = 42 }   // stream(seed, fallback=42), the map generator's own fallback
	return Rand{a}
}

rand_next :: proc(r: ^Rand) -> f64 {
	r.a = r.a + 0x6D2B79F5
	t := (r.a ~ (r.a >> 15)) * (r.a | 1)
	t = (t + (t ~ (t >> 7)) * (t | 61)) ~ t
	v := t ~ (t >> 14)
	return cast(f64)(v) / 4294967296.0
}

Vec2 :: struct { x, z: f64 }

// The difficulty table as terrain.js writes it: multipliers against the call-site base, plus the
// food/wood/stone bases and the two amounts the scatters carry. Gold has no entry — deliberately
// identical at every preset, because the scarcest resource should not be what separates them.
Mods :: struct { food, wood, stone: f64 }

mods_for :: proc(name: string) -> Mods {
	if name == "easy" { return Mods{2.0, 1.0, 1.0} }
	if name == "hard" { return Mods{0.25, 0.25, 0.5} }
	return Mods{0.5, 1.0, 1.0}
}

// Spawn placement, ported from game.js:369-381 rather than copied from the golden — this used to
// be the map gate's one recorded input, and it is the reason the stone and gold rotations land
// where they do.
//
//   mapSize 800; halfSize = 400 - 40 = 360; radius = halfSize * 0.85 = 306
//   angle(i) = (i / numPlayers) * 2π - π/2
//
// One coordinate space, since 5 October 2026. The recorded lines had carried two — nodes in a
// 200-unit world, because the recorder constructed its TerrainManager without the size argument
// and the constructor default 200 applied, while spawns sat on the 306-unit circle of the game's
// 800-unit world. The recorder is fixed (record.cjs now passes 800, as js/game.js and realm.cjs
// always did) and the fixtures are re-recorded; the map is one 800-world now, and the Town Center
// clearance — a structural no-op when the spawns sat outside the island — removes nodes in every
// recorded condition (golden loses one wood node, alpha/easy two, alpha/hard one, beta four).
//
// A variable rather than a constant because Odin refuses to index a constant with a variable index
// — a fair rule, since the thing being indexed here is exactly the kind of value a transcription
// must not smuggle in as a constant.
spawn_positions :: proc(n: int) -> [MAX_SEATS]Vec2 {
	map_size := 800.0
	half := map_size / 2.0 - 40.0
	radius := half * 0.85
	out: [MAX_SEATS]Vec2
	for i in 0 ..< n {
		angle := cast(f64)(i) / cast(f64)(n) * math.PI * 2.0 - math.PI / 2.0
		out[i] = Vec2{math.cos(angle) * radius, math.sin(angle) * radius}
	}
	return out
}

spawns:  [MAX_SEATS]Vec2
n_seats := MAX_SEATS

js_round :: proc(x: f64) -> int { return int(math.floor(x + 0.5)) }
hypot    :: proc(x, z: f64) -> f64 { return math.sqrt(x * x + z * z) }

Node :: struct { t: string, x, z: f64, a: int }

Nodes :: struct {
	items: [2048]Node,
	n:     int,
}

push :: proc(self: ^Nodes, t: string, x, z: f64, a: int) {
	self.items[self.n] = Node{t, x, z, a}
	self.n += 1
}

// clearResourcesNear (js/game.js / terrain.js): the survivors keep their order.
clear_near :: proc(out: ^Nodes, x: f64, z: f64, radius: f64) {
	j := 0
	for i in 0 ..< out.n {
		it := out.items[i]
		if hypot(it.x - x, it.z - z) < radius {
			continue
		}
		out.items[j] = it
		j += 1
	}
	out.n = j
}

// terrain.js:130 — the plentiful types. Equal per CELL, two draws per node, and the draws happen
// tile by tile in tx-then-tz order, which fixes the stream's consumption and therefore every
// coordinate after it.
scatter_equal :: proc(out: ^Nodes, r: ^Rand, t: string, total: int, amount: int) {
	usable := SIZE - MARGIN * 2.0
	tile := usable / cast(f64)(GRID)
	per := js_round(cast(f64)(total) / cast(f64)(GRID * GRID))
	if per < 1 { per = 1 }
	for tx in 0 ..< GRID {
		for tz in 0 ..< GRID {
			x0 := -usable / 2.0 + cast(f64)(tx) * tile
			z0 := -usable / 2.0 + cast(f64)(tz) * tile
			for _ in 0 ..< per {
				x := x0 + INSET + rand_next(r) * (tile - INSET * 2.0)
				z := z0 + INSET + rand_next(r) * (tile - INSET * 2.0)
				push(out, t, x, z, amount)
			}
		}
	}
}

// terrain.js:178 — the scarce types. Equal per PLAYER: draw one node in seat 0's sector, then
// rotate that same radius and angle onto every seat. Radius is drawn uniform by AREA between
// rMin 60 and the usable radius 360 — at the true 800-world size the draw spreads, and the
// recorded stone and gold radii range over that interval.
scatter_rotational :: proc(out: ^Nodes, r: ^Rand, t: string, total: int, amount: int) {
	per := js_round(cast(f64)(total) / cast(f64)(n_seats))
	if per < 1 { per = 1 }
	radius_max := SIZE / 2.0 - 40.0
	sector := math.PI * 2.0 / cast(f64)(n_seats)
	a0 := math.atan2(spawns[0].z, spawns[0].x)
	for _ in 0 ..< per {
		rr := R_MIN
		tt := a0
		for _ in 0 ..< TRIES {
			u := rand_next(r)
			rr = math.sqrt(R_MIN * R_MIN + u * (radius_max * radius_max - R_MIN * R_MIN))
			tt = a0 + (rand_next(r) - 0.5) * sector
			// Only the seats actually in play. Iterating the whole fixed array left the unfilled
			// tail at the origin, and the origin is 60 units from every candidate — inside the 95
			// keep-out — so at two and three seats every candidate looked too close, the retry loop
			// burned draws, and the angles came from the wrong place in the stream. The node COUNT
			// stayed perfect, which is why the counts gate stayed green the whole time.
			close := false
			for p in 0 ..< n_seats {
				if hypot(math.cos(tt) * rr - spawns[p].x, math.sin(tt) * rr - spawns[p].z) < KEEP_OUT { close = true }
			}
			if !close { break }
		}
		for p in 0 ..< n_seats {
			ang := tt + cast(f64)(p) * sector
			push(out, t, math.cos(ang) * rr, math.sin(ang) * rr, amount)
		}
	}
}

// ---- serialisation, done with a fixed buffer and a hand-rolled itoa -------------------------
// Why by hand: `fmt` in this compiler substitutes `{}` and nothing else, so a JSON template full
// of braces is a minefield, and a builder would allocate 47 KB per run and need a teardown the
// leak tracker cannot yet verify. A 64 KB buffer and eleven lines of integer printing cost less
// than either risk, and the output is byte-exact by construction.

Buf :: struct { b: [65536]u8, n: int }

put :: proc(self: ^Buf, s: string) {
	copy(self.b[self.n:self.n + len(s)], s)
	self.n += len(s)
}

put_int :: proc(self: ^Buf, v: int) {
	if v == 0 {
		put(self, "0")
		return
	}
	digits: [20]u8
	neg := v < 0
	m := v
	if neg { m = -m }
	dn := 0
	for m > 0 {
		digits[dn] = cast(byte)(int('0') + m %% 10)
		m = m / 10
		dn += 1
	}
	if neg { put(self, "-") }
	i := dn - 1
	for ; i >= 0; i -= 1 { put(self, string(digits[i:i + 1])) }
}

// record.cjs:316 — positions serialise in whole millimetres, and `Math.round` is half-up, which
// is why this file spells the rounding out instead of trusting an int cast's direction.
mm :: proc(v: f64) -> int { return js_round(v * MM_PER_UNIT) }

main :: proc() {
	// Filled here, not at global scope: Odin forbids context-requiring calls (which trig is) in a
	// global initialiser, and that is the right rule — it keeps a value this port must get right out
	// of the constant pool and into the code path that is under test.
	if len(os.args) >= 2 { seed_str = os.args[1] }
	if len(os.args) >= 3 { difficulty = os.args[2] }
	if len(os.args) >= 4 {
		v := 0
		for c in os.args[3] { v = v * 10 + int(c) - int('0') }
		seats = v
	}
	if seats < 2 || seats > MAX_SEATS { panic("seats must be 2, 3 or 4") }
	n_seats = seats

	spawns = spawn_positions(seats)
	m := mods_for(difficulty)

	r := stream_new(seed_str)
	out: Nodes

	diff_food := 196.0 * m.food
	diff_wood := 784.0 * m.wood
	diff_stone := 40.0 * m.stone

	scatter_equal(&out, &r, "food", js_round(diff_food), 500)
	scatter_equal(&out, &r, "wood", js_round(diff_wood), 300)
	scatter_rotational(&out, &r, "stone", js_round(diff_stone), 1000)
	scatter_rotational(&out, &r, "gold", 18, 2000)

	// The Town Center clearance, in seat order, before the map is dumped
	// (js/game.js: the same step the turn-1 port transcribes; radius
	// resourceClearance('town_center') + 3 = 12.5).
	for p in 0 ..< seats {
		clear_near(&out, spawns[p].x, spawns[p].z, 12.5)
	}

	buf: Buf
	put(&buf, "{\"playerId\":\"__map__\",\"type\":\"map\",\"seed\":\"")
	put(&buf, seed_str)
	put(&buf, "\",\"difficulty\":\"")
	put(&buf, difficulty)
	put(&buf, "\",\"seats\":")
	put_int(&buf, seats)
	put(&buf, ",\"size\":")
	put_int(&buf, int(SIZE))
	put(&buf, ",\"spawns\":[")
	for p in 0 ..< seats {
		if p > 0 { put(&buf, ",") }
		put(&buf, "{\"x\":")
		put_int(&buf, mm(spawns[p].x))
		put(&buf, ",\"z\":")
		put_int(&buf, mm(spawns[p].z))
		put(&buf, "}")
	}
	put(&buf, "],\"resources\":[")
	for i in 0 ..< out.n {
		if i > 0 { put(&buf, ",") }
		it := out.items[i]
		put(&buf, "{\"t\":\"")
		put(&buf, it.t)
		put(&buf, "\",\"x\":")
		put_int(&buf, mm(it.x))
		put(&buf, ",\"z\":")
		put_int(&buf, mm(it.z))
		put(&buf, ",\"a\":")
		put_int(&buf, it.a)
		put(&buf, ",\"h\":")
		put_int(&buf, it.a)
		put(&buf, "}")
	}
	put(&buf, "]}")

	fmt.printfln("{}", string(buf.b[0:buf.n]))
}
