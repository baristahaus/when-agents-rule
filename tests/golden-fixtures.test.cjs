// The golden corpus is the contract of the RULES, not of any one implementation.
//
// It used to live under `rust/core/golden/`, which quietly made a Rust-directory artifact
// the reference for a JavaScript game. The port is retired (spec §14), the fixtures are not:
// they are what any future core — Odin, Rust, a second JS pass — is measured against, and
// they cost a 10-minute recording to regenerate. So they live in `golden/` now, with their
// hashes written down, and this test is the reason nobody can change them by accident.
//
// Three things are checked, weakest first: the bytes are the bytes we agreed on; the map
// line really carries 941 nodes (post Town Center clearance) and the turn-1 file
// really holds four seats; and the two
// keyed vectors can still be *produced* by the shipping rules, which is the property that
// matters — a fixture nobody can regenerate is a rumor, not a gate.
'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto'), cp = require('node:child_process');
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

test('the map line is the map: 941 nodes post-clearance, and it parses as the reference map record', () => {
  const rec = JSON.parse(fs.readFileSync(G('map-line-b1040.json'), 'utf8'));
  assert.equal(rec.type, 'map');
  assert.equal(rec.seed, manifest.seed);
  assert.equal(rec.difficulty, manifest.difficulty);
  assert.equal(rec.seats, manifest.seats);
  // The reference world at b1040, re-recorded 5 Oct 2026 at the true 800-unit size (the recorder
  // had generated a 200-unit island by omitting the terrain size argument): 941 nodes — the
  // scatter's 942 minus one wood node the Town Center clearance removed — in integer
  // millimetres, all inside the usable box (measured max ~354 units from the centre).
  assert.equal(rec.resources.length, 941, 'the reference world at b1040 has 941 resource nodes, post Town Center clearance');
  for (const n of rec.resources) {
    assert.ok(Number.isInteger(n.x) && Number.isInteger(n.z), `node not in whole millimetres: ${JSON.stringify(n)}`);
    assert.ok(Math.abs(n.x) <= 360000 && Math.abs(n.z) <= 360000, `node far outside the map: ${JSON.stringify(n)}`);
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

test('the turn-1 fixture has a canonical form, and it is the one a port is diffed against', () => {
  // v1 mints seat ids from Math.random on purpose (a reloaded page must never read the previous
  // match's transcript), so the captured fixture cannot be byte-reproduced by anything — not a
  // replay, not a port, not the recorder twice. Without a canonical form the turn-1 gate would be
  // unpassable rather than hard; with one, the ids are the only thing that differs.
  const raw = fs.readFileSync(G('turn1-b1040.jsonl'), 'utf8').split('\n').filter(l => l.trim());
  const canonical = fs.readFileSync(G('turn1-b1040.canonical.jsonl'), 'utf8').split('\n').filter(l => l.trim());
  assert.equal(canonical.length, raw.length);
  const again = cp.execFileSync('node', [path.join(root, 'tools/golden/canonicalize-states.cjs'), G('turn1-b1040.jsonl')]).toString();
  assert.equal(again, canonical.join('\n') + '\n',
    'the checked-in canonical form has drifted from the raw capture it is derived from');
  // This file is a capture, not a regeneration: the reference today does not reproduce it (clock
  // reads 1 while the unit positions are the opening ones, and the vision fields differ). It stays
  // pinned and structurally checked, and it is NOT what a port is diffed against — see
  // states-b1040-t0-t1.canonical.jsonl above. Any port that matched it would be suspicious.
  for (const l of canonical) {
    const r = JSON.parse(l);
    assert.equal(r.playerId, `seat${r.seat}`, 'a canonical line still carries a session id');
    assert.equal(r.state.clock.matchSeconds, 1);
  }
  for (const l of raw) {
    const r = JSON.parse(l);
    assert.notEqual(r.playerId, `seat${r.seat}`,
      'the raw capture was edited to look canonical — it must stay exactly as recorded, for provenance');
  }
});

test('the state fixture regenerates byte-identically from the reference', () => {
  // This is the fixture a core is diffed against for the turn-1 gate, so the property that
  // matters is not its contents but its origin: dump the reference twice and the bytes must agree.
  // If this ever goes red, a rule changed under the fixture — which is a decision to re-record,
  // with a line in MERGE-STATE.MD, not a hash to update quietly.
  const pinned = fs.readFileSync(G('states-b1040-t0-t1.canonical.jsonl'), 'utf8');
  const dump = cp.execFileSync('node', [
    path.join(root, 'tools/golden/dump-states.cjs'),
    '-seed', 'golden', '-difficulty', 'medium',
    '-civs', 'egyptian,greek,persian,yamato', '-at', '0,1000',
  ], { maxBuffer: 64 * 1024 * 1024 }).toString();
  const again = cp.execFileSync('node', [path.join(root, 'tools/golden/canonicalize-states.cjs')],
    { input: dump }).toString();
  assert.equal(again, pinned, 'the reference no longer reproduces the pinned state fixture');
  const lines = pinned.split('\n').filter(l => l.trim()).map(l => JSON.parse(l));
  assert.equal(lines.length, 8, 'four seats at two moments');
  for (const r of lines) {
    assert.equal(r.playerId, `seat${r.seat}`);
    assert.equal(r.state.player.civilizationName.length > 0, true);
    // The language is part of the fixture, not a display detail: civilizationName is a translated
    // string inside the state view, and a dumper that inherits the host locale produces German.
    assert.equal(r.state.player.civilizationName,
      { egyptian: 'Egyptians', greek: 'Greeks', persian: 'Persians', yamato: 'Yamato' }[r.state.player.civilization]);
    assert.deepEqual({ ...r.state.resources }, { food: 200, wood: 200, stone: 100, gold: 50 });
    assert.equal(r.state.friendlyUnits.length, 3);
    assert.equal(r.state.clock.matchSeconds, r.t / 1000, 'the clock must read the moment dumped');
  }
});

test('the legacy turn-1 capture is kept as recorded, not as an oracle', () => {
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
