#!/usr/bin/env node
'use strict';
// ---------------------------------------------------------------------------
// Canonicalise a per-seat state fixture.
//
// `golden/turn1-b1040.jsonl` is a capture from the reference implementation, and it is therefore
// byte-exact except where v1 refuses to be deterministic on purpose: seat ids are minted from
// `Math.random` (js/ai.js, and `tests/match-determinism.test.cjs` pins that exemption) so a
// reloaded page can never confuse this match's transcript with the last one's. The ids are in the
// fixture, so the fixture cannot be reproduced byte for byte by *anything* — not the JS replaying
// the same seed, not a port, not the recorder run twice.
//
// That is not a defect to fix in the game; it is a property of what the fixture means. But it does
// mean a naive byte-diff would declare the turn-1 gate impossible, so here is the canonical form:
// every seat id replaced by `seat<index>`, exactly the re-key `tools/golden/compare.cjs` uses
// between two recorded runs. A port compares against THIS file; the raw capture stays as recorded,
// for provenance, and `tests/golden-fixtures.test.cjs` keeps the pair in step.
//
//   node tools/golden/canonicalize-states.cjs golden/turn1-b1040.jsonl > golden/turn1-b1040.canonical.jsonl
// ---------------------------------------------------------------------------
const fs = require('node:fs');

const src = process.argv[2] || '-';
const text = src === '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(src, 'utf8');
// The fixture's own lines carry the seat index, so the table needs no header.
const lines = text.split('\n').filter(l => l.trim());
const table = new Map();
for (const l of lines) {
  const rec = JSON.parse(l);
  if (rec.playerId !== undefined && rec.seat !== undefined) table.set(rec.playerId, `seat${rec.seat}`);
}
if (!table.size) throw new Error(`${src}: no line has both playerId and seat, so nothing can be re-keyed`);

// Entity ids are minted the same way seat ids are — Math.random, session-unique — so a fixture
// that carries `u_a91xk2` cannot be diffed either. They get canonical names in first-appearance
// order, which is deterministic because the state is: the same run twice produces the same names,
// and two runs that disagree in the mirror disagree in the rules, which is the whole point.
const minted = new Map();
function mint(id) {
  if (minted.has(id)) return minted.get(id);
  const kind = id.slice(0, id.indexOf('_'));
  const n = [...minted.values()].filter(v => v.startsWith(kind.toUpperCase())).length;
  const name = `${kind.toUpperCase()}${n}`;
  minted.set(id, name);
  return name;
}
const SESSION_ID = /^(ai|u|m|e|b|s)_[a-z0-9]{5,}$/;

function rekey(v) {
  if (typeof v === 'string') {
    if (table.has(v)) return table.get(v);
    if (SESSION_ID.test(v)) return mint(v);
    return v;
  }
  if (Array.isArray(v)) return v.map(rekey);
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v)) out[k] = rekey(v[k]);
    return out;
  }
  return v;
}

for (const l of lines) {
  process.stdout.write(JSON.stringify(rekey(JSON.parse(l))) + '\n');
}
