//! The match driver: the reference's `game.js:tick` and everything it calls,
//! for the spectator-mode (arena) path only.
//!
//! The recorder's loop is one 100 ms beat: advance the fake clock, call
//! `tick()`. `tick()` in the reference (game.js:694-780):
//!
//! - clamps the elapsed real time to 2000 ms (`MAX_CATCHUP`) — a single
//!   100 ms beat keeps the clamp inert, but the port keeps the shape;
//! - refreshes each seat's population counter FIRST (derived data is read
//!   later in the same tick, so it is computed before its readers);
//! - runs the brain's `update` (discovery beat + think beat);
//! - samples the match timeline (5 s cadence);
//! - replays the budgeted time in ≤100 ms `simulateStep` slices;
//! - clamps strays back ashore;
//! - runs the win conditions (arena: held Wonder, last standing, wipeout).
//!
//! Deferred from this port, with the reason for each (nothing in a one-minute
//! window exercises any of them):
//! - the combat cluster (`updateCombat` / `updateHealing` / `updateTowerAttack`
//!   / `updateAutoDefense` / `pruneBattles`): no attack is possible in the
//!   window — the brain's army never reaches strength 8, and the first
//!   military it trains (militia, ~T=22 s) has no enemy in range for 38 more
//!   seconds. The model carries the fields; the cluster lands with increment 2.
//! - `fogOfWar.update`: the seat exploration bitmap it feeds is already
//!   refreshed on the brain's 250 ms discovery beat (see `brain`), which is
//!   the only consumer the 1-minute window has.
//! - `keepUnitsAshore` needs the terrain's shoreline table, which the map
//!   module does not model (mapgen documents the gap). No unit dies in the
//!   window and every move stays near the base, so the sweep changes nothing;
//!   the test asserts the premise.
//! - standing orders: the brain issues none.

use serde::Serialize;

use crate::data::Cost;
use crate::model::{AgeUpgrade, Match, ResearchJob, Seat};

use super::brain::Brain;
use super::progress;
use super::worker;

impl Match {
    /// One 100 ms recorder beat: advance the clock, run the reference tick.
    pub fn step(&mut self) {
        self.t += 100.0;
        if !self.game_started {
            return;
        }
        let elapsed = (self.t - self.last_frame_time).max(0.0);
        self.last_frame_time = self.t;
        let sim_time = elapsed.min(2000.0); // MAX_CATCHUP
        self.tick(sim_time);
    }

    /// `game.js:694-780` — one tick, with `sim_time` the (clamped) elapsed ms.
    fn tick(&mut self, sim_time: f64) {
        // Population is derived FIRST: the brain and the state both read it.
        for s in &mut self.seats {
            s.resources.population = s.unit_ids.len() as u32;
        }
        Brain::update(self, sim_time);
        self.sample_timeline();
        // pruneBattles: time-driven battle expiry — increment 2 (no battles here).

        // simBudget: no Wonder stands, no pause, simSpeed 1 → the time itself.
        let budgeted = sim_time;
        let mut rem = budgeted;
        while rem > 0.0 {
            let slice = rem.min(100.0);
            self.simulate_step(slice);
            rem -= slice;
        }
        self.keep_units_ashore();
        self.check_win_conditions(budgeted);
        self.step += 1;
    }

    /// `game.js:811-842` — one ≤100 ms slice.
    fn simulate_step(&mut self, dt: f64) {
        // standing orders + formation lead: increment 2.
        worker::update_worker_tasks(self, dt);
        worker::update_unit_movement(self, dt);
        progress::update_production(self, dt);
        progress::update_farm_regeneration(self, dt);
        // updateCombat / updateHealing / updateTowerAttack / updateAutoDefense:
        // increment 2.
        // fogOfWar.update: deferred (see module docs).
        progress::update_research_progress(self, dt);
        progress::update_age_upgrade_progress(self, dt);
        // renderer.simulateStep: no renderer here.
    }

