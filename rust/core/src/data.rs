//! The static world content, loaded from `data/world.json`.
//!
//! That file is exported from the JS reference itself (`tools/export_data.cjs`
//! runs the real `civilizations.js` / `units.js` / `buildings.js` / `i18n.js`
//! in a vm sandbox and dumps the tables) — nothing in here is re-typed. The
//! golden state diff proves the port: if the reference tables change, the
//! export is re-run and the diff catches any drift in the logic around them.

use std::collections::HashMap;

use serde::Deserialize;

/// The exported world. Parsed once per process; every lookup below reads it.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorldData {
    pub ages: Vec<String>,
    pub age_costs: HashMap<String, Cost>,
    pub max_population_cap: u32,
    pub building_defs: HashMap<String, BuildingDef>,
    pub building_train_tiers: HashMap<String, HashMap<String, Vec<String>>>,
    pub unit_defs: HashMap<String, UnitDef>,
    pub civilizations: HashMap<String, Civilization>,
}

impl WorldData {
    /// Parse the exported world. The file is part of the crate; the golden
    /// fixtures pin every table it carries.
    pub fn load() -> Self {
        let raw = std::include_str!("../data/world.json");
        serde_json::from_str(raw).expect("data/world.json is committed and valid")
    }
}

/// A resource price. Every cost object in the reference carries all four keys
/// (a missing leg means zero — `cost.food || 0` in the reference does exactly
/// that), so the fields are plain `u32` with a default for safety.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub struct Cost {
    #[serde(default)]
    pub food: u32,
    #[serde(default)]
    pub wood: u32,
    #[serde(default)]
    pub stone: u32,
    #[serde(default)]
    pub gold: u32,
}

impl Cost {
    /// `ai.resources.hasResources(cost)` (resources.js) — the same test the
    /// state's "cost" gate and the executor use.
    pub fn affordable(&self, food: u32, wood: u32, stone: u32, gold: u32) -> bool {
        food >= self.food && wood >= self.wood && stone >= self.stone && gold >= self.gold
    }
}

/// A unit type: shared entry or civilization-unique override.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UnitDef {
    pub id: String,
    pub name: String,
    pub cost: Cost,
    pub health: u32,
    pub speed: f64,
    pub attack: u32,
    pub range: f64,
    /// The combat class: 'worker' 'militia' … — note: NOT the type string the
    /// model reads (that is `id`).
    #[serde(rename = "type", default)]
    pub combat: String,
    /// The age tier the unit sits in. Uniques repeat the shared entry's tier;
    /// the age gates read it from whatever `get_unit_def_for` returns.
    #[serde(default)]
    pub tier: Option<String>,
    /// Uniques only: the building that trains them (the shared table's host is
    /// read from `building_train_tiers` instead).
    #[serde(default)]
    pub train_at: Option<String>,
    #[serde(default = "default_one")]
    pub harvest_rate: f64,
    #[serde(default = "default_one")]
    pub build_speed: f64,
    #[serde(default)]
    pub description: Option<String>,
}

fn default_one() -> f64 {
    1.0
}

/// A building type from the shared table.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildingDef {
    pub id: String,
    pub name: String,
    pub cost: Cost,
    pub health: u32,
    #[serde(rename = "type", default)]
    pub kind: String,
    #[serde(default)]
    pub pop_bonus: u32,
    #[serde(default)]
    pub can_train: bool,
    #[serde(default)]
    pub train_options: Vec<String>,
    #[serde(default)]
    pub can_research: bool,
    #[serde(default)]
    pub research_options: Vec<String>,
    #[serde(default)]
    pub required_age: Option<String>,
    #[serde(default)]
    pub requires_tech: Option<String>,
    pub build_time: u32,
    /// Only some defs carry a weapon (the tower).
    #[serde(default)]
    pub attack: Option<u32>,
    /// The tower's reach.
    #[serde(default)]
    pub range: Option<f64>,
    #[serde(default)]
    pub description: Option<String>,
}


/// What a research finisher unlocks: buildings it makes buildable, the one
/// unit line it opens.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TechUnlocks {
    #[serde(default)]
    pub buildings: Vec<String>,
    #[serde(default)]
    pub units: Vec<String>,
}

/// A technology in a civilization's tree.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tech {
    pub name: String,
    pub cost: Cost,
    /// The building that researches it.
    pub research_at: String,
    pub required_age: String,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub research_time: u32,
    #[serde(default)]
    pub unlocks: Option<TechUnlocks>,
    #[serde(default)]
    pub applies_to: Option<String>,
}

