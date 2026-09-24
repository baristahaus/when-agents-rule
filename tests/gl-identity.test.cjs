// The renderer identity a result gets read against has to survive every kind of machine.
//
// GLCore.describeContext writes the GPU name into the transcript header, next to mapSeed, because
// the renderer sets the frame cadence and the cadence sets how many simulation steps a turn
// contains (21 fps under software rasterisation against 60 on the installed card, on this build).
// It runs on startup on every machine the game boots on, so it must never throw and must never
// write `undefined` into a file — and it has to answer something useful on the browsers that hide
// WEBGL_debug_renderer_info as a fingerprinting surface, which is most of them by default.
//
// Each case below is a real deployment shape, not a defensive flourish.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// glcore.js publishes itself onto `window` at load, as every shipped script here does.
const scope = { window: {}, console: { log() {}, warn() {}, error() {}, info() {} },
  Math, JSON, Object, Array, String, Number, Boolean, Set, Map, RegExp, Error };
vm.createContext(scope);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'js', 'engine', 'glcore.js'), 'utf8'), scope, { filename: 'js/engine/glcore.js' });
const GLCore = scope.window.GLCore;   // the file is an IIFE that publishes itself onto window

const EMPTY = { renderer: null, vendor: null, version: null, maxTextureSize: null };

test('no context at all still answers with the documented shape', () => {
  assert.deepEqual({ ...GLCore.describeContext(null) }, EMPTY);
  assert.deepEqual({ ...GLCore.describeContext(undefined) }, EMPTY);
});

test('without the debug extension it falls back to the core parameters', () => {
  // The common case: RENDERER/VERSION are core WebGL, UNMASKED_* are the optional surface.
  const gl = {
    RENDERER: 0x1f01, VENDOR: 0x1f00, VERSION: 0x1f02, MAX_TEXTURE_SIZE: 0x0d33,
    getExtension: () => null,
    getParameter: (p) => ({ 0x1f01: 'WebKit WebGL', 0x1f00: 'WebKit', 0x1f02: 'WebGL 1.0', 0x0d33: 8192 })[p],
  };
  assert.deepEqual({ ...GLCore.describeContext(gl) },
    { renderer: 'WebKit WebGL', vendor: 'WebKit', version: 'WebGL 1.0', maxTextureSize: 8192 });
});

test('the unmasked renderer wins when the browser exposes it', () => {
  const gl = {
    RENDERER: 0x1f01, VENDOR: 0x1f00, VERSION: 0x1f02, MAX_TEXTURE_SIZE: 0x0d33,
    getExtension: (n) => (n === 'WEBGL_debug_renderer_info' ? { UNMASKED_RENDERER_WEBGL: 0x9245, UNMASKED_VENDOR_WEBGL: 0x9246 } : null),
    getParameter: (p) => ({
      0x1f01: 'WebKit WebGL', 0x1f00: 'WebKit', 0x1f02: 'WebGL 1.0', 0x0d33: 16384,
      0x9245: 'ANGLE (AMD, Vulkan 1.4.354 (AMD Radeon AI PRO R9700 (RADV GFX1201)), radv)',
      0x9246: 'Google Inc. (AMD)',
    })[p],
  };
  const d = GLCore.describeContext(gl);
  assert.match(d.renderer, /R9700/, 'the whole point is to record the real device, not "WebKit WebGL"');
  assert.equal(d.maxTextureSize, 16384);
});

test('an extension that throws, or answers nothing, cannot take the boot down', () => {
  const throwing = {
    RENDERER: 0x1f01, VENDOR: 0x1f00, VERSION: 0x1f02, MAX_TEXTURE_SIZE: 0x0d33,
    getExtension: () => { throw new Error('blocked by the browser'); },
    getParameter: (p) => (p === 0x1f01 ? 'ANGLE (Software)' : undefined),
  };
  const d = GLCore.describeContext(throwing);
  assert.equal(d.renderer, 'ANGLE (Software)', 'the fallback still has to be read when getExtension explodes');
  assert.equal(d.vendor, null, 'a parameter the driver will not name is null, not undefined');
  assert.equal(Object.prototype.hasOwnProperty.call(d, 'maxTextureSize'), true);
  assert.equal(d.maxTextureSize, null);

  // getParameter itself throwing is the other half: a diagnostic must never become the failure.
  const hostile = { getExtension: () => null, getParameter: () => { throw new Error('context gone'); } };
  assert.deepEqual({ ...GLCore.describeContext(hostile) }, EMPTY);
});
