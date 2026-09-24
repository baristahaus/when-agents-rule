// A seeded match has to replay, and that promise lives in 62 call sites.
//
// What is pinned here, in descending strength:
//
//   1. the seeded generator itself — same seed, same stream, and no seed means no stream
//   2. the delegation Game.rand / Game.randJitter perform onto it
//   3. that the simulation files contain no unseeded Math.random draw except the two places
//      that mint session-unique identifiers, which must NOT be reproducible
//
// Number 3 is an allowlist over source text, which this suite otherwise avoids on purpose
// (asserting how code is spelled tests the diff, not the behaviour). It earns its place because
// the property it protects is invisible otherwise: one new `Math.random()` in a hot path does not
// change distributions, does not fail a gameplay test, and quietly makes every "same seed, same
// match" claim in docs/QUALITY_REVIEW.md false. A draw that must be seeded has to be routed
// through game.rand(); a draw that must NOT be seeded (an id) is added here with its reason.
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
  performance: { now: () => 0 }, localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  document: undefined,
};
vm.createContext(scope);
for (const f of ['js/civilizations.js', 'js/units.js', 'js/buildings.js', 'js/resources.js', 'js/i18n.js', 'js/terrain.js'])
  vm.runInContext(fs.readFileSync(path.join(ROOT, f), 'utf8'), scope, { filename: f });
vm.runInContext(fs.readFileSync(path.join(ROOT, 'js', 'game.js'), 'utf8')
  .split('\nconst WAR_PRIVATE_HOST')[0], scope, { filename: 'js/game.js' });

const TerrainManager = vm.runInContext('TerrainManager', scope);
const Game = vm.runInContext('Game', scope);

// The real generator, without building a map: _initRand is the whole seeding step.
const streamFor = (seed) => {
  const t = Object.create(TerrainManager.prototype);
  t.seed = seed;
  t._initRand();
  return t;
};

test('one seed is one stream, and a different seed is a different stream', () => {
  const draw = (t) => Array.from({ length: 40 }, () => t.rand());
  const a = draw(streamFor('DETERM-42')), b = draw(streamFor('DETERM-42')), c = draw(streamFor('DETERM-43'));
  assert.deepEqual(a, b, 'the same seed produced two different streams — nothing downstream can be reproducible');
  assert.notDeepEqual(a, c, 'two different seeds produced the same stream, so the seed is not reaching the generator');
  for (const v of a) assert.ok(v >= 0 && v < 1, 'rand() must stay in [0,1): got ' + v);
});

test('an unseeded terrain is Math.random, so the default game is untouched by all this', () => {
  const t = streamFor('');
  assert.equal(t.rand, Math.random, 'no seed must fall through to Math.random (terrain.js:89) — this is why '
    + 'routing the sim through game.rand() cannot change an unseeded match');
  assert.equal(streamFor(null).rand, Math.random);
});

test('Game.rand delegates to the terrain stream and randJitter is that stream, centred', () => {
  const g = Object.create(Game.prototype);
  const seq = [0.1, 0.9, 0.5, 0.25, 0.75];
  let i = 0;
  g.terrain = { rand: () => seq[i++] };
  assert.deepEqual([...Array.from({ length: 5 }, () => g.rand())], seq, 'Game.rand is not reading terrain.rand');

  i = 0;
  // randJitter(k) is (rand() - 0.5) * k: 0.1 -> -0.4k, 0.9 -> +0.4k, 0.5 -> 0
  assert.deepEqual([...Array.from({ length: 3 }, () => g.randJitter(10))], [-4, 4, 0],
    'randJitter changed shape; every one of the ~50 park-and-spread call sites assumes this');

  // A game with no terrain (the headless test harnesses, and any call before a map exists) must
  // still answer rather than throw, and answer from Math.random.
  const bare = Object.create(Game.prototype);
  assert.equal(typeof bare.rand(), 'number', 'rand() has to work before a terrain exists');
  const j = bare.randJitter(6);
  assert.ok(j >= -3 && j <= 3, 'jitter must stay within +/-k/2, got ' + j);
});

test('the simulation draws its randomness through the game, apart from id minting', () => {
  const ALLOWED = {
    // Session-unique identifiers: reproducibility here would be a bug, not a feature — two
    // matches in one page would mint the same seat/unit ids. Deliberately outside the stream.
    'js/game.js': [
      "return 'r' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);",   // camera subject key
    ],
    'js/ai.js': [
      "id: 'ai_' + Math.random().toString(36).substr(2, 9),",                             // seat id
    ],
    'js/openai-ai.js': [],
  };
  const offenders = [];
  for (const f of Object.keys(ALLOWED)) {
    const lines = fs.readFileSync(path.join(ROOT, f), 'utf8').split('\n');
    lines.forEach((line, idx) => {
      if (!line.includes('Math.random')) return;
      const t = line.trim();
      if (t.startsWith('//') || t.startsWith('*')) return;           // prose may name it
      if (ALLOWED[f].some(a => line.includes(a))) return;
      // The delegation itself is allowed to mention Math.random as the fallback.
      if (f === 'js/game.js' && t.startsWith('return ((')) return;
      offenders.push(`${f}:${idx + 1}: ${t.slice(0, 88)}`);
    });
  }
  assert.deepEqual(offenders, [],
    'unseeded randomness in a simulation file means a seeded match stops replaying. Route it '
    + 'through game.rand()/game.randJitter(), or add it to the allowlist with a reason:\n  '
    + offenders.join('\n  '));
});
