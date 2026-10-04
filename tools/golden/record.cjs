#!/usr/bin/env node
'use strict';
// ---------------------------------------------------------------------------
// Reference recorder for the v2 rebuild golden diff (docs/REBUILD_PROPOSAL.md,
// the P0 work package).
//
// Runs the SHIPPING v1 simulation (js/*.js, unchanged) in a bare `node:vm`
// context on a controlled fake wall clock, with a fixed seed and FOUR
// rule-brain seats (the in-repo AIManager — the same brains a campaign seat
// gets when no model is configured). No provider calls, no network, no human
// seat, no turn-based entanglement. Writes ONE JSONL stream:
//
//   line 1    type:'match'   conditions (seed, seats, difficulty, step/snapshot
//                             cadence, version) + the four seats — the exact
//                             header the game's own transcript recorder writes
//   then      type:'snap'    one per snapshot beat: the shared world pulse
//             type:'turn'    one per seat per beat: the seat's full state —
//                             the exact object buildGameStateJSON would hand a
//                             model sitting in that seat (built by that
//                             function, recorded by that recorder; every line
//                             below is verbatim recorder output)
//   finally   type:'results' who won, how each seat ended
//             type:'timeline'  the match's own economy/age/dry-up graph
//
// Determinism contract: for a given seed, two runs of this recorder differ
// ONLY in the session-unique identifiers v1 mints from Math.random (the seat
// ids, js/ai.js:34 — the one allowlisted draw, pinned by
// tests/match-determinism.test.cjs). tools/golden/compare.cjs re-keys those
// by seat index before diffing. Everything else — terrain, spawns, AI
// decisions, combat, economy, fog, state JSON — is a function of the seed.
//
// The clock. v1 advances on Date.now() (tick computes the real elapsed and
// feeds it in <=100ms sub-steps). Here every Date.now()/performance.now() read
// in the context returns T, which the driver advances STEP_MS per sub-step.
// The real timer API is stubbed to no-op (the one setTimeout in startGame is
// a camera resize; the background driver's Worker is try/catch-guarded and
// simply absent), and the rule brains need none: AIManager.update() is driven
// straight off the sim tick (game.js:717) with its own thinkTimer.
function arg(name, def) {
  for (const prefix of ['--', '-']) {
    const i = process.argv.indexOf(prefix + name);
    if (i !== -1) {
      const v = process.argv[i + 1];
      if (v === undefined || (v.startsWith('-') && !/^-\d/.test(v))) throw new Error(`--${name} needs a value`);
      return v;
    }
  }
  return def;
}
//   node tools/golden/record.cjs -seed golden -seats 4 -minutes 10 \
//     -difficulty easy -out samples/golden/easy/golden-10m.jsonl
// ---------------------------------------------------------------------------
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.join(__dirname, '..', '..');


const SEED = String(arg('seed', 'golden'));
const SEATS = Math.min(4, Math.max(2, parseInt(arg('seats', '4'), 10)));
const MINUTES = Math.max(1, parseInt(arg('minutes', '10'), 10));
const DIFFICULTY = arg('difficulty', 'easy');
const OUT = arg('out', null);
if (!OUT) { console.error('record.cjs: -out <file> is required'); process.exit(2); }
if (!['easy', 'medium', 'hard'].includes(DIFFICULTY)) { console.error('record.cjs: -difficulty is easy|medium|hard'); process.exit(2); }

const STEP_MS = 100;            // the sim's sub-step ceiling (game.js:733)
const SNAP_EVERY = 5;            // 500ms of sim — the fog sweep's own cadence
const TOTAL_STEPS = (MINUTES * 60 * 1000) / STEP_MS;

