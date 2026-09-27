//! Map generation, ported from terrain.js.
//!
//! The layout is seeded: a fixed seed reproduces the exact map. Two scatter
//! schemes, both ported operation-for-operation:
//! - `scatter_equal`: the PLENTIFUL types (food, wood). The map is split into a
//!   7x7 grid of equal tiles and every tile receives the same number of nodes,
//!   placed uniformly within it.
//! - `scatter_rotational`: the SCARCE types (stone, gold). One player's sector is
//!   laid out, then rotated onto every other player, so per-player equality holds
//!   for any seat count without divisibility.
//!
//! After generation, each spawn's resources are cleared within the Town Center
//! clearance radius (game.js:338), which removes (not empties) the nodes — the
//! difference matters: fog memory stores array indices.

use crate::prng::Mulberry32;

/// One resource node, in the exact field order the reference keeps.
#[derive(Debug, Clone, PartialEq)]
pub struct Resource {
    pub r#type: String,
    pub x: f64,
    pub z: f64,
    pub amount: i64,
    pub health: i64,
}

/// The finished map: spawn positions plus the resource array in generation order.
#[derive(Debug, Clone)]
pub struct Map {
    pub seed: String,
    pub difficulty: String,
    pub seats: usize,
    pub size: i64,
    pub spawns: Vec<(f64, f64)>,
    pub resources: Vec<Resource>,
}

/// The map's own size in world units. The arena runs 800 (game.js:79); the
/// reference's headless recorder runs the TerrainManager's 200 default.

/// game.js:293-305 — one spawn per arena participant, evenly spaced on a circle.
pub fn spawn_positions(n: usize) -> Vec<(f64, f64)> {
    let half_size = (400.0) - 40.0; // mapSize 800 / 2 - 40
    let radius = half_size * 0.85;
    (0..n)
        .map(|i| {
            let angle = (i as f64 / n as f64) * std::f64::consts::TAU - std::f64::consts::FRAC_PI_2;
            (angle.cos() * radius, angle.sin() * radius)
        })
        .collect()
}