/// An order-preserving map with serde.
///
/// Current `serde_json` versions implement `serde` only on their concrete
/// `Map<String, Value>`; a generic `serde_json::Map<K, V>` field no longer
/// derives, so this wrapper carries the civ's tech tree and keeps the
/// export file's key order — the state's `research.available` list walks it.
#[derive(Debug, Clone)]
pub struct OrderedMap<K, V>(pub indexmap::IndexMap<K, V>);

impl<K, V> std::ops::Deref for OrderedMap<K, V> {
    type Target = indexmap::IndexMap<K, V>;
    fn deref(&self) -> &indexmap::IndexMap<K, V> {
        &self.0
    }
}

impl<K, V> serde::Serialize for OrderedMap<K, V>
where
    K: std::hash::Hash + Eq + serde::Serialize,
    V: serde::Serialize,
{
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut m = serializer.serialize_map(Some(self.0.len()))?;
        for (k, v) in &self.0 {
            m.serialize_entry(k, v)?;
        }
        m.end()
    }
}

struct MapVisitor<K, V>(std::marker::PhantomData<(K, V)>);

impl<'de, K, V> serde::de::Visitor<'de> for MapVisitor<K, V>
where
    K: std::hash::Hash + Eq + serde::Deserialize<'de>,
    V: serde::Deserialize<'de>,
{
    type Value = indexmap::IndexMap<K, V>;
    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("a map")
    }
    fn visit_map<M: serde::de::MapAccess<'de>>(
        self,
        mut access: M,
    ) -> Result<Self::Value, M::Error> {
        let mut out = indexmap::IndexMap::new();
        while let Some((k, v)) = access.next_entry()? {
            out.insert(k, v);
        }
        Ok(out)
    }
}

impl<'de, K, V> serde::Deserialize<'de> for OrderedMap<K, V>
where
    K: std::hash::Hash + Eq + serde::Deserialize<'de>,
    V: serde::Deserialize<'de>,
{
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Self, D::Error> {
        Ok(Self(deserializer.deserialize_map(MapVisitor::<K, V>(
            std::marker::PhantomData,
        ))?))
    }
}

/// One of the four playable civilizations.
///
/// Key order matters in `tech_tree`: the state's research list walks
/// `Object.keys(techs)`, and `OrderedMap` keeps the export's order.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Civilization {
    pub name: String,
    /// The English rendering of `name` — the state's `civilizationName`
    /// carries it for a model reading English.
    pub en_name: String,
    pub color: u32,
    /// The five seat multipliers a fresh `bonus` effect leaves behind,
    /// pre-stringified exactly as `JSON.stringify` emits them (undefined legs
    /// dropped). Parsed at load.
    pub bonuses: serde_json::Value,
    pub building_health_multiplier: f64,
    #[serde(default)]
    pub excluded_units: Vec<String>,
    #[serde(default)]
    pub unique_units: Vec<UnitDef>,
    #[serde(default)]
    pub unique_buildings: Vec<BuildingDef>,
    pub tech_tree: OrderedMap<String, Tech>,
}

impl Civilization {
    /// `civ.bonus.name === 'Pyramide' / 'Akropolis'` — the building-health
    /// multiplier the reference folds into `buildingMaxHealth`.
    pub fn building_health_bonus(&self) -> f64 {
        match self.name.as_str() {
            "Pyramide" => 1.5,
            "Akropolis" => 1.3,
            _ => 1.0,
        }
    }
}
/// The tower's epoch firepower (buildings.js:163-172): how many attackers
/// a volley answers, and the damage each arrow carries.
#[derive(Debug, Clone, Copy)]
pub struct TowerPower {
    pub arrows: u32,
    pub attack: f64,
}

/// The def a civilization actually fields for `id`: its unique override wins
/// over the shared entry, and unique-only ids (Egypt's horse carriage) resolve
/// too (units.js:152-155).
impl WorldData {
    pub fn get_civilization(&self, id: &str) -> Option<&Civilization> {
        self.civilizations.get(id)
    }

    pub fn get_unit_def(&self, id: &str) -> Option<&UnitDef> {
        self.unit_defs.get(id)
    }

    pub fn get_unit_def_for(&self, civilization: &str, id: &str) -> Option<&UnitDef> {
        self.get_civilization(civilization)
            .and_then(|civ| civ.unique_units.iter().find(|u| u.id == id))
            .or_else(|| self.unit_defs.get(id))
    }

    pub fn get_building_def(&self, id: &str) -> Option<&BuildingDef> {
        self.building_defs.get(id)
    }

