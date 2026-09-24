// The age ladder has 26 copies in the shipped code and cannot be reduced to one.
//
// That is not laziness. These are classic scripts with a fixed load order and no module system:
// 16 test harnesses load game.js / ui.js / openai-ai.js WITHOUT units.js, so a single shared
// constant would be a ReferenceError the moment one of those paths ran (audited before deciding,
// because "just use the existing BUILDING_AGE_ORDER" is the obvious suggestion and it is the one
// that silently breaks the suite). Introducing js/constants.js would mean adding a shipped script
// and editing every loader to pull it in first — a bigger risk than the duplication it removes.
//
// The values also are not tunable: they are a wire format. game-state-schema.json pins them, and
// every transcript and ranking file this project has published stores them. The real failure mode
// is therefore not "someone changes the order" but "someone adds an age in one place" — and that
// is what this pins, from five directions that do not share a source:
//
//   1. what the units module declares the ladder to be
//   2. what the rule AI's own next-age step walks
//   3. what the shipped content actually requires (building requiredAge, unit tier)
//   4. what the published schema says a state may contain
//   5. that every age is reachable AND nothing requires an age outside the ladder
//
// A fifth age added to the schema but not the engine fails 3/5; added to units.js only, fails 2
// and 5; a typo in one copy's spelling fails 3 or 5 outright.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const LADDER = ['stone', 'neolithic', 'bronze', 'iron'];

const scope = {
  console: { log() {}, warn() {}, error() {} },
  Math, JSON, Date, Object, Array, String, Number, Boolean, Set, Map, RegExp, Error, Promise,
  isNaN, parseInt, parseFloat, setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {},
  performance: { now: () => Date.now() },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} }, document: undefined,
};
vm.createContext(scope);
for (const f of ['js/civilizations.js', 'js/units.js', 'js/buildings.js', 'js/resources.js', 'js/i18n.js'])
  vm.runInContext(fs.readFileSync(path.join(ROOT, f), 'utf8'), scope, { filename: f });
vm.runInContext(fs.readFileSync(path.join(ROOT, 'js', 'game.js'), 'utf8')
  .split('\nconst WAR_PRIVATE_HOST')[0], scope, { filename: 'js/game.js' });
vm.runInContext(fs.readFileSync(path.join(ROOT, 'js', 'ai.js'), 'utf8'), scope, { filename: 'js/ai.js' });

const AIManager = vm.runInContext('AIManager', scope);
const CIVS = [...vm.runInContext('Object.keys(CIVILIZATIONS)', scope)];

test('the units module and the schema name the same four ages, in order', () => {
  const declared = [...vm.runInContext('BUILDING_AGE_ORDER', scope)];
  assert.deepEqual(declared, LADDER, 'the ladder in units.js moved; every copy in the other files did not');

  const schema = JSON.parse(fs.readFileSync(path.join(ROOT, 'game-state-schema.json'), 'utf8'));
  const enums = [];
  (function walk(node) {
    if (Array.isArray(node)) return node.forEach(walk);
    if (node && typeof node === 'object') {
      if (Array.isArray(node.enum) && node.enum.includes('iron')) enums.push(node.enum);
      Object.values(node).forEach(walk);
    }
  })(schema);
  assert.ok(enums.length >= 1, 'the schema no longer declares any age enum at all');
  for (const e of enums)
    assert.deepEqual([...e], LADDER, 'the published schema admits ages the engine does not have: ' + e.join(','));
});

test('the rule AI walks the ladder and stops at the top', () => {
  const next = AIManager.prototype.getNextAge;
  const walked = [];
  let cur = 'stone';
  for (let i = 0; i < LADDER.length + 2 && cur; i++) { cur = next.call(null, cur); if (cur) walked.push(cur); }
  assert.deepEqual(walked, ['neolithic', 'bronze', 'iron'], 'the AI steps the ladder differently than it is defined');
  assert.equal(next.call(null, 'iron'), null, 'iron must be terminal, or upgrade_age has no last answer');
});

test('no shipped content requires an age the ladder does not have', () => {
  const offenders = [];
  const buildings = vm.runInContext('BUILDING_DEFS', scope);
  for (const [id, def] of Object.entries(buildings)) {
    const req = def && (def.requiredAge != null ? def.requiredAge : def.age);
    if (typeof req === 'string' && req && !LADDER.includes(req)) offenders.push(`building ${id} requires "${req}"`);
  }
  const units = vm.runInContext('UNIT_DEFS', scope);
  for (const [id, def] of Object.entries(units))
    if (def && typeof def.tier === 'string' && !LADDER.includes(def.tier)) offenders.push(`unit ${id} is tier "${def.tier}"`);
  for (const host of vm.runInContext('Object.keys(BUILDING_TRAIN_TIERS)', scope))
    for (const age of vm.runInContext(`Object.keys(BUILDING_TRAIN_TIERS[${JSON.stringify(host)}])`, scope))
      if (!LADDER.includes(age)) offenders.push(`${host} has a tier list for "${age}"`);
  assert.deepEqual(offenders, [], 'content gated on an unreachable age: ' + offenders.join('; '));
});

test('every age in the ladder is something content actually unlocks', () => {
  // An age nothing requires is dead: the ladder says four, the game plays three.
  const used = new Set();
  for (const def of Object.values(vm.runInContext('UNIT_DEFS', scope))) if (def && def.tier) used.add(def.tier);
  for (const def of Object.values(vm.runInContext('BUILDING_DEFS', scope))) {
    const req = def && (def.requiredAge != null ? def.requiredAge : def.age);
    if (typeof req === 'string' && req) used.add(req);
  }
  for (const host of vm.runInContext('Object.keys(BUILDING_TRAIN_TIERS)', scope))
    for (const age of vm.runInContext(`Object.keys(BUILDING_TRAIN_TIERS[${JSON.stringify(host)}])`, scope)) used.add(age);
  const dead = LADDER.filter((a) => !used.has(a));
  assert.deepEqual(dead, [], 'ages the ladder offers that no building, unit or tier list names: ' + dead.join(', '));
});

test('a civ tree never names an age it cannot reach', () => {
  // The per-civ tech trees are data, so they can name a researchAt age the engine has no idea
  // about. Cheapest to assert here than to discover as an unlock that never fires.
  const stray = [];
  for (const civ of CIVS) {
    const tree = vm.runInContext(`CIVILIZATIONS[${JSON.stringify(civ)}].techTree || {}`, scope);
    for (const [tech, def] of Object.entries(tree)) {
      const at = def && (def.requiredAge != null ? def.requiredAge : def.age);
      if (typeof at === 'string' && at && !LADDER.includes(at)) stray.push(`${civ}/${tech} @ ${at}`);
    }
  }
  assert.deepEqual(stray, [], 'techs gated on an age outside the ladder: ' + stray.join(', '));
});
