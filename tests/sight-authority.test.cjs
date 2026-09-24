// One question, one answer: "can this seat see that spot?"
//
// Three code paths ask it — the rule-based AI's targeting (aiManager.isVisibleTo), the
// simulation's auto-defence gate (Game.canOwnerSee), and the predicate that decides which
// enemies and resource nodes a model is told about (OpenAIAIManager.isPositionVisibleToAI) —
// and a fourth (computeAIFogGrid) draws the seat's knowledge on the spectator's minimap.
//
// They were written independently and drifted: the fog and the model-facing grid carried
// local copies of the numbers (15 / 12 / 60, cavalry ×1.2) against the authority's
// 15 / 20 / 80 and cavalry 22.5, and only some of them honoured the Farsight tech
// (visionBonus). The visible result was that a seat's own auto-defence reacted to things its
// state said it could not see, and the overlay used to ask "what did this model know?"
// understated it.
//
// So: probe the same points through every path and require one answer, then pin the anchors
// so agreement on a wrong number cannot pass either.
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
  performance: { now: () => 0 },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} }, document: undefined,
};
vm.createContext(scope);
for (const f of ['js/civilizations.js', 'js/units.js', 'js/buildings.js', 'js/resources.js', 'js/i18n.js'])
  vm.runInContext(fs.readFileSync(path.join(ROOT, f), 'utf8'), scope, { filename: f });
vm.runInContext(fs.readFileSync(path.join(ROOT, 'js', 'game.js'), 'utf8')
  .split('\nconst WAR_PRIVATE_HOST')[0], scope, { filename: 'js/game.js' });
vm.runInContext(fs.readFileSync(path.join(ROOT, 'js', 'ai.js'), 'utf8'), scope, { filename: 'js/ai.js' });
vm.runInContext(fs.readFileSync(path.join(ROOT, 'js', 'openai-ai.js'), 'utf8'), scope, { filename: 'js/openai-ai.js' });

const Game = vm.runInContext('Game', scope);
const AIManager = vm.runInContext('AIManager', scope);
const OpenAIAIManager = vm.runInContext('OpenAIAIManager', scope);

const MAP = 800;
const seat = (over) => Object.assign({ id: 'a', seat: 1, units: [], buildings: [], resources: {} }, over);

function world(ai) {
  const g = Object.create(Game.prototype);
  g.player = { id: 'player', units: [], buildings: [] };
  g.aiManager = Object.assign(Object.create(AIManager.prototype), { game: g, aiPlayers: [ai] });
  g.openAIAIManager = Object.create(OpenAIAIManager.prototype);
  g.terrain = { size: MAP };
  g._stepStamp = 1;
  return g;
}

const unit = (x, z, over) => Object.assign({ x, z, health: 100, owner: 'a', unitType: 'infantry' }, over);
const bldg = (type, x, z, over) => Object.assign({ x, z, health: 500, type, owner: 'a' }, over);

test('the three visibility paths give one answer across the map', () => {
  const ai = seat({
    units: [unit(0, 0), unit(40, 0, { unitType: 'cavalry' }), unit(80, 80, { health: 0 }),
      unit(-60, 0, { visionBonus: 1.2 })],                        // the Farsight tech
    buildings: [bldg('tower', 200, 0), bldg('barracks', -200, 0), bldg('town_center', 0, 200),
      bldg('tower', -300, 0, { underConstruction: true })],
  });
  const g = world(ai);
  const om = g.openAIAIManager, aim = g.aiManager;

  // Every point below is chosen so at least one of the retired copies would get it wrong:
  // x=20 and x=-76 need cavalry 22.5 and the Farsight bonus (the copies said 18 and 15);
  // x=121/279 need the tower's 80 (they said 60); x=-300 must stay dark because a
  // construction site sees nothing. The town center at (0,200) is out of range of the x axis
  // entirely, which is its own check that a building's radius is measured, not assumed.
  const PROBE = [-320, -300, -80, -76, -44, -225, -205, -195, -100, -10, 0, 14, 16, 17, 20, 60, 63, 119, 121, 279, 281];
  const answers = new Map();
  const disagreements = [];
  for (const x of PROBE) {
    const viaAIManager = !!aim.isVisibleTo(ai, x, 0);
    const viaGame = g.canOwnerSee('a', x, 0);
    const viaModel = om.isPositionVisibleToAI(ai, x, 0, g) === 'visible';
    if (viaAIManager !== viaGame || viaGame !== viaModel)
      disagreements.push(`x=${x}: aiManager=${viaAIManager} simulation=${viaGame} model-facing=${viaModel}`);
    answers.set(x, viaGame);
  }
  assert.deepEqual(disagreements, [], 'one question, three answers:\n  ' + disagreements.join('\n  '));

  // Anchors, so unanimity on a wrong number still fails.
  const at = (x) => answers.get(x);
  assert.equal(at(14), true, 'infantry sees 15');
  assert.equal(at(16), false, 'and no farther');
  assert.equal(at(20), true, 'cavalry is 22.5, not the 18 the copy computed');
  assert.equal(at(-76), true, 'the Farsight tech reaches the model-facing and sim paths too');
  assert.equal(at(-300), false, 'a tower under construction sees nothing');
  assert.equal(at(121), true, 'a tower sweeps 80, not 60');
  assert.equal(at(119), false, 'and stops there');
  assert.equal(at(279), true, 'the far side of the same 80');
  assert.equal(at(281), false);
});

test('the radii themselves are the documented ones', () => {
  const g = world(seat({}));
  assert.equal(g.unitVision(unit(0, 0)), 15, 'infantry');
  assert.equal(g.unitVision(unit(0, 0, { unitType: 'cavalry' })), 22.5, 'cavalry sees 50% farther');
  assert.equal(g.unitVision(unit(0, 0, { visionBonus: 1.2 })), 18, 'and a vision tech multiplies it');
  assert.equal(g.buildingVision(bldg('tower', 0, 0)), 80);
  assert.equal(g.buildingVision(bldg('town_center', 0, 0)), 40);
  assert.equal(g.buildingVision(bldg('barracks', 0, 0)), 20);
  assert.equal(g.buildingVision(bldg('tower', 0, 0, { underConstruction: true })), 0, 'scaffolding does not see');
});

test('a dying unit is not a scout, in any path', () => {
  const ai = seat({ units: [unit(0, 0, { health: 0 })] });
  const g = world(ai);
  assert.equal(g.aiManager.isVisibleTo(ai, 1, 0), false);
  assert.equal(g.canOwnerSee('a', 1, 0), false);
  assert.equal(g.openAIAIManager.isPositionVisibleToAI(ai, 1, 0, g), null);
});

test('the seat overlay draws the real tower radius, not the copy', () => {
  // computeAIFogGrid feeds the minimap's per-seat fog — the thing a reader uses to ask
  // "what could this model see". It used a local 60 where the game gives 80.
  const ai = seat({ buildings: [bldg('tower', 0, 0)] });
  const g = world(ai);
  const N = 400;                                  // fogOfWar's resolution: gridSize 2 on an 800 map
  const grid = g.openAIAIManager.computeAIFogGrid(ai, g, N);
  const cell = (x) => grid[Math.floor(N / 2) * N + Math.floor(N / 2 + x / 2)];
  assert.equal(cell(70), 2, '70 from a tower is inside its 80 sweep');
  assert.equal(cell(90), 0, 'and 90 is outside it');
});