// ---------------------------------------------------------------- the clock
let T = 0; // the single authority: every Date/performance read in the context
class FakeDate {
  static now() { return T; }
  constructor(v = T) { this._v = typeof v === 'number' ? v : T; }
  getTime() { return this._v; }
  toISOString() { return new Date(this._v).toISOString(); }
  getFullYear() { return new Date(this._v).getFullYear(); }
  getMonth() { return new Date(this._v).getMonth(); }
  getDate() { return new Date(this._v).getDate(); }
  getHours() { return new Date(this._v).getHours(); }
  getMinutes() { return new Date(this._v).getMinutes(); }
  getSeconds() { return new Date(this._v).getSeconds(); }
  toString() { return String(this._v); }
}

// ------------------------------------------------------------------- scope
const scope = {
  console: { log() {}, warn() {}, error() {}, info() {}, debug() {} },
  Math, JSON, Object, Array, String, Number, Boolean, Set, Map, RegExp, Error, Promise,
  Date: FakeDate,
  isNaN, isFinite, parseInt, parseFloat,
  // The real game re-enters itself only through no-ops here: the one
  // setTimeout is a camera resize, the worker is try/catch-guarded, and the
  // rule brains keep their own timers inside update().
  setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
  requestAnimationFrame: () => 1, cancelAnimationFrame() {},
  performance: { now: () => T },
  localStorage: { getItem: k => (k === 'difficulty' ? DIFFICULTY : null), setItem() {}, removeItem() {} },
  sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  navigator: { storage: null, userAgent: 'node-golden' }, // null storage: the recorder keeps everything in memory
};

// Canvas 2D: a proxy that returns the data shapes code reads (createImageData /
// getImageData) and no-ops every draw call.
function makeCtx() {
  const props = {};
  return new Proxy(props, {
    get(t, k) {
      if (k in t) return t[k];
      if (k === 'createImageData' || k === 'getImageData') {
        return (x, y, w, h) => {
          const ww = (w == null && h == null) ? 1 : (w || 1);
          const hh = (h == null) ? 1 : h;
          return { width: ww, height: hh, data: new Uint8ClampedArray(ww * hh * 4) };
        };
      }
      if (k === 'createLinearGradient' || k === 'createRadialGradient' || k === 'createConicGradient') {
        return () => ({ addColorStop() {} });
      }
      if (k === 'createPattern') {
        return () => ({});
      }
      if (k === 'measureText') return s => ({ width: String(s == null ? '' : s).length });
      return () => undefined;
    },
    set(t, k, v) { t[k] = v; return true; }
  });
}
function makeCanvas() {
  return {
    width: 0, height: 0, style: {},
    classList: { add() {}, remove() {} },
    addEventListener() {}, removeEventListener() {},
    appendChild() {}, removeChild() {},
    childElementCount: 0,
    getContext: () => makeCtx(),
    toDataURL: () => '',
  };
}
function makeElement() {
  return {
    style: {}, classList: { add() {}, remove() {} },
    setAttribute() {}, getAttribute: () => null,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 300, height: 300 }),
    appendChild() {}, removeChild() {},
  };
}
scope.document = {
  hidden: false,
  body: makeElement(),
  createElement: tag => (tag === 'canvas' ? makeCanvas() : makeElement()),
  createElementNS: (ns, tag) => makeCanvas(),
  getElementById: () => makeCanvas(),
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener() {}, removeEventListener() {},
};
// The engine's top level reads three of TexGen's constants the moment its file
// loads, and wants M3D/GLCore handles like the browser gives it.
scope.window = {
  M3D: { scaling: (...a) => a },
  GLCore: { createMeshBuffers: () => ({}) },
  devicePixelRatio: 1,
  location: { search: '', href: 'file:/' },
  navigator: scope.navigator,
  addEventListener() {}, removeEventListener() {},
  requestAnimationFrame: () => 1,
};

