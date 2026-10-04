//! The live arena match: its model, and the constructors that place it.
//!
//! This is the whole world a match runs on: the seats, their units and
//! buildings, and the resource nodes — as the reference keeps them (the
//! `game.js` / `units.js` / `ai.js` objects, spectator mode only: every seat
//! is driven by the rule-based brain, there is no human player and no LLM
//! pipeline). The driver that steps it lives in `super::match_`; the
//! reference's `createUnit` / `createBuilding` are ported here as the
//! `create_unit` / `create_building` methods, field for field.
//!
//! Conventions, kept from the reference:
//! - Units and buildings live in the match's global `units` / `buildings`
//!   lists; a seat's `unit_ids` / `building_ids` are indices into them, in
//!   creation order (the reference's per-`ai` arrays).
//! - Cross-references are those indices. `Unit::harvest_target` is either a
//!   resource node (an index into `Match::resources`) or a farm (an index
//!   into `Match::buildings`) — the reference's `isFarm` / `farmRef` split.
//! - Ids: the reference mints `unit_<Date.now()>_<9 random chars>`; neither
//!   half is seedable, and nothing but the id's LENGTH is read by simulation
//!   logic (the dead-centre rim spread). The model therefore mints a
//!   fixed-shape 28-character id — the exact length the reference produces —
//!   and the per-owner handle is the identity the state publishes.
//! - The seat's `id` is a config input (the golden match line carries it).
//!   It is a session key, not a map fact.

use std::collections::{HashMap, HashSet};

use serde::Serialize;

use crate::data::{BuildingDef, Cost, UnitDef, WorldData};
use crate::mapgen::{self, Map, Resource};
use crate::prng::Mulberry32;

/// What a unit's `harvest_target` points at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// A resource node: index into `Match::resources`.
    Node(usize),
    /// A farm building: index into `Match::buildings`.
    Farm(usize),
}

/// The job a borrowed worker was doing, so `release_builder` can put it back.
/// The reference's `_formerTask` (game.js:3376).
#[derive(Debug, Clone)]
pub struct FormerTask {
    pub task: String,
    pub harvest_target: Option<Target>,
    pub farm_ref: Option<usize>,
}

/// A live unit, field for field with `units.js:createUnit` (179-233).
#[derive(Debug)]
pub struct Unit {
    pub id: String,
    /// Short, published, per-owner, never reused (units.js:171-177).
    pub handle: u32,
    pub r#type: String,
    pub name: String,
    pub x: f64,
    pub z: f64,
    pub health: f64,
    pub max_health: f64,
    pub speed: f64,
    pub attack: f64,
    pub range: f64,
    /// The combat class ('worker', 'militia', …) — NOT the id string.
    pub unit_type: String,
    /// Owner seat id.
    pub owner: String,
    pub seat: u8,
    pub color: u32,
    pub current_tier: String,
    pub target_x: f64,
    pub target_z: f64,
    pub is_moving: bool,
    pub is_attacking: bool,
    /// Unit or building index (the reference's `attackTarget` is a union).
    pub attack_target: Option<usize>,
    pub attack_target_is_unit: bool,
    pub attack_move: Option<(f64, f64)>,
    pub attack_timer: f64,
    pub harvest_target: Option<Target>,
    pub harvest_amount: f64,
    pub max_harvest: f64,
    pub is_harvesting: bool,
    pub harvest_timer: f64,
    pub is_building: bool,
    pub build_progress: f64,
    pub build_target: Option<usize>,
    pub repair_target: Option<usize>,
    pub farm_ref: Option<usize>,
    pub carrying_resource: bool,
    pub carrying_resource_type: Option<String>,
    pub task: Option<String>,
    pub former_task: Option<FormerTask>,
    pub selected: bool,
    pub vision_bonus: f64,
    pub harvest_rate: f64,
    pub build_speed: f64,
    pub march_speed: Option<f64>,
    pub formation_axis: Option<(f64, f64)>,
    pub formation_group: Option<usize>,
    pub last_attack_time: f64,
    pub last_hit_by: Option<String>,
    pub attack_seq: u32,
    /// The brain's scout leg counter (`_scoutTicks`).
    pub scout_ticks: u32,
}

