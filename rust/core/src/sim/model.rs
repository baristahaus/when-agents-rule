//! The live match state: resources, units, buildings, seats.
//!
//! Field for field with the reference objects the brain and the state
//! builder read: the seat object (`js/ai.js:27`), the unit
//! (`js/units.js:191`), the building (`js/units.js:294`) and the
//! `ResourceManager` (`js/resources.js`). What is read is present; what
//! is never read by the simulation is not.

use std::collections::HashMap;

use crate::data::Cost;

/// `ResourceManager` (resources.js): the four stockpile floats and the
/// population counters. Values are floats — harvest adds fractions and
/// the display floors.
#[derive(Debug, Clone)]
pub struct Resources {
    pub food: f64,
    pub wood: f64,
    pub stone: f64,
    pub gold: f64,
    pub population: u32,
    pub max_population: u32,
    /// Lifetime ever DELIVERED, per type. Lazy in the reference: the
    /// object materialises on the first `addResource` with all four
    /// zeroes, and only then do positive adds accumulate into it.
    pub gathered: HashMap<String, f64>,
}

impl Resources {
    /// resources.js:2-12 — the opening stockpile every seat holds.
    pub fn new() -> Self {
        Self {
            food: 200.0,
            wood: 200.0,
            stone: 100.0,
            gold: 50.0,
            population: 0,
            max_population: 10,
            gathered: HashMap::new(),
        }
    }

    /// `resources[a]` — the dynamic property read the brain leans on.
    pub fn value(&self, r: &str) -> f64 {
        match r {
            "food" => self.food,
            "wood" => self.wood,
            "stone" => self.stone,
            "gold" => self.gold,
            _ => 0.0,
        }
    }

    fn value_mut(&mut self, r: &str) -> &mut f64 {
        match r {
            "food" => &mut self.food,
            "wood" => &mut self.wood,
            "stone" => &mut self.stone,
            "gold" => &mut self.gold,
            _ => unreachable!("unknown resource type"),
        }
    }

    /// resources.js:29 — the only door resources have into the stockpile.
    pub fn add_resource(&mut self, r: &str, amount: f64) {
        *self.value_mut(r) += amount;
        if self.gathered.is_empty() {
            let mut g: HashMap<String, f64> = HashMap::new();
            g.insert("food".to_string(), 0.0);
            g.insert("wood".to_string(), 0.0);
            g.insert("stone".to_string(), 0.0);
            g.insert("gold".to_string(), 0.0);
            self.gathered = g;
        }
        if let Some(g) = self.gathered.get_mut(r) {
            if amount > 0.0 {
                *g += amount;
            }
        }
    }

    /// resources.js:14 — the reference's `hasResources`, `cost.x || 0`.
    pub fn has_resources(&self, cost: &Cost) -> bool {
        self.food >= cost.food as f64
            && self.wood >= cost.wood as f64
            && self.stone >= cost.stone as f64
            && self.gold >= cost.gold as f64
    }

    /// resources.js:21 — spend, then notify (the core keeps no HUD to
    /// notify; the call stays in the port so the sequence reads the same).
    pub fn spend_resources(&mut self, cost: &Cost) {
        self.food -= cost.food as f64;
        self.wood -= cost.wood as f64;
        self.stone -= cost.stone as f64;
        self.gold -= cost.gold as f64;
    }

    /// resources.js:57 — the population is a count the tick block writes.
    pub fn update_population(&mut self, count: u32) {
        self.population = count;
    }
}

/// The task a pulled worker resumes on (applyBuilder saves it).
#[derive(Debug, Clone, Default)]
pub struct FormerTask {
    pub task: String,
    pub harvest_target: Option<usize>,
    pub farm_ref: Option<String>,
}

