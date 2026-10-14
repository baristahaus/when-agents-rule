#!/usr/bin/env node
'use strict';
// ---------------------------------------------------------------------------
// The analyzer's CLI (P3 the eyes): the report, the A/B view, the chain.
//
//   node tools/analyze.cjs report <folder>            one match, everything
//   node tools/analyze.cjs ab <folderA> <folderB>     two matches, the diff
//   node tools/analyze.cjs chain <folder> [type]      why did this happen
//
// A folder is what the core writes: meta.json (the conditions), transcript.jsonl
// (the canonical stream: match, map, seat states, snapshots, results, timeline),
// events.jsonl (the frame-accurate action log), traces/seat-N.jsonl (one line per
// turn: the model, the prompt version, the decisions, the reply tier).
//
// Every number is READ off the folder — nothing is re-simulated, so the tool
// cannot disagree with the record it describes.
// ---------------------------------------------------------------------------
const fs = require('fs');
const path = require('path');

const readJsonl = (p) => fs.readFileSync(p, 'utf8').split('\n').filter(l => l.trim()).map(l => {
  try { return JSON.parse(l); } catch (e) { return { _bad: true }; }
});

function load(folder) {
  return {
    folder,
    meta: JSON.parse(fs.readFileSync(path.join(folder, 'meta.json'), 'utf8')),
    transcript: readJsonl(path.join(folder, 'transcript.jsonl')),
    events: readJsonl(path.join(folder, 'events.jsonl')),
    traces: fs.readdirSync(path.join(folder, 'traces')).sort().map(f => ({
      file: f,
      lines: readJsonl(path.join(folder, 'traces', f)),
    })),
  };
}

// ---- the seat view: who played, how much they decided, what they ordered ----
function seatProfile(m) {
  return m.traces.map(t => {
    const lines = t.lines.filter(l => l.model || l.decisions);
    const model = (lines[0] && lines[0].model) || null;
    const promptVersion = (lines.find(l => l.promptVersion) || {}).promptVersion || null;
    const withDec = lines.filter(l => l.decisions && l.decisions.length);
    const orders = {};
    for (const l of withDec) for (const d of l.decisions) orders[d.order] = (orders[d.order] || 0) + 1;
    const tokens = lines.reduce((a, l) => {
      const u = l.reply && l.reply.usage;
      return u ? { p: a.p + (u.prompt_tokens || 0), c: a.c + (u.completion_tokens || 0) } : a;
    }, { p: 0, c: 0 });
    const lat = lines.map(l => l.reply && l.reply.usage && l.reply.usage.latencyMs).filter(Boolean);
    return {
      seat: t.file.match(/seat-(\d+)/)[1],
      model, promptVersion,
      turns: lines.length,
      decisionTurns: withDec.length,
      orders,
      tokens: tokens.p || tokens.c ? `${tokens.p}/${tokens.c}` : null,
      avgLatencyMs: lat.length ? Math.round(lat.reduce((a, b) => a + b, 0) / lat.length) : null,
    };
  });
}

// ---- the economy/force timeline, off the sampled states ---------------------
// One row per snapshot: the tick, then per seat the population, the four
// resources, the unit count and the explored percent (mean of map.exploration).
function timeline(m) {
  const seats = m.meta.seats;
  const rows = [];
  for (const rec of m.transcript) {
    if (!rec.state || rec.playerId === undefined) continue;
    const seat = Number(rec.playerId.replace('seat', '')) || 0;
    const st = rec.state;
    const ex = st.map && st.map.exploration;
    let seen = 0, total = 0;
    if (ex) for (const k of Object.keys(ex)) { total++; seen += ex[k]; }
    rows[rec.turn] = rows[rec.turn] || { turn: rec.turn };
    rows[rec.turn][seat] = {
      pop: st.population && `${st.population.used}/${st.population.capacityNow}`,
      res: st.resources && `${Math.round(st.resources.food)},${Math.round(st.resources.wood)},${Math.round(st.resources.stone)},${Math.round(st.resources.gold)}`,
      units: (st.friendlyUnits || []).length,
      workers: st.workers && st.workers.idle !== undefined ? `${st.workers.idle} idle` : null,
      explored: ex ? `${Math.round(seen / total)}%` : null,
    };
  }
  return rows.filter(Boolean);
}

