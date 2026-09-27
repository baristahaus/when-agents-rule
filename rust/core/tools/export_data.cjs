// Exports the STATIC world content of the JS reference to data/world.json:
// the ages ladder and its costs, the shared unit/building definition tables,
// and every civilization (tech tree, uniques, exclusions, name translations,
// and the bonus multipliers a fresh seat carries into a match).
//
// The Rust core loads this file and the golden-diff proves the port: the data
// is exported by running the real code, never re-typed.
//
// Usage: node tools/export_data.cjs  (from rust/core/, or with the repo root
// as argv[2])
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = process.argv[2] || path.join(__dirname, '..', '..', '..');

// The same sandbox the shipped test harnesses use (tests/age-ladder.test.cjs):
// fixed load order, no module system, a few browser shims for the scripts that
// probe for one. game.js is cut at the private-host section, which the suite
// never loads.
const scope = {
    console: { log() {}, warn() {}, error() {} },
    Math, JSON, Date, Object, Array, String, Number, Boolean, Set, Map, RegExp, Error, Promise,
    isNaN, parseInt, parseFloat, setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {},
    performance: { now: () => Date.now() },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    document: undefined,
};
vm.createContext(scope);
for (const f of ['js/civilizations.js', 'js/units.js', 'js/buildings.js', 'js/resources.js', 'js/i18n.js'])
    vm.runInContext(fs.readFileSync(path.join(ROOT, f), 'utf8'), scope, { filename: f });
vm.runInContext(
    fs.readFileSync(path.join(ROOT, 'js', 'game.js'), 'utf8').split('\nconst WAR_PRIVATE_HOST')[0],
    scope, { filename: 'js/game.js' }
);

// The fields addAIPlayer gives every fresh seat (js/ai.js:27-61). The civ bonus
// effect mutates exactly this object at match start (game.js:355), so running it
// here reproduces the multipliers the first state of every match carries.
scope.freshAi = function freshAi() {
    return {
        resources: { food: 200, wood: 200, stone: 100, gold: 50 },
        workerHarvestBonus: 1.0,
        trainSpeedBonus: 1.0,
        techCostMultiplier: 1.0,
        buildingHealthMultiplier: 1.0,
        attackBonus: undefined,
        healthBonus: undefined,
        miningBonus: undefined,
        units: [],
        buildings: [],
    };
};

const data = vm.runInContext(`(() => {
    const civs = {};
    for (const id of Object.keys(CIVILIZATIONS)) {
        const civ = CIVILIZATIONS[id];
        const ai = freshAi();
        if (civ.bonus && civ.bonus.effect) civ.bonus.effect(ai);
        civs[id] = {
            name: civ.name,
            // The model-language rendering of the German source name, as the
            // state's civilizationName field carries it (openai-ai.js:2487).
            enName: tgIn('en', civ.name),
            color: civ.color,
            // The five numbers the state's "bonuses" section reads off the
            // fresh seat (openai-ai.js:2715-2720). undefined stays absent —
            // JSON.stringify drops it, which is exactly what the reference
            // sends.
            bonuses: JSON.stringify({
                harvest: ai.workerHarvestBonus,
                attack: ai.attackBonus,
                health: ai.healthBonus,
                mining: ai.miningBonus,
                techCostMult: ai.techCostMultiplier
            }),
            buildingHealthMultiplier: ai.buildingHealthMultiplier,
            excludedUnits: civ.excludedUnits || [],
            uniqueUnits: civ.uniqueUnits || [],
            uniqueBuildings: civ.uniqueBuildings || [],
            techTree: civ.techTree || {}
        };
    }
    return {
        ages: BUILDING_AGE_ORDER,
        ageCosts: AGE_COSTS,
        maxPopulationCap: MAX_POPULATION_CAP,
        buildingDefs: BUILDING_DEFS,
        buildingTrainTiers: BUILDING_TRAIN_TIERS,
        unitDefs: UNIT_DEFS,
        civilizations: civs
    };
})()`, scope, { filename: 'export_data' });

const dest = path.join(__dirname, '..', 'data', 'world.json');
fs.mkdirSync(path.dirname(dest), { recursive: true });
fs.writeFileSync(dest, JSON.stringify(data, null, 2) + '\n');
console.log(`wrote ${dest} (${fs.statSync(dest).size} bytes)`);
