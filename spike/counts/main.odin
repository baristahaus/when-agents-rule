package main

// The map gate's cheap first step: reproduce the node COUNTS of the golden map before trying to
// place a single node. It is worth doing because the counts are a real gate, not a warm-up: they
// come from the difficulty table and the scatter rules, and they land on the golden's four numbers
// only if no node was ever dropped. 98/784/40/20 is what a full port must print before it prints
// any coordinate, and a wrong table or a silently dropped node shows up here rather than 900 lines
// later in a byte-diff nobody can localize.
//
// The four call sites, from js/terrain.js, with the base counts rather than the multipliers,
// because the multipliers are applied against the call site (the table's own comment spends a
// paragraph on that confusion):
//
//     scatterEqual('food',       196 * mods.food,  500)
//     scatterEqual('wood',       784 * mods.wood,  300)
//     scatterRotational('stone',  40 * mods.stone, 1000)
//     scatterRotational('gold',         18,        2000)   // no difficulty entry by design
//
// The two scatters round differently, and that is the whole trick: the grid scatter divides by 49
// tiles and is exact at every preset (medium food 98/49 = 2 per tile), while the rotational one
// divides by the seat count and rounds UP so every seat gets the same share — gold 18 across 4
// seats becomes 5 each, i.e. 20, which is the "repays the rounding" note in the source and the
// reason the golden holds 20 gold and not 18.

import "core:fmt"
import "core:math"
import "core:os"

Mods :: struct { food, wood, stone: f64 }

diff_mods :: proc(name: string) -> Mods {
	if name == "easy" { return Mods{2.0, 1.0, 1.0} }
	if name == "hard" { return Mods{0.25, 0.25, 0.5} }
	return Mods{0.5, 1.0, 1.0}   // medium, and the fallback the JS table uses
}

// JS `Math.max(1, Math.round(total/N)) * N`. Round-to-nearest, NOT ceil: the difference is visible
// in the source's own comment — stone is 40 at two or four seats but **39 at three**, which ceil
// would have made 42. My first version of this proc used ceil and its printed output happened to
// agree at four seats, which is exactly how a wrong rounding rule survives.
js_round :: proc(x: f64) -> int {
	return int(math.floor(x + 0.5))
}

rotational_total :: proc(total: int, seats: int) -> int {
	if seats <= 0 { return total }
	per := js_round(cast(f64)(total) / cast(f64)(seats))
	if per < 1 { per = 1 }
	return per * seats
}

// The grid scatter's rule, spelled out: per-tile count is max(1, round(total/49)) and the world
// total is that times 49, so the golden's food 98 and wood 784 are 2 and 16 per tile exactly.
grid_total_from_base :: proc(total: int) -> int {
	per := js_round(cast(f64)(total) / 49.0)
	if per < 1 { per = 1 }
	return per * 49
}

Counts :: struct { food, wood, stone, gold: int }

layout :: proc(difficulty: string, seats: int) -> Counts {
	m := diff_mods(difficulty)
	// The multipliers are float by source, and the products are whole at every preset. Round once,
	// at the point the JS would have to; do not trust `int()` to truncate in the right direction.
	food := int(196.0 * m.food + 0.5)
	wood := int(784.0 * m.wood + 0.5)
	stone := int(40.0 * m.stone + 0.5)
	return Counts{
		food  = grid_total_from_base(food),
		wood  = grid_total_from_base(wood),
		stone = rotational_total(stone, seats),
		gold  = rotational_total(18, seats),
	}
}

main :: proc() {
	difficulty := "medium"
	seats := 4
	if len(os.args) >= 2 { difficulty = os.args[1] }
	if len(os.args) >= 3 {
		s := 0
		for c in os.args[2] { s = s * 10 + int(c) - int('0') }
		seats = s
	}

	got := layout(difficulty, seats)

	// The golden is `medium`, 4 seats. Any other argument prints what that choice implies and
	// does not claim a pass, so the file stays useful as a table probe.
	want := Counts{98, 784, 40, 20}
	fmt.printfln("{} seats={} -> food={} wood={} stone={} gold={} (total {})",
		difficulty, seats, got.food, got.wood, got.stone, got.gold,
		got.food + got.wood + got.stone + got.gold)

	if difficulty != "medium" || seats != 4 {
		// The 3-seat stone figure is a test of the rounding rule, not of the golden: the source
		// says 39, ceil would say 42. Checked here so the rule cannot quietly regress.
		if difficulty == "medium" && seats == 3 && got.stone != 39 {
			fmt.printfln("3-seat stone is {} and the source says 39 — the rounding rule regressed", got.stone)
			panic("rotational rounding is not JS round-to-nearest")
		}
		fmt.println("not the golden configuration; nothing asserted against it")
		return
	}
	if got.food != want.food || got.wood != want.wood || got.stone != want.stone || got.gold != want.gold {
		fmt.printfln("MISMATCH: expected food={} wood={} stone={} gold={}",
			want.food, want.wood, want.stone, want.gold)
		panic("node counts do not match the golden map")
	}
	fmt.println("COUNTS GREEN: 98/784/40/20, the golden map's breakdown")
}
