//! Sight, exploration and labour: the pure helpers the brain and the state
//! builder call.
//!
//! Everything here is either a function of a single entity (a unit's or a
//! building's vision, a seat's exploration bitmap) or a free function over
//! the map — none of it takes the match, so a brain method may use them
//! while holding its own seat. The radii are the reference's
//! (game.js:3577, 3583); the fog gate is fogofwar.js:69: an AI seat's own
//! live eyes and nothing else.

use std::collections::HashSet;

use crate::data::WorldData;
use crate::mapgen::{Map, Resource};
use crate::prng::Mulberry32;

use super::model::{Building, Resources, Seat, Unit};

/// A park-and-spread offset, ±k/2 (game.js:2008). A free function so a brain
/// method may draw from the shared stream without re-borrowing the match.
pub fn rand_jitter(prng: &mut Mulberry32, k: f64) -> f64 {
    (prng.next_f64() - 0.5) * k
}

/// The sight radius of a single unit (game.js:3577): cavalry see 50%
/// farther; a researched vision bonus multiplies per unit.
pub fn unit_vision(u: &Unit) -> f64 {
    let base = if u.unit_type == "cavalry" {
        22.5
    } else {
        15.0
    };
    let bonus = if u.vision_bonus > 0.0 { u.vision_bonus } else { 1.0 };
    base * bonus
}

/// The shared sight radii (game.js:3583): a construction site sees nothing,
/// a tower sees far, a finished wonder is a long-range landmark.
pub fn building_vision(b: &Building) -> f64 {
    if b.under_construction {
        return 0.0;
    }
    if b.r#type == "tower" {
        return 80.0;
    }
    if b.is_wonder {
        return 60.0;
    }
    if b.r#type == "town_center" {
        return 40.0;
    }
    20.0
}

impl Seat {
    /// fogofwar.js:69 — the gate an AI seat's discovery runs through: in
    /// sight of the seat's own living units or buildings right now.
    pub fn is_visible_to(&self, x: f64, z: f64) -> bool {
        for u in &self.units {
            if u.health > 0.0 {
                let range = unit_vision(u);
                if (u.x - x).hypot(z - u.z) <= range {
                    return true;
                }
            }
        }
        for b in &self.buildings {
            if b.health > 0.0 {
                let range = building_vision(b);
                if range > 0.0 && (b.x - x).hypot(z - b.z) <= range {
                    return true;
                }
            }
        }
        false
    }

    /// game.js:4275 — stamp the 42×42 "ever seen" bitmap from the seat's
    /// live eyes. A construction site grants zero radius and marks exactly
    /// the cell it stands in; the range-0 mark reproduces that.
    pub fn mark_exploration(&mut self, map_size: i64) {
        const G: usize = 42;
        if self.explored.is_empty() || self.explored.len() != G * G {
            self.explored = vec![false; G * G];
        }
        let size = map_size as f64;
        let cell = size / G as f64;
        let half = size / 2.0;
        let grid = &mut self.explored;
        let mut mark = |x: f64, z: f64, range: f64| {
            let cr = (range / cell).ceil() as i32;
            let cx = ((x + half) / cell).floor() as i32;
            let cz = ((z + half) / cell).floor() as i32;
            for dz in -cr..=cr {
                for dx in -cr..=cr {
                    let gx = cx + dx;
                    let gz = cz + dz;
                    if gx < 0 || gx >= G as i32 || gz < 0 || gz >= G as i32 {
                        continue;
                    }
                    let wx = (gx as f64 + 0.5) * cell - half;
                    let wz = (gz as f64 + 0.5) * cell - half;
                    if (wx - x).hypot(wz - z) <= range {
                        grid[(gz as usize) * G + (gx as usize)] = true;
                    }
                }
            }
        };
        for u in &self.units {
            if u.health > 0.0 {
                mark(u.x, u.z, unit_vision(u));
            }
        }
        for b in &self.buildings {
            if b.health > 0.0 {
                mark(b.x, b.z, building_vision(b));
            }
        }
    }

    /// game.js:4307 — the 7×7 grid of 0-100 percentages, row 0 = north,
    /// col 0 = west.
    pub fn exploration_summary(&self) -> [[u32; 7]; 7] {
        const T: usize = 7;
        const G: usize = 42;
        let s = G as f64 / T as f64; // 6 bitmap cells per tile side
        let mut out = [[0u32; 7]; 7];
        if self.explored.is_empty() {
            return out;
        }
        for tz in 0..T {
            for tx in 0..T {
                let mut seen = 0.0;
                for z in (tz as f64 * s) as usize..((tz + 1) as f64 * s) as usize {
                    for x in (tx as f64 * s) as usize..((tx + 1) as f64 * s) as usize {
                        seen += f64::from(self.explored[z * G + x]);
                    }
                }
                out[tz][tx] = (seen / (s * s) * 100.0).round() as u32;
            }
        }
        out
    }