// ---- the causal chain: for each terminal event, the orders behind it --------
// A researchCompleted is caused by the research order of the same seat whose
// detail matches the tech; a buildingFinished by the build order whose detail
// matches the type; the matchEnded by whatever the record says. The chain is
// the event and the orders that fed it, in time order — read off the record.
function chains(m, only) {
  const out = [];
  const causes = m.events.filter(e => e.type === 'order');
  for (const e of m.events) {
    const terminals = ['researchCompleted', 'buildingFinished', 'matchEnded', 'unitKilled'];
    if (!terminals.includes(e.type)) continue;
    if (only && e.type !== only) continue;
    if (e.type === 'unitKilled') {
      // the kill's chain: every damage event on a victim of this type at this
      // spot in the 10 s before the death, grouped by attacker seat, then the
      // attacker seat's last order before the first blow
      const blows = m.events.filter(d => (d.type === 'unitDamaged' || d.type === 'buildingDamaged')
        && d.victimSeat === e.seat && d.victimType === e.unitType
        && d.t <= e.t && e.t - d.t <= 10000);
      const bySeat = {};
      for (const d of blows) {
        const k = d.attackerSeat;
        (bySeat[k] = bySeat[k] || { n: 0, dmg: 0, who: d.attackerType, last: 0 });
        bySeat[k].n++; bySeat[k].dmg += d.amount; bySeat[k].last = Math.max(bySeat[k].last, d.t);
      }
      const parts = Object.keys(bySeat).map(k => {
        const v = bySeat[k];
        const lastOrder = causes.filter(o => Number(o.seat) === Number(k) && o.t <= v.last).pop();
        return `seat ${k} ${v.who} ×${v.n} (${Math.round(v.dmg)} dmg)${lastOrder ? ` — after ${lastOrder.t}:${lastOrder.order} ${lastOrder.detail || ''}`.trimEnd() : ''}`;
      });
      out.push({ at: e.t, type: e.type, seat: e.seat, what: e.unitType, fedBy: parts });
      continue;
    }
    const feed = causes.filter(c => c.seat === e.seat && c.t <= e.t && (
      (e.type === 'researchCompleted' && c.order === 'research' && c.detail === (e.tech || e.techId || e.detail)) ||
      (e.type === 'buildingFinished' && c.order === 'build' && (e.buildingType ? c.detail === e.buildingType : true)) ||
      (e.type === 'matchEnded')));
    out.push({ at: e.t, type: e.type, seat: e.seat, what: e.tech || e.techId || e.buildingType || e.reason || '', fedBy: feed.map(f => `${f.t}:${f.order} ${f.detail || ''}`.trim()) });
  }
  return out;
}

const fmtSeat = (s) => `seat ${s.seat}: ${s.model || 'rule brain'}${s.promptVersion ? ` @ ${s.promptVersion}` : ''} — decided ${s.decisionTurns}/${s.turns} turns, orders ${JSON.stringify(s.orders)}, tokens ${s.tokens || '—'}${s.avgLatencyMs ? `, ${s.avgLatencyMs} ms/turn` : ''}`;

