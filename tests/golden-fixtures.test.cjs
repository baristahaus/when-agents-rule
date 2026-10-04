// The golden corpus is the contract of the RULES, not of any one implementation.
//
// It used to live under `rust/core/golden/`, which quietly made a Rust-directory artifact
// the reference for a JavaScript game. The port is retired (spec §14), the fixtures are not:
// they are what any future core — Odin, Rust, a second JS pass — is measured against, and
// they cost a 10-minute recording to regenerate. So they live in `golden/` now, with their
// hashes written down, and this test is the reason nobody can change them by accident.
//
// Three things are checked, weakest first: the bytes are the bytes we agreed on; the map
// line really carries 942 nodes and the turn-1 file really holds four seats; and the two
// keyed vectors can still be *produced* by the shipping rules, which is the property that
// matters — a fixture nobody can regenerate is a rumor, not a gate.
'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const G = f => path.join(root, 'golden', f);
const manifest = JSON.parse(fs.readFileSync(G('MANIFEST.json'), 'utf8'));

const sha256 = f => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');

test('every file in the golden manifest is the byte sequence we pinned', () => {
  const problems = [];
  for (const [name, pin] of Object.entries(manifest.files)) {
    const f = path.resolve(root, name);
    if (!fs.existsSync(f)) { problems.push(`${name}: missing`); continue; }
    const bytes = fs.statSync(f).size;
    if (bytes !== pin.bytes) problems.push(`${name}: ${bytes} bytes, pinned ${pin.bytes}`);
    const hash = sha256(f);
    if (hash !== pin.sha256) problems.push(`${name}: sha256 ${hash.slice(0, 16)}…, pinned ${pin.sha256.slice(0, 16)}…`);
  }
  assert.deepEqual(problems, [], 'the golden moved. Re-deriving it is a decision with a section\n' +
    '  in docs/CORE-REPLAN.md and a line in MERGE-STATE.MD — it is not a side effect of a commit.\n' +
    `  ${problems.join('\n  ')}`);
});

test('the map line is the map: 942 nodes, and it parses as the reference map record', () => {
  const rec = JSON.parse(fs.readFileSync(G('map-line-b1040.json'), 'utf8'));
  assert.equal(rec.type, 'map');
  assert.equal(rec.seed, manifest.seed);
  assert.equal(rec.difficulty, manifest.difficulty);
  assert.equal(rec.seats, manifest.seats);
  // The reference world at b1040: 942 nodes, coordinates in integer millimetres, all inside
  // the coast (§3.4's "~77 units from the centre" is generous; the measured max is 60).
  assert.equal(rec.resources.length, 942, 'the reference world at b1040 has 942 resource nodes');
  for (const n of rec.resources) {
    assert.ok(Number.isInteger(n.x) && Number.isInteger(n.z), `node not in whole millimetres: ${JSON.stringify(n)}`);
    assert.ok(Math.abs(n.x) <= 100000 && Math.abs(n.z) <= 100000, `node far outside the island: ${JSON.stringify(n)}`);
    assert.ok(['food', 'wood', 'stone', 'gold'].includes(n.t), `node of unknown kind: ${JSON.stringify(n)}`);
  }
});

test('the turn-1 file holds one state per seat, degenerate exactly as §3.4 says', () => {
  const lines = fs.readFileSync(G('turn1-b1040.jsonl'), 'utf8').split('\n').filter(l => l.trim());
  assert.equal(lines.length, 4, 'one line per seat');
  const seen = new Set();
  for (const l of lines) {
    const r = JSON.parse(l);
    seen.add(r.seat);
    assert.ok(typeof r.playerId === 'string' && r.playerId.length > 0, 'the header player id is present');
    assert.ok(typeof r.state.player.civilization === 'string' && r.state.player.civilization.length > 0,
      'the seat has a civilization; age is not a turn-1 field and is asserted nowhere');
    assert.equal(r.state.clock.matchSeconds, 1,
      'the clock reads 1, not 0: 0 was the build 934-949 bug that build 950 fixed (spec §3.4)');
    assert.deepEqual({ ...r.state.resources }, { food: 200, wood: 200, stone: 100, gold: 50 },
      'the opening stockpile is 200/200/100/50');
    assert.equal(r.state.friendlyUnits.length, 3, 'three starting workers');
    // The positions are the keyed draw's output: the one part of turn 1 the map seed alone
    // does not decide, and the reason rust/core/src/prng.rs grew KeyedRng (S1).
    for (const u of r.state.friendlyUnits) {
      assert.equal(u.type, 'worker');
      assert.ok(Number.isFinite(u.x) && Number.isFinite(u.z));
    }
  }
  assert.deepEqual([...seen].sort(), [0, 1, 2, 3]);
});

test('the shipping rules still produce the keyed vectors a new core must match', () => {
  const WarRng = require('../js/simulation/rng.js');
  const st = WarRng.keyed(manifest.seed);
  const key = 's0:start-workers';
  const got = [WarRng.draw(st, key), WarRng.draw(st, key)];
  const want = [manifest.keyedVectors[key + '#0'], manifest.keyedVectors[key + '#1']];
  assert.deepEqual(got, want,
    `the reference prints ${JSON.stringify(got)} where the manifest pinned ${JSON.stringify(want)}`);
  // The property that made the keyed design worth porting at all: another key, drawn in
  // between, must not move this key's next value.
  const a = WarRng.keyed(manifest.seed), b = WarRng.keyed(manifest.seed);
  WarRng.draw(a, key); WarRng.draw(b, key);
  WarRng.draw(b, 's3:scout-target'); WarRng.draw(b, 's3:scout-target');
  assert.equal(WarRng.draw(a, key), WarRng.draw(b, key),
    'a draw on another key moved this key: the invariance the whole determinism story rests on is gone');
});
