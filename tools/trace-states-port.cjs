#!/usr/bin/env node
'use strict';
// ---------------------------------------------------------------------------
// Port of WAR's per-seat state view, and its gate.
//
// The reference is the game's own rule code (js/ at HEAD) run the way the
// benchmark drives it: a real arena match on the seeded 'golden' map, four
// seats (egyptian, greek, persian, yamato), advanced in whole 50 ms steps,
// with the harness's buildGameStateJSON printed per seat at t=0 and t=1000.
// tools/golden/dump-states.cjs does that on the reference; this file does the
// same thing re-implemented here, so a diff between the two is a finding,
// not a faith of the reader.
//
//   node tools/trace-states-port.cjs                      # print the 8 lines
//   node tools/trace-states-port.cjs <golden file>        # and gate: byte-compare
//                                                          # the canonical form
//
// The gate compares against golden/states-b1040-t0-t1.canonical.jsonl, the
// form tools/golden/canonicalize-states.cjs leaves behind: seat ids re-keyed
// to seat<n> in line order, session-minted entity ids renamed in
// first-appearance order. The raw ids are minted from the match's keyed
// random draws, so they are reproducible run to run on the reference; the
// canonical form still exists because the re-key is the same one compare.cjs
// applies between two recorded runs, and a fixture that only matches under
// one id scheme would hide a drift in exactly that scheme.
//
// ROLE (decided 5 October 2026, the day the Odin turn-1 gate landed — see
// docs/REBUILD-EFFORT.md §5 item 6): this file is the LINE-MAP SPEC for the remaining
// transcription. The remaining gates — the enemy-unit memory (b1041/42), the enemy-building
// memory, the rule brain, the whole-match sequence P0(c) — are transcribed from the functions
// below, not from the browser game. It retires to provenance when the Odin port covers a whole
// match (the rule-brain gate green, P0(c) green) and becomes the second oracle; the
// “standing second JS opinion” role is declined — the parent already ships js/resim.js as
// their second implementation, and a third JS implementation without a stated role is a habit,
// not a check.
//
// What is re-implemented, and from which reference file:
//   rng          js/simulation/rng.js          (keyed draws, id minting)
//   terrain      js/terrain.js                 (seeded scatter, TC clearance)
//   civ data     js/civilizations.js           (costs, tech trees, wonders)
//   units        js/units.js                   (defs, handles, building HP)
//   buildings    js/buildings.js               (defs, train tiers, ages)
//   resources    js/resources.js
//   game core    js/game.js                    (clock, vision, exploration,
//                                               rival contacts, elimination,
//                                               the 50 ms step order)
//   position     js/game.js WarPositionRules   (separation + building clearance)
//   ai manager   js/ai.js                      (the 250 ms discovery beat)
//   state view   js/openai-ai.js observe()     (the whole buildGameStateJSON)
//
// Updated 5 October 2026, after the b1054 merge: isPlayerEliminated and
// canAffordAnyMilitary below are the parent's b1054 semantics (the room gate
// lives in the predicate; cost alone answers the afford question). One part of
// the b1041/b1042 reference is NOT yet transcribed here: the enemy-unit memory
// machinery (enemyUnits as remembered contacts, gameStats.opponents[].
// seenAlive/seenSecondsAgo, the pruned recentEvents). It is invisible at this
// gate's two moments — no seat has met a rival at t=0 or t=1000, which is why
// the fixture and this port still agree byte for byte — and it becomes required
// at the first gate with contacts in it (the whole-match gate, P0(c)).
//
// One deliberate simplification, flagged here rather than hidden: the
// reference's WarMath (js/simulation/math.js) is a portable fdlibm port
// because BROWSERS disagree in the last bit; on x64 Node it equals Math to
// the last bit, and the declared reference runtime is Node. This port uses
// Math directly, which is therefore bit-identical on the reference runtime.
// ---------------------------------------------------------------------------

// ============================================================
// 1. RNG — js/simulation/rng.js
// ============================================================