/// A unit instance — the exact shape of `createUnit` (units.js:191-233).
///
/// `type` is the unit id the model reads (`'worker'`, `'militia'`, …);
/// `unit_type` is the def's combat class (`'cavalry'`, `'support'`, …)
/// which the vision radii and the archer counts key on.
#[derive(Debug, Clone)]
pub struct Unit {
    /// `unit_<wallclock>_<rand>` — the internal id. Wall clock and `Math.random`
    /// are the reference's only sanctioned non-determinism (units.js:192): the
    /// id is never seeded and never re-derivable, so the match's identity is
    /// the monotonic `handle` and the recorded state carries it as-is.
    pub id: String,
    /// Per-owner, monotonic, never reused (units.js:171-177).
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
    pub unit_type: String,
    pub owner: String,
    /// The owner's seat, resolved once at spawn — the team badge.
    pub seat: Option<u8>,
    /// The age the unit was created at (its tier for the age-up chain).
    pub current_tier: String,
    pub target_x: f64,
    pub target_z: f64,
    pub is_moving: bool,
    pub is_attacking: bool,
    /// The building id under attack, if any.
    pub attack_target: Option<String>,
    /// The (x, z) of an attack-move order.
    pub attack_move: Option<(f64, f64)>,
    /// Milliseconds until the next swing (the combat cluster advances it).
    pub attack_timer: f64,
    /// The map resource node the worker harvests, by index into the map.
    pub harvest_target: Option<usize>,
    pub harvest_amount: f64,
    pub max_harvest: f64,
    pub is_harvesting: bool,
    pub is_building: bool,
    /// The building id the worker is building, if any.
    pub build_target: Option<String>,
    pub build_progress: f64,
    /// The building id the worker repairs, if any.
    pub repair_target: Option<String>,
    /// '' | 'harvesting' | 'carrying' | 'building' | 'repairing' | 'farm_work' | 'scouting'
    pub task: String,
    /// The farm id the worker works, if any.
    pub farm_ref: Option<String>,
    pub carrying_resource: bool,
    pub carrying_type: Option<String>,
    pub selected: bool,
    /// A researched multiplier (e.g. Farsight 1.2), applied per unit.
    pub vision_bonus: f64,
    pub harvest_rate: f64,
    pub build_speed: f64,
    /// The task saved by a builder pull, to resume after.
    pub former_task: Option<FormerTask>,
    /// Wall-clock ms of the unit's last combat hit (repair lockout).
    pub last_attack_time: f64,
    /// The attacker id that last hit this unit.
    pub last_hit_by: Option<String>,
    /// A monotonically rising counter so a swing is never answered twice.
    pub attack_seq: u32,
    /// The standing-order squad this unit belongs to, if any.
    pub formation: Option<String>,
    /// The unit's slot inside its formation.
    pub formation_offset: Option<(f64, f64)>,
    /// Movement scratch, kept per unit like the reference does.
    pub move_progress: f64,
    pub move_remaining: f64,
}

/// A building instance — the exact shape of `createBuilding`
/// (units.js:286-352).
#[derive(Debug, Clone)]
pub struct Building {
    /// `building_<wallclock>_<rand>` — the same non-seeded id scheme as
    /// units: the identity is the position and the owner, never the id.
    pub id: String,
    pub r#type: String,
    pub name: String,
    /// The epoch the building stands in (it morphs on age-ups).
    pub age: String,
    pub x: f64,
    pub z: f64,
    /// Facing the map centre, snapped to a right angle.
    pub rotation_y: f64,
    pub under_construction: bool,
    pub build_progress: f64,
    pub build_time: f64,
    pub is_wonder: bool,
    pub health: f64,
    pub max_health: f64,
    pub owner: String,
    /// The owner's seat, resolved once at spawn.
    pub seat: Option<u8>,
    pub selected: bool,
    pub can_train: bool,
    pub can_research: bool,
    /// The unit ids this building trains, at its current age.
    pub train_options: Vec<String>,
    pub research_options: Vec<String>,
    pub production_queue: Vec<String>,
    pub is_producing: bool,
    pub production_progress: f64,
    /// The total duration of the current production run, in ms.
    pub production_time: f64,
    pub production_duration: f64,
    pub attack: f64,
    pub range: f64,
    pub food_amount: f64,
    pub max_food_amount: f64,
    pub regen_timer: f64,
    /// The worker id working this farm, if any.
    pub assigned_worker: Option<String>,
    /// Wall-clock ms of the last hit taken (the repair lockout reads it).
    pub last_damage_time: f64,
}