// The game's one nondeterminism source is Math.random (player ids at
// ai.js:34, terrain splats). Hand the context its own Math — prototype-chained
// to the host one so every other method is untouched — with random fed by a
// mulberry32 derived from -seed. Same seed, byte-identical file; another
// seed, another map.
let seedState = (() => { let a = 1779033703; for (let i = 0; i < SEED.length; i++) a = Math.imul(a ^ SEED.charCodeAt(i), 3432918353) >>> 0; return a; })();
const ScopeMath = Object.create(Math);
ScopeMath.random = function () {
  seedState |= 0; seedState = seedState + 0x6D2B79F5 | 0;
  let t = Math.imul(seedState ^ seedState >>> 15, 1 | seedState);
  t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
  return ((t ^ t >>> 14) >>> 0) / 4294967296;
};
scope.Math = ScopeMath;
// ------------------------------------------------------------------- load
vm.createContext(scope);
function load(f, cutTail) {
  let src = fs.readFileSync(path.join(ROOT, f), 'utf8');
  if (cutTail) src = src.split('\nconst WAR_PRIVATE_HOST')[0]; // the showcase classifier is browser-only
  vm.runInContext(src, scope, { filename: f });
}
// One list, from js/manifest.js — the same list the page loads and the fingerprint hashes,
// and the reason a hand-rolled copy here once stopped mattering: it predated
// js/simulation/{rng,math,position-rules}.js, so the recorder ran the rules without the
// seeded draws and the trig that decides positions, and died on `WarMath is not defined` the
// first time game.js reached for a spawn ring. A golden recorded by a loader that disagrees
// with index.html is not the reference anything is being ported against.
// i18n and the transcript writer are not rule files, so the manifest does not name them; the
// renderer files are not rules either, and come in below with their window bridges.
load('js/i18n.js');
load('js/transcript.js');
for (const f of require(path.join(ROOT, 'js/manifest.js')).vm) load(f);
load('js/engine/glcore.js');
// In the browser, window IS the global object, so `window.TexGen = ...` also
// answers a bare `TexGen` in the next script. A vm context does not: bridge it.
scope.TexGen = scope.window.TexGen;
scope.M3D = scope.window.M3D;
scope.GLCore = scope.window.GLCore;
load('js/engine/gamerenderer.js');
scope.EngineRenderer = scope.window.EngineRenderer;

const Game = vm.runInContext('Game', scope);
const AIManager = vm.runInContext('AIManager', scope);
const TerrainManager = vm.runInContext('TerrainManager', scope);
const EngineRenderer = vm.runInContext('EngineRenderer', scope);
const TranscriptRecorder = vm.runInContext('TranscriptRecorder', scope);

// ----------------------------------------------------------------- wiring
const game = new Game();
game.spectatorMode = true; // four AI seats, no human

// ----------------------------------------------------------------- wiring
// The renderer is a real EngineRenderer prototype instance: every real method
// exists (bookkeeping, the referee passes, the inert shims). Only the
// GL-entangled methods are overridden — addUnit/addBuilding (mesh composition)
// and setTerrain (terrain mesh). The constructor-built camera/cameraTarget get
// equivalent handles: the game pokes their positions, aspect and projection.
//
// this.renderer.units / .buildings IS the game's single entity list
// (game.getAllUnits / getAllBuildings iterate it; the real clearScene
// empties it). The bookkeeping half of the real addUnit (the re-add guard,
// gamerenderer.js:751, and the inert handles game.js and fogofwar.js poke,
// 776-779) is kept; the GL model composition beside it is skipped.
const units = [];
const buildings = [];
const renderer = Object.create(EngineRenderer.prototype);
renderer.units = units;
renderer.buildings = buildings;
renderer.selectedUnits = [];
renderer._ghosts = [];
renderer._projectiles = [];
renderer._rings = [];
renderer._dustPool = [];
renderer._flagTextures = null;
renderer.isPlacingBuilding = false;
renderer.buildingPreview = null;
renderer.placingBuildingType = null;
renderer._cameraMoveId = 0;
renderer.W = 800;
renderer.H = 600;
renderer.replayMode = false;
renderer.game = null;
renderer.terrain = null;
renderer.renderer = { setSize() {}, canvas: makeCanvas() };
renderer.camera = { position: { x: 0, y: 120, z: 120, set(x, y, z) { this.x = x; this.y = y; this.z = z; } }, lookAt() {}, aspect: 4 / 3, updateProjectionMatrix() {} };
renderer.cameraTarget = { x: 0, y: 0, z: 0, set(x, y, z) { this.x = x; this.y = y == null ? 0 : y; this.z = z; } };
renderer.setTerrain = t => { renderer.terrain = t; };
renderer.addUnit = function (unit) {
  const prev = units.indexOf(unit);
  if (prev > -1) units.splice(prev, 1);
  units.push(unit);
  unit._engine = null;
  unit.mesh = { visible: true, position: { set() {}, x: 0, y: 0, z: 0 }, rotation: { z: 0 } };
  unit.healthBar = { material: { color: { setHex() {} } } };
  unit.body = { material: { emissive: { setHex() {} } } };
};
renderer.removeUnit = function (unit) {
  const i = units.indexOf(unit);
  if (i > -1) units.splice(i, 1);
  unit._engine = null;
  unit.mesh = null;
};
renderer.addBuilding = function (b) {
  const prev = buildings.indexOf(b);
  if (prev > -1) buildings.splice(prev, 1);
  buildings.push(b);
  b._engine = null;
  b.mesh = { visible: true, children: [] };
};
renderer.removeBuilding = function (b) {
  const i = buildings.indexOf(b);
  if (i > -1) buildings.splice(i, 1);
  b._engine = null;
  b.mesh = null;
};
game.renderer = renderer;

