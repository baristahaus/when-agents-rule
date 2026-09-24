// Elimination must be decided from the game's own training tables.
//
// isPlayerEliminated spares a seat that can still field a military unit. Until recently the
// "can it train anything?" clause carried a hand-copied map of three buildings and their
// units, which disagreed with BUILDING_TRAIN_TIERS + BUILDING_TYPES in two directions: the
// temple (whose priest lives in the building def, not in the tier table) was missing, so a
// seat whose last trainer was a temple was DELETED from a match while its own controller was
// still being told priests were available; and civ-unique units were invisible to it, so
// which building a seat happened to own decided its fate instead of the rules.
//
// These fixtures load the real shipped files: the point is that THE PREDICATE the game runs
// behaves this way, not that a reimplementation of it does.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const scope = {
  console: { log() {}, warn() {}, error() {} },
  Math, JSON, Date, Object, Array, String, Number, Boolean, Set, Map, RegExp, Error, Promise,
  isNaN, parseInt, parseFloat, setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {},
  performance: { now: () => Date.now() },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} }, document: undefined,
};
vm.createContext(scope);
for (const f of ['js/civilizations.js', 'js/units.js', 'js/buildings.js', 'js/resources.js', 'js/i18n.js'])
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', f), 'utf8'), scope, { filename: f });
// game.js up to its WAR_PRIVATE_HOST tail — see tests/action-vocabulary.test.cjs.
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'js', 'game.js'), 'utf8')
  .split('\nconst WAR_PRIVATE_HOST')[0], scope, { filename: 'js/game.js' });
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'js', 'openai-ai.js'), 'utf8'), scope, { filename: 'js/openai-ai.js' });

const Game = vm.runInContext('Game', scope);
const OpenAIAIManager = vm.runInContext('OpenAIAIManager', scope);
const game = Object.create(Game.prototype);

const RES = (over) => Object.assign({ food: 5000, wood: 5000, stone: 5000, gold: 5000 }, over, {
  hasResources(cost) { return Object.entries(cost).every(([k, v]) => this[k] >= v); },
});
const building = (type, over) => Object.assign({ type, health: 800, maxHealth: 800, underConstruction: false }, over);
const seat = (over) => Object.assign({
  civilization: 'greek', age: 'bronze', units: [], buildings: [], resources: RES({}),
}, over);

const eliminated = (ai) => game.isPlayerEliminated.call(game, ai);

test('a seat that can still train a priest is not out of the match', () => {
  const ai = seat({ buildings: [building('temple')] });
  assert.equal(eliminated(ai), false, 'priest costs 50 food + 30 gold, both plentiful — the old copy could not see the temple');
  // and it is the training clause that spares it, not a stray one
  assert.equal(game.canAffordAnyMilitary.call(game, ai), true);
});

test('a seat that cannot pay for the priest is still out', () => {
  // The tier and affordability gates have to survive the derivation, or "look it up in the
  // data" would just mean "nobody is ever eliminated".
  assert.equal(eliminated(seat({ buildings: [building('temple')], resources: RES({ gold: 0 }) })), true,
    'a temple with no gold cannot produce anything');
  assert.equal(eliminated(seat({ buildings: [building('temple')], age: 'stone' })), true,
    'the temple is a bronze-age host; at stone there is nothing to train');
});

test('the military hosts still decide it the same way they always did', () => {
  for (const type of ['barracks', 'archery_range', 'stable']) {
    assert.equal(eliminated(seat({ buildings: [building(type)] })), false, type + ' must keep its owner alive');
    assert.equal(eliminated(seat({ buildings: [building(type, { health: 0 })] })), true, 'a ' + type + ' in ruins is not a trainer');
  }
  // A village is not an army: the town_center trains workers, and workers never spare a seat
  // that has no other way to field a unit. (It is spared here for OWNING a living TC.)
  assert.equal(eliminated(seat({ buildings: [building('town_center')] })), false);
  assert.equal(eliminated(seat({ buildings: [building('house'), building('farm')] })), true,
    'no trainer, no army, no TC, no way to rebuild one');
});

test('an unfinished host counts only while a living worker is building it', () => {
  const site = building('barracks', { underConstruction: true, buildProgress: 4 });
  const worker = (task, target) => ({ type: 'worker', health: 40, task, buildTarget: target });
  // Food and wood for one militia, and NOT enough for a town center — otherwise the seat is
  // spared by the "it can rebuild its TC" clause and this test measures nothing.
  const pay = RES({ food: 60, wood: 30, stone: 0, gold: 0 });
  assert.equal(eliminated(seat({ buildings: [site], units: [worker('building', site)], resources: pay })), false,
    'a staffed site plus the cost of a militia is an army on the way');
  assert.equal(eliminated(seat({ buildings: [site], units: [worker('harvest', null)], resources: pay })), true,
    'the same site with nobody building it is not a promise of an army');
});

test('what the predicate considers trainable is what the model is told is trainable', () => {
  // The anti-drift assertion: the harness advertises a vocabulary to the model and the sim
  // decides survival from a list of units. They must not be separate lists any more.
  for (const civ of ['greek', 'egyptian', 'persian', 'yamato']) {
    for (const age of ['stone', 'neolithic', 'bronze', 'iron']) {
      const advertised = new Map();
      for (const u of [...OpenAIAIManager.prototype.trainableUnitsFor.call(null, civ)]) {
        if (!advertised.has(u.at)) advertised.set(u.at, new Set());
        advertised.get(u.at).add(u.id);
      }
      for (const [host, ids] of advertised) {
        const ai = seat({ civilization: civ, age });
        const considered = [...game.trainOptionsFor.call(game, ai, { type: host })];
        const unknown = considered.filter((id) => id !== 'worker' && !ids.has(id));
        assert.deepEqual(unknown, [], civ + '/' + age + ': ' + host + ' counts units the model was never offered: ' + unknown.join(', '));
      }
    }
  }
});