    /// game.js:4350 — the centre (and percent) of the seat's darkest 7×7
    /// tile; ties break in reading order (the north-west corner first).
    pub fn least_explored_section(&self, map_size: i64) -> (f64, f64, u32) {
        let sum = self.exploration_summary();
        const T: usize = 7;
        let size = map_size as f64;
        let tile = size / T as f64;
        let (mut br, mut bc) = (0, 0);
        for r in 0..T {
            for c in 0..T {
                if sum[r][c] < sum[br][bc] {
                    br = r;
                    bc = c;
                }
            }
        }
        (
            ((bc as f64 + 0.5) * tile - size / 2.0).round(),
            ((br as f64 + 0.5) * tile - size / 2.0).round(),
            sum[br][bc],
        )
    }

    /// The task a pulled worker resumes on: the triage price of pulling it.
    /// game.js:3313 — builders and fighters are never pulled (infinite);
    /// scouts are the last resort, a scout mid-walk loses the whole walk.
    pub fn worker_pull_rank(&self, u: &Unit, resources: &[Resource]) -> f64 {
        if u.task == "building" || u.is_building {
            return f64::INFINITY;
        }
        if u.is_attacking || u.attack_target.is_some() || u.attack_move.is_some() {
            return f64::INFINITY;
        }
        if u.task == "repairing" {
            return 5.0;
        }
        if u.farm_ref.is_some() || u.task == "farm_work" {
            return 6.0;
        }
        if u.task == "scouting" {
            return 7.0;
        }
        if (u.task == "harvesting" || u.task == "carrying") && u.harvest_target.is_some() {
            // Fattest stockpile first: 1 … 4. Stable sort, like the reference.
            let mut order = ["food", "wood", "stone", "gold"];
            order.sort_by(|a, b| self.resources.value(b).total_cmp(&self.resources.value(a)));
            let t = resources
                .get(u.harvest_target.unwrap())
                .map(|r| r.r#type.clone())
                .unwrap_or_default();
            let idx = order.iter().position(|&x| x == t).unwrap_or(3);
            return 1.0 + idx as f64;
        }
        0.0
    }
}

/// game.js:3544 — keep a point inside the map, a margin from the edge.
pub fn clamp_to_map(x: f64, z: f64, map_size: i64, margin: f64) -> (f64, f64) {
    let half = map_size as f64 / 2.0 - margin;
    (x.max(-half).min(half), z.max(-half).min(half))
}

/// The walkable ring a building keeps around a resource node
/// (game.js:3555).
pub fn resource_clearance(building_type: &str, is_wonder: bool) -> f64 {
    let half = if building_type == "town_center" || is_wonder {
        5.0
    } else {
        3.5
    };
    half + 4.5
}

/// game.js:3561 — a placement over or inside the ring of any live node is
/// refused. Depleted nodes do not block.
pub fn is_too_close_to_resource(
    map: &Map,
    x: f64,
    z: f64,
    building_type: &str,
    is_wonder: bool,
) -> bool {
    let clr = resource_clearance(building_type, is_wonder);
    for r in &map.resources {
        if r.amount <= 0 {
            continue;
        }
        if (r.x - x).hypot(r.z - z) < clr {
            return true;
        }
    }
    false
}

/// The resource the seat needs most right now (ai.js:214): food gates
/// workers, age-ups and military; otherwise the leanest of the four stocks.
pub fn needed_resource_type(r: &Resources) -> &'static str {
    if r.food < 200.0 {
        return "food";
    }
    let mut best = "wood";
    let mut best_val = f64::INFINITY;
    for t in ["food", "wood", "gold", "stone"] {
        let v = r.value(t);
        if v < best_val {
            best_val = v;
            best = t;
        }
    }
    best
}

/// The nearest DISCOVERED node (optionally of a type) with anything left
/// (ai.js:226). The index is into the map's resource list.
pub fn find_known_resource(
    resources: &[Resource],
    known: &HashSet<usize>,
    x: f64,
    z: f64,
    r#type: Option<&str>,
) -> Option<usize> {
    let mut nearest = None;
    let mut min_dist = f64::INFINITY;
    // JS Set iteration is insertion order; a HashSet's is not — the reference
    // walks the discovered set, so collect the same index set (order only
    // breaks exact ties in distance, which the reference resolves by first).
    let mut idxs: Vec<usize> = known.iter().copied().collect();
    idxs.sort_unstable();
    for i in idxs {
        let r = match resources.get(i) {
            Some(r) => r,
            None => continue,
        };
        if r.amount <= 0 {
            continue;
        }
        if let Some(t) = r#type {
            if r.r#type != t {
                continue;
            }
        }
        let d = (r.x - x).hypot(r.z - z);
        if d < min_dist {
            min_dist = d;
            nearest = Some(i);
        }
    }
    nearest
}

