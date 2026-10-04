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

const src = process.argv[2];
if (!src) {
  console.error('usage: canonicalize-states.cjs <states.jsonl>   (prints to stdout)');
  process.exit(2);
}

// The fixture's own lines carry the seat index, so the table needs no header.
const lines = fs.readFileSync(src, 'utf8').split('\n').filter(l => l.trim());
const table = new Map();
for (const l of lines) {
  const rec = JSON.parse(l);
  if (rec.playerId !== undefined && rec.seat !== undefined) table.set(rec.playerId, `seat${rec.seat}`);
}
if (!table.size) throw new Error(`${src}: no line has both playerId and seat, so nothing can be re-keyed`);

function rekey(v) {
  if (typeof v === 'string') return table.has(v) ? table.get(v) : v;
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