/// A live building, field for field with `units.js:createBuilding` (286-352).
#[derive(Debug)]
pub struct Building {
    pub id: String,
    pub r#type: String,
    pub name: String,
    /// The epoch it was constructed in (drives look + HP; morphs on age-up).
    pub age: String,
    pub x: f64,
    pub z: f64,
    pub rotation_y: f64,
    pub under_construction: bool,
    pub build_progress: f64,
    pub build_time: f64,
    pub is_wonder: bool,
    pub health: f64,
    pub max_health: f64,
    pub owner: String,
    pub seat: u8,
    pub color: u32,
    pub selected: bool,
    pub can_train: bool,
    pub can_research: bool,
    pub train_options: Vec<String>,
    pub research_options: Vec<String>,
    pub production_queue: Vec<String>,
    pub is_producing: bool,
    pub production_type: Option<String>,
    pub production_progress: f64,
    pub production_time: f64,
    pub production_duration: f64,
    pub attack: f64,
    pub range: f64,
    pub food_amount: f64,
    pub max_food_amount: f64,
    pub regen_timer: f64,
    pub assigned_worker: Option<usize>,
    pub last_damage_time: f64,
}

/// The seat's bank, `resources.js:ResourceManager` (arena path: no UI hook).
#[derive(Debug, Clone, Default)]
pub struct Resources {
    pub food: f64,
    pub wood: f64,
    pub stone: f64,
    pub gold: f64,
    pub population: u32,
    pub max_population: u32,
    /// Lifetime delivered, per type (`gathered` in the reference) — the
    /// timeline's `f`/`w`/`s`/`o` columns read it.
    pub gathered: [f64; 4],
}

impl Resources {
    pub fn food(&self) -> f64 { self.food }
    pub fn wood(&self) -> f64 { self.wood }
    pub fn stone(&self) -> f64 { self.stone }
    pub fn gold(&self) -> f64 { self.gold }

    pub fn has(&self, cost: &Cost) -> bool {
        self.food >= cost.food as f64
            && self.wood >= cost.wood as f64
            && self.stone >= cost.stone as f64
            && self.gold >= cost.gold as f64
    }

    pub fn spend(&mut self, cost: &Cost) {
        self.food -= cost.food as f64;
        self.wood -= cost.wood as f64;
        self.stone -= cost.stone as f64;
        self.gold -= cost.gold as f64;
    }

    /// `resources.js:addResource` — the one funnel every delivery passes,
    /// including the `gathered` lifetime total.
    pub fn add(&mut self, ty: &str, amount: f64) {
        match ty {
            "food" => self.food += amount,
            "wood" => self.wood += amount,
            "stone" => self.stone += amount,
            "gold" => self.gold += amount,
            _ => return,
        }
        let i = match ty {
            "food" => 0,
            "wood" => 1,
            "stone" => 2,
            _ => 3,
        };
        if amount > 0.0 {
            self.gathered[i] += amount;
        }
    }
}

/// A timed research job, as the brain starts it (the game advances it).
#[derive(Debug, Clone)]
pub struct ResearchJob {
    pub tech_id: String,
    pub progress: f64,
    pub duration: f64,
}

/// A timed age upgrade (the brain's `maybeAdvanceAge`; 30s, always).
#[derive(Debug, Clone)]
pub struct AgeUpgrade {
    pub target_age: String,
    pub progress: f64,
    pub duration: f64,
}

/// One match seat: the rule-based AI's `ai` object, plus the fog memory.
#[derive(Debug)]
pub struct Seat {
    pub id: String,
    pub seat: u8,
    pub civ: String,
    pub resources: Resources,
    pub age: String,
    // The arena path never applies a civ's standing bonus (game.js:530-562
    // has no `bonus.effect` call; state.rs documents the same): these stay
    // at the reference's defaults, and are read the same way anyway.
    pub worker_harvest_bonus: f64,
    pub worker_speed_bonus: f64,
    pub worker_build_speed_bonus: f64,
    pub train_speed_bonus: f64,
    pub tech_cost_multiplier: f64,
    pub building_health_multiplier: f64,
    pub researched_techs: HashSet<String>,
    pub current_research: Option<ResearchJob>,
    pub current_age_upgrade: Option<AgeUpgrade>,
    pub unit_ids: Vec<usize>,
    pub building_ids: Vec<usize>,
    // Fog memory (ai.js:56-57).
    pub known_res_idx: HashSet<usize>,
    pub known_res_amt: HashMap<usize, u32>,
    pub known_enemy_buildings: HashSet<usize>,
    // First-contact memory (game.js:updateRivalContacts).
    pub met_rivals: HashSet<usize>,
    // Exploration bitmap (game.js:markExploration): 42×42, row-major, 0/1.
    pub explored: Vec<u8>,
    // The brain's own timers and memory.
    pub explore_timer: u32,
    pub scout_angle: Option<f64>,
    pub scout_radius: f64,
    pub army_scout_ticks: u32,
    pub army_scout_target: Option<(f64, f64)>,
    pub army_scout_angle: Option<f64>,
    pub army_scout_radius: f64,
    pub eliminated: bool,
    pub wonder_hold: f64,
    /// One dry-node notice per (type, rounded position), per owner.
    pub dry_nodes_told: HashSet<String>,
}