/// game.js:3291 — a worker with nothing to do.
pub fn is_idle_worker(u: &Unit) -> bool {
    u.r#type == "worker"
        && u.health > 0.0
        && !u.is_building
        && u.task != "building"
        && u.task != "harvesting"
        && u.task != "carrying"
        && u.task != "farm_work"
        && !u.is_harvesting
        && !u.carrying_resource
        && u.farm_ref.is_none()
}

/// The outcome of picking a builder (game.js:3343).
pub enum BuilderPick {
    /// The worker's index in the seat, whether it is borrowed, and what it
    /// was doing (the report the caller may want to say out loud).
    Chosen {
        worker: usize,
        restore: bool,
        was_doing: Option<String>,
    },
    NoWorkers,
    NoIdle,
}

/// game.js:3343 — price every worker in SECONDS: the walk to the site plus
/// the cost of interrupting its task — and take the cheapest.
pub fn pick_builder(seat: &Seat, resources: &[Resource], sx: f64, sz: f64) -> BuilderPick {
    const PULL_SECS: [f64; 8] = [0.0, 4.0, 6.0, 8.0, 10.0, 14.0, 18.0, 45.0];
    let mut best: Option<(usize, f64, bool, Option<String>)> = None;
    for (i, u) in seat.units.iter().enumerate() {
        if u.r#type != "worker" || u.health <= 0.0 {
            continue;
        }
        let rank = seat.worker_pull_rank(u, resources);
        if rank.is_infinite() {
            continue;
        }
        let s = if u.speed > 0.0 { u.speed * 3.0 } else { 3.0 };
        let walk = (u.x - sx).hypot(u.z - sz) / s;
        let cost = walk + PULL_SECS[(rank as usize).min(7)];
        if let Some((_, bcost, _, _)) = best {
            if bcost <= cost {
                continue;
            }
        }
        let was_doing = if u.task == "scouting" {
            Some("scouting".to_string())
        } else if u.farm_ref.is_some() || u.task == "farm_work" {
            Some("farming".to_string())
        } else if u.task == "repairing" {
            Some("repairing".to_string())
        } else if u.harvest_target.is_some() {
            Some("gathering".to_string())
        } else {
            None
        };
        best = Some((i, cost, rank > 0.0, was_doing));
    }
    match best {
        Some((worker, _, restore, was_doing)) => BuilderPick::Chosen {
            worker,
            restore,
            was_doing,
        },
        None => {
            if seat.units.iter().any(|u| u.r#type == "worker" && u.health > 0.0) {
                BuilderPick::NoIdle
            } else {
                BuilderPick::NoWorkers
            }
        }
    }
}

/// game.js:3372 — configure the chosen worker for the site, saving its task
/// if borrowed.
pub fn apply_builder(seat: &mut Seat, pick: &BuilderPick, site_id: &str) -> bool {
    let BuilderPick::Chosen {
        worker,
        restore,
        ..
    } = pick
    else {
        return false;
    };
    let Some(w) = seat.units.get_mut(*worker) else {
        return false;
    };
    if *restore {
        w.former_task = Some(super::model::FormerTask {
            task: std::mem::take(&mut w.task),
            harvest_target: w.harvest_target,
            farm_ref: w.farm_ref.clone(),
        });
    } else {
        w.former_task = None;
    }
    if let Some(farm) = &w.farm_ref {
        if let Some(f) = seat.buildings.iter_mut().find(|b| &b.id == farm) {
            if f.assigned_worker.as_deref() == Some(&w.id) {
                f.assigned_worker = None;
            }
        }
    }
    w.farm_ref = None;
    w.task = "building".to_string();
    w.build_target = Some(site_id.to_string());
    w.is_moving = false;
    w.is_harvesting = false;
    w.carrying_resource = false;
    true
}

/// game.js:3598 — the population cap is derived from what stands, never
/// accumulated.
pub fn recompute_max_population(
    resources: &mut Resources,
    buildings: &[Building],
    world: &WorldData,
) {
    let mut slots: u32 = 0;
    for b in buildings {
        if b.under_construction || b.health <= 0.0 {
            continue;
        }
        if let Some(def) = world.get_building_def(&b.r#type) {
            slots += def.pop_bonus;
        }
    }
    resources.max_population = world.max_population_cap.min(slots);
}
