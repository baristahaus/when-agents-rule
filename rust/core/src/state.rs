//! The initial (turn-1) match state, ported from the reference's
//! `buildGameStateJSON` (openai-ai.js:2472) at the exact moment the first
//! state of every seat is built: before the first discovery beat, before any
//! research, building or combat.
//!
//! The state is four kinds of fact:
//! - the constants of a fresh seat (age, stockpile, population, Town Center),
//! - the map the seed generated, and what its vision can see of it,
//! - the civ's vocabulary of what it can research, train and build, with the
//!   gates standing in each one's way,
//! - the other seats, with the public facts only (epoch, defeat).
//!
//! The one thing a seed does not decide is the seat's player id: the
//! reference mints it with `Math.random` (ai.js:34) because a
//! session-unique key is what the harness addresses, and a key derived from
//! the seed would collide across replays. The config takes it instead, and
//! the golden diff normalizes it on both sides.

use serde::Serialize;

use crate::data::{Cost, WorldData};
use crate::mapgen;
use crate::prng::{KeyedRng, Mulberry32};

/// Everything the builder needs that a seed alone does not decide.
pub struct InitialConfig<'a> {
    pub world: &'a WorldData,
    pub seed: &'a str,
    pub difficulty: &'a str,
    pub seats: usize,
    /// The terrain's own size: 200 for the headless recorder's matches, 800
    /// for the arena. The spawn circle stays on the 800-world regardless.
    pub map_size: u32,
    /// One civ id per seat, in seat order.
    pub civs: &'a [String],
    /// The seat whose state this is.
    pub seat: usize,
    /// The seat's player id (see the module docs).
    pub player_id: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Player {
    id: String,
    civilization: String,
    civilization_name: String,
    is_human: bool,
}

