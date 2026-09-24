// Auto-acquisition may only react to what the seat can see.
//
// The aggro radius is 24 for melee and weapon-range + 20 for the rest (27.5 for an archer),
// while sight is 15 for infantry and 22.5 for cavalry. So the scan that decides "someone is
// near, fight them" reached past what the seat could observe, and a fogged match was really
// one board watched by four omniscient brains — including the models, who are told the
// opposite. Ordered attacks and retaliation keep the old behaviour on purpose: a model may
// chase something it spotted and lost, and being shot is information.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
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

const Game = vm.runInContext('Game', scope);

const unit = (over) => Object.assign({ health: 100, maxHealth: 100, owner: 'a', x: 0, z: 0, range: 0.5, unitType: 'infantry' }, over);
const building = (over) => Object.assign({ health: 500, maxHealth: 500, owner: 'a', x: 0, z: 0, type: 'barracks' }, over);

// Two seats. The scanning unit belongs to `a`; anything owned by `b` is an enemy. `a` has no
// units or buildings other than the ones a case puts there on purpose.
function world(scanningUnit, enemies, ownUnits = [], ownBuildings = []) {
  const a = { id: 'a', units: [scanningUnit, ...ownUnits], buildings: ownBuildings };
  const g = Object.create(Game.prototype);
  g.player = { id: 'player', units: [], buildings: [] };
  g.aiManager = { aiPlayers: [a] };
  g.renderer = { units: [scanningUnit, ...enemies], buildings: ownBuildings.concat(enemies.filter((e) => e.type)) };
  g._stepStamp = 1;
  return { g, a, scanningUnit };
}

const ARCHER_AGGRO = 7.5 + 20;   // what updateCombat hands the scan for a unit with range > 1

test('a target outside the seat\'s sight is not acquired, though it is well inside aggro', () => {
  const me = unit({ x: 0, z: 0, owner: 'a', range: 7.5, unitType: 'ranged' });
  const foe = unit({ x: 22, z: 0, owner: 'b' });          // 22 away: inside 27.5, outside 15
  const { g } = world(me, [foe]);
  assert.ok(22 < ARCHER_AGGRO && 22 > g.unitVision(me), 'the fixture must straddle the two radii');
  assert.equal(g.findNearestEnemyInRange(me, ARCHER_AGGRO, true, true), null,
    'the archer must not react to an enemy nobody can see');
  // …and the same scan without the gate still finds it: this is a filter on acquisition,
  // not a change to what the engine is able to target.
  assert.equal(g.findNearestEnemyInRange(me, ARCHER_AGGRO, true, false), foe);
});

test('the moment the seat can see it, acquisition works as it always did', () => {
  const me = unit({ x: 0, z: 0, owner: 'a', range: 7.5, unitType: 'ranged' });
  const foe = unit({ x: 14, z: 0, owner: 'b' });          // inside infantry sight (15)
  const { g } = world(me, [foe]);
  assert.equal(g.findNearestEnemyInRange(me, ARCHER_AGGRO, true, true), foe);
});

test('a friendly building carries its owner\'s sight, so a base defends itself', () => {
    const me = unit({ x: 0, z: 0, owner: 'a', range: 7.5, unitType: 'ranged' });
    // 26 away: inside the 27.5 aggro radius, outside the archer's own 15 sight. With no
    // town center in the world the same scan must come back empty — that pair is what
    // shows it is the BUILDING's sight doing the work, not the distance.
    const foe = unit({ x: 26, z: 0, owner: 'b' });
    const bare = world(me, [foe]);
    assert.equal(bare.g.findNearestEnemyInRange(me, ARCHER_AGGRO, true, true), null);
    const tc = building({ type: 'town_center', x: 20, z: 0 });   // buildingVision 40
    const { g } = world(me, [foe], [], [tc]);
    assert.equal(g.findNearestEnemyInRange(me, ARCHER_AGGRO, true, true), foe,
        'the town center saw it, so the archer may react');
});

test('a construction site grants no sight, and neither does a corpse', () => {
  const me = unit({ x: 0, z: 0, owner: 'a', range: 7.5, unitType: 'ranged' });
  const foe = unit({ x: 30, z: 0, owner: 'b' });
  const site = building({ type: 'town_center', x: 25, z: 0, underConstruction: true });
  const dead = unit({ x: 25, z: 0, health: 0 });
  const { g } = world(me, [foe], [dead], [site]);
  assert.equal(g.findNearestEnemyInRange(me, ARCHER_AGGRO, true, true), null,
    'nothing living and finished covers that ground');
});

test('an enemy building is only spotted when it is spotted', () => {
  const me = unit({ x: 0, z: 0, owner: 'a', range: 7.5, unitType: 'ranged' });
  const barracks = building({ x: 20, z: 0, owner: 'b', type: 'barracks' });
  const { g } = world(me, [barracks]);
  assert.equal(g.findNearestEnemyInRange(me, ARCHER_AGGRO, true, true), null);
  const { g: g2 } = world(me, [barracks], [unit({ x: 19, z: 0 })]);
  assert.equal(g2.findNearestEnemyInRange(me, ARCHER_AGGRO, true, true), barracks,
    'a scout standing on it makes it a target');
});

test('the sight list is rebuilt per sub-step, not per candidate', () => {
  const me = unit({ x: 0, z: 0, owner: 'a', range: 7.5, unitType: 'ranged' });
  const { g, a } = world(me, [unit({ x: 30, z: 0, owner: 'b' })]);
  const first = g.visionSources(a);
  assert.equal(g.visionSources(a), first, 'same sub-step must reuse the list');
  g._stepStamp = 2;
  const second = g.visionSources(a);
  assert.notEqual(second, first, 'a new sub-step must not reuse stale positions');
});

test('outside a sub-step nothing is cached', () => {
    // Stamp 0 means the caller is not inside the sim loop (an analyzer rebuild, a test).
    // A list cached there would outlive every move the caller makes afterwards.
    const me = unit({ x: 0, z: 0, owner: 'a', range: 7.5, unitType: 'ranged' });
    const { g, a } = world(me, [unit({ x: 30, z: 0, owner: 'b' })]);
    g._stepStamp = 0;
    const first = g.visionSources(a);
    a.units[0].x = 99;
    assert.notEqual(g.visionSources(a), first, 'a stale sight list was handed out outside a step');
    assert.equal(g.canOwnerSee('a', 99, 0), true, 'the moved unit still sees its own square');
});

test('an unknown owner is treated as seeing, never as blind', () => {
  const me = unit({ x: 0, z: 0, owner: 'nobody', range: 7.5, unitType: 'ranged' });
  const foe = unit({ x: 22, z: 0, owner: 'b' });
  const { g } = world(me, [foe]);
  assert.equal(g.findNearestEnemyInRange(me, ARCHER_AGGRO, true, true), foe,
    'a scan must not fail closed into a unit that fights nothing, ever');
});