/// terrain.js:137-155 — the fair scatter for the plentiful types.
fn scatter_equal(rand: &mut Mulberry32, size: i64, out: &mut Vec<Resource>, r#type: &str, total: f64, amount: i64) {
    let margin = 40.0;
    let usable = (size as f64) - margin * 2.0;
    let g = 7.0;
    let tile = usable / g;
    let per = (total / (g * g)).round().max(1.0) as usize;
    for tx in 0..7 {
        for tz in 0..7 {
            let x0 = -usable / 2.0 + tx as f64 * tile;
            let z0 = -usable / 2.0 + tz as f64 * tile;
            for _ in 0..per {
                let inset = 6.0; // stay off the tile seams (visual clumping)
                let x = x0 + inset + rand.next_f64() * (tile - inset * 2.0);
                let z = z0 + inset + rand.next_f64() * (tile - inset * 2.0);
                out.push(Resource { r#type: r#type.to_string(), x, z, amount, health: amount });
            }
        }
    }
}

/// terrain.js:182-209 — per-player equality by rotating one sector onto the rest.
fn scatter_rotational(
    rand: &mut Mulberry32,
    size: i64,
    out: &mut Vec<Resource>,
    r#type: &str,
    total: f64,
    amount: i64,
    spawns: &[(f64, f64)],
) {
    if spawns.is_empty() {
        return scatter_equal(rand, size, out, r#type, total, amount); // no match context: grid it
    }
    let n = spawns.len();
    let per = (total / n as f64).round().max(1.0) as usize;
    let r_max = (size as f64 / 2.0) - 40.0; // same usable radius the grid's box spans
    let r_min = 60.0; // nothing on the map's navel
    let keepout = 95.0; // no stone/gold this close to ANY Town Center
    let sector = std::f64::consts::TAU / n as f64;
    let a0 = spawns[0].1.atan2(spawns[0].0);
    for _ in 0..per {
        let mut r = r_min;
        let mut t = a0;
        for _ in 0..60 {
            let u = rand.next_f64();
            r = (r_min * r_min + u * (r_max * r_max - r_min * r_min)).sqrt();
            t = a0 + (rand.next_f64() - 0.5) * sector;
            let (px, pz) = (t.cos() * r, t.sin() * r);
            if !spawns.iter().any(|(sx, sz)| ((px - sx).hypot(pz - sz)) < keepout) {
                break;
            }
        }
        for p in 0..n {
            let ang = t + p as f64 * sector;
            out.push(Resource {
                r#type: r#type.to_string(),
                x: ang.cos() * r,
                z: ang.sin() * r,
                amount,
                health: amount,
            });
        }
    }
}

/// terrain.js:211-301 — the four scatter passes, in order: food, wood, stone, gold.
/// The order is part of the seed: the single PRNG stream is shared across passes.
fn difficulty_mods(difficulty: &str) -> (f64, f64, f64) {
    match difficulty {
        "easy" => (2.0, 1.0, 1.0),
        "medium" => (0.5, 1.0, 1.0),
        "hard" => (0.25, 0.25, 0.5),
        d => panic!("unknown difficulty {d}"),
    }
}

/// The seeded scatters, then Town Center clearance per spawn, in seat order
/// (game.js:326-357). Takes the caller's PRNG so the same stream can keep
/// drawing after the map — the initial worker jitter continues it
/// (state.rs) exactly as the reference's startGame does.
pub fn generate_map(
    rand: &mut Mulberry32,
    size: i64,
    difficulty: &str,
    seats: usize,
) -> (Vec<(f64, f64)>, Vec<Resource>) {
    let spawns = spawn_positions(seats);
    let (food_m, wood_m, stone_m) = difficulty_mods(difficulty);

    let mut resources: Vec<Resource> = Vec::new();
    scatter_equal(rand, size, &mut resources, "food", 196.0 * food_m, 500);
    scatter_equal(rand, size, &mut resources, "wood", 784.0 * wood_m, 300);
    scatter_rotational(rand, size, &mut resources, "stone", 40.0 * stone_m, 1000, &spawns);
    scatter_rotational(rand, size, &mut resources, "gold", 18.0, 2000, &spawns);

    // game.js:338 — clear any resource node under each starting Town Center.
    // clearance('town_center') = 5 + 4.5 = 9.5, plus the 3 the call site adds.
    let clearance = 9.5 + 3.0;
    for (sx, sz) in &spawns {
        let keep: Vec<Resource> = resources
            .drain(..)
            .filter(|r| (r.x - sx).hypot(r.z - sz) >= clearance)
            .collect();
        resources = keep;
    }

    (spawns, resources)
}

/// Build the map from a seed: the seeded scatters, then Town Center clearance
/// per spawn, in seat order.
pub fn build_map(seed: &str, difficulty: &str, seats: usize, size: i64) -> Map {
    let mut rand = Mulberry32::from_seed(seed);
    let (spawns, resources) = generate_map(&mut rand, size, difficulty, seats);

    Map {
        seed: seed.to_string(),
        difficulty: difficulty.to_string(),
        seats,
        size,
        spawns,
        resources,
    }
}

/// The one-line fingerprint the reference recorder writes (record.cjs `__map__`),
/// positions in integer millimetres. Byte-identical to the JS line is the diff.
pub fn fingerprint_line(map: &Map) -> String {
    let mm = |v: f64| (v * 1000.0).round() as i64;
    let mut s = String::with_capacity(map.resources.len() * 72 + 512);
    s.push_str("{\"playerId\":\"__map__\",\"type\":\"map\"");
    s.push_str(&format!(",\"seed\":\"{}\"", map.seed));
    s.push_str(&format!(",\"difficulty\":\"{}\"", map.difficulty));
    s.push_str(&format!(",\"seats\":{},\"size\":{}", map.seats, map.size));
    s.push_str(",\"spawns\":[");
    for (i, (x, z)) in map.spawns.iter().enumerate() {
        if i > 0 { s.push(','); }
        s.push_str(&format!("{{\"x\":{},\"z\":{}}}", mm(*x), mm(*z)));
    }
    s.push_str("],\"resources\":[");
    for (i, r) in map.resources.iter().enumerate() {
        if i > 0 { s.push(','); }
        s.push_str(&format!(
            "{{\"t\":\"{}\",\"x\":{},\"z\":{},\"a\":{},\"h\":{}}}",
            r.r#type, mm(r.x), mm(r.z), r.amount, r.health
        ));
    }
    s.push_str("]}");
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spawn_circle_is_deterministic_and_rounds_clean() {
        let s = spawn_positions(4);
        assert_eq!(s.len(), 4);
        // (0, -306), (306, 0), (0, 306), (-306, 0) in millimetres
        let mm = |v: f64| (v * 1000.0).round() as i64;
        assert_eq!((mm(s[0].0), mm(s[0].1)), (0, -306000));
        assert_eq!((mm(s[1].0), mm(s[1].1)), (306000, 0));
        assert_eq!((mm(s[2].0), mm(s[2].1)), (0, 306000));
        assert_eq!((mm(s[3].0), mm(s[3].1)), (-306000, 0));
    }

    #[test]
    fn easy_four_seat_map_shape() {
        let map = build_map("smoke", "easy", 4, 800);
        // node counts after TC clearance (clearance only touches the food/wood grid:
        // every stone/gold node sits at radius 60 from centre, far from the 306 spawns)
        let count = |t: &str| map.resources.iter().filter(|r| r.r#type == t).count();
        assert_eq!(count("food"), 392 - cleared(&map, "food"));
        assert!(count("wood") > 700);
        assert_eq!(count("stone"), 40);
        assert_eq!(count("gold"), 20); // round(18/4) = 5 per player, x4
    }

    fn cleared(map: &Map, t: &str) -> usize {
        // the reference's own totals (state turn-1 `nodes.totalOnMap`) minus survivors
        let total = match t {
            "food" => 392,
            "wood" => 784,
            _ => 0,
        };
        total - map.resources.iter().filter(|r| r.r#type == t).count()
    }
}
