// The engine must STOP drawing when the GPU takes the context away.
//
// Two properties are worth pinning here rather than trusting, because both are one line of
// reordering away from silently failing, and neither fails loudly when it breaks:
//
//  - the guard in animate() has to run BEFORE the loop reschedules itself and before it
//    touches anything else. Placed after the `requestAnimationFrame` call — which is where
//    an innocent-looking "return early" refactor puts it — the loop never dies, and the
//    visible symptom is only a permanently black canvas plus a tab that will not idle.
//  - handleContextLost() has to call preventDefault(). A context the browser thinks nobody
//    claimed is never offered back, so forgetting it also closes the door on recovery.
//
// Only prototype methods are exercised, so no canvas, no GL context and no page: the whole
// point is that these two behave the same whether or not a renderer was ever built.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const src = fs.readFileSync(path.join(__dirname, '..', 'js', 'engine', 'gamerenderer.js'), 'utf8');
const scheduled = [];
const sandbox = vm.createContext({
  window: {},
  // The engine reads three of TexGen's constants the moment its file loads (gamerenderer.js:44
  // — terrain extents, used to size the ground plane). None of them reach the two methods
  // under test, so they are named rather than real; everything else the engine uses it looks
  // up lazily through window, which is why no canvas or GL context is needed here.
  TexGen: { TERRAIN_SEED: 1, TERRAIN_WORLD: { w: 800, h: 800 }, TERRAIN_LAND: { w: 700, h: 700 } },
  document: { createElement: () => ({ style: {}, addEventListener() {}, appendChild() {} }), getElementById: () => null },
  performance: { now: () => 0 },
  requestAnimationFrame: (fn) => { scheduled.push(fn); return scheduled.length; },
  cancelAnimationFrame: () => {},
  console: { log() {}, warn() {}, error() {} },
  Math, Date, JSON, Object, Array, Number, String, Boolean, Error, Map, Set, Promise, RegExp, isNaN, parseFloat, parseInt,
});
vm.runInContext(src, sandbox);
const EngineRenderer = sandbox.window.EngineRenderer;

test('every loss is claimed, but only the first one is reported', () => {
  let prevented = 0;
  const event = { preventDefault: () => { prevented++; } };
  const r = { _contextLost: false };

  assert.equal(EngineRenderer.prototype.handleContextLost.call(r, event), true, 'the first loss must report itself, so the caller shows a notice');
  assert.equal(prevented, 1, 'not calling preventDefault tells the browser nobody owns the loss, and it stops offering the context back');
  assert.equal(r._contextLost, true, 'the flag is what the draw loop reads');

  // Claiming is per-event, reporting is per-session: a second loss after a restore is a new
  // event that has to be answered on its own terms even though our state has not changed,
  // while the user already has a banner that says exactly what happened.
  assert.equal(EngineRenderer.prototype.handleContextLost.call(r, event), false, 'a repeat must stay quiet — one notice, not two');
  assert.equal(prevented, 2, 'the repeat still has to be claimed');
});

test('a lost loop schedules no further frame and does no work at all', () => {
  // Any property read besides the flag means animate() got past the guard and started
  // drawing: this `this` has no camera, no GL, no terrain to draw with.
  const strict = new Proxy({ _contextLost: true }, {
    get: (t, k) => {
      if (k === '_contextLost') return t._contextLost;
      throw new Error('the draw loop did work after the context was lost: read ' + String(k));
    },
  });
  const before = scheduled.length;
  EngineRenderer.prototype.animate.call(strict);
  assert.equal(scheduled.length, before, 'the reschedule must not happen');
});

test('a healthy loop still reschedules itself before it starts drawing', () => {
  // The counter-party to the guard above: if animate() ever stops rescheduling early, the
  // second test would pass for the wrong reason and the game would be a still image.
  const before = scheduled.length;
  try {
    EngineRenderer.prototype.animate.call({ _contextLost: false });
  } catch (e) {
    // Expected — there is no GL or camera behind this `this`. What matters is that it got
    // far enough to prove the loop continues.
  }
  assert.equal(scheduled.length, before + 1, 'a live loop must queue exactly one next frame');
});