function report(folder) {
  const m = load(folder);
  console.log(`== ${path.basename(folder)} — seed ${m.meta.seed}, ${m.meta.seats} seats, ${m.meta.difficulty}, ${m.meta.minutes}m, core ${m.meta.core}${m.meta.rulesBuild ? ` @ rules b${m.meta.rulesBuild}` : ''}`);
  for (const s of seatProfile(m)) console.log('  ' + fmtSeat(s));
  const ev = {};
  for (const e of m.events) ev[e.type] = (ev[e.type] || 0) + 1;
  console.log('  events:', JSON.stringify(ev));
  const tl = timeline(m);
  const last = tl[tl.length - 1];
  if (last) console.log('  final state per seat:', JSON.stringify(last));
  const ch = chains(m);
  for (const c of ch) console.log(`  chain @${c.at}: ${c.type}${c.what ? ' ' + c.what : ''} (seat ${c.seat}) <— ${c.fedBy.join(' <— ') || 'no recorded orders'}`);
}

function ab(aFolder, bFolder) {
  const a = load(aFolder), b = load(bFolder);
  const same = ['seed', 'difficulty', 'seats', 'minutes'].every(k => String(a.meta[k]) === String(b.meta[k]));
  console.log(`== A/B: ${path.basename(aFolder)} vs ${path.basename(bFolder)} — conditions ${same ? 'MATCH' : 'DIFFER'}${same ? '' : ` (${JSON.stringify([a.meta, b.meta].map(m => `${m.seed}/${m.difficulty}/${m.seats}seats/${m.minutes}m`))})`}`);
  const pa = seatProfile(a), pb = seatProfile(b);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i], y = pb[i];
    if (!x || !y) { console.log(`  seat ${i}: ${x ? 'A only' : 'B only'}`); continue; }
    const dDec = y.decisionTurns - x.decisionTurns;
    const modelNote = x.model !== y.model ? ` (${x.model} → ${y.model})` : '';
    console.log(`  seat ${i}${modelNote}: decisions ${x.decisionTurns} → ${y.decisionTurns} (${dDec >= 0 ? '+' : ''}${dDec}), tokens ${x.tokens || '—'} → ${y.tokens || '—'}`);
    const keys = new Set([...Object.keys(x.orders), ...Object.keys(y.orders)]);
    const orderDiff = [...keys].map(k => `${k}: ${(x.orders[k] || 0)}→${(y.orders[k] || 0)}`).filter(s => !s.endsWith(':0→0') && !/^([a-z_]+):(\d+)→\2$/.test(s));
    if (orderDiff.length) console.log('    orders ' + orderDiff.join(', '));
  }
  const evA = {}, evB = {};
  for (const e of a.events) evA[e.type] = (evA[e.type] || 0) + 1;
  for (const e of b.events) evB[e.type] = (evB[e.type] || 0) + 1;
  const eKeys = new Set([...Object.keys(evA), ...Object.keys(evB)]);
  const evDiff = [...eKeys].map(k => `${k}: ${evA[k] || 0}→${evB[k] || 0}`).filter(s => !/^([a-zA-Z]+):(\d+)→\2$/.test(s));
  console.log('  events ' + (evDiff.length ? evDiff.join(', ') : 'identical'));
  const la = timeline(a).pop(), lb = timeline(b).pop();
  if (la && lb) {
    for (let s = 0; s < a.meta.seats; s++) {
      if (!la[s] || !lb[s]) continue;
      console.log(`  final seat ${s}: A ${JSON.stringify(la[s])}`);
      console.log(`           B ${JSON.stringify(lb[s])}`);
    }
  }
}

function chain(folder, only) {
  const m = load(folder);
  const ch = chains(m, only);
  if (!ch.length) { console.log(`no ${only || 'terminal'} events in ${folder}`); return; }
  for (const c of ch) console.log(`@${c.at} ${c.type}${c.what ? ' ' + c.what : ''} (seat ${c.seat}) <— ${c.fedBy.join(' <— ') || 'no recorded orders'}`);
}

const [, , cmd, ...args] = process.argv;
if (cmd === 'report' && args[0]) report(args[0]);
else if (cmd === 'ab' && args[1]) ab(args[0], args[1]);
else if (cmd === 'chain' && args[0]) chain(args[0], args[1]);
else console.log('usage: node tools/analyze.cjs report <folder> | ab <folderA> <folderB> | chain <folder> [event-type]');