#[derive(Serialize)]
struct Clock {
    #[serde(rename = "matchSeconds")]
    match_seconds: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Epoch {
    current_epoch: String,
    next_epoch: Option<String>,
    next_epoch_cost: Option<Cost>,
    upgrade_in_progress: Option<()>,
}

#[derive(Serialize)]
struct Resources {
    food: u32,
    wood: u32,
    stone: u32,
    gold: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Population {
    used: u32,
    capacity_now: u32,
    capacity_ceiling: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Bounds {
    min_x: i64,
    max_x: i64,
    min_z: i64,
    max_z: i64,
}

#[derive(Serialize)]
struct MapState {
    size: i64,
    bounds: Bounds,
    #[serde(rename = "yourSpawnArea")]
    your_spawn_area: Point,
    #[serde(rename = "yourBaseTiles")]
    your_base_tiles: serde_json::Map<String, serde_json::Value>,
    exploration: serde_json::Map<String, serde_json::Value>,
}

#[derive(Serialize)]
struct Point {
    x: i64,
    z: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Nodes {
    discovered: NodeCounts,
    total_on_map: NodeCounts,
}

#[derive(Serialize)]
struct NodeCounts {
    food: u32,
    wood: u32,
    stone: u32,
    gold: u32,
}

#[derive(Debug, Clone, Serialize)]
struct Node {
    #[serde(rename = "type")]
    r#type: String,
    x: i64,
    z: i64,
    amount: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BuildingEntry {
    r#type: String,
    x: i64,
    z: i64,
    health_pct: u32,
    state: String,
    busy: bool,
    activity: String,
    producing: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UnitEntry {
    id: u32,
    #[serde(rename = "type")]
    r#type: String,
    x: i64,
    z: i64,
    health_pct: u32,
}

#[derive(Serialize)]
struct Workers {
    total: u32,
    idle: u32,
    building: u32,
    farm: u32,
    scouting: u32,
    moving: u32,
    fighting: u32,
    food: u32,
    wood: u32,
    stone: u32,
    gold: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Research {
    researched: Vec<String>,
    current: Option<()>,
    available: Vec<AvailableTech>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AvailableTech {
    id: String,
    cost: Cost,
    research_at: String,
    blocked_by: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UnlockedContent {
    buildings: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Threats {
    under_attack: Vec<()>,
    enemy_wonders: Vec<()>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Opponent {
    id: String,
    civilization: String,
    age: String,
    discovered: bool,
    defeated: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GameStats {
    wonder_required: u32,
    opponents: Vec<Opponent>,
}

/// The full initial state, in the key order the reference emits.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct State {
    player: Player,
    clock: Clock,
    epoch: Epoch,
    resources: Resources,
    population: Population,
    recent_events: Vec<()>,
    bonuses: serde_json::Map<String, serde_json::Value>,
    map: MapState,
    nodes: Nodes,
    nearest_nodes: Vec<Node>,
    friendly_buildings: Vec<BuildingEntry>,
    enemy_buildings: Vec<()>,
    friendly_units: Vec<UnitEntry>,
    workers: Workers,
    enemy_units: Vec<()>,
    research: Research,
    unlocked_content: UnlockedContent,
    units: serde_json::Map<String, serde_json::Value>,
    buildings: serde_json::Map<String, serde_json::Value>,
    threats: Threats,
    game_stats: GameStats,
}

const RES: [&str; 4] = ["food", "wood", "stone", "gold"];
/// The gates that mean "not yet" as against "not right now"
/// (openai-ai.js:816).
const STRUCTURAL_BLOCKS: [&str; 4] = ["age", "tech", "host", "alreadyBuilt"];

/// Build the turn-1 state for one seat of one match.
pub fn build_initial_state(cfg: &InitialConfig) -> serde_json::Value {
    let world = cfg.world;
    let civ_id = &cfg.civs[cfg.seat];
    let civ = world
        .get_civilization(civ_id)
        .unwrap_or_else(|| panic!("seat {} has unknown civ {civ_id}", cfg.seat));

    let current_age = "stone";
    let age_idx = world.ages.iter().position(|a| a == current_age).unwrap_or(0);

    // --- The seeded world, then the workers. The map draws from the terrain
    // stream; the workers are spread by KEYED draws (game.js:659:
    // `spawn.x + (this.rand(ai, 'start-workers') - 0.5) * 10`), which is the one
    // part of the turn-1 state the map seed alone does not decide. The key names the
    // seat by INDEX and the purpose, never the random player id (rngOwnerKey,
    // game.js:117) — an id minted from Math.random cannot be part of a reproducible
    // draw, and this is the state where that id is not even assigned yet.
    let mut rand = Mulberry32::from_seed(cfg.seed);
    let (spawns, resources) =
        mapgen::generate_map(&mut rand, cfg.map_size as i64, cfg.difficulty, cfg.seats);
    let mut key_rng = KeyedRng::new(cfg.seed);
    let mut workers_per_seat: Vec<Vec<(f64, f64)>> = Vec::with_capacity(cfg.seats);
    for (i, spawn) in spawns.iter().enumerate().take(cfg.seats) {
        let key = format!("s{i}:start-workers");
        let mut ws = Vec::with_capacity(3);
        for _ in 0..3 {
            let x = spawn.0 + (key_rng.draw(&key) - 0.5) * 10.0;
            let z = spawn.1 + (key_rng.draw(&key) - 0.5) * 10.0;
            ws.push((x, z));
        }
        workers_per_seat.push(ws);
    }
    let spawn = spawns[cfg.seat];
    let workers = &workers_per_seat[cfg.seat];

    // --- Vision. The discovery beat has not run yet, so a node is "known"
    // exactly when it is in the sight of the seat's own units or completed
    // buildings right now (isPositionVisibleToAI, openai-ai.js:3627).
    // A worker sees 15 (game.js:3577); a completed Town Center 40 (:3585).
    let mut discovered = [0u32; 4];
    let mut total = [0u32; 4];
    let mut by_type: [Vec<Node>; 4] = [vec![], vec![], vec![], vec![]];
    for r in &resources {
        let ti = RES.iter().position(|t| *t == r.r#type).unwrap_or(0);
        if r.amount > 0 {
            total[ti] += 1;
        }
        let visible = (r.x - spawn.0).hypot(r.z - spawn.1) <= 40.0
            || workers.iter().any(|(wx, wz)| (r.x - wx).hypot(r.z - wz) <= 15.0);
        if visible && r.amount > 0 {
            discovered[ti] += 1;
            by_type[ti].push(Node {
                r#type: r.r#type.clone(),
                x: r.x.round() as i64,
                z: r.z.round() as i64,
                amount: r.amount as u32,
            });
        }
    }

    // --- nearestNodes: stone and gold in full; food and wood the ten nearest
    // to each Town Center — the set assign_workers picks anyway. The
    // reference keys a Map on "x,z": a node later seen at the same rounded
    // point overwrites, in that order.
    let mut nearby: Vec<(i64, i64, Node)> = Vec::new();
    let mut near_idx: std::collections::HashMap<(i64, i64), usize> = std::collections::HashMap::new();
    let mut add_near = |n: &Node| {
        let k = (n.x, n.z);
        match near_idx.get(&k) {
            Some(i) => nearby[*i] = (k.0, k.1, n.clone()),
            None => {
                near_idx.insert(k, nearby.len());
                nearby.push((k.0, k.1, n.clone()));
            }
        }
    };
    for n in &by_type[2] {
        add_near(n);
    }
    for n in &by_type[3] {
        add_near(n);
    }
    for nodes_src in by_type.iter().take(2) {
        let mut nodes: Vec<&Node> = nodes_src.iter().collect();
        nodes.sort_by(|a, b| {
            let da = (spawn.0 - a.x as f64).hypot(spawn.1 - a.z as f64);
            let db = (spawn.0 - b.x as f64).hypot(spawn.1 - b.z as f64);
            da.partial_cmp(&db).unwrap_or(std::cmp::Ordering::Equal)
        });
        for n in nodes.iter().take(10) {
            add_near(n);
        }
    }
    let nearest_nodes = nearby.iter().map(|(_, _, n)| n.clone()).collect();

    // --- The map section. `tileLabelAt` (game.js:3725) divides the terrain
    // into a 7x7 grid: the arena's 800 map measures from the box's corner,
    // while a smaller map measures from the origin (the map's centre) plus a
    // half-grid offset — clamped at the edges, so a Town Center sitting on the
    // 800-world spawn ring of a 200 map clamps to its corner tile.
    let size = cfg.map_size;
    let cell = if size == 800 { (size - 80) as f64 / 7.0 } else { size as f64 / 7.0 };
    let half = size as f64 / 2.0;
    let tile_at = |x: f64, z: f64| -> String {
        let (row, col) = if size < 800 {
            ((x / cell).floor() + 3.0, (z / cell).floor() + 3.0)
        } else {
            (((x + half) / cell).floor(), ((z + half) / cell).floor())
        };
        let r = row.clamp(0.0, 6.0) as u8;
        let c = col.clamp(0.0, 6.0) as u8;
        format!("{}{}", (65 + r) as char, c + 1)
    };
    let mut your_base_tiles = serde_json::Map::new();
    your_base_tiles
        .insert(tile_at(spawn.0, spawn.1), serde_json::json!(1));
    // exploration: the 7x7 bitmap summary. The discovery beat starts one tick
    // after the first state is built, so every tile reads 0 — the
    // all-zeros the reference's first state carries.
    let mut exploration = serde_json::Map::new();
    for r in 0..7u8 {
        for c in 0..7u8 {
            exploration.insert(
                format!("{}{}", (65 + c) as char, r + 1),
                serde_json::json!(0),
            );
        }
    }

    // --- The seat.
    let player = Player {
        id: cfg.player_id.to_string(),
        civilization: civ_id.clone(),
        civilization_name: civ.en_name.clone(),
        is_human: false,
    };
    let next_epoch = world.ages.get(age_idx + 1).cloned();
    let epoch = Epoch {
        current_epoch: current_age.to_string(),
        next_epoch: next_epoch.clone(),
        next_epoch_cost: next_epoch
            .as_ref()
            .and_then(|e| world.age_costs.get(e).copied()),
        upgrade_in_progress: None,
    };
    let resources_obj = Resources { food: 200, wood: 200, stone: 100, gold: 50 };
    let population = Population {
        used: 3,
        capacity_now: 10, // the Town Center's popBonus; nothing else stands
        capacity_ceiling: world.max_population_cap,
    };

    // The seat's bonus multipliers, filtered the way the state does: a value
    // of 1.0 is not a bonus (openai-ai.js:2715-2720). At turn 1 every seat
    // reads empty. Two reasons, both v1 facts the rebuild must preserve:
    // no tech is researched yet, and a civ's standing bonus effect is applied
    // to campaign seats only (game.js:352-356); the arena's seat loop
    // (game.js:530-562) never calls it, so an arena Persian carries the
    // default 1.0, not the declared 1.2. `world.json`'s civ `bonuses`
    // strings are the declared design values; they are data, not state, and
    // the arena path does not turn them into multipliers.
    let bonuses: serde_json::Map<String, serde_json::Value> = serde_json::Map::new();

    // --- Buildings and units of the seat.
    let friendly_buildings = vec![BuildingEntry {
        r#type: "town_center".into(),
        x: spawn.0.round() as i64,
        z: spawn.1.round() as i64,
        health_pct: 100,
        state: "complete".into(),
        busy: false,
        activity: "idle".into(),
        producing: None,
    }];
    let friendly_units = workers
        .iter()
        .enumerate()
        .map(|(i, (x, z))| UnitEntry {
            id: i as u32 + 1,
            r#type: "worker".into(),
            x: x.round() as i64,
            z: z.round() as i64,
            health_pct: 100,
        })
        .collect();
    let workers_obj = Workers {
        total: 3,
        idle: 3, // a fresh worker has no task, carry, farm or fight
        building: 0,
        farm: 0,
        scouting: 0,
        moving: 0,
        fighting: 0,
        food: 0,
        wood: 0,
        stone: 0,
        gold: 0,
    };

    // --- Research: the civ's whole tree, gated, in the tree's own key order.
    let available: Vec<AvailableTech> = civ
        .tech_tree
        .iter()
        .filter_map(|(id, t)| {
            let cost = Cost {
                food: (t.cost.food as f64) as u32,
                wood: (t.cost.wood as f64) as u32,
                stone: (t.cost.stone as f64) as u32,
                gold: (t.cost.gold as f64) as u32,
            };
            // age reached?
            let ti = world.ages.iter().position(|a| a == &t.required_age)?;
            if ti > age_idx {
                return None;
            }
            // prerequisites researched? nothing is, at turn one
            if !t.requires.is_empty() {
                return None;
            }
            let at = if t.research_at.is_empty() {
                "town_center"
            } else {
                t.research_at.as_str()
            };
            let mut blocked_by = vec![];
            // the only standing building is the Town Center
            if at != "town_center" {
                blocked_by.push("host".to_string());
            }
            if !cost.affordable(200, 200, 100, 50) {
                blocked_by.push("cost".to_string());
            }
            Some(AvailableTech {
                id: id.clone(),
                cost,
                research_at: at.to_string(),
                blocked_by,
            })
        })
        .collect();
    let research = Research {
        researched: vec![],
        current: None,
        available,
    };

    // --- The trainable-unit vocabulary, split as the state splits it.
    let units = split_units(world, civ_id);
    let buildings = buildable_list(world, civ_id);

    // --- The rivals: epochs and defeat are public; everything else appears
    // only after first contact, which has not happened.
    let mut opponents = Vec::new();
    for (s, other) in cfg.civs.iter().enumerate() {
        if s == cfg.seat {
            continue;
        }
        opponents.push(Opponent {
            id: format!("{}-{}", other, s + 1),
            civilization: other.clone(),
            age: "stone".into(),
            discovered: false,
            defeated: false,
        });
    }
    let game_stats = GameStats {
        wonder_required: 600,
        opponents,
    };

    let state = State {
        player,
        // One second, not zero. Builds 934-949 told every model `matchSeconds: 0` on every
        // turn (docs/RULES-CHANGES.md build 950: two different clocks subtracted and clamped
        // to zero), and the golden this port is measured against was recorded in that window,
        // which is why our spec §3.4 could list "the clock reads 0 on every beat" as a
        // degenerate invariant. Build 950 fixed the clock; the invariant is gone, and a port
        // that still emits 0 is now the one that changed the game.
        clock: Clock { match_seconds: 1 },
        epoch,
        resources: resources_obj,
        population,
        recent_events: vec![],
        bonuses,
        map: MapState {
            size: cfg.map_size as i64,
            bounds: Bounds {
                min_x: -(cfg.map_size as i64 / 2),
                max_x: cfg.map_size as i64 / 2,
                min_z: -(cfg.map_size as i64 / 2),
                max_z: cfg.map_size as i64 / 2,
            },
            your_spawn_area: Point { x: spawn.0.round() as i64, z: spawn.1.round() as i64 },
            your_base_tiles,
            exploration,
        },
        nodes: Nodes {
            discovered: NodeCounts {
                food: discovered[0],
                wood: discovered[1],
                stone: discovered[2],
                gold: discovered[3],
            },
            total_on_map: NodeCounts {
                food: total[0],
                wood: total[1],
                stone: total[2],
                gold: total[3],
            },
        },
        nearest_nodes,
        friendly_buildings,
        enemy_buildings: vec![],
        friendly_units,
        workers: workers_obj,
        enemy_units: vec![],
        research,
        unlocked_content: UnlockedContent { buildings: vec![] },
        units,
        buildings,
        threats: Threats { under_attack: vec![], enemy_wonders: vec![] },
        game_stats,
    };
    serde_json::to_value(state).expect("state serializes")
}

/// `units: { trainable, blocked }` — the host -> age -> entries nesting,
/// split by the structural gates (openai-ai.js:820, 3554).
fn split_units(world: &WorldData, civ_id: &str) -> serde_json::Map<String, serde_json::Value> {
    world
        .get_civilization(civ_id)
        .expect("civ for split_units");
    let age_order = &world.ages;
    let age_idx = age_order.iter().position(|a| a == "stone").unwrap_or(0);
    let age_reached = |need: &str| age_idx >= age_order.iter().position(|a| a == need).unwrap_or(0);

    let mut open: serde_json::Map<String, serde_json::Value> = serde_json::Map::new();
    let mut blocked: serde_json::Map<String, serde_json::Value> = serde_json::Map::new();
    for (id, at, age) in world.trainable_units_for(civ_id) {
        let def = world.get_unit_def_for(civ_id, &id);
        let mut blocked_by = vec![];
        if !age_reached(&age) {
            blocked_by.push("age".to_string());
        }
        if at != "town_center" {
            blocked_by.push("host".to_string());
        }
        if 3 >= 10 {
            blocked_by.push("pop".to_string());
        }
        let poor = match def {
            Some(d) => !d.cost.affordable(200, 200, 100, 50),
            None => true, // `tooPoor(null)` is true: a def that cannot resolve
        };
        if poor {
            blocked_by.push("cost".to_string());
        }
        let structural = blocked_by
            .iter()
            .any(|b| STRUCTURAL_BLOCKS.contains(&b.as_str()));
        let target = if structural { &mut blocked } else { &mut open };
        let host = target
            .entry(at.to_string())
            .or_insert_with(|| serde_json::Map::new().into());
        let by_age = host
            .as_object_mut()
            .expect("host is an object")
            .entry(age.clone())
            .or_insert_with(|| serde_json::Value::Array(Vec::new()));
        let mut entry = serde_json::json!({
            "id": id,
            "cost": def.map(|d| d.cost).unwrap_or(Cost { food: 0, wood: 0, stone: 0, gold: 0 }),
            "blockedBy": blocked_by,
        });
        if !structural {
            // `strip`: drop an EMPTY blockedBy, keep a non-structural one
            if entry["blockedBy"].as_array().map(|a| a.is_empty()) == Some(true) {
                entry.as_object_mut().expect("object").remove("blockedBy");
            }
        }
        by_age.as_array_mut().expect("array").push(entry);
    }
    let mut out = serde_json::Map::new();
    out.insert("trainable".to_string(), open.into());
    out.insert("blocked".to_string(), blocked.into());
    out
}

/// `buildings: { buildable, blocked }` — the civ's whole buildable list
/// (the shared list plus the Wonder), split by structural gate
/// (openai-ai.js:3278-3321, 3555).
fn buildable_list(
    world: &WorldData,
    civ_id: &str,
) -> serde_json::Map<String, serde_json::Value> {
    let civ = world
        .get_civilization(civ_id)
        .expect("civ for buildable_list");
    let age_order = &world.ages;
    let age_idx = age_order.iter().position(|a| a == "stone").unwrap_or(0);
    let age_reached = |need: &str| age_idx >= age_order.iter().position(|a| a == need).unwrap_or(0);

    let std_buildings = [
        "town_center",
        "house",
        "farm",
        "barracks",
        "archery_range",
        "stable",
        "academy",
        "tower",
        "temple",
    ];
    let mut buildable: Vec<serde_json::Value> = vec![];
    let mut blocked: Vec<serde_json::Value> = vec![];
    for t in std_buildings {
        let def = match world.get_building_def(t) {
            Some(d) => d,
            None => continue,
        };
        let req_tech = def.requires_tech.clone();
        let civ_supports = match &req_tech {
            Some(r) => civ.tech_tree.contains_key(r),
            None => true,
        };
        if !civ_supports {
            continue; // a host the civ can never build advertises nothing
        }
        let tech_done = req_tech.is_none(); // nothing is researched at turn one
        let req_age = world.effective_building_age(civ_id, def);
        let mut blocked_by = vec![];
        if !age_reached(&req_age) {
            blocked_by.push("age".to_string());
        }
        if !tech_done {
            blocked_by.push("tech".to_string());
        }
        if !def.cost.affordable(200, 200, 100, 50) {
            blocked_by.push("cost".to_string());
        }
        let structural = blocked_by
            .iter()
            .any(|b| STRUCTURAL_BLOCKS.contains(&b.as_str()));
        let mut line = serde_json::json!({
            "type": t,
            "requiredAge": req_age,
            "requiresTech": req_tech,
            "cost": def.cost,
            "blockedBy": blocked_by,
        });
        if !structural {
            if line["blockedBy"].as_array().map(|a| a.is_empty()) == Some(true) {
                line.as_object_mut().expect("object").remove("blockedBy");
            }
            buildable.push(line);
        } else {
            blocked.push(line);
        }
    }
    // The Wonder, advertised as "wonder" with the civ's id in `builtAs`.
    if let Some(w) = world.wonder_def_for(civ_id) {
        let w_age = w.required_age.clone().unwrap_or_else(|| "iron".to_string());
        let mut blocked_by = vec![];
        if !age_reached(&w_age) {
            blocked_by.push("age".to_string());
        }
        // no wonder stands yet
        if !w.cost.affordable(200, 200, 100, 50) {
            blocked_by.push("cost".to_string());
        }
        let structural = blocked_by
            .iter()
            .any(|b| STRUCTURAL_BLOCKS.contains(&b.as_str()));
        let mut line = serde_json::json!({
            "type": "wonder",
            "builtAs": w.id,
            "requiredAge": w_age,
            "requiresTech": serde_json::Value::Null,
            "isWonder": true,
            "cost": w.cost,
            "blockedBy": blocked_by,
        });
        if !structural {
            if line["blockedBy"].as_array().map(|a| a.is_empty()) == Some(true) {
                line.as_object_mut().expect("object").remove("blockedBy");
            }
            buildable.push(line);
        } else {
            blocked.push(line);
        }
    }
    let mut out = serde_json::Map::new();
    out.insert("buildable".to_string(), serde_json::Value::Array(buildable));
    out.insert("blocked".to_string(), serde_json::Value::Array(blocked));
    out
}