/// One match seat — the reference's `ai` object (ai.js:27-43) plus the
/// brain's per-seat runtime state (the `_`-prefixed fields).
#[derive(Debug, Clone)]
pub struct Seat {
    /// The reference mints it from `Math.random` (ai.js:32-34): the one
    /// seat field a seed does not decide.
    pub id: String,
    pub civilization: String,
    /// Stored ('medium'); nothing in the v1 read it.
    pub difficulty: String,
    pub resources: Resources,
    pub units: Vec<Unit>,
    pub buildings: Vec<Building>,
    /// The seat's current epoch.
    pub age: String,
    /// The researched bonuses, per category (all start 1.0).
    pub worker_harvest_bonus: f64,
    pub worker_speed_bonus: f64,
    pub worker_build_speed_bonus: f64,
    pub train_speed_bonus: f64,
    pub heal_power_bonus: f64,
    pub tech_cost_multiplier: f64,
    pub building_health_multiplier: f64,
    /// The researched tech ids, in completion order (the state's
    /// `research.researched` walks them).
    pub researched_techs: Vec<String>,
    /// The building ids techs have unlocked, in grant order.
    pub unlocked_buildings: Vec<String>,
    /// The unit ids techs have unlocked, in grant order.
    pub unlocked_units: Vec<String>,
    pub current_research: Option<ResearchJob>,
    pub current_age_upgrade: Option<AgeUpgrade>,
    // ---- The brain's per-seat runtime (the `_`-prefixed ai.js fields) ----
    /// ms since the last think; the update block gates on it.
    pub think_timer: f64,
    /// ms since the last discovery; the update block gates on it.
    pub discovery_timer: f64,
    /// The multi-turn command exchange is in flight for this seat.
    pub turn_active: bool,
    /// The result lines of this seat's executed commands, in order.
    pub pending_command_results: Vec<String>,
    /// The map resource node indices this seat has seen (the fog's
    /// `knownResources`), monotonic.
    pub known_res_idx: std::collections::HashSet<usize>,
    /// The enemy building ids this seat has seen, monotonic.
    pub known_enemy_buildings: std::collections::HashSet<String>,
    /// The 42×42 exploration bitmap, row 0 = north.
    pub explored: Vec<bool>,
    /// The rival seat ids this seat has ever seen something of.
    pub met_rivals: std::collections::HashSet<String>,
    /// The scout's wandering state (exploreMap).
    pub explore_timer: f64,
    pub scout_angle: f64,
    pub scout_radius: f64,
    pub army_scout_ticks: f64,
    pub army_scout_target: Option<(f64, f64)>,
    pub army_scout_angle: f64,
    pub army_scout_radius: f64,
}

/// A research in flight — the reference's `ai.currentResearch` object
/// (ai.js:405): what is researched, its clock, its total duration.
#[derive(Debug, Clone)]
pub struct ResearchJob {
    pub tech_id: String,
    /// ms elapsed.
    pub progress: f64,
    /// Total duration of the run, in ms.
    pub duration: f64,
}

/// An age upgrade in flight — the reference's `ai.currentAgeUpgrade`
/// object (ai.js:421).
#[derive(Debug, Clone)]
pub struct AgeUpgrade {
    pub target_age: String,
    pub progress: f64,
    pub duration: f64,
}

impl Seat {
    pub fn new(id: String, civilization: String) -> Self {
        Self {
            id,
            difficulty: "medium".into(),
            civilization,
            resources: Resources::new(),
            units: Vec::new(),
            buildings: Vec::new(),
            age: "stone".into(),
            worker_harvest_bonus: 1.0,
            worker_speed_bonus: 1.0,
            worker_build_speed_bonus: 1.0,
            train_speed_bonus: 1.0,
            heal_power_bonus: 1.0,
            tech_cost_multiplier: 1.0,
            building_health_multiplier: 1.0,
            researched_techs: Vec::new(),
            unlocked_buildings: Vec::new(),
            unlocked_units: Vec::new(),
            current_research: None,
            current_age_upgrade: None,
            think_timer: 0.0,
            discovery_timer: 0.0,
            turn_active: false,
            pending_command_results: Vec::new(),
            known_res_idx: std::collections::HashSet::new(),
            known_enemy_buildings: std::collections::HashSet::new(),
            explored: Vec::new(),
            met_rivals: std::collections::HashSet::new(),
            explore_timer: 0.0,
            scout_angle: 0.0,
            scout_radius: 0.0,
            army_scout_ticks: 0.0,
            army_scout_target: None,
            army_scout_angle: 0.0,
            army_scout_radius: 0.0,
        }
    }

    pub fn has_tech(&self, id: &str) -> bool {
        self.researched_techs.iter().any(|t| t == id)
    }
}