/// The match: the world, the clock, and everything the driver mutates.
pub struct Match {
    pub world: WorldData,
    /// The immutable layout (fingerprint material). The live nodes in
    /// `resources` are the same objects the map was built from — the
    /// reference keeps one mutable array; harvesting depletes it in place.
    pub map: Map,
    pub resources: Vec<Resource>,
    /// The terrain's PRNG stream, continued past the map scatter. Every
    /// `rand` / `randJitter` the sim draws from it, in the reference's
    /// order, in order.
    pub rng: Mulberry32,
    pub seats: Vec<Seat>,
    pub units: Vec<Unit>,
    pub buildings: Vec<Building>,
    /// seat id -> seat index.
    pub seat_of: HashMap<String, usize>,
    /// Per-owner unit-handle counters (units.js:171-177).
    pub handles: HashMap<String, u32>,

    // -- the clock ---------------------------------------------------------
    pub t: f64,
    pub last_frame_time: f64,
    pub game_started: bool,
    pub winner: Option<usize>,
    pub ended_reason: Option<String>,
    pub step: u32,

    // -- the match timeline (game.js:resetTimeline / sampleTimeline) --------
    pub tl_t0: f64,
    pub tl_samples: Vec<serde_json::Value>,
    pub tl_ages: Vec<serde_json::Value>,
    pub tl_exhausted: Vec<serde_json::Value>,
    pub tl_wonders: Vec<serde_json::Value>,
    pub tl_last: f64,
    pub tl_age: HashMap<usize, String>,
    pub tl_dry: HashMap<usize, [bool; 4]>,
}

impl Match {
    /// Configuration for `Match::new`. Mirrors the recorder's match line:
    /// a seed, a difficulty, a seat count, and the ids the recorder minted.
    pub fn new(
        world: &WorldData,
        seed: &str,
        difficulty: &str,
        map_size: u32,
        civs: &[String],
        seat_ids: &[String],
    ) -> Self {
        let seats = civs.len();
        let mut rng = Mulberry32::from_seed(seed);
        // The reference's spawn circle is the 800-world's regardless of the
        // terrain size (game.js:466-479); the map is `map_size`.
        let (spawns, map_resources) = mapgen::generate_map(&mut rng, map_size as i64, difficulty, seats);

        let mut match_ = Match {
            world: world.clone(),
            map: Map {
                seed: seed.to_string(),
                difficulty: difficulty.to_string(),
                seats,
                size: map_size as i64,
                spawns: spawns.clone(),
                resources: map_resources.clone(),
            },
            resources: map_resources,
            rng,
            seats: Vec::new(),
            units: Vec::new(),
            buildings: Vec::new(),
            seat_of: HashMap::new(),
            handles: HashMap::new(),
            t: 0.0,
            last_frame_time: 0.0,
            game_started: true,
            winner: None,
            ended_reason: None,
            step: 0,
            tl_t0: 0.0,
            tl_samples: Vec::new(),
            tl_ages: Vec::new(),
            tl_exhausted: Vec::new(),
            tl_wonders: Vec::new(),
            tl_last: 0.0,
            tl_age: HashMap::new(),
            tl_dry: HashMap::new(),
        };

        // The reference's addAIPlayer (ai.js:27-61): the arena loop's seats.
        for (i, (civ, id)) in civs.iter().zip(seat_ids.iter()).enumerate() {
            let mut resources = Resources::default();
            resources.food = 200.0;
            resources.wood = 200.0;
            resources.stone = 100.0;
            resources.gold = 50.0;
            resources.max_population = 10;
            let seat = Seat {
                id: id.clone(),
                seat: i as u8,
                civ: civ.clone(),
                resources,
                age: "stone".into(),
                worker_harvest_bonus: 1.0,
                worker_speed_bonus: 1.0,
                worker_build_speed_bonus: 1.0,
                train_speed_bonus: 1.0,
                tech_cost_multiplier: 1.0,
                building_health_multiplier: 1.0,
                researched_techs: HashSet::new(),
                current_research: None,
                current_age_upgrade: None,
                unit_ids: Vec::new(),
                building_ids: Vec::new(),
                known_res_idx: HashSet::new(),
                known_res_amt: HashMap::new(),
                known_enemy_buildings: HashSet::new(),
                met_rivals: HashSet::new(),
                explored: vec![0u8; mapgen::EXPLORE_GRID * mapgen::EXPLORE_GRID],
                explore_timer: 0,
                scout_angle: None,
                scout_radius: 60.0,
                army_scout_ticks: 0,
                army_scout_target: None,
                army_scout_angle: None,
                army_scout_radius: 90.0,
                eliminated: false,
                wonder_hold: 0.0,
                dry_nodes_told: HashSet::new(),
            };
            match_.seat_of.insert(id.clone(), i);
            match_.seats.push(seat);
        }

        // game.js:startGame (523-562), per seat, in seat order: the Town
        // Center first, then three workers, then the population counter.
        for i in 0..seats {
            let (sx, sz) = match_.map.spawns[i];
            let civ = match_.seats[i].civ.clone();
            let owner = match_.seats[i].id.clone();
            let tc = match_.create_building("town_center", sx, sz, &owner, &civ, false, Some("stone"));
            match_.seats[i].building_ids.push(tc);

            for _ in 0..3 {
                let w = match_.create_unit(
                    "worker",
                    sx + match_.rand_jitter(10.0),
                    sz + match_.rand_jitter(10.0),
                    &owner,
                    &civ,
                    "stone",
                );
                match_.seats[i].unit_ids.push(w);
            }
            match_.seats[i].resources.population = match_.seats[i].unit_ids.len() as u32;
        }

        match_
    }

