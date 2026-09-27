#!/usr/bin/env node
'use strict';
// ---------------------------------------------------------------------------
// Golden comparator.
//
// Two runs of tools/golden/record.cjs on the SAME conditions must be
// indistinguishable, except for the one place v1 deliberately does not seed:
// the session-unique seat ids, minted from Math.random (js/ai.js:34) so a
// reloaded page can never confuse this match's transcript with the last
// match's. tests/match-determinism.test.cjs pins that allowlist.
//
// So this re-keys each run's seat ids to canonical names BY SEAT INDEX (the
// seat order is deterministic — spawn order is civ order, and nothing between
// the two runs may reorder it), and then compares the streams line for
// line. A clean run prints the line count and exits 0; any divergence is
// reported as a JSON path on the first differing line(s) and exits 1.
//
//   node tools/golden/compare.cjs samples/golden/easy/golden-10m.jsonl \
//                                samples/golden/easy/golden-10m-b.jsonl
// ---------------------------------------------------------------------------
const fs = require('node:fs');

if (process.argv.length < 4) {
  console.error('usage: compare.cjs <golden-a.jsonl> <golden-b.jsonl>');
  process.exit(2);
}
const [FILE_A, FILE_B] = [process.argv[2], process.argv[3]];

function parseAll(file) {
  const lines = fs.readFileSync(file, 'utf8').split('\n').filter(l => l.length > 0);
  return lines.map((l, i) => {
    try { return JSON.parse(l); }
    catch (e) { throw new Error(`${file}:${i + 1} is not a JSON line: ${e.message}`); }
  });
}
const a = parseAll(FILE_A);
const b = parseAll(FILE_B);

// The header (type:'match') names every seat; its player list is in seat
// order, so the re-key table is seat-index -> canonical id.
function rekeyTable(lines) {
  const header = lines[0];
  if (!header || header.type !== 'match') throw new Error('first line is not the match header');
  const table = new Map();
  (header.players || []).forEach(p => table.set(p.id, `seat${p.seat}`));
  return table;
}
const tableA = rekeyTable(a);
const tableB = rekeyTable(b);

// Sanity, not a gate: v1 mints the ids from Math.random, so two independent
// runs should produce disjoint id spaces. If they ever collide, the re-key
// below is still correct (it is keyed by seat, not by value) — but the
// "ids are session-unique" invariant the schema relies on would be broken.
const idsA = new Set(tableA.keys());
const idsB = new Set(tableB.keys());
const overlap = [...idsA].filter(id => idsB.has(id));
if (overlap.length) {
  console.error(`note: seat id spaces overlap between runs (${overlap.length} shared) — v1's Math.random id minting is expected to keep them disjoint`);
}

function rekeyDeep(v, table) {
  if (typeof v === 'string') return table.has(v) ? table.get(v) : v;
  if (Array.isArray(v)) return v.map(x => rekeyDeep(x, table));
  if (v && typeof v === 'object') {
    const out = {};
    for (const [k, val] of Object.entries(v)) out[table.has(k) ? table.get(k) : k] = rekeyDeep(val, table);
    return out;
  }
  return v;
}
const aN = a.map(l => rekeyDeep(l, tableA));
const bN = b.map(l => rekeyDeep(l, tableB));

if (aN.length !== bN.length) {
  console.error(`MISMATCH: ${aN.length} lines in ${FILE_A} vs ${bN.length} in ${FILE_B}`);
  process.exit(1);
}

// Cheap whole-line compare first; on a mismatch, structural paths.
function diffPaths(x, y, p, out, max) {
  if (out.length >= max) return;
  if (x === y) return;
  if (x === null || y === null || typeof x !== typeof y || (typeof x !== 'object' && typeof y !== 'object')) {
    out.push(`${p || '$'}: ${JSON.stringify(x)} != ${JSON.stringify(y)}`);
    return;
  }
  if (Array.isArray(x) !== Array.isArray(y)) {
    out.push(`${p || '$'}: array vs object`);
    return;
  }
  if (Array.isArray(x)) {
    if (x.length !== y.length) out.push(`${p || '$'}.length: ${x.length} != ${y.length}`);
    const n = Math.min(x.length, y.length);
    for (let i = 0; i < n; i++) diffPaths(x[i], y[i], `${p || '$'}[${i}]`, out, max);
    return;
  }
  const kx = Object.keys(x), ky = Object.keys(y);
  for (const k of kx) if (!ky.includes(k)) out.push(`${p ? p + '.' : ''}${k}: present only in first file`);
  for (const k of ky) if (!kx.includes(k)) out.push(`${p ? p + '.' : ''}${k}: present only in second file`);
  for (const k of kx) if (ky.includes(k)) diffPaths(x[k], y[k], p ? `${p}.${k}` : k, out, max);
}

let bad = 0;
const MAX_DIFFS = 40;
for (let i = 0; i < aN.length; i++) {
  if (JSON.stringify(aN[i]) === JSON.stringify(bN[i])) continue;
  bad++;
  if (bad > 4) { console.error(`  ... and ${aN.length - i + 4 - 5} more differing lines`); break; }
  const out = [];
  diffPaths(aN[i], bN[i], `$[line ${i + 1}]`, out, MAX_DIFFS);
  console.error(`line ${i + 1} (${aN[i].type || '?'}) differs:`);
  for (const d of out) console.error(`  ${d}`);
}

if (bad === 0) {
  console.error(`IDENTICAL: ${aN.length} lines, ${a[0].players.length} seats, seed ${a[0].seed}`);
  process.exit(0);
}
console.error(`MISMATCH: ${bad}+ of ${aN.length} lines differ (first ${Math.min(bad, 4)} shown above)`);
process.exit(1);