    /// `game.js:3480-3497` — the shoreline clamp. See the module docs: a no-op
    /// in this window (the map does not model the shoreline table, and no unit
    /// ever leaves the grass it started on).
    fn keep_units_ashore(&mut self) {
        // no-op — see module docs.
    }

    // -- win conditions --------------------------------------------------------

    /// `game.js:5704-5758` — the spectator branch decides between the AIs.
    fn check_win_conditions(&mut self, delta_time: f64) {
        if !self.game_started {
            return;
        }
        self.check_arena_end(delta_time);
    }

    /// `game.js:5841-5867`.
    fn check_arena_end(&mut self, delta_time: f64) {
        let wonder_types = ["pyramid", "akropolis", "firetemple", "shrine"];
        let required = 600.0 * 1000.0; // wonderRequired 600 s
        let n = self.seats.len();

        // Defeat is terminal for the seat.
        for (i, s) in self.seats.iter_mut().enumerate() {
            if self.is_player_eliminated(i) {
                s.eliminated = true;
            }
        }

        let mut wonder_holder: Option<usize> = None;
        for (i, s) in self.seats.iter().enumerate() {
            if s.eliminated {
                continue;
            }
            let has_wonder = s.building_ids.iter().any(|&b| {
                let b = &self.buildings[b];
                (b.is_wonder || wonder_types.contains(&b.r#type.as_str())) && !b.under_construction
            });
            if has_wonder {
                self.seats[i].wonder_hold += delta_time;
                if self.seats[i].wonder_hold >= required {
                    wonder_holder = Some(i);
                }
            } else {
                self.seats[i].wonder_hold = 0.0;
            }
        }
        if let Some(h) = wonder_holder {
            self.end_arena(Some(h), "wonder");
            return;
        }

        let alive: Vec<usize> = (0..n)
            .filter(|&i| !self.is_player_eliminated(i))
            .collect();
        if alive.len() == 1 && n > 1 {
            self.end_arena(Some(alive[0]), "last_standing");
            return;
        }
        if alive.is_empty() {
            self.end_arena(None, "mutual_destruction");
        }
    }

    /// `game.js:5870-5946` — the sim-side half of the ending: the match stops;
    /// the reference's final-words/UI handoff is the harness's, not the sim's.
    fn end_arena(&mut self, winner: Option<usize>, reason: &str) {
        if !self.game_started {
            return;
        }
        self.game_started = false;
        self.winner = winner;
        self.ended_reason = Some(reason.to_string());
    }

    /// `game.js:5771-5781` — the one elimination rule, arena and campaign.
    pub fn is_player_eliminated(&self, seat: usize) -> bool {
        let s = &self.seats[seat];
        if s.eliminated {
            return true;
        }
        // Has an army: any living non-worker.
        if s.unit_ids
            .iter()
            .any(|&u| self.units[u].health > 0.0 && self.units[u].r#type != "worker")
        {
            return false;
        }
        if self.can_afford_any_military(seat) {
            return false;
        }
        // Has a Town Center.
        if s.building_ids
            .iter()
            .any(|&b| {
                let b = &self.buildings[b];
                b.health > 0.0 && b.r#type == "town_center"
            })
        {
            return false;
        }
        // Or a worker plus the resources to build a new one.
        let tc_def = self.world.get_building_def("town_center");
        let tc_cost = tc_def.map(|d| d.cost);
        if s.unit_ids
            .iter()
            .any(|&u| self.units[u].health > 0.0 && self.units[u].r#type == "worker")
        {
            if let Some(c) = tc_cost {
                if s.resources.has(&c) {
                    return false;
                }
            }
        }
        true
    }

    /// `game.js:5785-5817`.
    fn can_afford_any_military(&self, seat: usize) -> bool {
        let s = &self.seats[seat];
        if s.resources.population >= s.resources.max_population {
            return false;
        }
        let age_order = ["stone", "neolithic", "bronze", "iron"];
        let a_idx = age_order.iter().position(|a| a == &s.age).unwrap_or(0);
        for &b in &s.building_ids {
            let b = &self.buildings[b];
            if !(b.health > 0.0) {
                continue;
            }
            if !b.under_construction
                && b.is_producing
                && b.production_type.as_deref() != Some("worker")
            {
                return true;
            }
            if b.under_construction
                && !s.unit_ids.iter().any(|&u| {
                    let u = &self.units[u];
                    u.health > 0.0
                        && u.r#type == "worker"
                        && u.task.as_deref() == Some("building")
                        && u.build_target == Some(b)
                })
            {
                continue;
            }
            for uid in self.train_options_for(seat, b) {
                if uid == "worker" {
                    continue;
                }
                let def = match self.world.get_unit_def_for(&s.civ, &uid) {
                    Some(d) => d,
                    None => continue,
                };
                let tier = def.tier.as_deref().unwrap_or("stone");
                if age_order.iter().position(|a| a == tier).unwrap_or(0) > a_idx {
                    continue;
                }
                if s.resources.has(&def.cost) {
                    return true;
                }
            }
        }
        false
    }

    /// `game.js:5830-5838` — the building's current training list, the same
    /// resolution order the training panel and the model-facing list use.
    fn train_options_for(&self, seat: usize, b: &crate::model::Building) -> Vec<String> {
        let s = &self.seats[seat];
        let tiered = self.world.get_train_options_for_building(&b.r#type, &s.age, &s.civ);
        if !tiered.is_empty() {
            return tiered;
        }
        if !b.train_options.is_empty() {
            return b.train_options.clone();
        }
        if let Some(def) = self.world.get_building_def(&b.r#type) {
            if def.can_train {
                return def.train_options.clone();
            }
        }
        Vec::new()
    }

    // -- the match timeline ------------------------------------------------------

    /// `game.js:3660-3719` — one 5-second sample of every seat.
    fn sample_timeline(&mut self) {
        if self.t - self.tl_last < 5000.0 {
            return;
        }
        self.tl_last = self.t;
        let t = ((self.t - self.tl_t0) / 1000.0).round() as i64;

        let mut p = serde_json::Map::new();
        for (i, s) in self.seats.iter().enumerate() {
            let g = &s.resources.gathered;
            let alive = !s.building_ids.is_empty() || !s.unit_ids.is_empty();
            p.insert(
                s.id.clone(),
                serde_json::json!({
                    "f": (g[0]).round() as i64,
                    "w": (g[1]).round() as i64,
                    "s": (g[2]).round() as i64,
                    "o": (g[3]).round() as i64,
                    "pw": 0, // the recorder's ui.spectatorPowerScore: no ui
                    "al": if alive { 1 } else { 0 },
                }),
            );
            if !alive {
                continue;
            }
            // Age advances.
            let prev = self.tl_age.get(&i).cloned();
            if prev.as_deref() != Some(s.age.as_str()) {
                if let Some(prev) = prev {
                    if prev != s.age {
                        self.tl_ages.push(serde_json::json!({
                            "t": t,
                            "id": s.id,
                            "age": s.age,
                        }));
                    }
                }
                self.tl_age.insert(i, s.age.clone());
            }
            // Dry transitions.
            let disc = self.discovered_node_counts(i);
            let dry = self
                .tl_dry
                .entry(i)
                .or_insert_with(|| [true; 4]);
            for (k, ty) in ["food", "wood", "stone", "gold"].iter().enumerate() {
                let is_dry = disc[ty] == 0;
                if is_dry && !dry[k] {
                    dry[k] = true;
                    self.tl_exhausted.push(serde_json::json!({
                        "t": t,
                        "id": s.id,
                        "type": ty,
                    }));
                } else if !is_dry {
                    dry[k] = false;
                }
            }
        }
        self.tl_samples.push(serde_json::json!({ "t": t, "p": p }));
    }

    /// `game.js:3650-3658` — discovered (by this seat) nodes of each type that
    /// still hold something, live amounts.
    fn discovered_node_counts(&self, seat: usize) -> [u32; 4] {
        let s = &self.seats[seat];
        let mut out = [0u32; 4];
        for (i, r) in self.resources.iter().enumerate() {
            if r.amount <= 0.0 || !s.known_res_idx.contains(&i) {
                continue;
            }
            match r.r#type.as_str() {
                "food" => out[0] += 1,
                "wood" => out[1] += 1,
                "stone" => out[2] += 1,
                "gold" => out[3] += 1,
                _ => {}
            }
        }
        out
    }

    /// `game.js:3625-3633` — a wonder's life on the graph.
    pub fn note_wonder(&mut self, building: &crate::model::Building, event: &str) {
        if !building.is_wonder {
            return;
        }
        let Some(owner) = self.seat_of.get(&building.owner) else {
            return;
        };
        self.tl_wonders.push(serde_json::json!({
            "t": ((self.t - self.tl_t0) / 1000.0).round() as i64,
            "id": self.seats[*owner].id,
            "event": event,
        }));
    }

    // -- the recorded lines ------------------------------------------------------

    /// The `__snap__` line: one per 500 ms of the match clock.
    pub fn snap_line(&self, seq: u32) -> String {
        let seats: Vec<serde_json::Value> = self
            .seats
            .iter()
            .map(|s| {
                serde_json::json!({
                    "seat": s.seat,
                    "age": s.age,
                    "population": s.resources.population,
                    "maxPopulation": s.resources.max_population,
                    "units": s.unit_ids.len(),
                    "buildings": s.building_ids.len(),
                    "eliminated": s.eliminated,
                })
            })
            .collect();
        let line = serde_json::json!({
            "playerId": "__snap__",
            "type": "snap",
            "t": self.t,
            "seq": seq,
            "world": {
                "ages": &self.tl_ages,
                "exhausted": &self.tl_exhausted,
                "seats": seats,
            },
        });
        line.to_string()
    }

    /// The `results` line, written when the match stops (or the clock runs
    /// out — the recorder's `time-limit` ending).
    pub fn results_line(&self) -> String {
        let winner_id = self
            .winner
            .map(|w| self.seats[w].id.clone())
            .unwrap_or_else(|| serde_json::Value::Null);
        let seats: Vec<serde_json::Value> = self
            .seats
            .iter()
            .map(|s| {
                let mut units = serde_json::Map::new();
                let mut buildings = serde_json::Map::new();
                for &u in &s.unit_ids {
                    let u = &self.units[u];
                    if u.health <= 0.0 {
                        continue;
                    }
                    *units.entry(u.r#type.clone()).or_insert(serde_json::json!(0)) +=
                        serde_json::json!(1);
                }
                for &b in &s.building_ids {
                    let b = &self.buildings[b];
                    if b.health <= 0.0 {
                        continue;
                    }
                    *buildings.entry(b.r#type.clone()).or_insert(serde_json::json!(0)) +=
                        serde_json::json!(1);
                }
                serde_json::json!({
                    "seat": s.seat,
                    "civ": s.civ,
                    "age": s.age,
                    "eliminated": s.eliminated,
                    "population": s.resources.population,
                    "maxPopulation": s.resources.max_population,
                    "resources": {
                        "food": s.resources.food.floor(),
                        "wood": s.resources.wood.floor(),
                        "stone": s.resources.stone.floor(),
                        "gold": s.resources.gold.floor(),
                    },
                    "units": units,
                    "buildings": buildings,
                })
            })
            .collect();
        let reason = self.ended_reason.as_deref().unwrap_or("time-limit");
        serde_json::json!({
            "type": "results",
            "endedAt": if self.game_started { serde_json::Value::Null } else { (self.t / 1000.0) as i64 },
            "endedReason": reason,
            "winner": winner_id,
            "seats": seats,
        })
        .to_string()
    }

    /// The `__timeline__` line: the match graph's data, in the reference's
    /// one-line shape.
    pub fn timeline_line(&self) -> String {
        serde_json::json!({
            "type": "timeline",
            "timeline": {
                "t0": 0,
                "samples": &self.tl_samples,
                "ages": &self.tl_ages,
                "exhausted": &self.tl_exhausted,
                "wonders": &self.tl_wonders,
            },
        })
        .to_string()
    }
}