// mulberry32. `fallback` replaces a zero seed: 1 for textures, 42 for maps.
function rngStream(seed, fallback = 1) {
    let a = (seed >>> 0) || fallback;
    return function () {
        a |= 0; a = (a + 0x6D2B79F5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

// A string to a 32-bit seed: the map generator's own hash, kept exactly, so an
// existing map seed still produces its map.
function hashSeed(text) {
    const s = String(text);
    let h = 1779033703 ^ s.length;
    for (const ch of s) {
        h = Math.imul(h ^ ch.charCodeAt(0), 3432918353);
        h = (h << 13) | (h >>> 19);
    }
    return h >>> 0;
}

const WarRng = {
    stream: rngStream,
    hashSeed,
    keyed(seed) { return { seed: String(seed == null ? '' : seed), n: {} }; },
    // An id from two draws: 52 bits as eleven base-36 characters.
    id(prefix, next) {
        const hi = Math.floor(next() * 0x100000000), lo = Math.floor(next() * 0x100000);
        return prefix + (hi * 0x100000 + lo).toString(36).padStart(11, '0');
    },
    // The n-th draw for `key` in this match, in [0, 1).
    draw(state, key) {
        const n = state.n[key] || 0;
        state.n[key] = n + 1;
        return WarRng.stream(WarRng.hashSeed(state.seed + '|' + key + '|' + n), 42)();
    }
};

// ============================================================
// 2. Terrain — js/terrain.js (the seeded part of it)
// ============================================================

// Difficulty presets: resource-count multipliers against the scatter bases
// (food 196, wood 784, stone 40, gold 18 — the bases live in generate* below).
const DIFFICULTY_MODS = {
    easy:   { food: 2.0,  wood: 1.0,  stone: 1.0 },
    medium: { food: 0.5,  wood: 1.0,  stone: 1.0 },
    hard:   { food: 0.25, wood: 0.25, stone: 0.5 }
};

function makeTerrain(seedText, difficulty) {
    const t = {
        size: 800,
        seed: seedText,
        difficulty,
        resources: [],
        spawns: null,
        rand: null,
        diffMods() { return DIFFICULTY_MODS[this.difficulty] || DIFFICULTY_MODS.easy; },
        _initRand() {
            if (this.seed == null || this.seed === '') { this.rand = Math.random; return; }
            this.rand = WarRng.stream(WarRng.hashSeed(this.seed), 42);
        },
        // Depleted nodes stay in the array (fog memory stores indices); count
        // amount > 0, per type.
        nodesLeftOnMap() {
            return (this.resources || []).reduce((a, r) => {
                if (r.amount > 0) a[r.type] = (a[r.type] || 0) + 1;
                return a;
            }, {});
        },
        // Clear every node within `radius` of (x,z); used to keep starting
        // Town Centers off the nodes under them.
        clearResourcesNear(x, z, radius) {
            let n = 0;
            for (let i = this.resources.length - 1; i >= 0; i--) {
                const r = this.resources[i];
                const dx = r.x - x, dz = r.z - z;
                if (Math.sqrt(dx * dx + dz * dz) < radius) {
                    this.resources.splice(i, 1);
                    n++;
                }
            }
            return n;
        },
        // Fairness scatter for the PLENTIFUL types: a 7x7 grid of equal tiles,
        // every tile the same number of nodes, placed uniformly within it.
        scatterEqual(type, totalCount, amount) {
            const margin = 40;
            const usable = this.size - margin * 2;
            const G = 7;
            const tile = usable / G;
            const per = Math.max(1, Math.round(totalCount / (G * G)));
            for (let tx = 0; tx < G; tx++) {
                for (let tz = 0; tz < G; tz++) {
                    const x0 = -usable / 2 + tx * tile;
                    const z0 = -usable / 2 + tz * tile;
                    for (let i = 0; i < per; i++) {
                        const inset = 6;
                        const x = x0 + inset + this.rand() * (tile - inset * 2);
                        const z = z0 + inset + this.rand() * (tile - inset * 2);
                        this.resources.push({ type, x, z, amount, mesh: null, health: amount });
                    }
                }
            }
        },
        // Fairness placement for the SCARCE types: lay k nodes in one player's
        // sector and rotate that sector onto every other. Radius drawn uniform
        // by AREA; the keep-out is a radius around every spawn.
        scatterRotational(type, totalCount, amount) {
            const spawns = (this.spawns && this.spawns.length) ? this.spawns : null;
            if (!spawns) return this.scatterEqual(type, totalCount, amount);
            const N = spawns.length;
            const per = Math.max(1, Math.round(totalCount / N));
            const R = this.size / 2 - 40;
            const rMin = 60;
            const KEEPOUT = 95;
            const sector = (Math.PI * 2) / N;
            const a0 = Math.atan2(spawns[0].z, spawns[0].x);
            const tooClose = (x, z) => spawns.some(s => {
                const dx = x - s.x, dz = z - s.z;
                return Math.sqrt(dx * dx + dz * dz) < KEEPOUT;
            });
            for (let i = 0; i < per; i++) {
                let r = rMin, t = a0;
                for (let tries = 0; tries < 60; tries++) {
                    const u = this.rand();
                    r = Math.sqrt(rMin * rMin + u * (R * R - rMin * rMin));
                    t = a0 + (this.rand() - 0.5) * sector;
                    if (!tooClose(Math.cos(t) * r, Math.sin(t) * r)) break;
                }
                for (let p = 0; p < N; p++) {
                    const ang = t + p * sector;
                    this.resources.push({
                        type, x: Math.cos(ang) * r, z: Math.sin(ang) * r,
                        amount, mesh: null, health: amount
                    });
                }
            }
        },
        generateTerrain() {
            this._initRand();
            this.resources = [];
            this.generateResources();
            this.generateTrees();
            this.generateStones();
            this.generateGold();
        },
        generateResources() {
            // Food: 196 base, EXACT on the 49-cell grid (8/2/1 per tile).
            this.scatterEqual('food', 196 * this.diffMods().food, 500);
        },
        generateTrees() {
            // Wood: 784 base, 16 per tile.
            this.scatterEqual('wood', 784 * this.diffMods().wood, 300);
        },
        generateStones() {
            // Stone: 40 base, rotational.
            this.scatterRotational('stone', 40 * this.diffMods().stone, 1000);
        },
        generateGold() {
            // Gold: 18 base (20 at four seats: round(18/4) = 5 per seat), rotational.
            this.scatterRotational('gold', 18, 2000);
        }
    };
    return t;
}

// ============================================================
// 3. Civilisation data — js/civilizations.js, js/units.js, js/buildings.js
// ============================================================

const AGE_COSTS = {
    neolithic: { food: 1000, wood: 800,  stone: 0,    gold: 0 },
    bronze:    { food: 2000, wood: 1500, stone: 400,  gold: 200 },
    iron:      { food: 4000, wood: 3000, stone: 1000, gold: 600 }
};

// nameEn is what the harness sends once the dumper has pinned the UI language
// to 'en'; the reference's source strings are German.
const CIVS = {
    egyptian: {
        nameEn: 'Egyptians',
        bonus: { kind: 'buildingHealth', mult: 1.5 },
        excludedUnits: ['cavalry', 'heavy_cavalry'],
        uniqueUnits: [
            { id: 'priest',        cost: { food: 50,  wood: 0,  stone: 0,   gold: 30 }, health: 60,  speed: 1.2, attack: 3,  range: 10.5, type: 'support',  tier: 'bronze' },
            { id: 'slinger',       cost: { food: 60,  wood: 20, stone: 0,   gold: 0 }, health: 45,  speed: 1.0, attack: 6,  range: 12,   type: 'ranged',   tier: 'neolithic', trainAt: 'archery_range' },
            { id: 'horse_carriage', cost: { food: 60,  wood: 20, stone: 40,  gold: 40 }, health: 100, speed: 2.0, attack: 8,  range: 2,    type: 'cavalry',  tier: 'bronze', trainAt: 'stable' }
        ],
        wonder: { id: 'pyramid', cost: { food: 4800, wood: 4800, stone: 4250, gold: 2650 }, health: 1500, requiredAge: 'iron' },
        techs: {
            house:       { cost: { food: 50,  wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            farm:        { cost: { food: 100, wood: 50,  stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            barracks:    { cost: { food: 100, wood: 150, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            agriculture: { cost: { food: 100, wood: 50,  stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: ['farm'] },
            pottery:     { cost: { food: 80,  wood: 40,  stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            longbow:     { cost: { food: 50,  wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            academy:     { cost: { food: 200, wood: 150, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'neolithic', requires: [] },
            mining:      { cost: { food: 50,  wood: 50,  stone: 50,   gold: 0 },  researchAt: 'academy', requiredAge: 'neolithic', requires: ['academy'] },
            archery:     { cost: { food: 100, wood: 100, stone: 0,    gold: 50 }, researchAt: 'academy', requiredAge: 'neolithic', requires: [] },
            bronze_armor: { cost: { food: 0, wood: 0, stone: 150, gold: 100 }, researchAt: 'academy', requiredAge: 'bronze', requires: [] },
            horseback:   { cost: { food: 150, wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'neolithic', requires: [] },
            healing:     { cost: { food: 150, wood: 0,   stone: 0,    gold: 100 }, researchAt: 'temple', requiredAge: 'bronze', requires: [] },
            iron_working: { cost: { food: 0, wood: 0, stone: 200, gold: 200 }, researchAt: 'academy', requiredAge: 'iron', requires: ['bronze_armor'] },
            fire_arrows: { cost: { food: 50,  wood: 100, stone: 80,   gold: 100 }, researchAt: 'academy', requiredAge: 'iron', requires: [] }
        }
    },
    greek: {
        nameEn: 'Greeks',
        bonus: { kind: 'buildingHealth', mult: 1.3 },
        excludedUnits: ['cavalry', 'heavy_cavalry'],
        uniqueUnits: [
            { id: 'hoplite', cost: { food: 80, wood: 0, stone: 50, gold: 30 }, health: 150, speed: 0.9, attack: 10, range: 1, type: 'infantry', tier: 'neolithic', trainAt: 'barracks' },
            { id: 'phalanx', cost: { food: 60, wood: 0, stone: 40, gold: 20 }, health: 100, speed: 0.8, attack: 8,  range: 2, type: 'infantry', tier: 'bronze',   trainAt: 'barracks' }
        ],
        wonder: { id: 'akropolis', cost: { food: 4500, wood: 4500, stone: 4000, gold: 2500 }, health: 1500, requiredAge: 'iron' },
        techs: {
            house:       { cost: { food: 50,  wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            farm:        { cost: { food: 100, wood: 50,  stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            barracks:    { cost: { food: 100, wood: 150, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            horseback:   { cost: { food: 150, wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'neolithic', requires: [] },
            falx:        { cost: { food: 100, wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: ['barracks'] },
            farsight:    { cost: { food: 100, wood: 50,  stone: 0,    gold: 30 }, researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            longbow:     { cost: { food: 50,  wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            academy:     { cost: { food: 200, wood: 150, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'neolithic', requires: [] },
            philosophy:  { cost: { food: 200, wood: 0,   stone: 0,    gold: 150 }, researchAt: 'academy', requiredAge: 'neolithic', requires: ['academy'] },
            democracy:   { cost: { food: 300, wood: 0,   stone: 0,    gold: 200 }, researchAt: 'academy', requiredAge: 'bronze', requires: ['philosophy'] },
            phalanx_armor: { cost: { food: 0, wood: 50, stone: 150, gold: 100 }, researchAt: 'academy', requiredAge: 'bronze', requires: [] },
            healing:     { cost: { food: 150, wood: 0,   stone: 0,    gold: 100 }, researchAt: 'temple', requiredAge: 'bronze', requires: [] },
            iron_working: { cost: { food: 0, wood: 0, stone: 200, gold: 200 }, researchAt: 'academy', requiredAge: 'iron', requires: ['phalanx_armor'] },
            fire_arrows: { cost: { food: 50,  wood: 100, stone: 80,   gold: 100 }, researchAt: 'academy', requiredAge: 'iron', requires: [] }
        }
    },
    persian: {
        nameEn: 'Persians',
        bonus: { kind: 'workerHarvest', mult: 1.2 },
        uniqueUnits: [
            { id: 'archer',        cost: { food: 70,  wood: 30, stone: 0,   gold: 0 },  health: 50,  speed: 1.1, attack: 7,  range: 15, type: 'ranged',   tier: 'neolithic' },
            { id: 'cavalry',        cost: { food: 110, wood: 0,  stone: 0,   gold: 40 }, health: 140, speed: 2.0, attack: 12, range: 1,  type: 'cavalry',  tier: 'bronze' },
            { id: 'heavy_cavalry',  cost: { food: 160, wood: 0,  stone: 40,  gold: 70 }, health: 200, speed: 1.8, attack: 18, range: 1,  type: 'cavalry',  tier: 'iron' }
        ],
        wonder: { id: 'firetemple', cost: { food: 4500, wood: 4500, stone: 4000, gold: 2500 }, health: 1500, requiredAge: 'iron' },
        techs: {
            house:        { cost: { food: 50,  wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            farm:         { cost: { food: 100, wood: 50,  stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            barracks:     { cost: { food: 100, wood: 150, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            horseback:    { cost: { food: 150, wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'neolithic', requires: [] },
            longbow:      { cost: { food: 50,  wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            academy:      { cost: { food: 200, wood: 150, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'neolithic', requires: [] },
            cavalry_training: { cost: { food: 150, wood: 50, stone: 0, gold: 100 }, researchAt: 'academy', requiredAge: 'neolithic', requires: ['horseback'] },
            cavalry_armor:  { cost: { food: 0, wood: 0, stone: 200, gold: 150 }, researchAt: 'academy', requiredAge: 'bronze', requires: ['cavalry_training'] },
            immortals:      { cost: { food: 0, wood: 0, stone: 150, gold: 100 }, researchAt: 'academy', requiredAge: 'bronze', requires: [] },
            healing:        { cost: { food: 150, wood: 0,  stone: 0,   gold: 100 }, researchAt: 'temple', requiredAge: 'bronze', requires: [] },
            archery:        { cost: { food: 100, wood: 100, stone: 0,  gold: 50 }, researchAt: 'academy', requiredAge: 'bronze', requires: [] },
            siege:          { cost: { food: 0, wood: 200, stone: 150, gold: 200 }, researchAt: 'academy', requiredAge: 'iron', requires: ['archery'] },
            fire_arrows:    { cost: { food: 50, wood: 100, stone: 80,  gold: 100 }, researchAt: 'academy', requiredAge: 'iron', requires: [] }
        }
    },
    yamato: {
        nameEn: 'Yamato',
        bonus: { kind: 'techCost', mult: 0.7 },
        uniqueUnits: [
            { id: 'samurai',    cost: { food: 100, wood: 50,  stone: 0,   gold: 50 }, health: 130, speed: 1.3, attack: 14, range: 1,  type: 'infantry', tier: 'bronze', trainAt: 'barracks' },
            { id: 'archer_ship', cost: { food: 150, wood: 150, stone: 0,   gold: 50 }, health: 200, speed: 1.5, attack: 8,  range: 12, type: 'ranged' }
        ],
        wonder: { id: 'shrine', cost: { food: 4500, wood: 4500, stone: 4000, gold: 2500 }, health: 1500, requiredAge: 'iron' },
        techs: {
            house:       { cost: { food: 50,  wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            farm:        { cost: { food: 100, wood: 50,  stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            barracks:    { cost: { food: 100, wood: 150, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            bushido:     { cost: { food: 150, wood: 0,   stone: 0,    gold: 100 }, researchAt: 'town_center', requiredAge: 'stone', requires: ['barracks'] },
            healing:     { cost: { food: 150, wood: 0,   stone: 0,    gold: 100 }, researchAt: 'temple', requiredAge: 'bronze', requires: [] },
            speed:       { cost: { food: 100, wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            longbow:     { cost: { food: 50,  wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'stone', requires: [] },
            academy:     { cost: { food: 200, wood: 150, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'neolithic', requires: [] },
            horseback:   { cost: { food: 150, wood: 100, stone: 0,    gold: 0 },  researchAt: 'town_center', requiredAge: 'neolithic', requires: [] },
            armor:       { cost: { food: 0, wood: 100, stone: 150,  gold: 150 }, researchAt: 'academy', requiredAge: 'bronze', requires: ['bushido'] },
            lamellar_armor: { cost: { food: 0, wood: 0, stone: 150, gold: 100 }, researchAt: 'academy', requiredAge: 'bronze', requires: [] },
            iron_working: { cost: { food: 0, wood: 0, stone: 200, gold: 200 }, researchAt: 'academy', requiredAge: 'iron', requires: ['armor'] },
            fire_arrows: { cost: { food: 50,  wood: 100, stone: 80,   gold: 100 }, researchAt: 'academy', requiredAge: 'iron', requires: [] }
        }
    }
};

// Shared unit defs (js/units.js UNIT_DEFS); the unique unit of a civ that
// reuses a shared id resolves to the civ's own copy (getUnitDefFor).
const UNIT_DEFS = {
    worker:        { cost: { food: 50,  wood: 0,  stone: 0,   gold: 0 },  health: 40,  speed: 1.0, attack: 3,  range: 0.5,  type: 'worker',   tier: 'stone' },
    militia:       { cost: { food: 50,  wood: 20, stone: 0,   gold: 0 },  health: 70,  speed: 1.1, attack: 7,  range: 0.5,  type: 'infantry', tier: 'stone' },
    warrior:       { cost: { food: 80,  wood: 0,  stone: 30,  gold: 20 }, health: 120, speed: 1.0, attack: 12, range: 0.5,  type: 'infantry', tier: 'bronze' },
    champion:      { cost: { food: 150, wood: 50, stone: 50,  gold: 100 }, health: 200, speed: 1.5, attack: 18, range: 0.5,  type: 'infantry', tier: 'iron' },
    archer:        { cost: { food: 60,  wood: 30, stone: 0,   gold: 0 },  health: 40,  speed: 1.0, attack: 6,  range: 12,   type: 'ranged',   tier: 'neolithic' },
    crossbowman:   { cost: { food: 100, wood: 40, stone: 20,  gold: 30 }, health: 60,  speed: 0.9, attack: 12, range: 13.5, type: 'ranged',   tier: 'iron' },
    elite_archer:  { cost: { food: 150, wood: 60, stone: 30,  gold: 50 }, health: 80,  speed: 1.1, attack: 16, range: 15,   type: 'ranged',   tier: 'iron' },
    scout_cavalry: { cost: { food: 100, wood: 0,  stone: 0,   gold: 30 }, health: 100, speed: 2.2, attack: 8,  range: 0.5,  type: 'cavalry',  tier: 'neolithic' },
    cavalry:       { cost: { food: 120, wood: 0,  stone: 0,   gold: 50 }, health: 140, speed: 2.0, attack: 12, range: 0.5,  type: 'cavalry',  tier: 'bronze' },
    heavy_cavalry: { cost: { food: 180, wood: 0,  stone: 50,  gold: 80 }, health: 200, speed: 1.8, attack: 18, range: 0.5,  type: 'cavalry',  tier: 'iron' },
    priest:        { cost: { food: 50,  wood: 0,  stone: 0,   gold: 30 }, health: 60,  speed: 1.0, attack: 3,  range: 10.5, type: 'support',  tier: 'bronze' }
};

// Building defs (js/buildings.js). canTrain/trainOptions feed the train tiers.
const BUILDING_DEFS = {
    town_center:   { cost: { food: 100, wood: 100, stone: 100, gold: 100 }, health: 1000, popBonus: 10, type: 'economic',   canTrain: true, trainOptions: ['worker'], canResearch: true, requiredAge: 'stone', buildTime: 15000 },
    house:          { cost: { food: 30,  wood: 20,  stone: 0,   gold: 0 },   health: 300,  popBonus: 5,  type: 'economic',   requiredAge: 'stone', requiresTech: 'house' },
    temple:         { cost: { food: 100, wood: 100, stone: 150, gold: 100 }, health: 800,  type: 'religious', canTrain: true, trainOptions: ['priest'], canResearch: true, requiredAge: 'bronze' },
    barracks:       { cost: { food: 50,  wood: 150, stone: 0,   gold: 0 },   health: 800,  type: 'military',  canTrain: true, requiredAge: 'stone', requiresTech: 'barracks' },
    stable:         { cost: { food: 100, wood: 100, stone: 0,   gold: 50 },  health: 700,  type: 'military',  canTrain: true, requiredAge: 'neolithic', requiresTech: 'horseback' },
    archery_range:  { cost: { food: 50,  wood: 100, stone: 50,  gold: 0 },   health: 600,  type: 'military',  canTrain: true, requiredAge: 'neolithic', requiresTech: 'longbow' },
    academy:        { cost: { food: 100, wood: 100, stone: 100, gold: 50 },  health: 700,  type: 'economic',  canResearch: true, requiredAge: 'neolithic', requiresTech: 'academy' },
    farm:           { cost: { food: 50,  wood: 50,  stone: 0,   gold: 0 },   health: 400,  type: 'economic',   requiredAge: 'stone', requiresTech: 'farm' },
    tower:          { cost: { food: 50,  wood: 50,  stone: 100, gold: 0 },   health: 600,  type: 'defense',  attack: 10, range: 18, requiredAge: 'stone' }
};

// Unit tiers per age per military building (js/buildings.js BUILDING_TRAIN_TIERS).
const TRAIN_TIERS = {
    barracks: {
        stone: ['militia'],
        neolithic: ['militia'],
        bronze: ['militia', 'warrior'],
        iron: ['militia', 'warrior', 'champion']
    },
    stable: {
        neolithic: ['scout_cavalry'],
        bronze: ['scout_cavalry', 'cavalry'],
        iron: ['scout_cavalry', 'cavalry', 'heavy_cavalry']
    },
    archery_range: {
        neolithic: ['archer'],
        bronze: ['archer'],
        iron: ['archer', 'crossbowman', 'elite_archer']
    }
};

const AGE_ORDER = ['stone', 'neolithic', 'bronze', 'iron'];

function getUnitDef(id) { return UNIT_DEFS[id] || null; }
// The def a civilisation actually fields for `id`: its unique override wins
// over the shared entry.
function getUnitDefFor(civilization, id) {
    const civ = CIVS[civilization];
    const u = civ && civ.uniqueUnits.find(x => x.id === id);
    return u || getUnitDef(id);
}
function getBuildingDef(id) { return BUILDING_DEFS[id] || null; }

// The age a civ can ACTUALLY build this at: the def's requiredAge, or the
// unlocking tech's age if that comes later (Egypt's bronze horseback tech).
function effectiveBuildingAge(civilization, buildingDef) {
    let idx = Math.max(0, AGE_ORDER.indexOf(buildingDef.requiredAge || 'stone'));
    if (buildingDef.requiresTech) {
        const civ = CIVS[civilization];
        const tech = civ && civ.techs[buildingDef.requiresTech];
        if (tech && tech.requiredAge) idx = Math.max(idx, AGE_ORDER.indexOf(tech.requiredAge));
    }
    return AGE_ORDER[idx];
}

function getTrainOptionsForBuilding(buildingType, age, civilization) {
    const tiers = TRAIN_TIERS[buildingType];
    if (!tiers) return [];
    const currentIdx = AGE_ORDER.indexOf(age);
    let result = [];
    for (let i = 0; i <= currentIdx; i++) {
        if (tiers[AGE_ORDER[i]]) result = tiers[AGE_ORDER[i]];
    }
    const civ = CIVS[civilization];
    if (civ) {
        for (const u of civ.uniqueUnits || []) {
            if (u.trainAt !== buildingType) continue;
            if (u.tier && AGE_ORDER.indexOf(u.tier) > currentIdx) continue;
            if (!result.includes(u.id)) result = result.slice().concat(u.id);
        }
        if (civ.excludedUnits && civ.excludedUnits.length) {
            result = result.filter(id => !civ.excludedUnits.includes(id));
        }
    }
    return result;
}

// ============================================================
// 4. Resources — js/resources.js
// ============================================================

class ResourceManager {
    constructor() {
        this.food = 200;
        this.wood = 200;
        this.stone = 100;
        this.gold = 50;
        this.population = 0;
        this.maxPopulation = 10;
    }
    hasResources(cost) {
        return this.food >= (cost.food || 0) &&
               this.wood >= (cost.wood || 0) &&
               this.stone >= (cost.stone || 0) &&
               this.gold >= (cost.gold || 0);
    }
    updatePopulation(count) { this.population = count; }
}

// ============================================================
// 5. Entities — js/units.js
// ============================================================

const MAX_POPULATION_CAP = 100;
const BUILDING_AGE_ORDER = AGE_ORDER;

// Max HP for a building of a given def/civ/age: x1.5 per age over stone,
// rounded to the nearest 50, with the civ's wall bonus — and WONDERS take
// neither multiplier: the number in the def is the number on the field.
function buildingMaxHealth(buildingDef, civ, age) {
    if (buildingDef.type === 'wonder' || buildingDef.requiredAge === 'iron' && buildingDef.id && (civ ? civ.wonder : null) && buildingDef.id === civ.wonder.id) {
        return Math.max(50, buildingDef.health);
    }
    const mult = civ && civ.bonus && civ.bonus.kind === 'buildingHealth' ? civ.bonus.mult : 1.0;
    const idx = Math.max(0, BUILDING_AGE_ORDER.indexOf(age));
    return Math.max(50, Math.round(buildingDef.health * Math.pow(1.5, idx) * mult / 50) * 50);
}

// Unit handles: a short per-owner counter, published in the state, never reused.
// The same module-global the reference keeps (js/units.js):
// owner -> next handle, 1, 2, 3 ... in creation order.
const unitHandleCounters = (() => {
    let seq = null;
    return () => (seq || (seq = new Map()));
})();
function nextUnitHandle(owner) {
    const seq = unitHandleCounters();
    const n = (seq.get(owner) || 0) + 1;
    seq.set(owner, n);
    return n;
}

// An entity id from two keyed draws of the match: 52 bits, eleven base-36
// characters. Checked against the renderer's living entities (the reference's
// `mintEntityId`), and redrawn on a clash.
function mintEntityId(game, prefix, ownerObj, purpose) {
    const r = game.renderer;
    const taken = id => !!(r && ((r.units || []).some(e => e.id === id) || (r.buildings || []).some(e => e.id === id)));
    let id;
    do {
        id = WarRng.id(prefix, () => game.rand(ownerObj, purpose));
    } while (taken(id));
    return id;
}

function createUnit(game, type, x, z, owner, civilization, age) {
    const unitDef = getUnitDefFor(civilization, type);
    if (!unitDef) return null;
    const ownerObj = game.aiManager.aiPlayers.find(a => a.id === owner) || null;
    const unit = {
        id: mintEntityId(game, 'unit_', ownerObj, 'unit-id'),
        handle: nextUnitHandle(owner),
        type,
        x, z,
        health: unitDef.health,
        maxHealth: unitDef.health,
        speed: unitDef.speed,
        attack: unitDef.attack,
        range: unitDef.range,
        unitType: unitDef.type,
        owner,
        civilization,
        seat: (ownerObj && ownerObj.seat != null) ? ownerObj.seat : null,
        currentTier: age || 'stone',
        targetX: x,
        targetZ: z,
        isMoving: false,
        isAttacking: false,
        attackTarget: null,
        harvestTarget: null,
        harvestAmount: 0,
        isHarvesting: false,
        isBuilding: false,
        buildProgress: 0,
        task: null,
        carryingResource: false,
        farmRef: null,
        repairTarget: null
    };
    return unit;
}

function createBuilding(game, type, x, z, owner, civilization, options) {
    const civ = CIVS[civilization];
    const uniqueBuilding = civ && civ.wonder && civ.wonder.id === type ? civ.wonder : null;
    const buildingDef = uniqueBuilding || BUILDING_DEFS[type];
    if (!buildingDef) return null;
    const ownerObj = game.aiManager.aiPlayers.find(a => a.id === owner) || null;
    const age = (options && options.age && BUILDING_AGE_ORDER.includes(options.age)) ? options.age : 'stone';
    const underConstruction = !!(options && options.underConstruction);
    const maxHealth = buildingMaxHealth(buildingDef, civ, age);
    const buildTime = buildingDef.buildTime || 10000;
    return {
        id: mintEntityId(game, 'building_', ownerObj, 'building-id'),
        type,
        age,
        x, z,
        underConstruction,
        buildProgress: 0,
        buildTime,
        isWonder: (uniqueBuilding ? 'wonder' : buildingDef.type) === 'wonder',
        health: underConstruction ? Math.max(1, maxHealth * 0.2) : maxHealth,
        maxHealth,
        owner,
        civilization,
        seat: (ownerObj && ownerObj.seat != null) ? ownerObj.seat : null,
        canTrain: buildingDef.canTrain || false,
        canResearch: buildingDef.canResearch || false,
        trainOptions: buildingDef.trainOptions || [],
        isProducing: false,
        productionProgress: 0,
        attack: buildingDef.attack || 0,
        range: buildingDef.range || 0,
        foodAmount: type === 'farm' ? 300 : 0,
        maxFoodAmount: type === 'farm' ? 300 : 0,
        assignedWorker: type === 'farm' ? null : undefined
    };
}

// ============================================================
// 6. Game core — js/game.js
// ============================================================

function makeGame() {
    const game = {
        terrain: null,
        aiManager: null,
        openAIAIManager: null,
        spectatorMode: true,
        mapSeed: null,
        difficulty: 'medium',
        wonderRequired: 600,
        EXPLORE_GRID: 42,
        EXPLORE_TILES: 7,
        gameStarted: false,
        clock: { stepNo: 0, simMs: 0, matchMs: 0 },
        player: null
    };

    game.simNow = function () { return this.clock.simMs; };
    // The match clock the model lives on: real time, at the current rate.
    game.advanceMatchClock = function (wallMs) {
        if (wallMs > 0) this.clock.matchMs += wallMs;
    };
    game.realSecsSince = function (simStamp) {
        return (this.clock.matchMs - (simStamp ? this.matchMsAt(simStamp) : this.clock.simMsToMatch(simStamp))) / 1000;
    };
    game.matchMsAt = function (simStamp) {
        // One rate only in this world (1x, no pauses): match time is sim time.
        return Math.max(0, Math.min(simStamp, this.clock.matchMs));
    };

    // Every random choice a rule makes, keyed: the value depends on the match
    // seed, who drew, what for, and which draw of that pair -- never on how many
    // draws anything else made first.
    game.rand = function (who, purpose) {
        if (!this._rng) this._rng = WarRng.keyed(this.mapSeed);
        return WarRng.draw(this._rng, this.rngOwnerKey(who) + ':' + purpose);
    };
    // Seats, not player ids: a key must mean the same seat in every run.
    game.rngOwnerKey = function (who) {
        if (!who) return 'world';
        if (who === this.player || who.units) {
            const owner = who;
            return owner.seat != null ? 's' + owner.seat : 'id:' + owner.id;
        }
        const o = this.getOwner(who);
        return o ? (o.seat != null ? 's' + o.seat : 'id:' + o.id) : 'world';
    };
    game.getOwner = function (e) {
        if (!e || e.id == null) return null;
        return this.aiManager.aiPlayers.find(a => a.id === e.id) || null;
    };

    // Shared sight radii: what a living unit and a finished building see.
    game.unitVision = function (unit) {
        return (unit && unit.unitType === 'cavalry' ? 22.5 : 15) * ((unit && unit.visionBonus) || 1);
    };
    game.buildingVision = function (b) {
        if (!b || b.underConstruction) return 0;
        if (b.type === 'tower') return 80;
        if (b.isWonder) return 60;
        if (b.type === 'town_center') return 40;
        return 20;
    };

    // A worker that could take a gather job: nothing set, nothing in hand.
    game.isIdleWorker = function (u) {
        return u && u.type === 'worker' && u.health > 0 &&
            !u.isBuilding && u.task !== 'building' &&
            u.task !== 'harvesting' && u.task !== 'carrying' && u.task !== 'farm_work' &&
            !u.isHarvesting && !u.carryingResource && !u.farmRef;
    };

    // What a worker is carrying, as far as a viewer can tell.
    game.observedWorkerLoad = function (unit) {
        if (unit.type !== 'worker') return undefined;
        if (!unit.carryingResource || !(unit.harvestAmount > 0)) return 'empty';
        return ['food', 'wood', 'stone', 'gold'].includes(unit.carryingResourceType)
            ? unit.carryingResourceType : 'unknown';
    };

    // Exploration bitmap: 42x42 cells; a unit's or finished building's sight
    // disc marks the cells it covers, forever (the fog's memory of the map).
    game.markExploration = function (owner) {
        if (!owner) return;
        const G = this.EXPLORE_GRID;
        if (!owner._explored || owner._explored.length !== G * G) owner._explored = new Uint8Array(G * G);
        const size = (this.terrain && this.terrain.size) || 800;
        const cell = size / G;
        const half = size / 2;
        const grid = owner._explored;
        const mark = (x, z, range) => {
            const cr = Math.ceil(range / cell);
            const cx = Math.floor((x + half) / cell);
            const cz = Math.floor((z + half) / cell);
            for (let dz = -cr; dz <= cr; dz++) {
                for (let dx = -cr; dx <= cr; dx++) {
                    const gx = cx + dx, gz = cz + dz;
                    if (gx < 0 || gx >= G || gz < 0 || gz >= G) continue;
                    const wx = (gx + 0.5) * cell - half;
                    const wz = (gz + 0.5) * cell - half;
                    const ddx = wx - x, ddz = wz - z;
                    if (Math.sqrt(ddx * ddx + ddz * ddz) <= range) grid[gz * G + gx] = 1;
                }
            }
        };
        (owner.units || []).forEach(u => { if (u.health > 0) mark(u.x, u.z, this.unitVision(u)); });
        (owner.buildings || []).forEach(b => {
            if (b.health > 0) mark(b.x, b.z, this.buildingVision(b));
        });
    };

    // Percent of each map tile this player has ever seen, 7x7, row 0 north.
    game.explorationSummary = function (owner) {
        const T = this.EXPLORE_TILES;
        const out = Array.from({ length: T }, () => new Array(T).fill(0));
        if (!owner || !owner._explored) return out;
        const G = this.EXPLORE_GRID, S = G / T;
        for (let tz = 0; tz < T; tz++) {
            for (let tx = 0; tx < T; tx++) {
                let seen = 0;
                for (let z = tz * S; z < (tz + 1) * S; z++) {
                    for (let x = tx * S; x < (tx + 1) * S; x++) seen += owner._explored[z * G + x];
                }
                out[tz][tx] = Math.round((seen / (S * S)) * 100);
            }
        }
        return out;
    };

    // Which of the 7x7 tiles is this world position in?
    game.tileLabelAt = function (x, z) {
        const T = this.EXPLORE_TILES || 7;
        const size = (this.terrain && this.terrain.size) || 800;
        const cell = size / T, half = size / 2;
        const col = Math.min(T - 1, Math.max(0, Math.floor((x + half) / cell)));
        const row = Math.min(T - 1, Math.max(0, Math.floor((z + half) / cell)));
        return String.fromCharCode(65 + col) + (row + 1);
    };

    // First-contact memory: has the viewer ever seen any unit or building of
    // each rival? Monotonic; gates the rival counts a state carries.
    game.updateRivalContacts = function (viewer) {
        if (!viewer) return;
        if (!viewer._metRivals) viewer._metRivals = new Set();
        // Built only if some rival is still unmet: most calls find everyone met.
        let see = null;
        const canSee = (x, z) => (see || (see = buildVisionTest(this, viewer, false)))(x, z);
        const consider = (owner, key) => {
            if (owner === viewer || viewer._metRivals.has(key)) return;
            const spotted = (owner.units || []).some(u => u.health > 0 && canSee(u.x, u.z)) ||
                            (owner.buildings || []).some(b => b.health > 0 && canSee(b.x, b.z));
            if (spotted) viewer._metRivals.add(key);
        };
        this.aiManager.aiPlayers.forEach(o => consider(o, o.id));
    };

    // The seat label the state and events use for an owner.
    game.seatLabel = function (o) {
        if (!o) return 'an unknown force';
        if (o === this.player || o === 'player') return 'player';
        const list = (this.aiManager && this.aiManager.aiPlayers) || [];
        const ai = (typeof o === 'string') ? list.find(a => a.id === o) : o;
        if (!ai) return typeof o === 'string' ? o : 'an enemy';
        const seat = (ai.seat != null) ? ai.seat + 1 : (list.indexOf(ai) + 1);
        return (ai.civilization || 'seat') + '-' + (seat > 0 ? seat : '?');
    };

    // Is this player out of the match? The parent's b1054 predicate, transcribed after
    // the 5 October merge: a live fighter or a producing trainer or a unit in training;
    // then the trainers and the Town Center, each gated on a population slot (`room`);
    // then the climb-back clauses — a worker who can found a Town Center, build a house
    // it may build, or finish a Town Center site (a producer site counts only with room).
    // The fork's old gate inside canAffordAnyMilitary is gone: b1054 moved the room into
    // this predicate, and canAffordAnyMilitary answers cost alone again (the parent's own
    // test pins that; FORK-DIVERGENCES S5).
    game.isPlayerEliminated = function (ai) {
        if (!ai || ai._eliminated) return true;
        const units = (ai.units || []).filter(u => u.health > 0);
        if (units.some(u => u.type !== 'worker' && u.unitType !== 'support')) return false;
        const buildings = (ai.buildings || []).filter(b => b.health > 0);
        if (buildings.some(b => !b.underConstruction && b.isProducing && b.productionType)) return false;
        const cap = ai.resources && ai.resources.maxPopulation;
        const room = typeof cap !== 'number' || cap > units.length;   // no cap known: not the gate
        if (room && this.canAffordAnyMilitary(ai)) return false;
        const can = cost => !!(ai.resources && cost && ai.resources.hasResources(cost));
        const def = id => getUnitDefFor(ai.civilization, id);
        const workerCost = (def('worker') || {}).cost || { food: 50 };
        const townCenter = buildings.some(b => b.type === 'town_center' && !b.underConstruction);
        if (townCenter && room && can(workerCost)) return false;
        if (!units.some(u => u.type === 'worker')) return true;
        const producer = b => b.type === 'town_center' || this.militaryOptions(ai, b.type).length > 0;
        if (buildings.some(b => b.underConstruction && (b.type === 'town_center' || (room && producer(b))))) return false;
        if (townCenter) return false;
        const bdef = t => getBuildingDef(t);
        const tcCost = (bdef('town_center') || {}).cost || { food: 100, wood: 100, stone: 100, gold: 100 };
        if (can(tcCost)) return false;
        if (room) {
            for (const t of ['barracks', 'archery_range', 'stable']) if (can((bdef(t) || {}).cost)) return false;
        } else {
            const house = bdef('house');
            if (house && can(house.cost) && (!house.requiresTech || (ai.researchedTechs && ai.researchedTechs[house.requiresTech]))) return false;
        }
        return true;
    };

    // What a building of this type can train for this owner, at this age.
    game.militaryOptions = function (ai, type) {
        const ids = getTrainOptionsForBuilding(type, ai.age || 'stone', ai.civilization);
        return this.trainOptionsFor(ai, { type }, ids);
    };
    game.trainOptionsFor = function (owner, building, tierIds) {
        let ids = tierIds;
        if (ids === undefined) {
            ids = getTrainOptionsForBuilding(building.type, owner.age || 'stone', owner.civilization);
        }
        if (!ids || !ids.length) {
            const def = getBuildingDef(building.type);
            const civTree = (CIVS[owner.civilization] || {}).techs || {};
            if (def && def.canResearch && def.researchOptions && def.researchOptions.length) {
                // Not exercised by a seat that researches nothing: kept for shape.
            }
            ids = (def && def.trainOptions) || [];
        }
        return (ids || []).filter(id => {
            const u = getUnitDefFor(owner.civilization, id);
            if (!u) return false;
            if (u.tier && AGE_ORDER.indexOf(u.tier) > AGE_ORDER.indexOf(owner.age || 'stone')) return false;
            return true;
        });
    };

    // A seat with a living trainer it can afford from is not yet eliminated.
    // Cost alone — b1054 moved the population-room gate into isPlayerEliminated
    // (the `room` line there), where it belongs; the fork's old gate here is gone.
    game.canAffordAnyMilitary = function (ai) {
        if (!ai || !ai.buildings || !ai.resources) return false;
        const aIdx = AGE_ORDER.indexOf(ai.age);
        for (const b of ai.buildings) {
            if (!(b.health > 0) || b.underConstruction) continue;
            for (const uid of this.militaryOptions(ai, b.type)) {
                const d = getUnitDefFor(ai.civilization, uid);
                if (!d) continue;
                if (AGE_ORDER.indexOf(d.tier || 'stone') > aIdx) continue;
                if (ai.resources.hasResources(d.cost)) return true;
            }
        }
        return false;
    };

    return game;
}

// ---- The 50 ms step, in the order the rules run it (js/game.js stepOnce) ----

const SIM_STEP_MS = 50;

function stepOnce(game) {
    const dt = SIM_STEP_MS;
    // Population first: the brain below and the state a model is sent both read it.
    game.aiManager.aiPlayers.forEach(ai => {
        ai.resources.updatePopulation(ai.units.length);
    });
    // The rule-based brain thinks on simulated time; here every seat is
    // harness-controlled, so only the discovery beat runs (section 8).
    game.aiManager.update(dt);
    // The simulation step: the clock, then the world's periodic business.
    // (Worker tasks, production, research and combat all run in there; none of
    // it can fire on a seat that has issued no order, so it is a no-op here and
    // is left out on purpose rather than ported as theatre.)
    game.clock.simMs += dt;
    game.clock.stepNo++;
    // Separation and building clearance, on simulated time.
    WarPositionRules.apply(game.getAllUnits(), game.getAllBuildings(), dt / 1000);
    // The harness's own per-step discovery, for every seat.
    if (game.openAIAIManager && game.openAIAIManager.observeStep) game.openAIAIManager.observeStep();
    // pruneBattles / checkWinConditions: no battles can exist and no Wonder can
    // be standing at one second of a fresh match; both are no-ops, omitted.
}

// Frozen driver: exactly `simMs` of simulated time, whole 50 ms steps.
function advanceSim(game, simMs) {
    const steps = simMs / SIM_STEP_MS;
    if (!Number.isInteger(steps) || steps < 0) throw new RangeError('advanceSim takes a whole number of 50 ms steps');
    let done = 0;
    for (; done < steps && game.gameStarted; done++) {
        game.advanceMatchClock(SIM_STEP_MS);
        stepOnce(game);
    }
    return done;
}

// Position rules: the radial push-out and the building clearance that run at
// the end of every simulation step (js/game.js, WarPositionRules).
var WarPositionRules = {
    apply(units, buildings, deltaTime) {
        const SEPARATION_DIST = 1.2, SEPARATION_FORCE = 0.03;
        const sepK = Math.min(3, Math.max(0, deltaTime) * 60);
        for (let i = 0; i < units.length; i++) {
            for (let j = i + 1; j < units.length; j++) {
                const a = units[i], b = units[j];
                if (a.owner !== b.owner) continue;
                const dx = b.x - a.x, dz = b.z - a.z;
                const dist = Math.sqrt(dx * dx + dz * dz);
                if (dist < SEPARATION_DIST) {
                    let nx, nz;
                    if (dist > 0.01) { nx = dx / dist; nz = dz / dist; }
                    else { const s = i % 2 === 0 ? 1 : -1; nx = s; nz = 0; }
                    const push = (SEPARATION_DIST - dist) * SEPARATION_FORCE * sepK;
                    a.x -= nx * push; a.z -= nz * push;
                    b.x += nx * push; b.z += nz * push;
                }
            }
        }
        const CLEAR_DIST = 4.5, CLEAR_FORCE = 0.05;
        const clearK = Math.min(3, Math.max(0, deltaTime) * 60);
        for (const u of units) {
            for (const b of buildings) {
                if (b.owner === u.owner && !b.underConstruction) {
                    const dx = u.x - b.x, dz = u.z - b.z;
                    const dist = Math.sqrt(dx * dx + dz * dz);
                    if (dist > 0.01 && dist < CLEAR_DIST) {
                        const push = (CLEAR_DIST - dist) * CLEAR_FORCE * clearK;
                        u.x += (dx / dist) * push;
                        u.z += (dz / dist) * push;
                    }
                }
            }
        }
    }
};

// ============================================================
// 7. AI manager — js/ai.js
// ============================================================

function makeAIPlayer(game, civilization, seat) {
    const resources = new ResourceManager();
    const ai = {
        id: WarRng.id('ai_', () => game.rand(null, 'player-id')),
        civilization,
        difficulty: 'medium',
        profile: 'standard',
        thinkTimer: 0,
        resources,
        units: [],
        buildings: [],
        age: 'stone',
        state: 'economic',
        buildQueue: [],
        researchedTechs: {},
        unlockedBuildings: {},
        unlockedUnits: {},
        currentResearch: null,
        currentAgeUpgrade: null,
        _knownResIdx: new Set(),
        _knownEnemyBuildings: new Set(),
        workerHarvestBonus: 1.0,
        trainSpeedBonus: 1.0,
        techCostMultiplier: 1.0,
        buildingHealthMultiplier: 1.0,
        attackBonus: 1.0,
        healthBonus: 1.0,
        miningBonus: 1.0,
        seat
    };
    game.aiManager.aiPlayers.push(ai);
    return ai;
}

function makeAIManager(game) {
    const mgr = {
        aiPlayers: [],
        openAIControlled: new Set(),
        discoveryTimer: 0
    };
    mgr.game = game;
    mgr.markAsOpenAIControlled = function (id) { this.openAIControlled.add(id); };
    // The 4 Hz discovery beat: exploration for every player and first-contact
    // memory for the rival-count gate; the fog-limited discovery itself only
    // runs for seats the rule-based brain still plays.
    mgr.update = function (deltaTime) {
        this.discoveryTimer = (this.discoveryTimer || 0) + deltaTime;
        if (this.discoveryTimer >= 250) {
            this.discoveryTimer -= 250;
            this.aiPlayers.forEach(ai => {
                if (this.game.markExploration) this.game.markExploration(ai);
                if (this.game.updateRivalContacts) this.game.updateRivalContacts(ai);
                if (this.openAIControlled.has(ai.id)) return;
                // (updateDiscovery: rule-brain seats only; none here)
            });
        }
        // advanceThink: every clock here belongs to a harness-controlled seat,
        // and none of them has issued a command, so a think tick changes nothing.
    };
    return mgr;
}

// ============================================================
// 8. The harness state view — js/openai-ai.js observe()
// ============================================================

// Is (x,z) inside the sight of one of the AI's living units or finished
// buildings? The DIRECT check: this one call, not a batch index.
function isPositionVisibleToAI(ai, x, z, game) {
    for (const unit of ai.units) {
        if (!(unit.health > 0)) continue;
        const range = game.unitVision(unit);
        const dx = unit.x - x, dz = unit.z - z;
        if (Math.sqrt(dx * dx + dz * dz) <= range) return 'visible';
    }
    for (const bldg of ai.buildings) {
        if (bldg.underConstruction) continue;
        const range = game.buildingVision(bldg);
        const dx = bldg.x - x, dz = bldg.z - z;
        if (Math.sqrt(dx * dx + dz * dz) <= range) return 'visible';
    }
    return null;
}

// The batched test a batch of the same question uses: a 20-unit cell index of
// sight discs. `harness` selects the predicate's rules (sqrt, construction sites
// skipped); the dead never see under either.
function buildVisionTest(game, ai, harness) {
    const CELL = 20;
    const cells = new Map();
    const key = (cx, cz) => cx * 65536 + cz;
    const file = (x, z, r, eye) => {
        const x0 = Math.floor((x - r - 1) / CELL), x1 = Math.floor((x + r + 1) / CELL);
        const z0 = Math.floor((z - r - 1) / CELL), z1 = Math.floor((z + r + 1) / CELL);
        for (let cx = x0; cx <= x1; cx++) for (let cz = z0; cz <= z1; cz++) {
            const k = key(cx, cz);
            const list = cells.get(k);
            if (list) list.push(eye); else cells.set(k, [eye]);
        }
    };
    for (const u of (ai && ai.units) || []) {
        if (u.health <= 0) continue;
        const r = game.unitVision(u);
        if (r > 0) file(u.x, u.z, r, { x: u.x, z: u.z, r });
    }
    for (const b of (ai && ai.buildings) || []) {
        if (harness ? b.underConstruction : b.health <= 0) continue;
        const r = game.buildingVision(b);
        if (r > 0) file(b.x, b.z, r, { x: b.x, z: b.z, r });
    }
    return (x, z) => {
        const list = cells.get(key(Math.floor(x / CELL), Math.floor(z / CELL)));
        if (!list) return false;
        for (const e of list) {
            if (harness) {
                const dx = e.x - x, dz = e.z - z;
                if (Math.sqrt(dx * dx + dz * dz) <= e.r) return true;
            } else if (Math.hypot(e.x - x, e.z - z) <= e.r) return true;
        }
        return false;
    };
}

function makeHarness(game) {
    const mgr = {
        aiControllers: [],
        newStats() { return { requests: 0 }; },
        visionTestFor(ai) { return buildVisionTest(this.game, ai, true); },
        isPositionVisibleToAI,
        getAIBuildingCenter(ai) {
            if (ai.buildings.length === 0) return { x: 0, z: 0 };
            let sx = 0, sz = 0;
            ai.buildings.forEach(b => { sx += b.x; sz += b.z; });
            return { x: Math.round(sx / ai.buildings.length), z: Math.round(sz / ai.buildings.length) };
        },
        tileLabel(row, col) { return String.fromCharCode(65 + col) + (row + 1); },
        tileAt(game, x, z) { return game.tileLabelAt(x, z); },
        workerJob(game, u) {
            if (!u || u.type !== 'worker') return null;
            if (u.task === 'building' || u.isBuilding) return 'building';
            if (u.isAttacking || u.attackTarget || u.attackMove) return 'fighting';
            if (u.task === 'scouting') return 'scouting';
            if (u.task === 'farm_work' || u.farmRef) return 'farm';
            const carrying = !!(u.carryingResource || u.task === 'carrying');
            if (carrying || u.task === 'harvesting' || u.isHarvesting || u.harvestTarget) {
                const rt = (u.harvestTarget && u.harvestTarget.type) || u.carryingResourceType;
                return (rt === 'food' || rt === 'wood' || rt === 'stone' || rt === 'gold') ? rt : 'moving';
            }
            return (game && game.isIdleWorker && game.isIdleWorker(u)) ? 'idle' : 'moving';
        },
        splitByBlock(src, openName) {
            const STRUCTURAL = ['age', 'tech', 'host', 'alreadyBuilt'];
            const isBlocked = e => (e.blockedBy || []).some(b => STRUCTURAL.indexOf(b) >= 0);
            const strip = e => { const o = Object.assign({}, e); if (!(o.blockedBy || []).length) delete o.blockedBy; return o; };
            if (Array.isArray(src)) {
                return { [openName]: src.filter(e => !isBlocked(e)).map(strip),
                         blocked:    src.filter(isBlocked) };
            }
            const open = {}, blocked = {};
            Object.entries(src || {}).forEach(([host, byAge]) => {
                Object.entries(byAge || {}).forEach(([age, list]) => {
                    const o = list.filter(e => !isBlocked(e)).map(strip);
                    const b = list.filter(isBlocked);
                    if (o.length) ((open[host] = open[host] || {})[age] = o);
                    if (b.length) ((blocked[host] = blocked[host] || {})[age] = b);
                });
            });
            return { [openName]: open, blocked };
        },
        trainableUnitsFor(civilization) {
            const hosts = ['town_center', 'barracks', 'archery_range', 'stable', 'temple'];
            const seen = new Map();
            const civTree = (CIVS[civilization] || {}).techs || {};
            hosts.forEach(bt => {
                const def = getBuildingDef(bt);
                if (def && def.requiresTech && !civTree[def.requiresTech]) return;
                const floor = (def && def.requiredAge) || 'stone';
                AGE_ORDER.forEach(age => {
                    if (AGE_ORDER.indexOf(age) < AGE_ORDER.indexOf(floor)) return;
                    let opts = getTrainOptionsForBuilding(bt, age, civilization);
                    if (!opts || !opts.length) opts = (def && def.trainOptions) || [];
                    opts.forEach(id => { if (!seen.has(id)) seen.set(id, { id, at: bt, age }); });
                });
            });
            return [...seen.values()];
        },
        wonderDefFor(civilization) {
            const civ = CIVS[civilization];
            return ((civ && civ.uniqueBuildings) || []).find(b => b.type === 'wonder') || null;
        },
        // The per-step beat: the node indices each seat's sight now covers, into
        // its persistent known set. Amounts are recorded separately, at the
        // observation that shows them (commitObservation).
        updateResourceDiscovery() {
            const resources = (this.game.terrain && this.game.terrain.resources) || [];
            if (!resources.length) return;
            for (const controller of this.aiControllers) {
                const ai = controller.aiPlayer;
                if (!ai) continue;
                if (!ai._knownResIdx) ai._knownResIdx = new Set();
                const see = this.visionTestFor(ai);
                for (let idx = 0; idx < resources.length; idx++) {
                    if (ai._knownResIdx.has(idx)) continue;
                    const r = resources[idx];
                    if (see(r.x, r.z)) ai._knownResIdx.add(idx);
                }
            }
        },
        updateEnemyBuildingDiscovery() {
            const all = (this.game.getAllBuildings ? this.game.getAllBuildings() : []);
            for (const controller of this.aiControllers) {
                const ai = controller.aiPlayer;
                if (!ai) continue;
                if (!ai._knownEnemyBuildings) ai._knownEnemyBuildings = new Set();
                let see = null;
                for (const b of all) {
                    if (ai.buildings.includes(b)) continue;
                    if (b.health <= 0) { ai._knownEnemyBuildings.delete(b); continue; }
                    if (ai._knownEnemyBuildings.has(b)) continue;
                    if (!see) see = this.visionTestFor(ai);
                    if (see(b.x, b.z)) ai._knownEnemyBuildings.add(b);
                }
            }
        },
        observeStep() {
            if (this.aiControllers.length === 0) return;
            this.updateResourceDiscovery();
            this.updateEnemyBuildingDiscovery();
        }
    };
    mgr.game = game;
    return mgr;
}

// What a node is worth to the AI, and whether it knows it at all. With a sink,
// this look records what it saw (committed on the turn); without one, it writes
// the seat's persistent memory in place.
function knownAmount(ai, res, idx, game, sink) {
    if (sink) sink.touched = true;
    else {
        if (!ai._knownResIdx) ai._knownResIdx = new Set();
        if (!ai._knownResAmt) ai._knownResAmt = Object.create(null);
    }
    if (isPositionVisibleToAI(ai, res.x, res.z, game)) {
        const amount = Math.floor(res.amount);
        if (sink) sink.seen.set(idx, amount);
        else { ai._knownResIdx.add(idx); ai._knownResAmt[idx] = amount; }
        return { amount, visible: true, known: true };
    }
    const known = !!(ai._knownResIdx && ai._knownResIdx.has(idx)) || !!(sink && sink.seen.has(idx));
    const remembered = sink && sink.seen.has(idx) ? sink.seen.get(idx) : (ai._knownResAmt && ai._knownResAmt[idx]);
    return {
        amount: known ? (remembered != null ? remembered : Math.floor(res.amount)) : 0,
        visible: false, known
    };
}

// The one state a seat is sent: everything it may know, in one object.
function buildGameStateJSON(game, controller) {
    const ai = controller.aiPlayer;
    const civ = CIVS[ai.civilization];
    const ages = AGE_ORDER;
    const currentAgeIndex = ages.indexOf(ai.age);
    const nextEpoch = currentAgeIndex < ages.length - 1 ? ages[currentAgeIndex + 1] : null;

    // Everything this look would once have written, collected for the commit.
    const pending = { events: [], nodes: { touched: false, seen: new Map() } };

    // --- Player identity ---
    const playerObj = {
        id: ai.id,
        civilization: ai.civilization,
        civilizationName: civ.nameEn,   // the dumper pins 'en'; this is the pin read back
        isHuman: false
    };

    // --- Epoch ---
    const epochObj = {
        currentEpoch: ai.age,
        nextEpoch,
        nextEpochCost: nextEpoch ? AGE_COSTS[nextEpoch] : null,
        upgradeInProgress: ai.currentAgeUpgrade ? {
            targetEpoch: ai.currentAgeUpgrade.targetAge,
            progressPercent: Math.round((ai.currentAgeUpgrade.progress / ai.currentAgeUpgrade.duration) * 100),
            secondsRemaining: Math.max(0, Math.ceil(((ai.currentAgeUpgrade.duration || 0) - (ai.currentAgeUpgrade.progress || 0)) / 1000))
        } : null
    };

    // --- Resources / population ---
    const resourcesObj = {
        food: Math.floor(ai.resources.food),
        wood: Math.floor(ai.resources.wood),
        stone: Math.floor(ai.resources.stone),
        gold: Math.floor(ai.resources.gold)
    };
    const populationObj = {
        used: ai.resources.population,
        capacityNow: ai.resources.maxPopulation,
        capacityCeiling: MAX_POPULATION_CAP
    };

    // --- Recent events ---
    // Keyed on the player's own turns; nothing here fires at one second, so the
    // ring reads exactly what it has: nothing.
    const buildRecentEvents = () => {
        const seq = pending.turnSeq = (ai._turnSeq || 0) + 1;
        const found = pending.events.map(text => ({ at: game.simNow(), seq: ai._turnSeq || 0, text, ttl: 2 }));
        return (ai.events || []).concat(found)
            .filter(e => (e.seq || 0) >= seq - (e.ttl || 2))
            .slice(-8)
            .map(e => `${Math.max(0, Math.round((game.clock.matchMs - game.simNow()) / 1000))}s ago: ${e.text}`);
    };

    // --- Bonuses ---
    const bonusesObj = {};
    if (ai.workerHarvestBonus !== 1.0) bonusesObj.harvest = ai.workerHarvestBonus;
    if (ai.attackBonus !== 1.0) bonusesObj.attack = ai.attackBonus;
    if (ai.healthBonus !== 1.0) bonusesObj.health = ai.healthBonus;
    if (ai.miningBonus !== 1.0) bonusesObj.mining = ai.miningBonus;
    if (ai.techCostMultiplier !== 1.0) bonusesObj.techCostMult = ai.techCostMultiplier;

    // --- Map summary ---
    const halfMap = Math.round(game.terrain.size / 2);
    const seen = game.explorationSummary(ai);
    const exploration = {};
    for (let r = 0; r < (game.EXPLORE_TILES || 7); r++) {
        for (let c = 0; c < (game.EXPLORE_TILES || 7); c++) exploration[mgrTileLabel(r, c)] = seen[r][c];
    }
    const yourBaseTiles = {};
    ai.buildings.forEach(b => {
        const k = game.tileLabelAt(b.x, b.z);
        yourBaseTiles[k] = (yourBaseTiles[k] || 0) + 1;
    });
    const mapObj = {
        size: game.terrain.size,
        bounds: { minX: -halfMap, maxX: halfMap, minZ: -halfMap, maxZ: halfMap },
        yourSpawnArea: getAIBuildingCenterImpl(game, ai),
        yourBaseTiles,
        exploration
    };

    // --- Nodes ---
    const totalNodesOnMap = Object.assign({ food: 0, wood: 0, stone: 0, gold: 0 },
        game.terrain.nodesLeftOnMap());
    const discoveredNodesOnMap = { food: 0, wood: 0, stone: 0, gold: 0 };
    const byType = { food: [], wood: [], stone: [], gold: [] };
    (game.terrain.resources || []).forEach((res, idx) => {
        const k = knownAmount(ai, res, idx, game, pending.nodes);
        if (!k.known) return;
        if (k.amount <= 0 || !byType[res.type]) return;
        discoveredNodesOnMap[res.type]++;
        byType[res.type].push({
            type: res.type,
            x: Math.round(res.x),
            z: Math.round(res.z),
            amount: k.amount
        });
    });

    // Nearest per Town Center: the ten closest food/wood of each, and stone and
    // gold in full (the scarce kinds are not worth truncating).
    const tcAnchors = ai.buildings.filter(b => b.type === 'town_center' && !b.underConstruction);
    const anchors = tcAnchors.length ? tcAnchors
        : (ai.buildings.length ? [ai.buildings[0]] : (ai.units.length ? [ai.units[0]] : []));
    const nearby = new Map();
    byType.stone.concat(byType.gold).forEach(n => nearby.set(n.x + ',' + n.z, n));
    anchors.forEach(a => ['food', 'wood'].forEach(ty => {
        byType[ty]
            .map(n => ({ n, d: Math.hypot(a.x - n.x, a.z - n.z) }))
            .sort((p, q) => p.d - q.d)
            .slice(0, NEAREST_PER_ANCHOR)
            .forEach(({ n }) => nearby.set(n.x + ',' + n.z, n));
    }));
    const nearestNodes = [...nearby.values()];

    // --- Friendly buildings ---
    let researchHostType = null;
    if (ai.currentResearch) {
        const rt = (civ.techs || {})[ai.currentResearch.techId];
        researchHostType = (rt && rt.researchAt) || 'town_center';
    }
    const ageUpActive = !!ai.currentAgeUpgrade;
    let researchAssigned = false, ageAssigned = false;
    const friendlyBuildings = ai.buildings.map(b => {
        const constructing = !!b.underConstruction;
        const producing = !!b.isProducing && !constructing;
        let researching = false, advancing = false;
        if (!constructing) {
            if (ageUpActive && !ageAssigned && b.type === 'town_center') { advancing = true; ageAssigned = true; }
            else if (researchHostType && !researchAssigned && b.type === researchHostType) { researching = true; researchAssigned = true; }
        }
        const busy = constructing || producing || researching || advancing;
        const activity = constructing ? 'under_construction'
            : producing ? 'producing'
            : advancing ? 'advancing_age'
            : researching ? 'researching' : 'idle';
        const obj = {
            type: b.type,
            x: Math.round(b.x),
            z: Math.round(b.z),
            healthPct: Math.round((b.health / b.maxHealth) * 100),
            state: constructing ? 'under_construction' : 'complete',
            busy: busy,
            activity: activity,
            producing: producing ? b.productionType : null
        };
        if (b.type === 'farm') {
            obj.food = Math.floor(b.foodAmount || 0);
            obj.farmed = false;   // no worker mans a farm at one second
        }
        return obj;
    });

    // --- Enemy buildings ---
    const knownEnemyBuildings = pending.knownEnemyBuildings = new Set(ai._knownEnemyBuildings || []);
    const enemyBuildings = [];
    const enemyWonders = [];
    const seeNow = buildVisionTest(game, ai, true);
    (game.getAllBuildings ? game.getAllBuildings() : []).forEach(bldg => {
        if (ai.buildings.includes(bldg)) return;
        if (bldg.health <= 0) { knownEnemyBuildings.delete(bldg); return; }
        const isWonder = bldg.isWonder;
        const seenNow = isWonder || seeNow(bldg.x, bldg.z);
        if (seenNow) knownEnemyBuildings.add(bldg);
        if (!seenNow && !knownEnemyBuildings.has(bldg)) return;
        const entry = {
            id: bldg.id,
            type: bldg.type,
            x: Math.round(bldg.x),
            z: Math.round(bldg.z),
            owner: game.seatLabel(bldg.owner),
            healthPct: Math.round((bldg.health / bldg.maxHealth) * 100),
            visible: !!seenNow
        };
        if (isWonder) {
            entry.isWonder = true;
            const ownerAi = game.aiManager.aiPlayers.find(a => a.buildings.includes(bldg));
            const held = bldg.underConstruction ? 0 : ((ownerAi && ownerAi._wonderHold) || 0);
            entry.state = bldg.underConstruction ? 'under_construction' : 'complete';
            entry.secondsUntilEnemyWins = bldg.underConstruction ? null : Math.max(0, Math.ceil((game.wonderRequired * 1000 - held) / 1000));
            enemyWonders.push(entry);
        }
        enemyBuildings.push(entry);
    });

    // --- Units ---
    const friendlyUnits = ai.units.map(u => {
        let action = 'idle';
        if (u.isAttacking) {
            const inContact = u.attackTarget && u.attackTarget.health > 0;
            action = (!inContact && u.attackMove) ? 'marching' : 'attacking';
        }
        else if (u.task === 'harvesting') action = 'harvesting';
        else if (u.task === 'carrying' || u.carryingResource) action = 'returning';
        else if (u.task === 'building') action = 'building';
        else if (u.task === 'farm_work') action = 'farm_work';
        else if (u.isMoving) action = 'moving';
        return {
            id: u.handle,
            type: u.type,
            x: Math.round(u.x),
            z: Math.round(u.z),
            healthPct: Math.round((u.health / u.maxHealth) * 100),
            // Workers report jobs in the "workers" tally, not per unit.
            ...(u.type === 'worker' || (u._standingOrder && u._standingOrder.token === u._orderToken) ? {} : { action })
        };
    });

    // --- Worker breakdown ---
    const wk = { total: 0, idle: 0, building: 0, farm: 0, scouting: 0, moving: 0, fighting: 0, food: 0, wood: 0, stone: 0, gold: 0 };
    ai.units.forEach(u => {
        if (u.type !== 'worker') return;
        wk.total++;
        wk[workerJobImpl(game, u) || 'moving']++;
    });
    pending.sentIdle = wk.idle;

    // --- Enemy units ---
    const enemyUnits = [];
    (game.getAllUnits ? game.getAllUnits() : []).forEach(unit => {
        if (ai.units.includes(unit)) return;
        if (!seeNow(unit.x, unit.z)) return;
        const e = {
            id: unit.id,
            type: unit.type,
            x: Math.round(unit.x),
            z: Math.round(unit.z),
            owner: game.seatLabel(unit.owner)
        };
        if (unit.type === 'worker') e.carrying = game.observedWorkerLoad(unit);
        enemyUnits.push(e);
    });

    // --- Research ---
    const techs = civ.techs || {};
    const researchedTechIds = Object.keys(techs).filter(tid => ai.researchedTechs[tid]);
    const currentResearch = ai.currentResearch ? {
        techId: ai.currentResearch.techId,
        host: ai.currentResearch.host,
        progressPct: Math.round((ai.currentResearch.progress / ai.currentResearch.duration) * 100),
        secondsRemaining: Math.max(0, Math.ceil(((ai.currentResearch.duration || 0) - (ai.currentResearch.progress || 0)) / 1000))
    } : null;
    const costOf = (cost) => ({
        food: (cost && cost.food) || 0, wood: (cost && cost.wood) || 0,
        stone: (cost && cost.stone) || 0, gold: (cost && cost.gold) || 0
    });
    const tooPoor = (cost) => !(cost && ai.resources.hasResources(cost));
    const standing = (type) => ai.buildings.some(b => b.type === type && !b.underConstruction);
    const ageReached = (need) => AGE_ORDER.indexOf(ai.age) >= AGE_ORDER.indexOf(need || 'stone');
    const atPopCap = (ai.resources.population || 0) >= (ai.resources.maxPopulation || 0);

    const availableTechs = Object.keys(techs)
        .filter(tid => {
            const t = techs[tid];
            if (ai.researchedTechs[tid]) return false;
            if (AGE_ORDER.indexOf(t.requiredAge) > currentAgeIndex) return false;
            if (t.requires) {
                for (const req of t.requires) {
                    if (!ai.researchedTechs[req]) return false;
                }
            }
            return true;
        })
        .map(tid => {
            const t = techs[tid];
            const costMult = ai.techCostMultiplier || 1;
            const cost = {
                food: Math.floor((t.cost.food || 0) * costMult),
                wood: Math.floor((t.cost.wood || 0) * costMult),
                stone: Math.floor((t.cost.stone || 0) * costMult),
                gold: Math.floor((t.cost.gold || 0) * costMult)
            };
            const at = t.researchAt || 'town_center';
            const blockedBy = [];
            if (!ai.buildings.some(b => b.type === at && !b.underConstruction)) blockedBy.push('host');
            if (!ai.resources.hasResources(cost)) blockedBy.push('cost');
            return { id: tid, cost, researchAt: t.researchAt, blockedBy };
        });
    const researchObj = {
        researched: researchedTechIds,
        current: currentResearch,
        available: availableTechs
    };

    // --- Unlocked content ---
    const unlockedContent = {
        buildings: Object.keys(ai.unlockedBuildings || {})
    };

    // --- Trainable units ---
    const trainableUnits = {};
    trainableUnitsForImpl(game, ai.civilization).forEach(u => {
        const host = (trainableUnits[u.at] = trainableUnits[u.at] || {});
        const def = getUnitDefFor(ai.civilization, u.id);
        const blockedBy = [];
        if (!ageReached(u.age)) blockedBy.push('age');
        if (!standing(u.at)) blockedBy.push('host');
        if (atPopCap) blockedBy.push('pop');
        if (tooPoor(def && def.cost)) blockedBy.push('cost');
        (host[u.age] = host[u.age] || []).push({
            id: u.id, cost: costOf(def && def.cost), blockedBy
        });
    });

    // --- Buildable structures ---
    const stdBuildings = ['town_center', 'house', 'farm', 'barracks', 'archery_range', 'stable', 'academy', 'tower', 'temple'];
    const buildableStructures = stdBuildings.map(t => {
        const def = getBuildingDef(t);
        if (!def) return null;
        const reqTech = def.requiresTech || null;
        const civSupports = !reqTech || !!techs[reqTech];
        if (!civSupports) return null;
        const techDone = !reqTech || !!ai.researchedTechs[reqTech];
        const reqAge = effectiveBuildingAge(ai.civilization, def);
        const blockedBy = [];
        if (!ageReached(reqAge)) blockedBy.push('age');
        if (!techDone) blockedBy.push('tech');
        if (tooPoor(def.cost)) blockedBy.push('cost');
        return { type: t, requiredAge: reqAge, requiresTech: reqTech, cost: costOf(def.cost), blockedBy };
    }).filter(Boolean);
    const wDef = (civ.wonder) ? civ.wonder : null;
    if (wDef) {
        const wAge = wDef.requiredAge || 'iron';
        const wBlocked = [];
        if (!ageReached(wAge)) wBlocked.push('age');
        if (ai.buildings.some(b => b.isWonder)) wBlocked.push('alreadyBuilt');
        if (tooPoor(wDef.cost)) wBlocked.push('cost');
        buildableStructures.push({
            type: 'wonder', builtAs: wDef.id, requiredAge: wAge, requiresTech: null,
            isWonder: true, cost: costOf(wDef.cost), blockedBy: wBlocked
        });
    }

    // --- Threats ---
    const underAttack = [];   // no one takes fire at one second; the scan finds nothing
    const threatsObj = {
        underAttack: underAttack,
        enemyWonders: enemyWonders
    };

    // --- Opponents ---
    const met = ai._metRivals || new Set();
    const aiOpponents = [];
    const pushRival = (o, key) => {
        const entry = { id: game.seatLabel(o), civilization: o.civilization, age: o.age,
            discovered: met.has(key), defeated: game.isPlayerEliminated(o) };
        if (entry.discovered) {
            entry.population = o.units.length;
            entry.buildings = o.buildings.length;
        }
        aiOpponents.push(entry);
    };
    game.aiManager.aiPlayers.forEach(o => { if (o !== ai) pushRival(o, o.id); });

    // --- Clock ---
    const clockObj = {
        matchSeconds: Math.max(0, Math.round(((game.clock && game.clock.matchMs) || 0) / 1000))
    };

    const gameStatsObj = {
        wonderRequired: (game.wonderRequired || 600),
        opponents: aiOpponents
    };

    const state = {
        player: playerObj,
        clock: clockObj,
        epoch: epochObj,
        resources: resourcesObj,
        population: populationObj,
        recentEvents: buildRecentEvents(),
        bonuses: bonusesObj,
        map: mapObj,
        nodes: {
            discovered: discoveredNodesOnMap,
            totalOnMap: totalNodesOnMap
        },
        nearestNodes: nearestNodes,
        friendlyBuildings: friendlyBuildings,
        enemyBuildings: enemyBuildings,
        friendlyUnits: friendlyUnits,
        workers: wk,
        enemyUnits: enemyUnits,
        research: researchObj,
        unlockedContent: unlockedContent,
        units: splitByBlockImpl(trainableUnits, 'trainable'),
        buildings: splitByBlockImpl(buildableStructures, 'buildable'),
        threats: threatsObj,
        gameStats: gameStatsObj
    };

    commitObservation(game, ai, controller, pending);
    return state;
}

// Free-function twins of the harness methods the view calls (kept out of the
// manager object so the port stays one reader per source function).
const NEAREST_PER_ANCHOR = 10;
function mgrTileLabel(row, col) { return String.fromCharCode(65 + col) + (row + 1); }
function getAIBuildingCenterImpl(game, ai) {
    if (ai.buildings.length === 0) return { x: 0, z: 0 };
    let sx = 0, sz = 0;
    ai.buildings.forEach(b => { sx += b.x; sz += b.z; });
    return { x: Math.round(sx / ai.buildings.length), z: Math.round(sz / ai.buildings.length) };
}
function workerJobImpl(game, u) {
    if (!u || u.type !== 'worker') return null;
    if (u.task === 'building' || u.isBuilding) return 'building';
    if (u.isAttacking || u.attackTarget || u.attackMove) return 'fighting';
    if (u.task === 'scouting') return 'scouting';
    if (u.task === 'farm_work' || u.farmRef) return 'farm';
    const carrying = !!(u.carryingResource || u.task === 'carrying');
    if (carrying || u.task === 'harvesting' || u.isHarvesting || u.harvestTarget) {
        const rt = (u.harvestTarget && u.harvestTarget.type) || u.carryingResourceType;
        return (rt === 'food' || rt === 'wood' || rt === 'stone' || rt === 'gold') ? rt : 'moving';
    }
    return game.isIdleWorker(u) ? 'idle' : 'moving';
}
function trainableUnitsForImpl(game, civilization) {
    const seen = new Map();
    const civTree = (CIVS[civilization] || {}).techs || {};
    ['town_center', 'barracks', 'archery_range', 'stable', 'temple'].forEach(bt => {
        const def = getBuildingDef(bt);
        if (def && def.requiresTech && !civTree[def.requiresTech]) return;
        const floor = (def && def.requiredAge) || 'stone';
        AGE_ORDER.forEach(age => {
            if (AGE_ORDER.indexOf(age) < AGE_ORDER.indexOf(floor)) return;
            let opts = getTrainOptionsForBuilding(bt, age, civilization);
            if (!opts || !opts.length) opts = (def && def.trainOptions) || [];
            opts.forEach(id => { if (!seen.has(id)) seen.set(id, { id, at: bt, age }); });
        });
    });
    return [...seen.values()];
}
function splitByBlockImpl(src, openName) {
    const STRUCTURAL = ['age', 'tech', 'host', 'alreadyBuilt'];
    const isBlocked = e => (e.blockedBy || []).some(b => STRUCTURAL.indexOf(b) >= 0);
    const strip = e => { const o = Object.assign({}, e); if (!(o.blockedBy || []).length) delete o.blockedBy; return o; };
    if (Array.isArray(src)) {
        return { [openName]: src.filter(e => !isBlocked(e)).map(strip),
                 blocked: src.filter(isBlocked) };
    }
    const open = {}, blocked = {};
    Object.entries(src || {}).forEach(([host, byAge]) => {
        Object.entries(byAge || {}).forEach(([age, list]) => {
            const o = list.filter(e => !isBlocked(e)).map(strip);
            const b = list.filter(isBlocked);
            if (o.length) ((open[host] = open[host] || {})[age] = o);
            if (b.length) ((blocked[host] = blocked[host] || {})[age] = b);
        });
    });
    return { [openName]: open, blocked };
}

// The commit: what this look showed, written down so the next one can remember it.
function commitObservation(game, ai, controller, p) {
    ai._turnSeq = p.turnSeq;
    if (!ai._knownResIdx) ai._knownResIdx = new Set();
    if (p.nodes.touched) {
        if (!ai._knownResAmt) ai._knownResAmt = Object.create(null);
        for (const [idx, amount] of p.nodes.seen) {
            ai._knownResIdx.add(idx);
            ai._knownResAmt[idx] = amount;
        }
    }
    ai._lastNodeCounts = p.lastNodeCounts;
    ai._knownEnemyBuildings = p.knownEnemyBuildings || ai._knownEnemyBuildings;
}

// ============================================================
// 9. Setup — the arena start, and the dumper's drive
// ============================================================

function createMatch(seatCivs, seed, difficulty) {
    const game = makeGame();
    game.aiManager = makeAIManager(game);
    game.openAIAIManager = makeHarness(game);
    game.terrain = makeTerrain(seed, difficulty);

    // Spawn positions: one per seat, on a circle 85% of the half-inset, seat 0
    // due north. (js/game.js _startArenaFromSetup)
    const halfSize = 800 / 2 - 40;
    const spawnPositions = [];
    for (let i = 0; i < seatCivs.length; i++) {
        const angle = (i / seatCivs.length) * Math.PI * 2 - Math.PI / 2;
        const radius = halfSize * 0.85;
        spawnPositions.push({
            x: Math.cos(angle) * radius,
            z: Math.sin(angle) * radius
        });
    }
    game.terrain.spawns = spawnPositions;
    game.mapSeed = game.terrain.seed;
    game.terrain.generateTerrain();

    // One seat per civ.
    for (let i = 0; i < seatCivs.length; i++) {
        const ai = makeAIPlayer(game, seatCivs[i], i);
        // The arena's TC stands at the spawn, and clears the nodes under it.
        const townCenter = createBuilding(game, 'town_center', spawnPositions[i].x, spawnPositions[i].z, ai.id, ai.civilization, { age: ai.age });
        if (townCenter) {
            game.terrain.clearResourcesNear(spawnPositions[i].x, spawnPositions[i].z, 9.5 + 3);
            ai.buildings.push(townCenter);
        }
        for (let w = 0; w < 3; w++) {
            const worker = createUnit(game, 'worker',
                spawnPositions[i].x + (game.rand(ai, 'start-workers') - 0.5) * 10,
                spawnPositions[i].z + (game.rand(ai, 'start-workers') - 0.5) * 10,
                ai.id, ai.civilization, 'stone');
            if (worker) ai.units.push(worker);
        }
        // The civ bonus, applied to the seat.
        const civ = CIVS[ai.civilization];
        if (civ.bonus) {
            if (civ.bonus.kind === 'buildingHealth') ai.buildingHealthMultiplier = civ.bonus.mult;
            else if (civ.bonus.kind === 'workerHarvest') ai.workerHarvestBonus = civ.bonus.mult;
            else if (civ.bonus.kind === 'techCost') ai.techCostMultiplier = civ.bonus.mult;
        }
    }

    // The dumper's realm marks every seat harness-controlled, so the rule
    // brain leaves them alone while the harness's per-step work still runs.
    game.aiManager.aiPlayers.forEach(ai => game.aiManager.markAsOpenAIControlled(ai.id));
    game.aiManager.aiPlayers.forEach(ai => {
        game.openAIAIManager.aiControllers.push({
            id: ai.id,
            aiPlayer: ai,
            model: { name: 'scripted', model: 'scripted', language: 'en' },
            paused: true
        });
    });

    // The game's own accessors the view reaches for.
    game.getAllUnits = function () {
        const out = [];
        this.aiManager.aiPlayers.forEach(p => p.units.forEach(u => { if (u.health > 0) out.push(u); }));
        return out;
    };
    game.getAllBuildings = function () {
        const out = [];
        this.aiManager.aiPlayers.forEach(p => p.buildings.forEach(b => { if (b.health > 0) out.push(b); }));
        return out;
    };

    game.gameStarted = true;
    return game;
}

// The canonicalizer (tools/golden/canonicalize-states.cjs): seat ids re-keyed to
// seat<n> in line order; session-minted entity ids renamed in first-appearance
// order. Re-implemented here so the gate stands on this file alone.
const SESSION_ID = /^(ai|u|m|e|b|s)_[a-z0-9]{5,}$/;
function canonicalize(lines) {
    const table = new Map();
    for (const l of lines) {
        const rec = JSON.parse(l);
        if (rec.playerId !== undefined && rec.seat !== undefined) table.set(rec.playerId, `seat${rec.seat}`);
    }
    if (!table.size) throw new Error('no line has both playerId and seat');
    const minted = new Map();
    const mint = (id) => {
        if (minted.has(id)) return minted.get(id);
        const kind = id.slice(0, id.indexOf('_'));
        const n = [...minted.values()].filter(v => v.startsWith(kind.toUpperCase())).length;
        const name = kind.toUpperCase() + n;
        minted.set(id, name);
        return name;
    };
    const rekey = (v) => {
        if (typeof v === 'string') {
            if (table.has(v)) return table.get(v);
            if (SESSION_ID.test(v)) return mint(v);
            return v;
        }
        if (Array.isArray(v)) return v.map(rekey);
        if (v && typeof v === 'object') {
            const out = {};
            for (const k of Object.keys(v)) out[k] = rekey(v[k]);
            return out;
        }
        return v;
    };
    return lines.map(l => JSON.stringify(rekey(JSON.parse(l))));
}

// ---------------------------------------------------------------------------

function main() {
    const fs = require('fs');
    const path = require('path');

    const civs = ['egyptian', 'greek', 'persian', 'yamato'];
    const game = createMatch(civs, 'golden', 'medium');

    const lines = [];
    const observe = (atMs) => {
        game.aiManager.aiPlayers.forEach((ai, i) => {
            const built = buildGameStateJSON(game, game.openAIAIManager.aiControllers[i]);
            lines.push(JSON.stringify({ seat: i, playerId: ai.id, t: atMs, state: built }));
        });
    };

    let now = 0;
    for (const t of [0, 1000]) {
        if (t < now) throw new Error('-at times must ascend');
        if (t > now) {
            const steps = (t - now) / SIM_STEP_MS;
            for (let s = 0; s < steps; s++) {
                game.advanceMatchClock(SIM_STEP_MS);
                stepOnce(game);
            }
            now = t;
        }
        observe(t);
    }

    const canonical = canonicalize(lines);
    const text = canonical.join('\n') + '\n';
    const goldenPath = process.argv[2] || path.join(__dirname, '..', 'golden', 'states-b1040-t0-t1.canonical.jsonl');
    if (process.argv[2]) {
        const golden = fs.readFileSync(goldenPath, 'utf8');
        if (golden === text) {
            console.error(`GATE PASS: ${canonical.length} lines, byte-identical to ${goldenPath}`);
            process.exit(0);
        }
        // Show where the first difference is, line by line.
        const gLines = golden.trimEnd().split('\n');
        let first = -1;
        for (let i = 0; i < Math.max(gLines.length, canonical.length); i++) {
            if ((gLines[i] || '') !== (canonical[i] || '')) { first = i; break; }
        }
        console.error(`GATE FAIL: ${goldenPath}`);
        if (first >= 0) {
            console.error(`  first difference at line ${first + 1} (seat ${JSON.parse(canonical[first]).seat}, t=${JSON.parse(canonical[first]).t}):`);
            const a = gLines[first] || '(missing)';
            const b = canonical[first] || '(missing)';
            console.error(`  golden: ${a.slice(0, 400)}${a.length > 400 ? '…' : ''}`);
            console.error(`  port:   ${b.slice(0, 400)}${b.length > 400 ? '…' : ''}`);
        }
        process.exit(1);
    }
    process.stdout.write(text);
}

if (require.main === module) main();

module.exports = { createMatch, buildGameStateJSON, canonicalize, stepOnce, SIM_STEP_MS };