    // -- the terrain's random ----------------------------------------------

    /// `game.js:107-115` / `terrain.js:138`: one draw, scaled to `[-j, j]`.
    pub fn rand_jitter(&mut self, j: f64) -> f64 {
        self.rng.next() * 2.0 * j - j
    }

    /// `this.rand()` — the terrain stream itself.
    pub fn rand(&mut self) -> f64 {
        self.rng.next()
    }

    // -- creation ------------------------------------------------------------

    fn building_max_health(def: &BuildingDef, civ: &crate::data::Civilization, age: &str) -> f64 {
        // units.js:251-263.
        if def.kind == "wonder" {
            return def.health.max(50) as f64;
        }
        let mult = match civ.name.as_str() {
            "Pyramide" => 1.5,
            "Akropolis" => 1.3,
            _ => 1.0,
        };
        let order = ["stone", "neolithic", "bronze", "iron"];
        let idx = order.iter().position(|a| a == age).unwrap_or(0).max(0);
        (def.health as f64 * 1.5f64.powi(idx as i32) * mult / 50.0).round() * 50.0
    }

    /// `units.js:createBuilding` (286-352). Returns the new building's index.
    pub fn create_building(
        &mut self,
        ty: &str,
        x: f64,
        z: f64,
        owner: &str,
        civ: &str,
        under_construction: bool,
        age_opt: Option<&str>,
    ) -> usize {
        let civd = self.world.get_civilization(civ).expect("civ for create_building");
        let unique = civd.unique_buildings.iter().find(|b| b.id == ty);
        let def = match unique.or_else(|| self.world.get_building_def(ty)) {
            Some(d) => d,
            None => panic!("no building def for {ty}"),
        };
        let age_order = ["stone", "neolithic", "bronze", "iron"];
        let age = match age_opt.filter(|a| age_order.contains(a)) {
            Some(a) => a,
            None => "stone",
        };
        let max_health = Self::building_max_health(def, civd, age);
        let build_time = if def.build_time > 0 { def.build_time as f64 } else { 10000.0 };
        let is_farm = ty == "farm";
        let owner_idx = *self.seat_of.get(owner).expect("owner seat");
        let b = Building {
            id: format!("building_{:013}_000000000", 0),
            r#type: ty.to_string(),
            name: def.name.clone(),
            age: age.to_string(),
            x,
            z,
            rotation_y: ((-x).atan2(-z) / (std::f64::consts::PI / 2.0)).round() * (std::f64::consts::PI / 2.0),
            under_construction,
            build_progress: 0.0,
            build_time,
            is_wonder: def.kind == "wonder",
            health: if under_construction {
                (max_health * 0.2).max(1.0)
            } else {
                max_health
            },
            max_health,
            owner: owner.to_string(),
            seat: self.seats[owner_idx].seat,
            color: 0xff4444, // arena: no human seat
            selected: false,
            can_train: def.can_train,
            can_research: def.can_research,
            train_options: def.train_options.clone(),
            research_options: def.research_options.clone(),
            production_queue: Vec::new(),
            is_producing: false,
            production_type: None,
            production_progress: 0.0,
            production_time: 0.0,
            production_duration: 0.0,
            attack: if ty == "tower" {
                self.world.tower_power(age).attack
            } else {
                def.attack.map(u32::into).unwrap_or(0.0)
            },
            range: def.range.unwrap_or(0.0),
            food_amount: if is_farm { 300.0 } else { 0.0 },
            max_food_amount: if is_farm { 300.0 } else { 0.0 },
            regen_timer: 0.0,
            assigned_worker: None,
            last_damage_time: 0.0,
        };
        self.buildings.push(b);
        self.buildings.len() - 1
    }