    /// The wonder a civilization builds: the first `uniqueBuildings` entry of
    /// type 'wonder' (openai-ai.js:6422).
    pub fn wonder_def_for(&self, civilization: &str) -> Option<&BuildingDef> {
        self.get_civilization(civilization)
            .and_then(|civ| civ.unique_buildings.iter().find(|b| b.kind == "wonder"))
    }

    /// `getTrainOptionsForBuilding` (buildings.js:209): the highest tier at or
    /// below the age, then the civ's uniques that train there, minus its
    /// exclusions.
    pub fn get_train_options_for_building(
        &self,
        building_type: &str,
        age: &str,
        civilization: &str,
    ) -> Vec<String> {
        let age_order = &self.ages;
        let current_idx = match age_order.iter().position(|a| a == age) {
            Some(i) => i,
            None => return vec![],
        };
        let tiers = match self.building_train_tiers.get(building_type) {
            Some(t) => t,
            None => return vec![],
        };
        let mut result: Vec<String> = vec![];
        for a in age_order.iter().take(current_idx + 1) {
            if let Some(list) = tiers.get(a) {
                result = list.clone();
            }
        }
        if let Some(civ) = self.get_civilization(civilization) {
            let mut out = result;
            for u in &civ.unique_units {
                if u.train_at.as_deref() != Some(building_type) {
                    continue;
                }
                let tier_idx = u
                    .tier
                    .as_deref()
                    .and_then(|t| age_order.iter().position(|a| a == t));
                if tier_idx.is_some_and(|ti| ti > current_idx) {
                    continue;
                }
                if !out.iter().any(|x| x == &u.id) {
                    out.push(u.id.clone());
                }
            }
            if !civ.excluded_units.is_empty() {
                out.retain(|id| !civ.excluded_units.iter().any(|e| e == id));
            }
            return out;
        }
        result
    }

    /// `effectiveBuildingAge` (buildings.js:251): the def's own requiredAge, or
    /// later, the age of the civ tech that unlocks it.
    pub fn effective_building_age(&self, civilization: &str, def: &BuildingDef) -> String {
        let age_order = &self.ages;
        let mut idx = def
            .required_age
            .as_deref()
            .and_then(|a| age_order.iter().position(|x| x == a))
            .unwrap_or(0);
        if let Some(tech_id) = &def.requires_tech {
            if let Some(tech) = self
                .get_civilization(civilization)
                .and_then(|c| c.tech_tree.get(tech_id))
            {
                if let Some(ti) = age_order.iter().position(|a| a == &tech.required_age) {
                    idx = idx.max(ti);
                }
            }
        }
        age_order[idx].clone()
    }

    /// `trainableUnitsFor` (openai-ai.js:675): every unit the civ can EVER
    /// train, with the building that makes it and the earliest age it appears.
    pub fn trainable_units_for(&self, civilization: &str) -> Vec<(String, String, String)> {
        let age_order = &self.ages;
        let hosts = ["town_center", "barracks", "archery_range", "stable", "temple"];
        let civ = self.get_civilization(civilization);
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        // Order is the reference's: host order, then first appearance per age.
        let mut out: Vec<(String, String, String)> = vec![];
        for bt in hosts {
            let def = match self.get_building_def(bt) {
                Some(d) => d,
                None => continue,
            };
            if let Some(req) = &def.requires_tech {
                let has = civ.is_some_and(|c| c.tech_tree.contains_key(req));
                if !has {
                    continue;
                }
            }
            let floor = def.required_age.as_deref().unwrap_or("stone");
            for (ai, age) in age_order.iter().enumerate() {
                let fi = age_order.iter().position(|a| a == floor).unwrap_or(0);
                if ai < fi {
                    continue;
                }
                let mut opts = self.get_train_options_for_building(bt, age, civilization);
                if opts.is_empty() {
                    opts = def.train_options.clone();
                }
                for id in opts {
                    if seen.insert(id.clone()) {
                        out.push((id, bt.to_string(), age.clone()));
                    }
                }
            }
        }
        out
    }

    /// `towerPower` (buildings.js:170): the per-epoch table, the stone row
    /// as the fallback for any unknown age.
    pub fn tower_power(&self, age: &str) -> TowerPower {
        match age {
            "neolithic" => TowerPower {
                arrows: 3,
                attack: 12.0,
            },
            "bronze" => TowerPower {
                arrows: 4,
                attack: 15.0,
            },
            "iron" => TowerPower {
                arrows: 5,
                attack: 20.0,
            },
            _ => TowerPower {
                arrows: 2,
                attack: 10.0,
            },
        }
    }
}
