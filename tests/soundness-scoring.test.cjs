// The strategy score must not charge a seat for the harness's own failures.
//
// successRate / formatOk / reliability / reasonRate are null when there was nothing to
// divide — no scored action, no answer, no request — all three of which are caused by the
// harness (a cut request, a context overflow, a turn the rate limit ate) rather than by the
// model. When they read 0, the weights said otherwise: the three model-quality terms sum to
// 0.67, so a seat the harness never let speak topped out at 33/100 no matter how it played.
// An unknown term now drops out and the rest re-normalise over what is known.
//
// computeSoundness is loaded from the shipped file rather than reimplemented here: the whole
// point is that the number the app publishes is the number this describes.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ui = fs.readFileSync(path.join(__dirname, '..', 'js', 'ui.js'), 'utf8');
const sandbox = vm.createContext({
  window: {},
  document: { createElement: () => ({ style: {}, classList: { add() {}, remove() {} }, addEventListener() {}, appendChild() {} }),
              getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
              body: { classList: { add() {}, remove() {} } }, documentElement: { style: {} }, addEventListener() {} },
  navigator: { language: 'en' },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  requestAnimationFrame: () => 0, cancelAnimationFrame() {}, setTimeout, clearTimeout, setInterval, clearInterval,
  console: { log() {}, warn() {}, error() {} },
  Math, Date, JSON, Object, Array, Number, String, Boolean, Error, Map, Set, Promise, RegExp,
  isFinite, isNaN, parseFloat, parseInt, encodeURIComponent, decodeURIComponent, performance,
});
vm.runInContext(ui, sandbox);
// `t` is looked up at call time; stubbing it means tags are compared by KEY, so the
// assertions do not move when a translation does.
sandbox.t = (k) => k;
// UIManager is a top-level `class`, which is a lexical binding — visible to code running
// inside the context, not as a property of the global object.
const UIManager = vm.runInContext('UIManager', sandbox);
const uiProto = UIManager.prototype;
const view = (m) => Object.create(uiProto);

const W = { success: 0.34, progression: 0.20, format: 0.18, reliability: 0.15, diversity: 0.13 };

// A seat in the late game, six distinct actions, every term judgeable.
const metrics = (over) => Object.assign({
  successRate: 0.9, formatOk: 0.95, reliability: 0.98, reasonRate: 0.8,
  actionCounts: { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6 },
  attempted: 40, succeeded: 36, responded: 30, decisions: 34, timeouts: 0, networkErrors: 0,
  parseFails: 1, invalidActions: 0, roundsMissed: 0, avgLatency: 4000, silentMs: 0,
}, over);
const lateGame = { ageIdx: 3, buildings: 6, military: 10 };
const scoreOf = (m, game) => uiProto.computeSoundness.call(view(m), Object.assign({ metrics: m }, game || lateGame));

test('a fully judged seat still scores the published weighted sum', () => {
  const m = metrics({});
  const documented = 100 * (W.success * m.successRate + W.progression * 1 + W.format * m.formatOk
                          + W.reliability * m.reliability + W.diversity * 1);
  assert.equal(scoreOf(m), Math.round(documented), 're-normalising must be a no-op when nothing is missing');
});

test('a seat the harness never asked is scored on what it did, not docked for the silence', () => {
  const m = metrics({ successRate: null, formatOk: null, reliability: null, reasonRate: null });
  // Only progression (1.0) and diversity (1.0) are known, so they carry the whole score.
  assert.equal(scoreOf(m), 100, '0.20 + 0.13 re-normalised over themselves is the full range');
  // What the old code did with the same seat: the three unknowns counted as zeros.
  const docked = Math.round(100 * (W.progression * 1 + W.diversity * 1));
  assert.equal(docked, 33, 'and that is the number a seat used to get for playing a full game');
});

test('one missing term re-normalises the other four', () => {
  const m = metrics({ formatOk: null });
  const known = W.success + W.progression + W.reliability + W.diversity;
  const expected = Math.round(100 * (W.success * m.successRate + W.progression + W.reliability * m.reliability
                                   + W.diversity) / known);
  assert.equal(scoreOf(m), expected);
  assert.notEqual(scoreOf(m), Math.round(100 * (W.success * m.successRate + W.progression + W.reliability * m.reliability + W.diversity)),
    'treating the unknown as a zero has to be a different number, or the fix did nothing');
});

test('the score stays an integer inside its stated range when nothing at all is known', () => {
  const m = metrics({ successRate: null, formatOk: null, reliability: null, actionCounts: {} });
  const s = scoreOf(m, { ageIdx: 0, buildings: 0, military: 0 });
  assert.equal(typeof s, 'number');
  assert.ok(Number.isInteger(s) && s >= 0 && s <= 100, 'got ' + s);
  assert.equal(s, 0, 'no evidence of judgement and no evidence of play is the bottom of the scale');
});

test('a rate with no denominator renders as an absence, in both exports', () => {
  const u = view(metrics({}));
  assert.equal(uiProto.pct.call(u, null), '—', 'the on-screen metric says "no measurement"');
  assert.equal(uiProto.pct.call(u, null, 'n/a'), 'n/a', 'the markdown export says it in words');
  assert.equal(uiProto.pct.call(u, 0.937), '94%');
  assert.equal(uiProto.pct.call(u, 0), '0%', 'a measured zero must still read as zero');
});

test('an unjudged success rate must not read as failure', () => {
  // null < 0.5 is true in JS — the trap this pins.
  const silent = uiProto.computeBehaviorTags.call(view(), { metrics: metrics({
    attempted: 5, succeeded: 0, successRate: null, responded: 0, formatOk: null,
  }) });
  assert.equal(silent.some((x) => x.t === 'tag.manyFails'), false, 'nothing was scored, so nothing failed');

  const failing = uiProto.computeBehaviorTags.call(view(), { metrics: metrics({ attempted: 5, succeeded: 1, successRate: 0.2 }) });
  assert.ok(failing.some((x) => x.t === 'tag.manyFails'), 'a measured 20% still earns the tag');
});