    /// `units.js:createUnit` (179-233). Returns the new unit's index.
    pub fn create_unit(
        &mut self,
        ty: &str,
        x: f64,
        z: f64,
        owner: &str,
        civ: &str,
        age: &str,
    ) -> usize {
        let def: &UnitDef = self
            .world
            .get_unit_def_for(civ, ty)
            .unwrap_or_else(|| panic!("no unit def for {ty}"));
        let owner_idx = *self.seat_of.get(owner).expect("owner seat");
        let handle = self.handles.entry(owner.to_string()).or_insert(0);
        *handle += 1;
        let civd = self.world.get_civilization(civ).expect("civ for create_unit");
        let u = Unit {
            // 28 characters, the reference's exact length (5 + 13 + 1 + 9).
            id: format!("unit_{:013}_000000000", 0),
            handle: *handle,
            r#type: ty.to_string(),
            name: def.name.clone(),
            x,
            z,
            health: def.health as f64,
            max_health: def.health as f64,
            speed: def.speed,
            attack: def.attack as f64,
            range: def.range,
            unit_type: def.combat.clone(),
            owner: owner.to_string(),
            seat: self.seats[owner_idx].seat,
            color: civd.color,
            current_tier: age.to_string(),
            target_x: x,
            target_z: z,
            is_moving: false,
            is_attacking: false,
            attack_target: None,
            attack_target_is_unit: false,
            attack_move: None,
            attack_timer: 0.0,
            harvest_target: None,
            harvest_amount: 0.0,
            max_harvest: 15.0,
            is_harvesting: false,
            harvest_timer: 0.0,
            is_building: false,
            build_progress: 0.0,
            build_target: None,
            repair_target: None,
            farm_ref: None,
            carrying_resource: false,
            carrying_resource_type: None,
            task: None,
            former_task: None,
            selected: false,
            vision_bonus: 1.0,
            harvest_rate: def.harvest_rate,
            build_speed: def.build_speed,
            march_speed: None,
            formation_axis: None,
            formation_group: None,
            last_attack_time: 0.0,
            last_hit_by: None,
            attack_seq: 0,
            scout_ticks: 0,
        };
        self.units.push(u);
        self.units.len() - 1
    }

    // -- shared sight (game.js:3577-3589) ------------------------------------

    /// `unitVision`: cavalry sees 50% farther.
    pub fn unit_vision(&self, u: &Unit) -> f64 {
        (if u.unit_type == "cavalry" { 22.5 } else { 15.0 }) * u.vision_bonus
    }

    /// `buildingVision`: 0 while under construction; the tower 80, a
    /// standing wonder 60, the town centre 40, everything else 20.
    pub fn building_vision(&self, b: &Building) -> f64 {
        if b.under_construction || b.health <= 0.0 {
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
}

/// The serialized `Map`, as the state and the fingerprint both read it.
impl Map {
    pub fn fingerprint(&self) -> String {
        mapgen::fingerprint_line(self)
    }
}

/// The `units` / `buildings` roll-up a snap line carries, per seat.
#[derive(Debug, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SnapCounts {
    pub food: u32,
    pub wood: u32,
    pub stone: u32,
    pub gold: u32,
    pub units: u32,
    pub buildings: u32,
}