game.aiManager = new AIManager(game);
game.terrain = new TerrainManager(game);

// What the finished match says, when it ends on its own.
let arenaWinner = null;
let arenaReason = null;
game.ui = {
  showScreen() {},
  refreshActiveMenu() {},
  setupSeed: () => SEED,
  setupSpectatorUI() {},
  updateOpponentsPanel() {},
  refreshUnitInfo() {},
  updateResources() {},
  updateAge() {},
  showVictory() {},
  showDefeat() {},
  showArenaSummary(winner, reason) { arenaWinner = winner; arenaReason = reason; },
  hideFinalWordsWait() {},
  teardownSpectatorUI() {},
  finalWordsProgress() {},
};

game.startGame('spectator', SEATS);

// Positions serialise in millimetres as integers: the Rust port reproduces the
// same doubles up to libm ulps, and integers keep the byte diff exact.
const mm = v => Math.round(v * 1000);

// ------------------------------------------------------------------ record
(async () => {
  const rec = new TranscriptRecorder();
  const seats = game.aiManager.aiPlayers;
  await rec.begin('golden', seats.map(ai => ({
    id: ai.id, civilization: ai.civilization, seat: ai.seat, model: null,
    name: 'rule-brain', settings: { brain: 'rule-based' },
  })), {
    seed: SEED, difficulty: DIFFICULTY, seats: SEATS, minutes: MINUTES,
    stepMs: STEP_MS, snapshotMs: STEP_MS * SNAP_EVERY,
    simSpeed: 1, turnBased: false, resourceBoost: false, version: '1.0.0',
  });

  // The map's fingerprint: the seeded layout exactly as the match starts (after
  // Town Center clearance), one line before anything else happens. The Rust core's
  // first golden diff is this line, then the per-seat turn-1 state.
  rec.note('__map__', {
    type: 'map',
    seed: game.mapSeed,
    difficulty: game.difficulty,
    seats: SEATS,
    size: game.terrain.size,
    spawns: game.terrain.spawns.map(s => ({ x: mm(s.x), z: mm(s.z) })),
    resources: game.terrain.resources.map(r => ({
      t: r.type, x: mm(r.x), z: mm(r.z), a: r.amount, h: r.health,
    })),
  });

  const om = game.openAIAIManager;
  let endedAt = null;
  for (let s = 1; s <= TOTAL_STEPS; s++) {
    T += STEP_MS;
    game.tick();
    if (!game.gameStarted) { endedAt = T; break; }
    if (s % SNAP_EVERY === 0) {
      const seq = s / SNAP_EVERY;
      const states = seats.map(ai => om.buildGameStateJSON({ aiPlayer: ai, seat: {}, model: { language: 'en' } }));
      const tl = game._timeline;
      rec.note('__snap__', {
        type: 'snap', t: T, seq,
        world: {
          ages: tl && tl.ages ? tl.ages : [],
          exhausted: tl && tl.exhausted ? tl.exhausted : [],
          seats: seats.map(ai => ({
            seat: ai.seat, age: ai.age,
            population: ai.resources.population, maxPopulation: ai.resources.maxPopulation,
            units: ai.units.length, buildings: ai.buildings.length,
            eliminated: game.isPlayerEliminated ? game.isPlayerEliminated(ai) : false,
          })),
        },
      });
      seats.forEach((ai, i) => {
        rec.record(ai.id, { state: states[i] });
        rec.noteResult(ai.id, null);
      });
    }
  }

  // Let the end-of-match bookkeeping (collectFinalWords' promise chain) settle
  // before the tail is cut, so the captured winner is the final one.
  for (let i = 0; i < 5; i++) await new Promise(r => setImmediate(r));

  const count = (list) => list.reduce((m, x) => { m[x.type] = (m[x.type] || 0) + 1; return m; }, {});
  const results = {
    type: 'results',
    endedAt,
    endedReason: endedAt ? (arenaReason || 'elimination') : 'time-limit',
    winner: arenaWinner ? { seat: arenaWinner.seat, civ: arenaWinner.civilization } : null,
    seats: seats.map(ai => ({
      seat: ai.seat, civ: ai.civilization, age: ai.age,
      eliminated: game.isPlayerEliminated ? game.isPlayerEliminated(ai) : false,
      population: ai.resources.population, maxPopulation: ai.resources.maxPopulation,
      resources: {
        food: Math.floor(ai.resources.food), wood: Math.floor(ai.resources.wood),
        stone: Math.floor(ai.resources.stone), gold: Math.floor(ai.resources.gold),
      },
      units: count(ai.units), buildings: count(ai.buildings),
    })),
  };
  rec.finish([results, { type: 'timeline', timeline: game._timeline || null }]);
  await new Promise(r => setImmediate(r));

  // ----------------------------------------------------------------- write
  // The recorder buffers every line it wrote; pull them out verbatim and
  // interleave by beat (one __snap__ line, then that beat's per-seat lines).
  const header = rec.pending.get(TranscriptRecorder.MATCH_KEY());
  const map = rec.pending.get('__map__') || [];
  const snap = rec.pending.get('__snap__') || [];
  const seatLines = seats.map(ai => rec.pending.get(ai.id) || []);
  const tail = rec.pending.get(TranscriptRecorder.SUMMARY_KEY()) || [];
  if (!header || !header.length) throw new Error('recorder produced no match header');
  const out = [header[0], ...map];
  for (let k = 0; k < snap.length; k++) {
    out.push(snap[k]);
    for (const buf of seatLines) out.push(buf[k]);
  }
  out.push(...tail);

  const dest = path.resolve(OUT);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, out.join('\n') + '\n');
  console.error(`golden: ${dest}`);
  console.error(`  ${out.length} lines = 1 match + ${snap.length} snap + ${seatLines.reduce((n, b) => n + b.length, 0)} turn + ${tail.length} tail`);
  console.error(`  seed=${SEED} seats=${SEATS} difficulty=${DIFFICULTY} minutes=${MINUTES}`);
  console.error(`  ended: ${endedAt ? `${endedAt}ms (${arenaReason})` : `${MINUTES}m limit`}${arenaWinner ? ` winner=seat ${arenaWinner.seat} (${arenaWinner.civilization})` : ''}`);
  for (const ai of seats) {
    console.error(`  seat ${ai.seat} ${ai.civilization}: age=${ai.age} pop=${ai.resources.population}/${ai.resources.maxPopulation} units=${ai.units.length} buildings=${ai.buildings.length} eliminated=${game.isPlayerEliminated ? game.isPlayerEliminated(ai) : false}`);
  }
})().catch(e => { console.error('record.cjs failed:', e && e.stack || e); process.exit(1); });
